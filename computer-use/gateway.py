#!/usr/bin/env python3
"""aibox computer use 网关:宿主机上的 LaunchAgent,容器里的 MCP 客户端只能经它碰到 Mac。

    容器 aibox-mac-mcp --TCP+token--> 本网关 --stdio--> cua-driver mcp --unix socket--> CuaDriver.app(bounded)

三层防护:
  1. 本网关:工具白名单、参数检查(launch_app、写文件的参数、run_steps 的每一步)、
     应用授权(request_access 在 Mac 上弹原生确认框)、审计日志。
  2. CuaDriver.app 以 bounded 模式运行,manifest 只列出已授权的应用,范围由驱动自己执行;
     授权变化时重写 manifest 并重启它(运行中的进程不支持热加载)。
  3. macOS 的屏幕录制 / 辅助功能权限只授给 CuaDriver.app。

用 /usr/bin/python3(命令行工具 CLT 自带,3.9)运行,只用标准库。策略相关的函数不依赖 macOS,
冒烟测试在 Linux 上直接 import 本文件测它们。

    gateway.py serve              LaunchAgent 的入口
    gateway.py resolve <应用>      解析应用名 / bundle id,输出 JSON(aibox cu allow 用)
    gateway.py register|unregister --claude-dir D --codex-dir D   写入 / 移除 MCP 配置
"""

import datetime
import hmac
import json
import os
import plistlib
import re
import signal
import socket
import subprocess
import sys
import threading
import time

PROTO = "AIBOX-CU1"
MCP_NAME = "mac"
RELAY_COMMAND = "aibox-mac-mcp"

# ---------------------------------------------------------------------------
# 工具白名单
# ---------------------------------------------------------------------------

# 透传给驱动的工具。不在这里的一律在 tools/list 里隐藏、调用时拒绝;
# 同一份清单也写进 bounded manifest 的 allow.tools,驱动那边再拦一道。
OBSERVE_TOOLS = (
    "list_windows", "get_window_state", "zoom", "verify_state", "parse_visual_regions",
    "get_screen_size", "check_permissions", "get_guide",
)
ACTION_TOOLS = (
    "launch_app", "bring_to_front", "set_window_frame", "invoke_menu", "click", "double_click",
    "right_click", "drag", "type_text", "press_key", "hotkey", "set_value", "scroll",
)
SESSION_TOOLS = ("start_session", "end_session", "get_session", "list_sessions")
DRIVER_TOOLS = OBSERVE_TOOLS + ACTION_TOOLS + SESSION_TOOLS + ("run_steps",)
# run_steps 里允许出现的步骤:驱动声明的动作工具(去掉 move_cursor),不能再嵌套 run_steps
STEP_TOOLS = frozenset({"click", "double_click", "right_click", "set_value", "type_text", "press_key", "hotkey",
                        "scroll", "drag"})

# 被拒绝时的说明(关掉的原因),没列出的统一说「aibox 未开放」
DISABLED_REASONS = {
    "list_apps": "bounded 模式下驱动不允许枚举应用。用 request_access 按应用名申请,批准后 launch_app(bundle_id=...) 拿 pid",
    "run_script": "脚本里的每一步无法逐一检查",
    "get_desktop_state": "不开放全屏截图,请用 get_window_state 截单个已授权窗口",
    "get_accessibility_tree": "会列出所有应用的窗口,不开放",
    "kill_app": "不开放强制结束进程",
    "move_cursor": "会移动用户的鼠标,不开放",
    "clipboard_read": "不开放读剪贴板",
    "clipboard_write": "不开放写剪贴板,输入文字请用 type_text",
    "set_config": "不开放修改驱动配置",
}

# 每个工具允许的参数(按 aibox 锁定的 CuaDriver 版本整理,升级驱动时对照新版的 tools/list 更新)。
# 多出来的参数一律拒绝,包括大小写、驼峰等变体。刻意不放行的参数:
#   screenshot_out_file / debug_image_out:让驱动往宿主机写文件
#   launch_app 的 name / urls / additional_arguments / webkit_inspector_port:按名字或路径启动、
#     让应用打开任意文件或 URL(例如一个 .command 脚本)、开调试端口
#   list_windows / run_steps 的 app、run_steps 的 window:按名字指定目标,绕开 pid 归属检查
#   start_session 的 capture_scope:旧版的截图范围升级
#   check_permissions 的 prompt:从工具触发系统授权弹窗
TOOL_ARGS = {
    "list_windows": ("on_screen_only", "pid", "session"),
    "get_window_state": ("capture_mode", "display_only", "full_output", "include_accessibility_tree",
                         "include_screenshot", "max_depth", "max_dimension", "max_elements",
                         "max_image_dimension", "pid", "query", "session", "since", "timeout_ms",
                         "tree_format", "verbose", "window_id"),
    "zoom": ("pid", "session", "window_id", "x1", "x2", "y1", "y2"),
    "verify_state": ("expect", "include_screenshot", "pid", "session", "stable_samples", "timeout_ms", "window_id"),
    "parse_visual_regions": ("capture_id", "options", "session"),
    "get_screen_size": ("session",),
    "check_permissions": ("probe_direct_capture", "session"),
    "get_guide": ("session", "topic"),
    "launch_app": ("bundle_id", "creates_new_application_instance", "session"),
    "bring_to_front": ("pid", "session", "window_id"),
    "set_window_frame": ("height", "pid", "session", "width", "window_id", "x", "y"),
    "invoke_menu": ("path", "pid", "session", "window_id"),
    "click": ("action", "button", "capture_id", "count", "delivery_mode", "element_token", "from_zoom",
              "modifier", "pid", "scope", "session", "target", "window_id", "x", "y"),
    "double_click": ("delivery_mode", "element_token", "pid", "session", "window_id", "x", "y"),
    "right_click": ("delivery_mode", "element_token", "modifier", "pid", "session", "window_id", "x", "y"),
    "drag": ("button", "delivery_mode", "duration_ms", "from_x", "from_y", "from_zoom", "modifier", "pid",
             "scope", "session", "steps", "target", "to_x", "to_y", "window_id"),
    "type_text": ("delay_ms", "delivery_mode", "element_token", "pid", "scope", "session", "target", "text",
                  "window_id", "x", "y"),
    "press_key": ("delivery_mode", "element_token", "key", "modifiers", "pid", "scope", "session", "target",
                  "window_id", "x", "y"),
    "hotkey": ("delivery_mode", "element_token", "keys", "pid", "scope", "session", "target", "window_id", "x", "y"),
    "set_value": ("element_token", "pid", "session", "value", "window_id"),
    "scroll": ("amount", "by", "delivery_mode", "direction", "element_token", "pid", "scope", "session", "target",
               "window_id", "x", "y"),
    "start_session": ("cursor_motion", "cursor_theme", "session"),
    "end_session": ("session",),
    "get_session": ("session",),
    "list_sessions": ("cursor", "limit"),
    "run_steps": ("delay_ms", "delivery_mode", "observe", "pid", "session", "steps", "window_id"),
}
# 不针对某个应用窗口的工具;其余工具都必须能落到一个已授权应用的 pid 上
TARGETLESS_TOOLS = frozenset({"get_screen_size", "check_permissions", "get_guide", "start_session", "end_session",
                              "get_session", "list_sessions", "parse_visual_regions"})
# run_steps 一步里除了工具名和参数之外允许的键
STEP_EXTRA_KEYS = ("wait_for", "expect", "timeout_ms")
# run_steps 的步骤参数可以按角色和名字定位元素(目标仍要落在 pid 上);按 app / window 名字指定目标的
# 写法绕开 pid 归属检查,不放行
STEP_SELECTOR_ARGS = ("role", "name", "nth")
# wait_for / expect 检查里不允许按名字指向别的应用或窗口
CHECK_TARGET_KEYS = ("app", "window")

# 参数白名单之外的第二道防线:任何层级里像是文件路径的参数名(归一成小写字母后比较)
FILE_ARG_SUFFIXES = ("outfile", "imageout", "dir", "directory", "file", "files", "filename", "filepath", "root")
FILE_ARG_NAMES = frozenset({"out", "output", "dest", "destination"})

BUNDLE_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.\-]{0,254}$")

# ---------------------------------------------------------------------------
# 应用分级:禁止清单写死在代码里,配置文件改不了
# ---------------------------------------------------------------------------

BLOCKED_BUNDLES = {
    # 终端:能直接在宿主机上执行命令
    "com.apple.Terminal": "终端", "com.googlecode.iterm2": "终端", "com.mitchellh.ghostty": "终端",
    "dev.warp.Warp-Stable": "终端", "dev.warp.Warp": "终端", "net.kovidgoyal.kitty": "终端",
    "org.alacritty": "终端", "io.alacritty": "终端", "com.github.wez.wezterm": "终端",
    "co.zeit.hyper": "终端", "com.raphaelamorim.rio": "终端", "org.tabby": "终端",
    "com.termius-dmg.mac": "终端",
    # 脚本与自动化:能运行脚本或启动任意程序
    "com.apple.ScriptEditor2": "脚本工具", "com.apple.Automator": "脚本工具",
    "com.apple.shortcuts": "脚本工具", "com.apple.ScriptMenuApp": "脚本工具",
    "com.raycast.macos": "启动器", "com.runningwithcrayons.Alfred": "启动器",
    "com.stairways.keyboardmaestro.editor": "脚本工具", "com.hegenberg.BetterTouchTool": "脚本工具",
    # 系统外壳:能打开 / 执行任意文件(在 Finder 里双击 .command 就会执行)
    "com.apple.finder": "文件管理", "com.apple.dock": "系统外壳", "com.apple.Spotlight": "系统外壳",
    "com.apple.systemuiserver": "系统外壳", "com.apple.controlcenter": "系统外壳",
    "com.apple.notificationcenterui": "系统外壳", "com.apple.loginwindow": "系统外壳",
    "com.apple.SecurityAgent": "系统外壳", "com.apple.Siri": "系统外壳",
    # 系统设置与系统工具:能改权限、装软件、抹盘
    "com.apple.systempreferences": "系统设置", "com.apple.ActivityMonitor": "系统工具",
    "com.apple.DiskUtility": "系统工具", "com.apple.installer": "系统工具",
    "com.apple.MigrateAssistant": "系统工具", "com.apple.Console": "系统工具",
    # 凭据
    "com.apple.keychainaccess": "凭据", "com.apple.Passwords": "凭据",
    "com.1password.1password": "凭据", "com.agilebits.onepassword7": "凭据",
    "com.bitwarden.desktop": "凭据", "org.keepassxc.keepassxc": "凭据",
    "com.lastpass.LastPass": "凭据",
    # 远程控制
    "com.apple.ScreenSharing": "远程控制", "com.apple.RemoteDesktop": "远程控制",
    "com.microsoft.rdc.macos": "远程控制", "com.teamviewer.TeamViewer": "远程控制",
    "com.philandro.anydesk": "远程控制",
    # IDE 与开发工具:集成终端、任务、插件都能执行命令(声明了 developer-tools 分类的另外按分类禁止)
    "com.microsoft.VSCode": "IDE", "com.microsoft.VSCodeInsiders": "IDE", "com.vscodium": "IDE",
    "com.todesktop.230313mzl4w4u92": "IDE", "com.exafunction.windsurf": "IDE", "dev.zed.Zed": "IDE",
    "dev.zed.Zed-Preview": "IDE", "com.apple.dt.Xcode": "IDE", "com.sublimetext.4": "编辑器",
    "com.sublimetext.3": "编辑器", "com.panic.Nova": "IDE", "com.barebones.bbedit": "编辑器",
    "com.github.GitHubClient": "开发工具", "com.docker.docker": "开发工具",
    "org.hammerspoon.Hammerspoon": "脚本工具", "com.apple.dt.Instruments": "开发工具",
    # 能执行命令的 AI 应用,以及驱动自己
    "com.anthropic.claudefordesktop": "AI 代理", "com.openai.chat": "AI 代理",
    "com.openai.codex": "AI 代理", "com.trycua.driver": "驱动自身",
    # 浏览器:第一版不开放(登录态、任意网页、点链接风险)
    "com.apple.Safari": "浏览器", "com.apple.SafariTechnologyPreview": "浏览器",
    "com.google.Chrome": "浏览器", "com.google.Chrome.canary": "浏览器",
    "org.mozilla.firefox": "浏览器", "org.mozilla.firefoxdeveloperedition": "浏览器",
    "com.microsoft.edgemac": "浏览器", "company.thebrowser.Browser": "浏览器",
    "company.thebrowser.dia": "浏览器", "com.brave.Browser": "浏览器",
    "com.operasoftware.Opera": "浏览器", "com.vivaldi.Vivaldi": "浏览器",
    "org.chromium.Chromium": "浏览器", "com.kagi.kagimacOS": "浏览器",
    "com.duckduckgo.macos.browser": "浏览器", "app.zen-browser.zen": "浏览器",
}
# 按前缀禁止的一类(JetBrains 全家等),以及按 Info.plist 分类禁止的开发工具(覆盖大多数 IDE 和终端)
BLOCKED_PREFIXES = (("com.jetbrains.", "IDE"), ("com.google.android.studio", "IDE"))
BLOCKED_CATEGORIES = {"public.app-category.developer-tools": "开发工具(IDE / 终端)"}


def blocked_reason(bundle_id, category=None):
    """返回禁止原因;允许时返回 None。"""
    if bundle_id in BLOCKED_BUNDLES:
        return BLOCKED_BUNDLES[bundle_id]
    lower = bundle_id.lower()
    for key, why in BLOCKED_BUNDLES.items():
        if key.lower() == lower:
            return why
    for prefix, why in BLOCKED_PREFIXES:
        if lower.startswith(prefix.lower()):
            return why
    if category and category in BLOCKED_CATEGORIES:
        return BLOCKED_CATEGORIES[category]
    return None


# ---------------------------------------------------------------------------
# 参数检查
# ---------------------------------------------------------------------------

def _file_args(args, path=""):
    """找出任何层级里像是文件路径的参数名。invoke_menu 的 path 是菜单路径,不算。"""
    found = []
    if isinstance(args, dict):
        for key, value in args.items():
            where = path + str(key)
            norm = re.sub(r"[^a-z]", "", str(key).lower())
            if norm in FILE_ARG_NAMES or (norm != "path" and norm.endswith(FILE_ARG_SUFFIXES)):
                found.append(where)
            elif isinstance(value, (dict, list)):
                found.extend(_file_args(value, where + "."))
    elif isinstance(args, list):
        for i, value in enumerate(args):
            found.extend(_file_args(value, "%s%d." % (path, i)))
    return found


def _is_pid(value):
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def _foreground(args):
    return args.get("delivery_mode") == "foreground" or bool(args.get("foreground_fallback"))


def _step_parts(step):
    """run_steps 的一步写作 {tool, args} 或 {<tool>: args},可另带 wait_for / expect / timeout_ms。
    返回 (tool, args);格式不对返回 (None, None)。"""
    if not isinstance(step, dict):
        return None, None
    if "tool" in step:
        if set(step) - {"tool", "args"} - set(STEP_EXTRA_KEYS):
            return None, None
        args = step.get("args", {})
        return (step["tool"], args) if isinstance(step["tool"], str) and isinstance(args, dict) else (None, None)
    names = [k for k in step if k not in STEP_EXTRA_KEYS]
    if not names and step:
        return "", {}   # 只做 wait_for / expect 检查的一步
    if len(names) != 1 or not isinstance(step[names[0]], dict):
        return None, None
    return names[0], step[names[0]]


def _check_step_checks(step):
    """wait_for / expect 里不能按名字指向别的应用或窗口。"""
    checks = []
    for key in ("wait_for", "expect"):
        value = step.get(key)
        if value is None:
            continue
        items = value if isinstance(value, list) else [value]
        for item in items:
            if not isinstance(item, dict):
                return "%s 必须是对象或对象数组" % key
            checks.append(item)
    for item in checks:
        bad = [k for k in CHECK_TARGET_KEYS if k in item]
        if bad:
            return "wait_for / expect 不支持 %s(只检查本步目标所在的窗口)" % ", ".join(bad)
    return None


def _check_target(name, args, granted, owner, default_pid=None):
    """非 TARGETLESS 的工具必须落到一个 pid 上,且这个 pid 属于本会话已授权的应用。"""
    pid = args.get("pid", default_pid)
    target = args.get("target")
    if target is not None:
        if not isinstance(target, dict) or target.get("kind") != "window":
            return "%s 只能作用于已授权应用的窗口,不支持桌面范围的 target" % name
        tpid = target.get("pid")
        if tpid is not None and pid is not None and tpid != pid:
            return "%s 的 pid 与 target.pid 不一致" % name
        if pid is None:
            pid = tpid
    if pid is None:
        return "%s 必须带 pid(用 element_token 时先 get_window_state,网关会补上 pid)" % name
    if not _is_pid(pid):
        return "%s 的 pid 必须是正整数" % name
    bundle = owner(pid) if owner else None
    if not bundle:
        return "pid %s 不是正在运行的应用" % pid
    if bundle not in granted:
        why = blocked_reason(bundle)
        if why:
            return "pid %s 是 %s,aibox 禁止控制这类应用(%s)" % (pid, bundle, why)
        return "pid %s 是 %s,本会话还没有授权,先调用 request_access" % (pid, bundle)
    return None


def _check_one(name, args, granted, owner, default_pid=None, extra_args=()):
    allowed = TOOL_ARGS.get(name)
    if allowed is None:
        why = DISABLED_REASONS.get(name)
        return "工具 %s 已被 aibox 禁用%s" % (name, ":" + why if why else "")
    if not isinstance(args, dict):
        return "%s 的参数必须是对象" % name
    extra = sorted(str(k) for k in args if k not in allowed and k not in extra_args)
    if extra:
        return "%s 不接受参数 %s" % (name, ", ".join(extra))
    bad = _file_args(args)
    if bad:
        return "aibox 不允许驱动往宿主机写文件(参数 %s)" % ", ".join(bad)
    if _foreground(args):
        return "aibox 不开放前台模式(delivery_mode=foreground):前台输入会落到当前前台应用或系统快捷键上"
    if name == "launch_app":
        bundle = args.get("bundle_id")
        if not isinstance(bundle, str) or not bundle:
            return "launch_app 必须用 bundle_id 指定应用;先用 request_access 申请,批准结果里有 bundle_id"
        if bundle not in granted:
            return "%s 本会话还没有授权,先调用 request_access" % bundle
        return None
    if name in TARGETLESS_TOOLS:
        return None
    return _check_target(name, args, granted, owner, default_pid)


def check_call(name, args, granted, owner=None):
    """检查一次 tools/call。granted 是本会话可用的 bundle id 集合,owner(pid) 返回该进程的 bundle id。
    通过返回 None,否则返回给 agent 看的拒绝原因。"""
    if not isinstance(name, str):
        return "工具名必须是字符串"
    if name != "run_steps":
        return _check_one(name, args, granted, owner)
    err = _check_one("run_steps", args, granted, owner) if not isinstance(args, dict) else None
    if err:
        return err
    extra = sorted(str(k) for k in args if k not in TOOL_ARGS["run_steps"])
    if extra:
        return "run_steps 不接受参数 %s" % ", ".join(extra)
    if _file_args(args):
        return "aibox 不允许驱动往宿主机写文件(参数 %s)" % ", ".join(_file_args(args))
    if _foreground(args):
        return "aibox 不开放前台模式(delivery_mode=foreground)"
    default_pid = args.get("pid")
    if default_pid is not None and not _is_pid(default_pid):
        return "run_steps 的 pid 必须是正整数"
    steps = args.get("steps")
    if not isinstance(steps, list) or not steps:
        return "run_steps 需要非空的 steps 数组"
    last_pid = default_pid
    for i, step in enumerate(steps, 1):
        tool, step_args = _step_parts(step)
        if tool is None:
            return "run_steps 第 %d 步格式不对(只能是 {tool, args} 或 {<工具>: args},可另带 %s)" % (
                i, " / ".join(STEP_EXTRA_KEYS))
        err = _check_step_checks(step)
        if err:
            return "run_steps 第 %d 步:%s" % (i, err)
        if tool == "":
            if last_pid is None:
                return "run_steps 第 %d 步:只做检查的一步需要 run_steps 顶层带 pid" % i
            continue
        if tool not in STEP_TOOLS:
            return "run_steps 第 %d 步的工具 %s 不允许" % (i, tool)
        err = _check_one(tool, step_args, granted, owner, default_pid, STEP_SELECTOR_ARGS)
        if err:
            return "run_steps 第 %d 步:%s" % (i, err)
        last_pid = step_args.get("pid", last_pid)
    observe = args.get("observe")
    if observe is not None:
        if not isinstance(observe, dict):
            return "run_steps 的 observe 必须是对象"
        err = _check_one("get_window_state", observe, granted, owner, last_pid)
        if err:
            return "run_steps 的 observe:%s" % err
    return None


# ---------------------------------------------------------------------------
# bounded manifest
# ---------------------------------------------------------------------------

MANIFEST_LIFETIME_HOURS = 24


def render_manifest(bundles):
    lines = [
        "# 由 aibox-cu-gateway 生成,每次授权变化时重写",
        "version: 3",
        "expires_after: %dh" % MANIFEST_LIFETIME_HOURS,
        "idle_timeout: %dh" % MANIFEST_LIFETIME_HOURS,
        "allow:",
        "  tools:",
    ]
    lines += ["    - %s" % t for t in DRIVER_TOOLS]
    lines += ["resources:"]
    apps = sorted(b for b in bundles if BUNDLE_ID_RE.match(b) and not blocked_reason(b))
    if apps:
        lines.append("  apps:")
        for bundle in apps:
            lines += ["    - bundle_id: %s" % bundle, "      launch: true",
                      "      windows: all", "      terminate: driver_launched"]
    else:
        lines.append("  apps: []")
    lines += ["  desktop:", "    display: false", ""]
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# 授权清单(「总是允许」持久化在 ~/.aibox/cu/allowed-apps,一行一个:bundle_id<TAB>名称)
# ---------------------------------------------------------------------------

def clean_name(name):
    """应用名来自应用包的 Info.plist,写进文件、日志和确认框前去掉控制字符(换行、制表符等)。"""
    return re.sub(r"[\x00-\x1f\x7f]+", " ", str(name)).strip()[:80] or "?"


def read_allowed(path):
    apps = {}
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                bundle, _, name = line.partition("\t")
                bundle = bundle.strip()
                if BUNDLE_ID_RE.match(bundle) and not blocked_reason(bundle):
                    apps[bundle] = clean_name(name.strip() or bundle)
    except FileNotFoundError:
        pass
    return apps


def write_allowed(path, apps):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("# aibox computer use「总是允许」的应用,一行一个:bundle_id<TAB>名称\n")
        for bundle in sorted(apps):
            if BUNDLE_ID_RE.match(bundle):
                f.write("%s\t%s\n" % (bundle, clean_name(apps[bundle])))
    os.replace(tmp, path)


# ---------------------------------------------------------------------------
# 应用解析(macOS)
# ---------------------------------------------------------------------------

# 只在这些目录里找应用:都在 Home 之外,容器挂载不到也写不进去。不认 ~/Applications 和任意路径,
# 否则容器里的 agent 可以在项目目录里伪造一个 .app(显示名写「备忘录」、bundle id 写成某个 IDE)
# 骗过确认框。
APP_DIRS = ("/Applications", "/Applications/Utilities", "/System/Applications",
            "/System/Applications/Utilities", "/System/Library/CoreServices")
TRUSTED_ROOTS = ("/Applications/", "/System/Applications/", "/System/Library/CoreServices/")


def trusted_app_path(path):
    real = os.path.realpath(path)
    return real.endswith(".app") and real.startswith(TRUSTED_ROOTS) and os.path.isdir(real)


def _app_info(path):
    try:
        with open(os.path.join(path, "Contents", "Info.plist"), "rb") as f:
            info = plistlib.load(f)
    except (OSError, plistlib.InvalidFileException, ValueError):
        return None
    bundle = info.get("CFBundleIdentifier")
    if not isinstance(bundle, str) or not BUNDLE_ID_RE.match(bundle):
        return None
    name = os.path.basename(path)[:-4] if path.endswith(".app") else path
    return {"bundle_id": bundle,
            "name": clean_name(info.get("CFBundleDisplayName") or info.get("CFBundleName") or name),
            "file_name": clean_name(name), "path": path, "category": info.get("LSApplicationCategoryType")}


def _mdfind(query):
    try:
        out = subprocess.run(["/usr/bin/mdfind", query], capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.TimeoutExpired):
        return []
    return [p for p in out.splitlines() if p.endswith(".app")]


def _quote_md(value):
    return value.replace("\\", "\\\\").replace('"', '\\"')


def resolve_app(query):
    """应用名(可本地化,如 备忘录 / Notes)或 bundle id → 安装在可信目录里的应用信息;找不到返回 None。
    不接受路径。"""
    query = (query or "").strip()
    if not query or "/" in query or len(query) > 255 or re.search(r"[\x00-\x1f]", query):
        return None
    if query.lower().endswith(".app"):
        query = query[:-4]
    is_bundle = "." in query and bool(BUNDLE_ID_RE.match(query))
    if is_bundle:
        candidates = _mdfind('kMDItemCFBundleIdentifier == "%s"c' % _quote_md(query))
    else:
        q = _quote_md(query)
        candidates = _mdfind(
            'kMDItemContentType == "com.apple.application-bundle" && '
            '(kMDItemDisplayName == "%s"cd || kMDItemDisplayName == "%s.app"cd || '
            'kMDItemAlternateNames == "%s.app"cd || kMDItemFSName == "%s.app"cd)' % (q, q, q, q))
        # Spotlight 被关掉时退回到常见目录里按文件名找(只看一层,不遍历)
        for d in APP_DIRS:
            p = os.path.join(d, query + ".app")
            if os.path.isdir(p):
                candidates.append(p)
    # 只认可信目录里的应用;常规安装位置优先,其次才是别的应用包里内嵌的副本
    candidates = [p for p in candidates if trusted_app_path(p)]
    candidates.sort(key=lambda p: (not any(p.startswith(d + "/") for d in APP_DIRS), p.count("/")))
    for path in candidates:
        info = _app_info(path)
        if info and (not is_bundle or info["bundle_id"].lower() == query.lower()):
            return info
    return None


# ---------------------------------------------------------------------------
# MCP 注册(Claude Code 的 .claude.json / settings.json,Codex 的 config.toml)
# ---------------------------------------------------------------------------

CODEX_BEGIN = "# >>> aibox cu >>>"
CODEX_END = "# <<< aibox cu <<<"
CODEX_BLOCK = """%s
# 由 aibox cu install 写入,aibox cu uninstall 移除。Mac 上的应用控制,经宿主机的 aibox 网关。
[mcp_servers.%s]
command = "%s"
default_tools_approval_mode = "approve"
startup_timeout_sec = 20
tool_timeout_sec = 300
%s
""" % (CODEX_BEGIN, MCP_NAME, RELAY_COMMAND, CODEX_END)


def _load_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except FileNotFoundError:
        return {}
    return json.loads(text) if text.strip() else {}


def _dump_json(path, data):
    tmp = path + ".aibox-tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
    try:
        os.chmod(tmp, os.stat(path).st_mode & 0o777)
    except FileNotFoundError:
        os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def _strip_codex_block(text):
    pattern = re.compile(r"\n?%s\n.*?%s\n?" % (re.escape(CODEX_BEGIN), re.escape(CODEX_END)), re.S)
    return pattern.sub("\n", text).rstrip("\n") + ("\n" if text.strip() else "")


def register(claude_dir, codex_dir):
    """写入两边的 MCP 配置;重复执行结果不变。返回提示信息列表。"""
    notes = []
    if claude_dir:
        os.makedirs(claude_dir, exist_ok=True)
        cfg_path = os.path.join(claude_dir, ".claude.json")
        cfg = _load_json(cfg_path)
        servers = cfg.setdefault("mcpServers", {})
        servers[MCP_NAME] = {"type": "stdio", "command": RELAY_COMMAND, "args": [], "env": {}}
        _dump_json(cfg_path, cfg)
        # 工具调用默认放行:人工关口是 request_access 在 Mac 上的确认框
        st_path = os.path.join(claude_dir, "settings.json")
        st = _load_json(st_path)
        allow = st.setdefault("permissions", {}).setdefault("allow", [])
        rule = "mcp__%s" % MCP_NAME
        if rule not in allow:
            allow.append(rule)
        _dump_json(st_path, st)
        notes.append("Claude Code: %s 的 mcpServers.%s,settings.json 放行 %s" % (cfg_path, MCP_NAME, rule))
    if codex_dir:
        os.makedirs(codex_dir, exist_ok=True)
        toml_path = os.path.join(codex_dir, "config.toml")
        try:
            with open(toml_path, encoding="utf-8") as f:
                text = f.read()
        except FileNotFoundError:
            text = ""
        text = _strip_codex_block(text)
        if re.search(r"^\s*\[mcp_servers\.%s\]" % re.escape(MCP_NAME), text, re.M):
            notes.append("Codex: %s 里已有自己写的 [mcp_servers.%s],未改动" % (toml_path, MCP_NAME))
        else:
            text = (text + "\n" if text else "") + CODEX_BLOCK
            tmp = toml_path + ".aibox-tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                f.write(text)
            os.replace(tmp, toml_path)
            notes.append("Codex: %s 的 [mcp_servers.%s]" % (toml_path, MCP_NAME))
    return notes


def unregister(claude_dir, codex_dir):
    if claude_dir:
        cfg_path = os.path.join(claude_dir, ".claude.json")
        if os.path.exists(cfg_path):
            cfg = _load_json(cfg_path)
            if MCP_NAME in cfg.get("mcpServers", {}) and \
                    cfg["mcpServers"][MCP_NAME].get("command") == RELAY_COMMAND:
                del cfg["mcpServers"][MCP_NAME]
                _dump_json(cfg_path, cfg)
        st_path = os.path.join(claude_dir, "settings.json")
        if os.path.exists(st_path):
            st = _load_json(st_path)
            allow = st.get("permissions", {}).get("allow", [])
            rule = "mcp__%s" % MCP_NAME
            if rule in allow:
                allow.remove(rule)
                _dump_json(st_path, st)
    if codex_dir:
        toml_path = os.path.join(codex_dir, "config.toml")
        if os.path.exists(toml_path):
            with open(toml_path, encoding="utf-8") as f:
                text = f.read()
            if CODEX_BEGIN in text:
                with open(toml_path + ".aibox-tmp", "w", encoding="utf-8") as f:
                    f.write(_strip_codex_block(text))
                os.replace(toml_path + ".aibox-tmp", toml_path)


# ---------------------------------------------------------------------------
# 网关运行期
# ---------------------------------------------------------------------------

AIBOX_NOTE = """[aibox] 这些工具操作的是宿主 Mac 上真实的应用,经 aibox 网关转给 cua-driver。
- 使用任何应用前,先调用 request_access(apps=[应用名或 bundle id], reason=一句话说明);用户在 Mac 上确认后才能用。
  批准结果里有 bundle_id,接着 launch_app(bundle_id=...) 拿到 pid 和 window_id(应用已在运行时也返回它的 pid)。
- 终端、IDE、浏览器、Finder、系统设置、密码管理、脚本工具、远程控制和 AI 应用被 aibox 禁止,不能申请;
  需要执行命令就用你自己的 shell,网页任务在容器里用无头浏览器。
- 授权变化会重启驱动:之前的 snapshot_id / element_token 全部失效,重新 get_window_state。
- 每个动作都要落在本会话已授权应用的窗口上:带 pid(用 element_token 时网关会按快照自动补上);
  不支持桌面坐标(target kind=desktop)和前台模式(delivery_mode=foreground)。
- 只认 /Applications 和系统目录里安装的应用,不接受路径。
- 不可用:list_apps、run_script、全屏截图、剪贴板、往宿主机写文件的参数(screenshot_out_file 等)。
- 不要点击邮件、消息、文档里的链接;不要替用户转账、下单或做任何涉及钱的操作。

"""

VIRTUAL_TOOLS = [
    {
        "name": "request_access",
        "description": "申请控制 Mac 上的应用。用户在 Mac 上看到确认框(拒绝 / 仅本次会话 / 总是允许),最长等 2 分钟。"
                       "批准后返回每个应用的 bundle_id;授权变化会重启驱动,之前的 element_token 失效。"
                       "只认 /Applications 和系统目录里安装的应用;终端、IDE、浏览器、Finder、系统设置等"
                       "被 aibox 禁止,不能申请。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "apps": {"type": "array", "items": {"type": "string"}, "minItems": 1, "maxItems": 5,
                         "description": "应用名(如 备忘录、Notes、计算器)或 bundle id(如 com.apple.Notes)"},
                "reason": {"type": "string", "description": "一句话说明要做什么,会显示在确认框里"},
            },
            "required": ["apps", "reason"],
            "additionalProperties": False,
        },
    },
    {
        "name": "list_granted_apps",
        "description": "列出本会话可以控制的应用(总是允许的 + 本次会话批准的)及其 bundle_id。",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
]
VIRTUAL_NAMES = frozenset(t["name"] for t in VIRTUAL_TOOLS)


# 转发给驱动的 MCP 方法白名单;其余(prompts/*、completion/* 等)一律拒绝。resources 只放行
# cua-driver 自带的说明文档。没有 method 的消息是客户端对驱动请求的回复,原样转发。
FORWARD_METHODS = frozenset({"initialize", "ping", "server/discover", "tools/list", "tools/call",
                             "resources/list", "resources/templates/list", "resources/read",
                             "logging/setLevel"})
RESOURCE_PREFIX = "skill://cua-driver/"


def method_error(msg):
    """客户端发来的消息不该转给驱动时,返回原因。"""
    method = msg.get("method")
    if method is None:
        return None if "id" in msg else "消息缺少 method"
    if not isinstance(method, str):
        return "method 必须是字符串"
    if method.startswith("notifications/"):
        return None
    if method not in FORWARD_METHODS:
        return "aibox 网关不转发 %s" % method[:80]
    if method == "resources/read":
        params = msg.get("params")
        uri = params.get("uri") if isinstance(params, dict) else None
        if not isinstance(uri, str) or not uri.startswith(RESOURCE_PREFIX) or ".." in uri:
            return "只能读取 %s 下的说明文档" % RESOURCE_PREFIX
    return None


def log(msg):
    sys.stderr.write("%s %s\n" % (datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"), msg))
    sys.stderr.flush()


def tool_result(text, is_error=False):
    result = {"content": [{"type": "text", "text": text}]}
    if is_error:
        result["isError"] = True
    return result


class Audit:
    def __init__(self, path):
        self.path = path
        self.lock = threading.Lock()

    def write(self, who, tool, target, verdict, detail=""):
        # 字段可能来自 agent(工具名、bundle id、理由),转义控制字符,防止伪造出整行假记录
        fields = [datetime.datetime.now().isoformat(timespec="seconds"), who, tool, target or "-", verdict,
                  detail[:300]]
        line = "\t".join(re.sub(r"[\x00-\x1f\x7f]", " ", str(f)) for f in fields) + "\n"
        with self.lock:
            try:
                if os.path.exists(self.path) and os.path.getsize(self.path) > 5 * 1024 * 1024:
                    os.replace(self.path, self.path + ".1")
                with open(self.path, "a", encoding="utf-8") as f:
                    f.write(line)
            except OSError as e:
                log("审计日志写入失败: %s" % e)


def describe_target(name, args):
    """审计日志里的目标:pid / bundle_id / 输入长度;不记输入的文字内容。"""
    parts = []
    if not isinstance(args, dict):
        return ""
    for key in ("bundle_id", "pid", "window_id"):
        if key in args:
            parts.append("%s=%s" % (key, str(args[key])[:80]))
    if "text" in args and isinstance(args["text"], str):
        parts.append("text_len=%d" % len(args["text"]))
    if name == "run_steps" and isinstance(args.get("steps"), list):
        parts.append("steps=%s" % ",".join(str(_step_parts(s)[0]) for s in args["steps"]))
    return " ".join(parts)


def osascript_js(script, *argv, timeout=180):
    try:
        res = subprocess.run(["/usr/bin/osascript", "-l", "JavaScript", "-e", script] + list(argv),
                             capture_output=True, text=True, timeout=timeout)
        return res.stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return ""


DIALOG_JS = """
function run(argv) {
  var app = Application.currentApplication();
  app.includeStandardAdditions = true;
  try { app.activate(); } catch (e) {}
  try {
    var r = app.displayDialog(argv[0], {withTitle: argv[1], buttons: ["拒绝", "仅本次会话", "总是允许"],
      defaultButton: "拒绝", cancelButton: "拒绝", givingUpAfter: 120, withIcon: "caution"});
    return r.gaveUp ? "timeout" : r.buttonReturned;
  } catch (e) { return "拒绝"; }
}
"""
NOTIFY_JS = """
function run(argv) {
  var app = Application.currentApplication();
  app.includeStandardAdditions = true;
  app.displayNotification(argv[0], {withTitle: argv[1]});
}
"""


class Driver:
    """管理专用的 bounded CuaDriver 常驻进程:独立 socket,与用户自己的默认实例互不干扰。"""

    def __init__(self, app, run_dir):
        self.app = app
        self.exe = os.path.join(app, "Contents", "MacOS", "cua-driver")
        self.run_dir = run_dir
        self.sock = os.path.join(run_dir, "cua.sock")
        self.pid_file = os.path.join(run_dir, "cua.pid")
        self.manifest = os.path.join(run_dir, "manifest.yaml")
        self.lock = threading.RLock()
        self.apps = None
        self.started = 0.0
        self.generation = 0

    def _status_ok(self):
        try:
            return subprocess.run([self.exe, "status", "--socket", self.sock, "--pid-file", self.pid_file],
                                  capture_output=True, timeout=10).returncode == 0
        except (OSError, subprocess.TimeoutExpired):
            return False

    def stop(self):
        with self.lock:
            try:
                subprocess.run([self.exe, "stop", "--socket", self.sock, "--pid-file", self.pid_file],
                               capture_output=True, timeout=15)
            except (OSError, subprocess.TimeoutExpired):
                pass
            for _ in range(50):
                if not self._status_ok():
                    break
                time.sleep(0.1)
            self.apps = None

    def ensure(self, apps):
        """让驱动以给定的应用白名单运行;白名单变了就重启。返回当前代号。"""
        apps = frozenset(apps)
        with self.lock:
            fresh = time.time() - self.started < (MANIFEST_LIFETIME_HOURS - 4) * 3600
            if self.apps == apps and fresh and self._status_ok():
                return self.generation
            self.stop()
            os.makedirs(self.run_dir, mode=0o700, exist_ok=True)
            tmp = self.manifest + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                f.write(render_manifest(apps))
            os.replace(tmp, self.manifest)
            # open -n:用户自己的默认实例在跑时也另起一个;经 LaunchServices 启动,
            # 屏幕录制 / 辅助功能权限归属 CuaDriver.app
            cmd = ["/usr/bin/open", "-g", "-n", "-a", self.app,
                   "--env", "CUA_DRIVER_RS_UPDATE_CHECK=0",
                   "--env", "CUA_DRIVER_RS_TELEMETRY_ENABLED=0",
                   "--env", "CUA_DRIVER_DISABLE_RUN_SCRIPT=1",
                   "--env", "CUA_DRIVER_DISABLE_UNRESTRICTED=1",
                   "--args", "serve", "--socket", self.sock, "--pid-file", self.pid_file,
                   "--permission-mode", "bounded", "--capability-manifest", self.manifest,
                   "--approve-capability-manifest"]
            subprocess.run(cmd, capture_output=True, timeout=20)
            for _ in range(100):
                if self._status_ok():
                    break
                time.sleep(0.1)
            else:
                raise RuntimeError("CuaDriver 常驻进程没有起来,运行 aibox cu doctor 排查")
            self.apps = apps
            self.started = time.time()
            self.generation += 1
            log("驱动已%s启动,第 %d 代,授权应用 %d 个" % ("重新" if self.generation > 1 else "", self.generation, len(apps)))
            return self.generation


class Gateway:
    def __init__(self, cfg):
        self.cfg = cfg
        self.driver = Driver(cfg["app"], cfg["run_dir"])
        self.audit = Audit(os.path.join(cfg["log_dir"], "audit.log"))
        self.sessions = set()
        self.lock = threading.Lock()
        self.dialog_lock = threading.Lock()
        self.notified = {}
        self.cache_lock = threading.Lock()
        self.app_cache = {}     # bundle id -> (时间, 可信目录里的应用信息或 None)
        self.pid_cache = {}     # pid -> (时间, bundle id 或 None)

    # ---- 授权 ----
    def installed(self, bundle):
        """可信目录里真实安装的这个应用(10 分钟缓存);没装或不在可信目录返回 None。"""
        now = time.time()
        with self.cache_lock:
            hit = self.app_cache.get(bundle)
            if hit and now - hit[0] < 600:
                return hit[1]
        info = resolve_app(bundle)
        if info and info["bundle_id"] != bundle:
            info = None
        with self.cache_lock:
            self.app_cache[bundle] = (now, info)
        return info

    def usable(self, apps):
        """去掉禁止的应用:按真实安装的应用复查分类,防止清单文件里混进按分类禁止的 IDE。"""
        out = {}
        for bundle, name in apps.items():
            info = self.installed(bundle)
            if info and not blocked_reason(bundle, info.get("category")):
                out[bundle] = name
        return out

    def always_apps(self):
        return read_allowed(self.cfg["allowed_file"])

    def granted(self):
        """驱动 manifest 用的全局白名单:总是允许的 + 所有在线会话批准的。"""
        apps = dict(self.always_apps())
        with self.lock:
            for s in self.sessions:
                apps.update(s.session_apps)
        return self.usable(apps)

    def session_granted(self, session):
        """某个会话可用的应用:总是允许的 + 这个会话自己批准的。网关按它检查每次调用。"""
        apps = dict(self.always_apps())
        apps.update(session.session_apps)
        return self.usable(apps)

    def owner(self, pid):
        """进程所属应用的 bundle id(5 秒缓存);不是应用返回 None。"""
        now = time.time()
        with self.cache_lock:
            hit = self.pid_cache.get(pid)
            if hit and now - hit[0] < 5:
                return hit[1]
        bundle = None
        try:
            out = subprocess.run(["/usr/bin/lsappinfo", "info", "-only", "bundleid", str(int(pid))],
                                 capture_output=True, text=True, timeout=5).stdout
            m = re.search(r'"CFBundleIdentifier"="([^"]+)"', out)
            bundle = m.group(1) if m else None
        except (OSError, subprocess.TimeoutExpired, ValueError):
            pass
        with self.cache_lock:
            self.pid_cache[pid] = (now, bundle)
        return bundle

    def ensure_driver(self):
        return self.driver.ensure(self.granted().keys())

    def token(self):
        try:
            with open(self.cfg["token_file"], encoding="utf-8") as f:
                return f.read().strip()
        except OSError:
            return ""

    def notify(self, label):
        now = time.time()
        if now - self.notified.get(label, 0) < 600:
            return
        self.notified[label] = now
        threading.Thread(target=osascript_js, args=(NOTIFY_JS, "容器 %s 连上了 Mac 应用控制" % label, "aibox"),
                         daemon=True).start()

    def ask(self, label, apps, reason):
        lines = ["容器「%s」里的 AI 请求控制这些应用:" % label, ""]
        lines += ["  · %s(%s)\n     %s" % (a["name"], a["bundle_id"], a["path"]) for a in apps]
        lines += ["", "理由(由 AI 填写):%s" % re.sub(r"[\x00-\x1f\x7f]+", " ", reason).strip()[:300], "",
                  "批准后它可以在这些应用里点击、输入和截取窗口,应用能做的事它都能做"
                  "(例如通过「存储」对话框写文件)。"]
        with self.dialog_lock:
            answer = osascript_js(DIALOG_JS, "\n".join(lines), "aibox · Mac 应用控制")
        return {"总是允许": "always", "仅本次会话": "session"}.get(answer, "deny")

    def add_session(self, s):
        with self.lock:
            self.sessions.add(s)

    def remove_session(self, s):
        with self.lock:
            self.sessions.discard(s)
            idle = not self.sessions
        if s.session_apps:
            # 收回本次会话的授权:下一次调用时驱动按新白名单重启;没人连着就立刻重启
            if idle:
                try:
                    self.ensure_driver()
                except Exception as e:
                    log("收回会话授权时重启驱动失败: %s" % e)

    # ---- 监听 ----
    def serve(self):
        os.makedirs(self.cfg["log_dir"], exist_ok=True)
        srv = None
        while srv is None:
            try:
                srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                srv.bind((self.cfg["bind"], self.cfg["port"]))
                srv.listen(16)
            except OSError as e:
                # 容器网络的网卡(bridge100)还没起来时地址不可用,等它出现
                log("暂时无法监听 %s:%d(%s),5 秒后重试" % (self.cfg["bind"], self.cfg["port"], e))
                srv.close()
                srv = None
                time.sleep(5)
        log("监听 %s:%d" % (self.cfg["bind"], self.cfg["port"]))
        while True:
            conn, addr = srv.accept()
            threading.Thread(target=self.handle, args=(conn, addr), daemon=True).start()

    def handle(self, conn, addr):
        try:
            conn.settimeout(10)
            f = conn.makefile("rb")
            line = f.readline(512).decode("utf-8", "replace").strip()
            if not line:
                # 端口探测(nc -z)连上就断,不算拒绝
                conn.close()
                return
            parts = line.split(" ", 2)
            expected = self.token()
            if len(parts) < 2 or parts[0] != PROTO or not expected or \
                    not hmac.compare_digest(parts[1].encode(), expected.encode()):
                log("拒绝来自 %s 的连接(token 不对)" % addr[0])
                conn.sendall(("%s DENIED token\n" % PROTO).encode())
                conn.close()
                return
            label = re.sub(r"[^\w.\-@]", "_", parts[2] if len(parts) > 2 else "")[:64] or addr[0]
            conn.settimeout(None)
            # 容器被强杀时连接可能一直挂着,本会话的授权也就收不回来;用 keepalive 尽快发现
            conn.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
            for opt, val in (("TCP_KEEPALIVE", 60), ("TCP_KEEPIDLE", 60), ("TCP_KEEPINTVL", 15), ("TCP_KEEPCNT", 4)):
                if hasattr(socket, opt):
                    try:
                        conn.setsockopt(socket.IPPROTO_TCP, getattr(socket, opt), val)
                    except OSError:
                        pass
            conn.sendall(("%s OK\n" % PROTO).encode())
            Session(self, conn, f, "%s@%s" % (label, addr[0]), label).run()
        except Exception as e:
            log("连接 %s 异常结束: %s" % (addr[0], e))
            try:
                conn.close()
            except OSError:
                pass


class Child:
    def __init__(self, proc, generation):
        self.proc = proc
        self.generation = generation
        self.pending = {}          # 已转发、等驱动回复的客户端请求:id 的 JSON -> 方法名
        self.waiters = {}          # 网关自己发的内部请求:id -> [Event, 回复]
        self.lock = threading.Lock()

    def alive(self):
        return self.proc.poll() is None


class Session:
    """一个容器连接。客户端的消息逐条检查后转给自己的 cua-driver mcp 子进程。"""

    def __init__(self, gw, conn, rfile, who, label):
        self.gw = gw
        self.conn = conn
        self.rfile = rfile
        self.who = who
        self.label = label
        self.send_lock = threading.Lock()
        self.child = None
        self.child_lock = threading.RLock()
        self.init_params = None
        self.session_apps = {}
        self.internal_id = 0
        # bounded 模式下只带 element_token 的动作会被当成「桌面范围的输入」拒绝,需要 pid。
        # 记下每个快照属于哪个 pid,调用时替 agent 补上。快照 id 只在同一个驱动子进程内有效。
        self.snapshots = {}
        self.snapshot_watch = {}
        self.stateless = False

    # ---- 发给容器 ----
    def send(self, msg):
        data = (json.dumps(msg, ensure_ascii=False) + "\n").encode("utf-8")
        with self.send_lock:
            try:
                self.conn.sendall(data)
            except OSError:
                pass

    def reply(self, msg_id, result):
        # 无状态的新版协议(2026-07-28 起,请求的 _meta 里带协议版本)要求结果带 resultType;
        # 转发自驱动的结果本来就有,这里补的是网关自己生成的结果
        if self.stateless and isinstance(result, dict):
            result.setdefault("resultType", "complete")
        self.send({"jsonrpc": "2.0", "id": msg_id, "result": result})

    def reply_error(self, msg_id, code, message):
        self.send({"jsonrpc": "2.0", "id": msg_id, "error": {"code": code, "message": message}})

    # ---- 驱动子进程 ----
    def fill_pid(self, args):
        tok = args.get("element_token")
        if isinstance(tok, str) and "pid" not in args and "target" not in args:
            pid = self.snapshots.get(tok.split(":", 1)[0])
            if pid is not None:
                args["pid"] = pid

    def _spawn(self):
        self.snapshots = {}
        gen = self.gw.ensure_driver()
        proc = subprocess.Popen([self.gw.driver.exe, "mcp", "--socket", self.gw.driver.sock],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        child = Child(proc, gen)
        threading.Thread(target=self.pump, args=(child,), daemon=True).start()
        return child

    def ensure_child(self, replay=True):
        """子进程不在了、或驱动已按新白名单重启过,就重建子进程并重放 initialize 握手。"""
        with self.child_lock:
            desired = frozenset(self.gw.granted())
            if self.gw.driver.apps != desired:
                self.gw.ensure_driver()
            c = self.child
            if c and c.alive() and c.generation == self.gw.driver.generation:
                return c
            if c and c.alive():
                c.proc.kill()
            c = self._spawn()
            self.child = c
            if replay and self.init_params is not None:
                try:
                    self.internal(c, "initialize", self.init_params)
                    self.write_child(c, {"jsonrpc": "2.0", "method": "notifications/initialized"})
                except Exception:
                    # 握手没完成的子进程不能留着接后续请求
                    c.proc.kill()
                    self.child = None
                    raise
            return c

    def write_child(self, child, msg):
        data = (json.dumps(msg, ensure_ascii=False) + "\n").encode("utf-8")
        child.proc.stdin.write(data)
        child.proc.stdin.flush()

    def internal(self, child, method, params, timeout=30):
        with child.lock:
            self.internal_id += 1
            mid = "aibox-%d" % self.internal_id
            slot = [threading.Event(), None]
            child.waiters[mid] = slot
        self.write_child(child, {"jsonrpc": "2.0", "id": mid, "method": method, "params": params})
        if not slot[0].wait(timeout):
            raise RuntimeError("驱动 %s 超时" % method)
        if slot[1] is None or "error" in slot[1]:
            raise RuntimeError("驱动 %s 失败: %s" % (method, (slot[1] or {}).get("error")))
        return slot[1]["result"]

    def pump(self, child):
        for raw in child.proc.stdout:
            try:
                self.pump_one(child, raw)
            except Exception as e:
                log("%s 处理驱动输出出错: %s" % (self.who, e))
        # 子进程退出(驱动重启会让它退出):还没回复的请求回一个错误,免得客户端一直等
        with child.lock:
            pending, child.pending = child.pending, {}
            for slot in child.waiters.values():
                slot[0].set()
        for key in pending:
            self.reply_error(json.loads(key), -32000, "aibox:驱动已重启或退出,请重试这次调用")

    def pump_one(self, child, raw):
        try:
            msg = json.loads(raw)
        except ValueError:
            return
        if not isinstance(msg, dict):
            return
        mid = msg.get("id")
        if "method" not in msg and mid is not None:
            with child.lock:
                slot = child.waiters.pop(mid, None) if isinstance(mid, str) else None
                method = child.pending.pop(json.dumps(mid), None)
            if slot:
                slot[1] = msg
                slot[0].set()
                return
            if method in ("initialize", "server/discover") and isinstance(msg.get("result"), dict):
                # 旧协议在 initialize 里给说明,无状态的新协议在 server/discover 里给
                res = msg["result"]
                res["instructions"] = AIBOX_NOTE + (res.get("instructions") or "")
            elif method in ("tools/list", "tools/list+page") and isinstance(msg.get("result"), dict):
                # 转发的是客户端自己的请求(新版 MCP 要求每个请求带客户端的元数据,网关不能自己合成),
                # 在回复里过滤工具清单;网关自己的工具只加在第一页
                res = msg["result"]
                res["tools"] = [t for t in res.get("tools") or [] if t.get("name") in DRIVER_TOOLS]
                if method == "tools/list":
                    res["tools"] += VIRTUAL_TOOLS
            pid = self.snapshot_watch.pop(json.dumps(mid), None)
            if pid is not None and isinstance(msg.get("result"), dict):
                snap = (msg["result"].get("structuredContent") or {}).get("snapshot_id")
                if not snap:
                    texts = " ".join(c.get("text", "") for c in msg["result"].get("content") or []
                                     if isinstance(c, dict))
                    m = re.search(r"snapshot_id=(\S+)", texts)
                    snap = m.group(1) if m else None
                if snap:
                    self.snapshots[snap] = pid
        self.send(msg)

    def forward(self, msg):
        is_req = "id" in msg and "method" in msg
        method = msg.get("method")
        if method == "tools/list" and (msg.get("params") or {}).get("cursor"):
            method = "tools/list+page"
        for attempt in (1, 2):
            c = self.ensure_child(replay=msg.get("method") != "initialize")
            if is_req:
                with c.lock:
                    c.pending[json.dumps(msg["id"])] = method
            try:
                self.write_child(c, msg)
                return
            except (BrokenPipeError, OSError):
                if is_req:
                    with c.lock:
                        c.pending.pop(json.dumps(msg["id"]), None)
                if attempt == 2:
                    raise

    # ---- 工具 ----
    def call_tool(self, msg):
        params = msg.get("params")
        mid = msg.get("id")
        if not isinstance(params, dict):
            self.reply_error(mid, -32602, "tools/call 的 params 必须是对象")
            return
        name = params.get("name")
        args = params.get("arguments")
        if args is None:
            args = params["arguments"] = {}
        if not isinstance(args, dict):
            self.reply(mid, tool_result("arguments 必须是对象", is_error=True))
            return
        if name == "request_access":
            self.reply(mid, self.request_access(args))
            return
        if name == "list_granted_apps":
            apps = self.gw.session_granted(self)
            text = "\n".join("%s\t%s" % (b, n) for b, n in sorted(apps.items())) or "目前没有授权任何应用"
            self.reply(mid, tool_result(text))
            return
        self.fill_pid(args)
        if name == "run_steps" and "pid" not in args and isinstance(args.get("steps"), list):
            for step in args["steps"]:
                step_args = _step_parts(step)[1]
                if isinstance(step_args, dict):
                    self.fill_pid(step_args)
        err = check_call(name, args, self.gw.session_granted(self), self.gw.owner)
        target = describe_target(name, args)
        if err:
            self.gw.audit.write(self.who, str(name), target, "拒绝", err)
            self.reply(mid, tool_result(err, is_error=True))
            return
        self.gw.audit.write(self.who, name, target, "放行")
        if name == "get_window_state" and _is_pid(args.get("pid")):
            self.snapshot_watch[json.dumps(mid)] = args["pid"]
        self.forward(msg)

    def request_access(self, args):
        names = args.get("apps")
        reason = args.get("reason") or ""
        if not isinstance(names, list) or not names or len(names) > 5:
            return tool_result("apps 需要 1 到 5 个应用名或 bundle id", is_error=True)
        granted = self.gw.session_granted(self)
        lines, ask, failed = [], [], False
        for q in names:
            info = resolve_app(q) if isinstance(q, str) else None
            if not info:
                lines.append("%s:找不到这个应用(只认 /Applications 和系统目录里安装的应用,不接受路径)"
                             % re.sub(r"[\x00-\x1f\x7f]+", " ", str(q))[:80])
                failed = True
                continue
            why = blocked_reason(info["bundle_id"], info.get("category"))
            if why:
                lines.append("%s(%s):aibox 禁止控制这类应用(%s)" % (info["name"], info["bundle_id"], why))
                self.gw.audit.write(self.who, "request_access", info["bundle_id"], "禁止", why)
                failed = True
                continue
            if info["bundle_id"] in granted:
                lines.append("%s:已授权,bundle_id=%s" % (info["name"], info["bundle_id"]))
                continue
            ask.append(info)
        if ask:
            answer = self.gw.ask(self.label, ask, reason)
            ids = " ".join(a["bundle_id"] for a in ask)
            self.gw.audit.write(self.who, "request_access", ids, answer, reason)
            if answer == "deny":
                lines += ["%s:用户拒绝或没有回应" % a["name"] for a in ask]
                failed = True
            else:
                if answer == "always":
                    always = self.gw.always_apps()
                    always.update({a["bundle_id"]: a["name"] for a in ask})
                    write_allowed(self.gw.cfg["allowed_file"], always)
                else:
                    self.session_apps.update({a["bundle_id"]: a["name"] for a in ask})
                scope = "总是允许" if answer == "always" else "仅本次会话"
                lines += ["%s:已批准(%s),bundle_id=%s" % (a["name"], scope, a["bundle_id"]) for a in ask]
                self.ensure_child()
                lines.append("驱动已按新的授权重启:之前的 snapshot_id / element_token 已失效,请重新 get_window_state。")
        return tool_result("\n".join(lines), is_error=failed and not any("已批准" in l or "已授权" in l for l in lines))

    # ---- 主循环 ----
    def run(self):
        self.gw.add_session(self)
        self.gw.notify(self.label)
        log("连接 %s" % self.who)
        try:
            for raw in self.rfile:
                try:
                    msg = json.loads(raw)
                except ValueError:
                    continue
                if not isinstance(msg, dict):
                    continue
                method = msg.get("method")
                mid = msg.get("id")
                meta = (msg.get("params") or {}).get("_meta") if isinstance(msg.get("params"), dict) else None
                self.stateless = isinstance(meta, dict) and "io.modelcontextprotocol/protocolVersion" in meta
                try:
                    err = method_error(msg)
                    if err:
                        if mid is not None:
                            self.reply_error(mid, -32601, err)
                    elif method == "initialize":
                        self.init_params = msg.get("params") or {}
                        self.forward(msg)
                    elif method == "tools/call":
                        self.call_tool(msg)
                    else:
                        self.forward(msg)
                except Exception as e:
                    log("%s 处理 %s 出错: %s" % (self.who, method, e))
                    if mid is not None and method:
                        self.reply_error(mid, -32603, "aibox 网关出错:%s" % e)
        finally:
            log("断开 %s" % self.who)
            with self.child_lock:
                if self.child and self.child.alive():
                    self.child.proc.kill()
            self.gw.remove_session(self)
            try:
                self.conn.close()
            except OSError:
                pass


def load_config():
    env = os.environ
    state = env.get("AIBOX_CU_STATE") or os.path.expanduser("~/.aibox/cu")
    run_dir = env.get("AIBOX_CU_RUN_DIR")
    if not run_dir:
        try:
            tmp = subprocess.run(["/usr/bin/getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True,
                                 text=True, timeout=5).stdout.strip()
        except (OSError, subprocess.TimeoutExpired):
            tmp = ""
        run_dir = os.path.join(tmp or env.get("TMPDIR", "/tmp"), "aibox-cu")
    return {
        "app": env.get("AIBOX_CU_APP", "/Applications/CuaDriver.app"),
        "bind": env.get("AIBOX_CU_BIND", "192.168.64.1"),
        "port": int(env.get("AIBOX_CU_PORT", "47123")),
        "state": state,
        "token_file": os.path.join(state, "client", "token"),
        "allowed_file": os.path.join(state, "allowed-apps"),
        "run_dir": run_dir,
        "log_dir": env.get("AIBOX_CU_LOG_DIR") or os.path.expanduser("~/Library/Logs/aibox-cu"),
    }


def main(argv):
    if len(argv) >= 2 and argv[1] == "serve":
        gw = Gateway(load_config())

        def stop(signum, frame):
            log("收到信号 %d,停止驱动后退出" % signum)
            gw.driver.stop()
            os._exit(0)

        signal.signal(signal.SIGTERM, stop)
        signal.signal(signal.SIGINT, stop)
        gw.serve()
        return 0
    if len(argv) == 3 and argv[1] == "resolve":
        info = resolve_app(argv[2])
        if not info:
            print(json.dumps({"error": "找不到应用 %s" % argv[2]}, ensure_ascii=False))
            return 1
        info["blocked"] = blocked_reason(info["bundle_id"], info.get("category"))
        print(json.dumps(info, ensure_ascii=False))
        return 0
    if len(argv) >= 2 and argv[1] in ("register", "unregister"):
        opts = dict(zip(argv[2::2], argv[3::2]))
        claude_dir, codex_dir = opts.get("--claude-dir"), opts.get("--codex-dir")
        if argv[1] == "register":
            for note in register(claude_dir, codex_dir):
                print(note)
        else:
            unregister(claude_dir, codex_dir)
        return 0
    if len(argv) >= 2 and argv[1] == "manifest":
        sys.stdout.write(render_manifest(argv[2:]))
        return 0
    if len(argv) >= 2 and argv[1] in ("apps", "allow", "revoke"):
        return manage_apps(argv[1], argv[2:], load_config())
    sys.stderr.write(__doc__)
    return 2


def manage_apps(action, args, cfg):
    """aibox cu apps / allow <应用> / revoke <应用>:管理「总是允许」清单。网关在下一次调用时按新清单重启驱动。"""
    path = cfg["allowed_file"]
    apps = read_allowed(path)
    if action == "apps":
        print("总是允许(%s):" % path.replace(os.path.expanduser("~"), "~", 1))
        for bundle, name in sorted(apps.items(), key=lambda kv: kv[1]):
            print("  %s\t%s" % (name, bundle))
        if not apps:
            print("  (无)")
        print("本次会话批准的应用只在网关内存里,连接断开即收回。")
        print("禁止控制(写死在代码里,不能授权):终端、IDE 等开发工具、浏览器、Finder 等系统外壳、"
              "系统设置与系统工具、密码类、脚本与启动器、远程控制、AI 应用。")
        return 0
    if len(args) != 1:
        sys.stderr.write("用法: aibox cu %s <应用名或 bundle id>\n" % action)
        return 2
    query = args[0]
    if action == "revoke":
        hit = [b for b, n in apps.items() if query.lower() in (b.lower(), n.lower())]
        if not hit:
            info = resolve_app(query)
            hit = [info["bundle_id"]] if info and info["bundle_id"] in apps else []
        if not hit:
            sys.stderr.write("「总是允许」清单里没有 %s\n" % query)
            return 1
        for b in hit:
            print("已收回:%s(%s)" % (apps.pop(b), b))
        write_allowed(path, apps)
        return 0
    info = resolve_app(query)
    if not info:
        sys.stderr.write("找不到应用 %s(可以写应用名、bundle id 或 .app 路径)\n" % query)
        return 1
    why = blocked_reason(info["bundle_id"], info.get("category"))
    if why:
        sys.stderr.write("%s(%s)属于禁止控制的应用:%s\n" % (info["name"], info["bundle_id"], why))
        return 1
    apps[info["bundle_id"]] = info["name"]
    os.makedirs(os.path.dirname(path), exist_ok=True)
    write_allowed(path, apps)
    print("已加入「总是允许」:%s(%s)" % (info["name"], info["bundle_id"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

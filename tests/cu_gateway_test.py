#!/usr/bin/env python3
"""Mac 应用控制(aibox cu)的单元测试:网关的策略函数、manifest、MCP 注册,以及容器侧转发器。

不需要 macOS:网关里依赖 macOS 的部分(驱动进程、确认框、Spotlight)不在这里测,
由 computer-use/README.md「验证」一节的真机端到端测试覆盖。由 tests/smoke.sh 调用。
"""

import importlib.util
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import threading
import unittest

sys.dont_write_bytecode = True

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GATEWAY = os.path.join(ROOT, "computer-use", "gateway.py")
RELAY = os.path.join(ROOT, "computer-use", "aibox-mac-mcp")

spec = importlib.util.spec_from_file_location("cu_gateway", GATEWAY)
gw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gw)

GRANTED = {"com.apple.calculator": "Calculator"}
# pid -> bundle id,模拟 lsappinfo
PIDS = {11: "com.apple.calculator", 22: "com.apple.Notes", 33: "com.apple.Terminal"}


def owner(pid):
    return PIDS.get(pid)


# element_token -> 网关读到过的行的角色
ROWS = {"s1:2": "AXButton", "s1:3": "AXTextField", "s1:9": "AXMenuItem", "s1:10": "AXMenuBarItem"}


def rows(token):
    return ROWS.get(token)


class PolicyTest(unittest.TestCase):
    def allowed(self, name, args):
        self.assertIsNone(gw.check_call(name, args, GRANTED, owner, rows), "%s %r 应该放行" % (name, args))

    def denied(self, name, args, words):
        err = gw.check_call(name, args, GRANTED, owner, rows)
        self.assertIsNotNone(err, "%s %r 应该拒绝" % (name, args))
        self.assertIn(words, err)

    def test_whitelist(self):
        self.allowed("get_window_state", {"pid": 11, "window_id": 2})
        self.allowed("invoke_menu", {"pid": 11, "window_id": 2, "path": ["File", "Save"]})
        self.allowed("get_screen_size", {})
        for name in ("run_script", "list_apps", "get_desktop_state", "get_accessibility_tree", "kill_app",
                     "clipboard_read", "clipboard_write", "set_config", "move_cursor", "browser_navigate",
                     "start_recording", "replay_trajectory", "install_extension", "set_agent_cursor_enabled",
                     "Click", "tools/call"):
            self.denied(name, {}, "禁用")
        self.denied(None, {}, "字符串")

    def test_unknown_args(self):
        # 参数白名单:大小写、驼峰等变体一律拒绝
        for key in ("screenshotOutFile", "SCREENSHOT_OUT_FILE", "output", "filename", "Pid", "urls"):
            self.denied("get_window_state", {"pid": 11, "window_id": 2, key: "x"}, "不接受参数")
        self.denied("start_session", {"capture_scope": "desktop"}, "不接受参数")
        self.denied("list_windows", {"app": "Terminal"}, "不接受参数")

    def test_file_writing_args(self):
        self.denied("get_window_state", {"pid": 11, "window_id": 2, "screenshot_out_file": "/tmp/x"}, "不接受参数")
        self.denied("click", {"pid": 11, "element_token": "s1:2", "debug_image_out": "~/x.png"}, "不接受参数")
        # 嵌套对象里的写文件参数(白名单只管第一层,第二道防线管任意层)
        self.denied("click", {"pid": 11, "target": {"kind": "window", "pid": 11, "output_dir": "/"}}, "写文件")
        self.allowed("get_window_state", {"pid": 11, "window_id": 2, "full_output": True})

    def test_pid_ownership(self):
        self.denied("click", {"element_token": "s1:2"}, "必须带 pid")
        self.denied("click", {"pid": 22, "x": 1, "y": 1}, "本会话还没有授权")
        self.denied("click", {"pid": 33, "x": 1, "y": 1}, "禁止控制")
        self.denied("click", {"pid": 999, "x": 1, "y": 1}, "不是正在运行的应用")
        self.denied("click", {"pid": True, "x": 1, "y": 1}, "正整数")
        self.denied("zoom", {"window_id": 1, "x1": 0, "y1": 0, "x2": 1, "y2": 1}, "必须带 pid")
        self.denied("click", {"target": {"kind": "desktop", "display_id": "primary"}, "x": 1, "y": 1}, "桌面")
        self.denied("click", {"pid": 11, "target": {"kind": "window", "pid": 22}}, "不一致")
        self.allowed("click", {"target": {"kind": "window", "pid": 11, "window_id": 2}, "x": 1, "y": 1})

    def test_foreground(self):
        self.denied("hotkey", {"pid": 11, "keys": ["cmd", "space"], "delivery_mode": "foreground"}, "前台")
        self.denied("run_steps", {"pid": 11, "foreground_fallback": True, "steps": [{"click": {"x": 1, "y": 1}}]},
                    "不接受参数")
        self.denied("run_steps", {"pid": 11, "delivery_mode": "foreground", "steps": [{"click": {"x": 1, "y": 1}}]},
                    "前台")
        self.denied("run_steps", {"steps": [{"type_text": {"pid": 11, "text": "x", "delivery_mode": "foreground"}}]},
                    "前台")

    def test_launch_app(self):
        self.allowed("launch_app", {"bundle_id": "com.apple.calculator"})
        self.denied("launch_app", {"bundle_id": "com.apple.Terminal"}, "还没有授权")
        self.denied("launch_app", {"name": "Calculator"}, "不接受参数")
        self.denied("launch_app", {"bundle_id": "com.apple.calculator", "urls": ["/tmp/x.command"]}, "不接受参数")
        self.denied("launch_app", {"bundle_id": "com.apple.calculator", "additional_arguments": ["-x"]}, "不接受参数")

    def test_misc_args(self):
        self.denied("list_windows", {}, "必须带 pid")
        self.denied("check_permissions", {"prompt": True}, "不接受参数")
        self.allowed("check_permissions", {})
        self.denied("click", "x", "对象")

    def test_run_steps(self):
        self.allowed("run_steps", {"steps": [{"tool": "click", "args": {"pid": 11}}, {"type_text": {"text": "x", "pid": 11}}]})
        self.allowed("run_steps", {"pid": 11, "steps": [{"tool": "click", "args": {"element_token": "s1:2"}}],
                                   "observe": {"include_screenshot": True}})
        self.denied("run_steps", {"steps": []}, "非空")
        self.denied("run_steps", {"steps": [{"tool": "run_steps", "args": {}}]}, "不允许")
        self.denied("run_steps", {"steps": [{"tool": "run_script", "args": {}}]}, "不允许")
        self.denied("run_steps", {"steps": [{"click": {"pid": 11}}, {"launch_app": {"bundle_id": "com.apple.Terminal"}}]},
                    "第 2 步")
        self.denied("run_steps", {"steps": [{"tool": "get_window_state",
                                             "args": {"pid": 11, "window_id": 2, "screenshot_out_file": "x"}}]}, "写文件")
        # 审查发现的两种夹带写法
        self.denied("run_steps", {"steps": [{"tool": "launch_app", "args": {"bundle_id": "com.apple.calculator"},
                                             "arguments": {"bundle_id": "com.apple.Terminal", "urls": ["/x"]}}]}, "格式不对")
        self.denied("run_steps", {"steps": [{"tool": "click", "args": {"pid": 11},
                                             "launch_app": {"bundle_id": "com.apple.Terminal"}}]}, "格式不对")
        self.denied("run_steps", {"steps": [{"tool": "click", "args": "x"}]}, "格式不对")
        # 按角色和名字定位元素可以;按 app / window 名字指定目标不行
        self.allowed("run_steps", {"pid": 11, "steps": [{"click": {"role": "button", "name": "7", "nth": 0}},
                                                        {"expect": [{"text": "7"}]}]})
        self.denied("run_steps", {"steps": [{"click": {"role": "button", "name": "7"}}]}, "必须带 pid")
        self.denied("run_steps", {"pid": 11, "steps": [{"click": {"app": "Terminal", "role": "button"}}]}, "不接受参数")
        self.denied("run_steps", {"pid": 11, "steps": [{"click": {"name": "7"}, "expect": [{"app": "Terminal",
                                                                                         "text": "x"}]}]}, "expect")
        self.denied("run_steps", {"steps": [{"wait_for": {"text": "x"}}]}, "顶层带 pid")
        self.denied("run_steps", {"pid": 11, "steps": [{"move_cursor": {"x": 1, "y": 1}}]}, "不允许")
        self.denied("click", {"pid": 11, "role": "button", "name": "7"}, "不接受参数")
        self.denied("run_steps", {"app": "Terminal", "steps": [{"click": {"x": 1, "y": 1}}]}, "不接受参数")
        self.denied("run_steps", {"pid": 22, "steps": [{"click": {"x": 1, "y": 1}}]}, "本会话还没有授权")
        self.denied("run_steps", {"pid": 11, "steps": [{"click": {"x": 1, "y": 1}}],
                                  "observe": {"pid": 22, "window_id": 1}}, "observe")
        self.denied("run_steps", {"pid": 11, "steps": [{"click": {"x": 1}}],
                                  "observe": {"screenshot_out_file": "/x"}}, "observe")

    def test_blocked_apps(self):
        for bundle, category in (("com.apple.Terminal", None), ("com.googlecode.iterm2", None),
                                 ("com.apple.finder", None), ("com.apple.Safari", None),
                                 ("com.apple.systempreferences", None), ("com.1password.1password", None),
                                 ("com.jetbrains.intellij", None), ("COM.APPLE.TERMINAL", None),
                                 ("com.microsoft.VSCode", None), ("com.todesktop.230313mzl4w4u92", None),
                                 ("dev.zed.Zed", None), ("com.apple.dt.Xcode", None),
                                 ("com.example.editor", "public.app-category.developer-tools"),
                                 ("com.trycua.driver", None), ("com.openai.chat", None)):
            self.assertIsNotNone(gw.blocked_reason(bundle, category), bundle)
        self.assertIsNone(gw.blocked_reason("com.apple.Notes", "public.app-category.productivity"))
        self.assertIsNone(gw.blocked_reason("com.apple.calculator"))

    def test_tool_tables_consistent(self):
        self.assertEqual(set(gw.TOOL_ARGS), set(gw.DRIVER_TOOLS))
        for name in gw.DRIVER_TOOLS:
            self.assertNotIn(name, gw.DISABLED_REASONS)
            for arg in gw.TOOL_ARGS[name]:
                self.assertEqual(gw._file_args({arg: 1}), [], "%s.%s 被误判成写文件参数" % (name, arg))
        self.assertNotIn("run_steps", gw.STEP_TOOLS)


class MenuAndKeysTest(unittest.TestCase):
    def check(self, name, args):
        return gw.check_call(name, args, GRANTED, owner, rows)

    def test_menu_paths(self):
        self.assertIsNone(self.check("invoke_menu", {"pid": 11, "window_id": 1, "path": ["控制", "播放"]}))
        for path in (["Apple", "关机"], [" apple ", "重新启动"], ["网易云音乐", "服务", "x"],
                     ["App", "Services", "New Terminal at Folder"], [""], []):
            self.assertIsNotNone(self.check("invoke_menu", {"pid": 11, "window_id": 1, "path": path}), path)

    def test_tokens(self):
        self.assertIsNone(self.check("click", {"pid": 11, "element_token": "s1:2"}))
        self.assertIn("菜单", self.check("click", {"pid": 11, "element_token": "s1:9"}))
        self.assertIn("菜单", self.check("click", {"pid": 11, "element_token": "s1:10"}))
        self.assertIn("读到过", self.check("click", {"pid": 11, "element_token": "s1:61"}))
        self.assertIn("读到过", self.check("type_text", {"pid": 11, "text": "x", "element_token": "s9:3"}))
        err = gw.check_call("run_steps", {"pid": 11, "steps": [{"click": {"element_token": "s1:9"}}]},
                            GRANTED, owner, rows)
        self.assertIn("菜单", err)

    def test_name_selectors(self):
        run = lambda a: gw.check_call("run_steps", {"pid": 11, "steps": [{"click": a}]}, GRANTED, owner, rows)
        self.assertIsNone(run({"role": "button", "name": "7"}))
        self.assertIn("role", run({"name": "关机"}))
        self.assertIn("菜单", run({"role": "menuitem", "name": "关机"}))
        self.assertIn("菜单", run({"role": "AXMenuItem", "name": "关机"}))
        self.assertIn("菜单", run({"role": "menu item", "name": "关机"}))

    def test_hotkeys(self):
        ok = (["cmd", "a"], ["cmd", "c"], ["cmd", "z"], ["cmd", "shift", "z"], ["cmd", "s"], ["option", "left"],
              ["shift", "tab"], ["cmd", "return"], ["command", "shift", "n"])
        bad = (["cmd", "shift", "q"], ["ctrl", "cmd", "q"], ["cmd", "option", "esc"], ["cmd", "space"],
               ["cmd", "v"], ["cmd", "shift", "4"], ["fn", "e"], ["cmd", "shift", "a"], ["cmd", "shift", "m"],
               ["Command", "Shift", "Q"], ["ctrl", "option", "cmd", "eject"], ["cmd", "tab"], ["hyper", "x"])
        for keys in ok:
            self.assertIsNone(self.check("hotkey", {"pid": 11, "keys": keys}), keys)
        for keys in bad:
            self.assertIsNotNone(self.check("hotkey", {"pid": 11, "keys": keys}), keys)
        self.assertIsNotNone(self.check("press_key", {"pid": 11, "key": "q", "modifiers": ["cmd", "shift"]}))
        self.assertIsNone(self.check("press_key", {"pid": 11, "key": "return"}))

    def test_coordinates_and_scope(self):
        self.assertIsNone(self.check("click", {"pid": 11, "x": 0, "y": 10}))
        self.assertIn("坐标", self.check("click", {"pid": 11, "x": -5, "y": 10}))
        self.assertIn("坐标", self.check("drag", {"pid": 11, "from_x": 1, "from_y": 1, "to_x": 3, "to_y": -1}))
        self.assertIn("scope", self.check("click", {"pid": 11, "x": 1, "y": 1, "scope": "desktop"}))


class TreeSanitizeTest(unittest.TestCase):
    TREE = "\n".join([
        "window_id=1 pid=11 snapshot_id=s00000003",
        "- [0] AXWindow \"计算器\" [actions=[raise]]",
        "  - [5] AXButton \"7\" [actions=[press]]",
        "- [1] AXMenuBar [actions=[cancel]]",
        "  - [2] AXMenuBarItem \"Apple\" [actions=[cancel,press,pick]]",
        "    - [3] AXMenu [actions=[cancel]]",
        "      - [4] AXMenuItem \"关于本机\" [actions=[press]]",
        "        - AXMenuItem \"简历.pdf\"",
        "      - [6] AXMenuItem \"关机\" [actions=[press]]",
        "  - [7] AXMenuBarItem \"计算器\" [actions=[press]]",
        "    - [8] AXMenu [actions=[cancel]]",
        "      - [9] AXMenuItem \"服务\" [actions=[press]]",
        "        - [10] AXMenu [actions=[cancel]]",
        "          - [11] AXMenuItem \"New Terminal at Folder\" [actions=[press]]",
        "      - [12] AXMenuItem \"退出计算器\" [actions=[press]]",
    ])

    def test_markdown(self):
        res = {"content": [{"type": "text", "text": self.TREE}],
               "structuredContent": {"snapshot_id": "s00000003", "tree_markdown": self.TREE}}
        snap, roles = gw.sanitize_tree_result(res)
        self.assertEqual(snap, "s00000003")
        for text in (res["content"][0]["text"], res["structuredContent"]["tree_markdown"]):
            for gone in ("Apple", "关于本机", "简历.pdf", "关机", "服务", "New Terminal"):
                self.assertNotIn(gone, text)
            for kept in ("计算器", "\"7\"", "退出计算器"):
                self.assertIn(kept, text)
        self.assertEqual(roles.get(5), "AXButton")
        self.assertEqual(roles.get(12), "AXMenuItem")
        for gone in (2, 3, 4, 6, 9, 10, 11):
            self.assertNotIn(gone, roles)

    def test_elements(self):
        els = [{"element_index": 0, "role": "AXWindow", "label": "计算器"},
               {"element_index": 1, "role": "AXMenuBar", "parent_index": None},
               {"element_index": 2, "role": "AXMenuBarItem", "label": "Apple", "parent_index": 1},
               {"element_index": 3, "role": "AXMenu", "parent_index": 2},
               {"element_index": 4, "role": "AXMenuItem", "label": "关机", "parent_index": 3},
               {"element_index": 5, "role": "AXButton", "label": "7", "parent_index": 0},
               {"element_index": 9, "role": "AXMenuItem", "label": "Services", "parent_index": 1},
               {"element_index": 11, "role": "AXMenuItem", "label": "x", "parent_index": 9}]
        res = {"structuredContent": {"snapshot_id": "s00000004", "elements": els}}
        snap, roles = gw.sanitize_tree_result(res)
        kept = [e["element_index"] for e in res["structuredContent"]["elements"]]
        self.assertEqual(kept, [0, 1, 5])
        self.assertEqual(set(roles), {0, 1, 5})


SKILL_SRC = os.path.join(ROOT, "computer-use", "skills", "aibox-mac")


class SkillTest(unittest.TestCase):
    def test_frontmatter_and_links(self):
        with open(os.path.join(SKILL_SRC, "SKILL.md"), encoding="utf-8") as f:
            text = f.read()
        self.assertTrue(text.startswith("---\n"))
        head = text.split("---\n")[1]
        meta = dict(line.split(": ", 1) for line in head.strip().splitlines())
        self.assertEqual(meta["name"], "aibox-mac")
        self.assertTrue(0 < len(meta["description"]) <= 1024)
        for link in re.findall(r"\]\((references/[^)]+)\)", text):
            self.assertTrue(os.path.exists(os.path.join(SKILL_SRC, link)), link)

    def test_install_update_uninstall(self):
        d = tempfile.mkdtemp()
        claude, codex = os.path.join(d, "claude"), os.path.join(d, "codex")
        gw.register(claude, codex, SKILL_SRC)
        with open(os.path.join(claude, "settings.json"), encoding="utf-8") as f:
            allow = json.load(f)["permissions"]["allow"]
        self.assertIn("Read(~/.claude/skills/aibox-mac/**)", allow)
        self.assertIn("Read(/%s/skills/aibox-mac/**)" % os.path.abspath(claude), allow)
        self.assertIn("Edit(~/.claude/skills/aibox-mac/references/local-notes.md)", allow)
        for root in (claude, codex):
            dest = os.path.join(root, "skills", "aibox-mac")
            self.assertTrue(os.path.exists(os.path.join(dest, "SKILL.md")))
            self.assertTrue(os.path.exists(os.path.join(dest, "references", "apps.md")))
            self.assertTrue(os.path.exists(os.path.join(dest, gw.SKILL_MARK)))
        # 本机记下的经验在重装 / 升级时保留
        notes = os.path.join(claude, "skills", "aibox-mac", "references", "local-notes.md")
        with open(notes, "a", encoding="utf-8") as f:
            f.write("\n## 测试应用(com.example.app)— 2026-10-30\n- 记一条\n")
        with open(os.path.join(claude, "skills", "aibox-mac", "SKILL.md"), "w") as f:
            f.write("旧版本")
        gw.register(claude, codex, SKILL_SRC)
        with open(notes, encoding="utf-8") as f:
            self.assertIn("记一条", f.read())
        with open(os.path.join(claude, "skills", "aibox-mac", "SKILL.md"), encoding="utf-8") as f:
            self.assertIn("name: aibox-mac", f.read())
        # 卸载:记过经验的 local-notes.md 保留,其余删掉;没记过的整个删掉
        gw.unregister(claude, codex, SKILL_SRC)
        with open(os.path.join(claude, "settings.json"), encoding="utf-8") as f:
            self.assertEqual(json.load(f)["permissions"]["allow"], [])
        self.assertTrue(os.path.exists(notes))
        self.assertFalse(os.path.exists(os.path.join(claude, "skills", "aibox-mac", "SKILL.md")))
        self.assertFalse(os.path.exists(os.path.join(codex, "skills", "aibox-mac")))

    def test_user_skill_untouched(self):
        d = tempfile.mkdtemp()
        dest = os.path.join(d, "skills", "aibox-mac")
        os.makedirs(dest)
        with open(os.path.join(dest, "SKILL.md"), "w") as f:
            f.write("mine")
        note = gw.install_skill(d, SKILL_SRC)
        self.assertIn("未改动", note)
        gw.uninstall_skill(d, SKILL_SRC)
        with open(os.path.join(dest, "SKILL.md")) as f:
            self.assertEqual(f.read(), "mine")


class MethodTest(unittest.TestCase):
    def test_methods(self):
        ok = [{"jsonrpc": "2.0", "id": 1, "method": m} for m in
              ("initialize", "ping", "server/discover", "tools/list", "tools/call")]
        ok += [{"jsonrpc": "2.0", "method": "notifications/initialized"}, {"jsonrpc": "2.0", "id": 5, "result": {}},
               {"jsonrpc": "2.0", "id": 6, "method": "resources/read", "params": {"uri": "skill://cua-driver/SKILL.md"}}]
        for msg in ok:
            self.assertIsNone(gw.method_error(msg), msg)
        bad = [{"id": 1, "method": "prompts/get"}, {"id": 1, "method": "Tools/call"}, {"id": 1, "method": 3},
               {"id": 1, "method": "resources/read", "params": {"uri": "file:///etc/passwd"}},
               {"id": 1, "method": "resources/read", "params": {"uri": "skill://cua-driver/../../x"}},
               {"method": None}]
        for msg in bad:
            self.assertIsNotNone(gw.method_error(msg), msg)


class ResolveTest(unittest.TestCase):
    def test_paths_rejected(self):
        # 容器里能写的位置(项目目录、Home)不能拿来伪造应用
        d = tempfile.mkdtemp()
        os.makedirs(os.path.join(d, "x.app", "Contents"))
        self.assertIsNone(gw.resolve_app(os.path.join(d, "x.app")))
        self.assertIsNone(gw.resolve_app("备忘录\ncom.microsoft.VSCode"))
        self.assertFalse(gw.trusted_app_path(os.path.join(d, "x.app")))
        self.assertTrue(gw.trusted_app_path("/Applications/Foo.app") or not os.path.isdir("/Applications/Foo.app"))

    def test_clean_name(self):
        self.assertEqual(gw.clean_name("备忘录\ncom.microsoft.VSCode\tVS"), "备忘录 com.microsoft.VSCode VS")


class ManifestTest(unittest.TestCase):
    def test_render(self):
        text = gw.render_manifest({"com.apple.Notes", "com.apple.Terminal", "bad id;", "com.apple.calculator"})
        self.assertIn("version: 3", text)
        self.assertIn("bounded" if False else "display: false", text)
        self.assertIn("- bundle_id: com.apple.Notes", text)
        self.assertIn("- bundle_id: com.apple.calculator", text)
        self.assertNotIn("Terminal", text)
        self.assertNotIn("bad id", text)
        for name in gw.DRIVER_TOOLS:
            self.assertIn("    - %s\n" % name, text)

    def test_empty(self):
        self.assertIn("apps: []", gw.render_manifest(set()))


class AllowedFileTest(unittest.TestCase):
    def test_roundtrip_and_blocked_entries(self):
        d = tempfile.mkdtemp()
        path = os.path.join(d, "allowed-apps")
        gw.write_allowed(path, {"com.apple.Notes": "备忘录"})
        with open(path, "a", encoding="utf-8") as f:
            f.write("com.apple.Terminal\t终端\n# 注释\n\nbad id\tx\n")
        self.assertEqual(gw.read_allowed(path), {"com.apple.Notes": "备忘录"})
        self.assertEqual(gw.read_allowed(os.path.join(d, "missing")), {})

    def test_name_injection(self):
        d = tempfile.mkdtemp()
        path = os.path.join(d, "allowed-apps")
        gw.write_allowed(path, {"com.apple.Notes": "备忘录\ncom.example.evil\tEvil"})
        self.assertEqual(set(gw.read_allowed(path)), {"com.apple.Notes"})

    def test_audit_escaping(self):
        d = tempfile.mkdtemp()
        a = gw.Audit(os.path.join(d, "audit.log"))
        a.write("who", "click\n2026-01-01\tfake\tclick\t-\t放行", "pid=1\nx", "拒绝", "a\nb")
        with open(os.path.join(d, "audit.log"), encoding="utf-8") as f:
            self.assertEqual(len(f.read().splitlines()), 1)


class RegisterTest(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.claude = os.path.join(self.d, "claude")
        self.codex = os.path.join(self.d, "codex")
        os.makedirs(self.claude)
        os.makedirs(self.codex)
        with open(os.path.join(self.claude, ".claude.json"), "w") as f:
            json.dump({"oauthAccount": {"a": 1}, "mcpServers": {"keep": {"command": "k"}}}, f)
        os.chmod(os.path.join(self.claude, ".claude.json"), 0o600)
        with open(os.path.join(self.codex, "config.toml"), "w") as f:
            f.write('model = "x"\n\n[mcp_servers.other]\ncommand = "y"\n')

    def read(self):
        with open(os.path.join(self.claude, ".claude.json")) as f:
            cfg = json.load(f)
        with open(os.path.join(self.claude, "settings.json")) as f:
            st = json.load(f)
        with open(os.path.join(self.codex, "config.toml")) as f:
            toml = f.read()
        return cfg, st, toml

    def test_register_idempotent_and_unregister(self):
        gw.register(self.claude, self.codex)
        gw.register(self.claude, self.codex)
        cfg, st, toml = self.read()
        self.assertEqual(cfg["oauthAccount"], {"a": 1})
        self.assertEqual(cfg["mcpServers"]["keep"], {"command": "k"})
        self.assertEqual(cfg["mcpServers"]["mac"]["command"], "aibox-mac-mcp")
        self.assertEqual(st["permissions"]["allow"].count("mcp__mac"), 1)
        self.assertEqual(toml.count("[mcp_servers.mac]"), 1)
        self.assertIn('default_tools_approval_mode = "approve"', toml)
        self.assertIn("[mcp_servers.other]", toml)
        self.assertEqual(os.stat(os.path.join(self.claude, ".claude.json")).st_mode & 0o777, 0o600)
        gw.unregister(self.claude, self.codex)
        cfg, st, toml = self.read()
        self.assertNotIn("mac", cfg["mcpServers"])
        self.assertIn("keep", cfg["mcpServers"])
        self.assertNotIn("mcp__mac", st["permissions"]["allow"])
        self.assertEqual(toml, 'model = "x"\n\n[mcp_servers.other]\ncommand = "y"\n')

    def test_user_defined_codex_server_is_kept(self):
        with open(os.path.join(self.codex, "config.toml"), "a") as f:
            f.write('\n[mcp_servers.mac]\ncommand = "mine"\n')
        notes = gw.register(None, self.codex)
        self.assertTrue(any("未改动" in n for n in notes))
        with open(os.path.join(self.codex, "config.toml")) as f:
            self.assertEqual(f.read().count("[mcp_servers.mac]"), 1)

    def test_unregister_keeps_foreign_mac_server(self):
        with open(os.path.join(self.claude, ".claude.json"), "w") as f:
            json.dump({"mcpServers": {"mac": {"command": "someone-else"}}}, f)
        gw.unregister(self.claude, None)
        with open(os.path.join(self.claude, ".claude.json")) as f:
            self.assertEqual(json.load(f)["mcpServers"]["mac"]["command"], "someone-else")


def relay_env(endpoint, token):
    home = tempfile.mkdtemp()
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": home,
           "AIBOX_STATE_DIR": os.path.join(home, ".aibox"),
           "AIBOX_CU_ENDPOINT": endpoint, "AIBOX_CU_TOKEN": token, "AIBOX_CONTAINER": "smoke"}
    return env


def talk(env, messages):
    """启动转发器,逐条发消息,收集有 id 的回复。"""
    p = subprocess.Popen([sys.executable, RELAY], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, env=env, text=True)
    out = []
    for msg in messages:
        p.stdin.write(json.dumps(msg) + "\n")
        p.stdin.flush()
        if "id" in msg:
            out.append(json.loads(p.stdout.readline()))
    p.stdin.close()
    p.wait(timeout=10)
    p.stdout.close()
    return out


class FakeGateway(threading.Thread):
    """模拟网关:校验握手行,然后把收到的每条请求原样回成 result。"""

    def __init__(self, token):
        super().__init__(daemon=True)
        self.token = token
        self.srv = socket.socket()
        self.srv.bind(("127.0.0.1", 0))
        self.srv.listen(1)
        self.port = self.srv.getsockname()[1]
        self.handshake = None

    def run(self):
        conn, _ = self.srv.accept()
        f = conn.makefile("rwb")
        self.handshake = f.readline().decode().strip()
        parts = self.handshake.split(" ")
        if len(parts) < 2 or parts[1] != self.token:
            f.write(b"AIBOX-CU1 DENIED token\n")
            f.flush()
            conn.close()
            return
        f.write(b"AIBOX-CU1 OK\n")
        f.flush()
        for line in f:
            msg = json.loads(line)
            if "id" in msg:
                f.write((json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": {"echo": msg["method"]}}) + "\n").encode())
                f.flush()
        conn.close()


class RelayTest(unittest.TestCase):
    def free_port(self):
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
        s.close()
        return port

    def test_passthrough(self):
        fake = FakeGateway("tok")
        fake.start()
        out = talk(relay_env("127.0.0.1:%d" % fake.port, "tok"),
                   [{"jsonrpc": "2.0", "id": 1, "method": "tools/list"}])
        self.assertEqual(out[0]["result"], {"echo": "tools/list"})
        self.assertEqual(fake.handshake, "AIBOX-CU1 tok smoke")

    def test_stub_when_gateway_unreachable(self):
        env = relay_env("127.0.0.1:%d" % self.free_port(), "tok")
        out = talk(env, [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
            {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "click"}},
        ])
        self.assertIn("不可用", out[0]["result"]["instructions"])
        self.assertEqual(out[0]["result"]["protocolVersion"], "2025-06-18")
        self.assertEqual(out[1]["result"], {"tools": []})
        self.assertIn("error", out[2])

    def test_stub_stateless_protocol(self):
        meta = {"_meta": {"io.modelcontextprotocol/protocolVersion": "2026-07-28"}}
        out = talk(relay_env("127.0.0.1:%d" % self.free_port(), "tok"), [
            {"jsonrpc": "2.0", "id": 1, "method": "server/discover", "params": meta},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": meta},
        ])
        self.assertIn("不可用", out[0]["result"]["instructions"])
        self.assertEqual(out[0]["result"]["resultType"], "complete")
        self.assertEqual(out[1]["result"]["resultType"], "complete")

    def test_stub_on_wrong_token(self):
        fake = FakeGateway("right")
        fake.start()
        out = talk(relay_env("127.0.0.1:%d" % fake.port, "wrong"),
                   [{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}])
        self.assertIn("token", out[0]["result"]["instructions"])

    def test_stub_without_token(self):
        env = relay_env("127.0.0.1:1", "")
        del env["AIBOX_CU_TOKEN"]
        out = talk(env, [{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}])
        self.assertIn("aibox cu install", out[0]["result"]["instructions"])


if __name__ == "__main__":
    unittest.main(verbosity=1)

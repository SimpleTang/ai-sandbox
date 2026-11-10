#!/bin/bash
# 管理长期容器系统盘上的 AI CLI(claude / codex)。以 root 运行 update / rollback。
#
#   aibox-dev-tools version  [all|claude|codex]       已装版本,以及可回退到的上一版
#   aibox-dev-tools update   <claude|codex>[@版本]...  安装指定版本(不写版本取 latest);
#                                                      也接受旧写法 all | claude | codex
#   aibox-dev-tools rollback <claude|codex>            与上一版互换(再执行一次即换回)
#
# 为什么不直接 npm install -g:
#   CLI 的本体在平台包里(claude 约 160 MB、codex 约 100 MB 的 tgz),npm 下载它没有进度;
#   下载超时(npm 默认 5 分钟)时还把它当「可选依赖」静默跳过,只留下一个运行即报
#   「native binary not installed」的占位脚本,而且是直接覆盖在正在用的那份上。
# 所以这里:
#   1. 包文件由 curl 下载 —— 有进度条、可续传(中断后重跑接着下),按 registry 登记的
#      sha512 校验;
#   2. 在暂存目录装好,实际运行 `<cli> --version` 确认是目标版本,通过了才替换正在用的;
#   3. 替换后再运行一次,不对立即换回;被替换下来的旧版留一份,供 rollback。
# 任何一步失败,正在用的那份都不受影响。
#
# 下载走哪条网络:依次尝试 直连 npmjs → 直连 npmmirror → 经代理 npmmirror → 经代理 npmjs,
# 不通或持续过慢就换下一条。「直连」走宿主机的网络出口;AIBOX_PROXY 是给 AI 服务固定
# 出口 IP 用的,下载公开的 npm 包用不着它,而且经海外代理绕回国内镜像很慢。
set -euo pipefail

action="${1:-}"
[[ $# -gt 0 ]] && shift

PREFIX="$(npm prefix -g)"
NPM_ROOT="$PREFIX/lib/node_modules"
BIN_DIR="$PREFIX/bin"
BACKUP_ROOT="$PREFIX/lib/aibox-cli-backup"   # 每个 CLI 留一份上一版,不在 node_modules 里
CACHE_DIR=/var/cache/aibox-cli               # 下载中的文件,中断后重跑可续传
LOCK_FILE=/run/lock/aibox-dev-tools.lock
NPMJS=https://registry.npmjs.org
MIRROR=https://registry.npmmirror.com
DEV_PROXY=http://127.0.0.1:8080              # aibox-dev-proxy(gost),转发到 AIBOX_PROXY

die() { echo "错误: $*" >&2; exit 1; }
say() { echo "==> $*"; }

pkg_of() {
    case "$1" in
        claude) echo "@anthropic-ai/claude-code" ;;
        codex)  echo "@openai/codex" ;;
        *)      return 1 ;;
    esac
}

# ---- JSON / 校验等小工具,用机内的 node 实现 ----
NODE_HELPER='
const fs = require("fs"), crypto = require("crypto");
const [cmd, ...a] = process.argv.slice(1);
const rd = f => JSON.parse(fs.readFileSync(f, "utf8"));
const out = s => process.stdout.write(s + "\n");
switch (cmd) {
case "get": {                 // get <json> <字段路径,如 dist.integrity>
    let v = rd(a[0]);
    for (const k of a[1].split(".")) v = v == null ? undefined : v[k];
    if (v === undefined || v === null) process.exit(1);
    out(typeof v === "object" ? JSON.stringify(v) : String(v));
    break; }
case "optdeps": {             // optdeps <json>:每行 别名<TAB>真实包名<TAB>版本
    const o = rd(a[0]).optionalDependencies || {};
    for (const [alias, spec] of Object.entries(o)) {
        const m = /^npm:(@?[^@]+)@(.+)$/.exec(spec);
        out(m ? `${alias}\t${m[1]}\t${m[2]}` : `${alias}\t${alias}\t${spec}`);
    }
    break; }
case "fits": {                // fits <json>:平台包的 os/cpu/libc 是否适合本机
    const m = rd(a[0]);
    const libc = process.report.getReport().header.glibcVersionRuntime ? "glibc" : "musl";
    const ok = (list, v) => !Array.isArray(list) || list.includes(v);
    process.exit(ok(m.os, process.platform) && ok(m.cpu, process.arch)
        && (process.platform !== "linux" || ok(m.libc, libc)) ? 0 : 1); }
case "bins": {                // bins <package.json>:每行 命令名<TAB>相对路径
    const p = rd(a[0]);
    const b = typeof p.bin === "string" ? { [p.name.split("/").pop()]: p.bin } : (p.bin || {});
    for (const [k, v] of Object.entries(b)) out(`${k}\t${v.replace(/^\.\//, "")}`);
    break; }
case "verify": {              // verify <文件> <integrity> <shasum>
    const [f, integ, sha1] = a;
    let alg = "sha1", want = sha1, enc = "hex";
    const sri = (integ || "").split(/\s+/).find(x => x.startsWith("sha512-"));
    if (sri) { alg = "sha512"; want = sri.slice(7); enc = "base64"; }
    if (!want) { console.error("registry 没有给出校验值"); process.exit(2); }
    const h = crypto.createHash(alg);
    fs.createReadStream(f).on("data", d => h.update(d))
        .on("end", () => process.exit(h.digest(enc) === want ? 0 : 1))
        .on("error", () => process.exit(2));
    break; }
default: process.exit(2);
}'
js() { node -e "$NODE_HELPER" "$@"; }

human_size() {
    awk -v b="${1:-0}" 'BEGIN { split("B KB MB GB", u); i = 1; while (b >= 1024 && i < 4) { b /= 1024; i++ } printf (i == 1 ? "%d %s" : "%.1f %s"), b, u[i] }'
}

# ---- 已装版本 ----
pkg_version() {   # pkg_version <包目录>
    [[ -r "$1/package.json" ]] && js get "$1/package.json" version 2>/dev/null
}

show_versions() {
    local target="$1" key label cur bak
    for key in claude codex; do
        [[ "$target" == "all" || "$target" == "$key" ]] || continue
        if [[ "$key" == "claude" ]]; then label="claude-code: "; else label="codex:       "; fi
        cur="$(pkg_version "$NPM_ROOT/$(pkg_of "$key")" || true)"
        echo "${label}${cur:-not installed}"
        bak="$(pkg_version "$BACKUP_ROOT/$key" || true)"
        # 缩进开头:ai-box 解析版本号时只认行首的「名字:」,不会误读这一行
        [[ -z "$bak" ]] || echo "  backup: $bak"
    done
}

# ---- 网络线路:「名称|registry|代理(空=直连)」 ----
ROUTES=("直连 npmjs|$NPMJS|" "直连 npmmirror|$MIRROR|")
if [[ -s /run/aibox/dev-proxy-url ]]; then
    ROUTES+=("经代理 npmmirror|$MIRROR|$DEV_PROXY" "经代理 npmjs|$NPMJS|$DEV_PROXY")
fi
ROUTE_FIRST=0     # 第一条拿到元数据的线路,下载时优先用它

route_name()  { echo "${1%%|*}"; }
route_reg()   { local r="${1#*|}"; echo "${r%%|*}"; }
route_curl() {    # route_curl <线路> curl参数...
    local proxy="${1##*|}"
    shift
    if [[ -n "$proxy" ]]; then
        curl --proxy "$proxy" "$@"
    else
        curl --noproxy '*' "$@"
    fi
}

# fetch_json <registry 内路径> <输出文件>:按线路顺序取元数据,记下第一条通的线路
fetch_json() {
    local path="$1" dest="$2" i
    for (( i = 0; i < ${#ROUTES[@]}; i++ )); do
        if route_curl "${ROUTES[$i]}" -fsS --connect-timeout 8 --max-time 60 \
                -H 'Accept: application/json' -o "$dest" "$(route_reg "${ROUTES[$i]}")/$path" 2>/dev/null \
            && node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$dest" 2>/dev/null; then
            ROUTE_FIRST=$i
            return 0
        fi
    done
    return 1
}

# download <tarball 在 registry 内的路径> <目标文件> <integrity> <shasum>
download() {
    local path="$1" dest="$2" integrity="$3" shasum="$4"
    local part="$dest.part" order=() i n route rc last progress=()
    mkdir -p "$CACHE_DIR"
    if [[ -f "$dest" ]] && js verify "$dest" "$integrity" "$shasum"; then
        echo "    已下载过: $(basename "$dest")"
        return 0
    fi
    rm -f "$dest"
    n=${#ROUTES[@]}
    order=("$ROUTE_FIRST")
    for (( i = 0; i < n; i++ )); do [[ $i -eq $ROUTE_FIRST ]] || order+=("$i"); done
    if [[ -t 2 ]]; then progress=(--progress-bar); else progress=(-sS); fi
    last="${order[$((n - 1))]}"
    for i in "${order[@]}"; do
        route="${ROUTES[$i]}"
        local slow=()
        # 不是最后一条线路时,持续 30 秒低于 64 KB/s 就放弃,换下一条
        [[ "$i" == "$last" ]] || slow=(--speed-limit 65536 --speed-time 30)
        echo "    下载 $(basename "$dest"),线路: $(route_name "$route")"
        rc=0
        route_curl "$route" -fL --connect-timeout 10 --retry 2 --retry-delay 3 -C - \
            "${progress[@]}" ${slow[@]+"${slow[@]}"} \
            -o "$part" "$(route_reg "$route")/$path" || rc=$?
        if [[ $rc -eq 0 ]]; then
            if js verify "$part" "$integrity" "$shasum"; then
                mv -f "$part" "$dest"
                echo "    校验通过(sha512)"
                return 0
            fi
            echo "    校验不通过,丢弃此文件" >&2
            rm -f "$part"
        else
            echo "    该线路下载失败(curl 退出码 $rc)" >&2
            # 416/33:续传位置不被接受,下次从头下
            [[ $rc -ne 33 && $rc -ne 36 ]] || rm -f "$part"
        fi
    done
    return 1
}

# ---- 在暂存目录里装好一个 CLI 并实测,成功时输出包目录 ----
# stage_one <claude|codex> <版本> <工作目录>
stage_one() {
    local key="$1" ver="$2" work="$3" name meta plat_line alias real pver
    local pmeta="" palias="" need avail tarpath integ sha bin rel outv
    name="$(pkg_of "$key")"
    meta="$work/$key.json"

    say "$key: 获取 $name@$ver 的元数据"
    fetch_json "$name/$ver" "$meta" || die "获取 $name@$ver 的元数据失败(所有线路都不通)"
    [[ "$(js get "$meta" version)" == "$ver" ]] || die "registry 返回的 $name 版本与 $ver 不符"
    echo "    线路: $(route_name "${ROUTES[$ROUTE_FIRST]}")"

    # 本机对应的平台包(os/cpu/libc 以 registry 登记的为准)
    local plat_os plat_arch
    plat_os="$(node -p process.platform)"
    plat_arch="$(node -p process.arch)"
    while IFS=$'\t' read -r alias real pver; do
        [[ -n "$alias" ]] || continue
        [[ "$alias" == *"$plat_os"* && "$alias" == *"$plat_arch"* ]] || continue
        fetch_json "$real/$pver" "$work/$key.plat.json" || die "获取平台包 $real@$pver 的元数据失败"
        if js fits "$work/$key.plat.json"; then
            [[ -z "$palias" ]] || die "$name 有多个平台包都适合本机($palias、$alias),无法判断该装哪个"
            palias="$alias"
            pmeta="$work/$key.plat.$plat_os-$plat_arch.json"
            cp "$work/$key.plat.json" "$pmeta"
        fi
    done < <(js optdeps "$meta")
    if js get "$meta" optionalDependencies >/dev/null 2>&1; then
        [[ -n "$palias" ]] || die "$name@$ver 没有适合本机($plat_os-$plat_arch)的平台包"
    fi

    # 磁盘空间:解压后的大小,加上安装脚本可能把本体复制一份,留两倍余量
    need=$(( $(js get "$meta" dist.unpackedSize 2>/dev/null || echo 0) ))
    [[ -z "$pmeta" ]] || need=$(( need + 2 * $(js get "$pmeta" dist.unpackedSize 2>/dev/null || echo 0) ))
    avail=$(( $(df -Pk "$PREFIX/lib" | awk 'NR == 2 { print $4 }') * 1024 ))
    (( avail > need * 2 )) || die "磁盘空间不足:需要约 $(human_size $((need * 2))),只剩 $(human_size "$avail")"

    # 下载并校验
    local f
    for f in "$meta" ${pmeta:+"$pmeta"}; do
        tarpath="$(js get "$f" dist.tarball | sed -E 's#^https?://[^/]+/##')"
        integ="$(js get "$f" dist.integrity 2>/dev/null || true)"
        sha="$(js get "$f" dist.shasum 2>/dev/null || true)"
        download "$tarpath" "$CACHE_DIR/$(basename "$tarpath")" "$integ" "$sha" \
            || die "下载 $(basename "$tarpath") 失败(所有线路都试过了)"
    done

    # 解包到暂存目录:主包 + 平台包放在它的 node_modules/<别名>,与 npm 的布局一致
    local pkg="$work/pkg-$key"
    mkdir -p "$pkg"
    tar xzf "$CACHE_DIR/$(basename "$(js get "$meta" dist.tarball)")" -C "$pkg" \
        --strip-components=1 --no-same-owner
    if [[ -n "$pmeta" ]]; then
        mkdir -p "$pkg/node_modules/$palias"
        tar xzf "$CACHE_DIR/$(basename "$(js get "$pmeta" dist.tarball)")" -C "$pkg/node_modules/$palias" \
            --strip-components=1 --no-same-owner
    fi
    chmod -R u+rwX,go+rX,go-w "$pkg"
    # 目前两个 CLI 都没有普通依赖;将来有了就交给 npm 装(只装依赖,不碰可选的平台包)
    if [[ "$(js get "$pkg/package.json" dependencies 2>/dev/null || echo '{}')" != "{}" ]]; then
        say "$key: 安装依赖"
        local npm_net=(--registry="$(route_reg "${ROUTES[$ROUTE_FIRST]}")")
        local rp="${ROUTES[$ROUTE_FIRST]##*|}"
        [[ -z "$rp" ]] || npm_net+=(--proxy="$rp" --https-proxy="$rp")
        (cd "$pkg" && npm install --omit=dev --omit=optional --ignore-scripts --no-package-lock \
            --no-audit --no-fund --fetch-timeout=600000 --fetch-retries=3 "${npm_net[@]}") \
            || die "$key: 安装依赖失败"
    fi
    # 安装脚本(claude 的 postinstall 把平台包里的本体放到 bin/claude.exe)
    local script
    for script in preinstall install postinstall; do
        local cmd
        cmd="$(js get "$pkg/package.json" "scripts.$script" 2>/dev/null || true)"
        [[ -n "$cmd" ]] || continue
        (cd "$pkg" && env -i PATH="$PATH" HOME="$work/home" npm_config_global=true sh -c "$cmd") \
            || die "$key: 执行 $script 脚本失败"
    done

    # 实测:每个命令都要能跑,且报出的版本就是目标版本
    while IFS=$'\t' read -r bin rel; do
        chmod 0755 "$pkg/$rel"
        outv="$(run_version "$pkg/$rel" "$work/home")" \
            || die "$key: 新版 $bin 无法运行:$(echo "$outv" | head -n 3)"
        [[ "$outv" == *"$ver"* ]] || die "$key: 新版 $bin 报告的版本不是 $ver:$(echo "$outv" | head -n 1)"
        echo "    实测通过: $bin --version → $(echo "$outv" | head -n 1)"
    done < <(js bins "$pkg/package.json")
}

# run_version <可执行文件> <HOME>:在干净环境里运行 --version
run_version() {
    mkdir -p "$2"
    env -i PATH="$BIN_DIR:/usr/local/bin:/usr/bin:/bin" HOME="$2" \
        timeout 60 "$1" --version 2>&1 </dev/null
}

# link_bins <包目录(已在 NPM_ROOT 下)> <包名>:按 npm 的方式建 $BIN_DIR 下的相对软链接
link_bins() {
    local dir="$1" name="$2" bin rel
    while IFS=$'\t' read -r bin rel; do
        chmod 0755 "$dir/$rel"
        ln -sfn "../lib/node_modules/$name/$rel" "$BIN_DIR/$bin"
    done < <(js bins "$dir/package.json")
}

# check_live <包名> <期望版本> <HOME>:经 $BIN_DIR 下的命令实测
check_live() {
    local name="$1" ver="$2" bin rel outv
    while IFS=$'\t' read -r bin rel; do
        outv="$(run_version "$BIN_DIR/$bin" "$3")" || return 1
        [[ "$outv" == *"$ver"* ]] || return 1
    done < <(js bins "$NPM_ROOT/$name/package.json")
}

# swap_in <key> <新包目录> <新版本> <工作目录>:旧版移到备份,新版就位;实测不过立即换回
swap_in() {
    local key="$1" new="$2" ver="$3" work="$4" name dest bak
    name="$(pkg_of "$key")"
    dest="$NPM_ROOT/$name"
    bak="$BACKUP_ROOT/$key"
    mkdir -p "$BACKUP_ROOT" "$(dirname "$dest")"
    # 只有能用的旧版才值得留作回退目标;已经坏了的(比如只剩占位脚本)直接丢弃
    if [[ -d "$dest" ]]; then
        if check_live "$name" "$(pkg_version "$dest" || echo '?')" "$work/home"; then
            rm -rf -- "$bak"
            mv -T -- "$dest" "$bak"
        else
            echo "    当前装的 $key 本身无法运行,不保留为回退版本"
            mv -T -- "$dest" "$work/broken-$key"
        fi
    fi
    if ! mv -T -- "$new" "$dest"; then
        [[ ! -d "$bak" ]] || mv -T -- "$bak" "$dest"
        die "$key: 新版就位失败,已恢复原版本"
    fi
    link_bins "$dest" "$name"
    if ! check_live "$name" "$ver" "$work/home"; then
        mv -T -- "$dest" "$work/failed-$key"
        if [[ -d "$bak" ]]; then
            mv -T -- "$bak" "$dest"
            link_bins "$dest" "$name"
            die "$key: 新版就位后实测失败,已换回 $(pkg_version "$dest")"
        elif [[ -d "$work/broken-$key" ]]; then
            mv -T -- "$work/broken-$key" "$dest"
        fi
        die "$key: 新版就位后实测失败,原来也没有可用版本可换回"
    fi
}

new_workdir() {
    # 与 node_modules 同一文件系统,最后一步替换是 rename,不是复制
    WORK="$(mktemp -d "$PREFIX/lib/.aibox-update.XXXXXX")"
    trap 'rm -rf -- "$WORK"' EXIT
}

take_lock() {
    exec 9>"$LOCK_FILE"
    flock -n 9 || die "另一个 aibox update / rollback 正在进行"
}

need_root() {
    [[ "$(id -u)" -eq 0 ]] || die "aibox-dev-tools $action 需要以 root 运行"
}

case "$action" in
    version)
        target="${1:-all}"
        case "$target" in all|claude|codex) ;; *) die "用法: aibox-dev-tools version [all|claude|codex]" ;; esac
        show_versions "$target"
        ;;
    update)
        need_root
        [[ $# -gt 0 ]] || set -- all
        specs=()
        for arg in "$@"; do
            case "$arg" in
                all)                   specs+=(claude codex) ;;
                claude|codex)          specs+=("$arg") ;;
                claude@?*|codex@?*)    specs+=("$arg") ;;
                *) die "用法: aibox-dev-tools update <claude|codex>[@版本] ..." ;;
            esac
        done
        take_lock
        new_workdir
        failed=""
        for spec in "${specs[@]}"; do
            key="${spec%%@*}"
            ver=""
            [[ "$spec" != *@* ]] || ver="${spec#*@}"
            if [[ -z "$ver" ]]; then
                fetch_json "$(pkg_of "$key")/latest" "$WORK/$key.latest.json" \
                    || die "获取 $(pkg_of "$key") 的最新版本失败"
                ver="$(js get "$WORK/$key.latest.json" version)"
            fi
            # 子 shell 里暂存:任何 die 只结束这一个 CLI 的更新,另一个照常进行
            if ( stage_one "$key" "$ver" "$WORK" ); then
                say "$key: 替换为 $ver"
                if ( swap_in "$key" "$WORK/pkg-$key" "$ver" "$WORK" ); then
                    say "$key: 已更新到 $ver(上一版留作回退:aibox rollback $([[ $key == claude ]] && echo cc || echo codex))"
                    # 装好了就不再需要下载缓存
                    rm -f -- "$CACHE_DIR"/"$(basename "$(pkg_of "$key")")"-*.tgz 2>/dev/null || true
                    continue
                fi
            fi
            echo "==> $key: 更新失败,正在用的版本没有改动。" >&2
            failed="${failed:+$failed }$key"
        done
        echo
        show_versions all
        [[ -z "$failed" ]] || exit 1
        ;;
    rollback)
        need_root
        key="${1:-}"
        case "$key" in claude|codex) ;; *) die "用法: aibox-dev-tools rollback <claude|codex>" ;; esac
        name="$(pkg_of "$key")"
        dest="$NPM_ROOT/$name"
        bak="$BACKUP_ROOT/$key"
        [[ -d "$bak" ]] || die "没有 $key 的上一版可回退(只有用新版 aibox update 更新过才会保留)"
        take_lock
        new_workdir
        from="$(pkg_version "$dest" || echo '未安装')"
        to="$(pkg_version "$bak")" || die "备份的 $key 已损坏"
        # 先确认备份本身能跑,再动正在用的那份
        while IFS=$'\t' read -r bin rel; do
            run_version "$bak/$rel" "$WORK/home" >/dev/null || die "备份的 $key $to 无法运行,不回退"
        done < <(js bins "$bak/package.json")
        say "$key: $from → $to"
        if [[ -d "$dest" ]]; then mv -T -- "$dest" "$WORK/cur"; fi
        mv -T -- "$bak" "$dest"
        link_bins "$dest" "$name"
        if ! check_live "$name" "$to" "$WORK/home"; then
            mv -T -- "$dest" "$bak"
            if [[ -d "$WORK/cur" ]]; then mv -T -- "$WORK/cur" "$dest"; link_bins "$dest" "$name"; fi
            die "$key: 回退后实测失败,已恢复 $from"
        fi
        # 被换下来的这一版成为新的「上一版」,再执行一次 rollback 即换回
        if [[ -d "$WORK/cur" ]]; then mv -T -- "$WORK/cur" "$bak"; fi
        say "$key: 已回退到 $to(再执行一次 aibox rollback 可换回 $from)"
        ;;
    *)
        die "用法: aibox-dev-tools <version|update|rollback> ..."
        ;;
esac

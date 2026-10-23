# shellcheck shell=bash
# aibox-ui.sh:ai-box 与 setup.sh 共用的交互输入,由调用方 source。兼容 macOS 自带的 Bash 3.2。
#
# 输入输出都是终端时,选择题用 ↑↓ 选、回车确认(是 / 否也可以直接按 y、n),文字输入用 readline;
# 否则(管道、脚本、测试)退回到输入编号和 y/n,行为与早先的纯文本提示一致。
#
# 调用方可以:
#   - 设置 UI_INDENT(提示前的缩进,默认无缩进),也可以只对一次调用设置:UI_INDENT="    " ui_yn ...;
#   - 在 source 之后重定义 ui_eof:读到输入结束时调用。默认什么也不做,提示按默认值返回;
#     setup.sh 把它改成直接退出向导。
# 函数内的局部变量都以 ui_ 开头,调用方传入的结果变量名不要用这个前缀。

UI_INDENT="${UI_INDENT:-}"
UI_TTY=0
if [[ -t 0 && -t 1 && "${TERM:-dumb}" != "dumb" && -z "${AIBOX_UI_PLAIN:-}" ]]; then
    UI_TTY=1
fi
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    UI_BOLD=$'\033[1m'; UI_OK=$'\033[32m'; UI_SEL=$'\033[1;36m'; UI_DIM=$'\033[2m'; UI_OFF=$'\033[0m'
else
    UI_BOLD=""; UI_OK=""; UI_SEL=""; UI_DIM=""; UI_OFF=""
fi
UI_OLD_INT=""

ui_eof() { :; }

ui_trim() {
    local ui_s="$1"
    ui_s="${ui_s#"${ui_s%%[![:space:]]*}"}"
    ui_s="${ui_s%"${ui_s##*[![:space:]]}"}"
    printf '%s' "$ui_s"
}

# 恢复光标和自动换行;菜单被打断时由 INT 处理或调用方的退出清理调用
ui_restore() {
    (( ! UI_TTY )) || printf '\033[?7h\033[?25h'
}

# 菜单显示期间临时接管 Ctrl+C:先恢复终端,再交给调用方原来的 INT 处理(没有就按默认退出)
ui_trap_on() {
    UI_OLD_INT="$(trap -p INT)"
    trap 'ui_restore; printf "\n"; trap - INT; [[ -z "$UI_OLD_INT" ]] || eval "$UI_OLD_INT"; kill -INT $$' INT
}

ui_trap_off() {
    if [[ -n "$UI_OLD_INT" ]]; then
        eval "$UI_OLD_INT"
    else
        trap - INT
    fi
}

# 读一个按键写入 UI_KEY:方向键归一成 up / down / left / right,回车为 enter,输入结束为 eof
ui_key() {
    local ui_k ui_rest=""
    if ! IFS= read -rsn1 ui_k; then
        ui_eof
        UI_KEY=eof
        return 0
    fi
    case "$ui_k" in
        "") UI_KEY=enter ;;
        $'\t') UI_KEY=tab ;;
        $'\033')
            IFS= read -rsn2 -t 1 ui_rest || true
            case "$ui_rest" in
                "[A"|"OA") UI_KEY=up ;;
                "[B"|"OB") UI_KEY=down ;;
                "[C"|"OC") UI_KEY=right ;;
                "[D"|"OD") UI_KEY=left ;;
                *)         UI_KEY=other ;;
            esac
            ;;
        *) UI_KEY="$ui_k" ;;
    esac
}

# 终端列数写入 UI_COLS,读不到时按 80
ui_cols() {
    UI_COLS="$(stty size 2>/dev/null | cut -d' ' -f2 || true)"
    [[ "$UI_COLS" =~ ^[1-9][0-9]*$ ]] || UI_COLS=80
}

# 估算显示宽度写入 UI_WIDTH:UTF-8 下中文字符 3 字节、占 2 列;
# 非 UTF-8 locale 下会估多,只会让问题和选项分两行显示,不会错位
ui_width() {
    local ui_chars="${#1}" ui_bytes
    ui_bytes="$(LC_ALL=C; printf '%s' "${#1}")"
    UI_WIDTH=$(( ui_chars + (ui_bytes - ui_chars) / 2 ))
}

# ui_choice <变量名> <最大编号> <默认编号>:读编号(非终端时的菜单)。输入结束时取默认并返回 1
ui_choice() {
    local ui_reply
    while true; do
        printf '%s%s?%s 请选择 [1-%s,默认 %s]: ' "$UI_INDENT" "$UI_BOLD" "$UI_OFF" "$2" "$3"
        if ! IFS= read -r ui_reply; then
            printf '\n'
            ui_eof
            printf -v "$1" '%s' "$3"
            return 1
        fi
        ui_reply="$(ui_trim "$ui_reply")"
        [[ -n "$ui_reply" ]] || ui_reply="$3"
        if [[ "$ui_reply" =~ ^[0-9]+$ ]] && (( ui_reply >= 1 && ui_reply <= $2 )); then
            printf -v "$1" '%s' "$ui_reply"
            return 0
        fi
        printf '%s  请输入 1 到 %s 之间的数字。\n' "$UI_INDENT" "$2"
    done
}

# 绘制菜单选项(由 ui_menu 调用,读取它的 ui_items / ui_sel / ui_n)
ui_menu_draw() {
    local ui_i
    for (( ui_i = 0; ui_i < ui_n; ui_i++ )); do
        if (( ui_i == ui_sel )); then
            printf '\r\033[2K%s  %s❯ %s%s\n' "$UI_INDENT" "$UI_SEL" "${ui_items[ui_i]}" "$UI_OFF"
        else
            printf '\r\033[2K%s    %s\n' "$UI_INDENT" "${ui_items[ui_i]}"
        fi
    done
}

# ui_menu <变量名> <默认编号> <问题> <选项...>:选中的编号(从 1 开始)写入变量。
# 输入结束时取默认编号并返回 1。
ui_menu() {
    local ui_var="$1" ui_def="$2" ui_q="$3" ui_n ui_i ui_sel ui_up ui_rc=0
    shift 3
    local ui_items=("$@")
    ui_n=${#ui_items[@]}
    if (( ! UI_TTY )); then
        printf '%s%s?%s %s\n' "$UI_INDENT" "$UI_BOLD" "$UI_OFF" "$ui_q"
        for (( ui_i = 0; ui_i < ui_n; ui_i++ )); do
            printf '%s  %d) %s\n' "$UI_INDENT" "$((ui_i + 1))" "${ui_items[ui_i]}"
        done
        ui_choice "$ui_var" "$ui_n" "$ui_def"
        return
    fi
    printf '%s%s?%s %s %s(↑↓ 选择,回车确认)%s\n' "$UI_INDENT" "$UI_BOLD" "$UI_OFF" "$ui_q" "$UI_DIM" "$UI_OFF"
    # 问题只占一行时,选完把它和结果并成一行;折行了就只收起选项
    ui_cols
    ui_width "$UI_INDENT? $ui_q (↑↓ 选择,回车确认)"
    ui_up=$ui_n
    (( UI_WIDTH >= UI_COLS )) || ui_up=$((ui_n + 1))
    ui_sel=$((ui_def - 1))
    ui_trap_on
    # 关掉自动换行,每个选项恰好占一行,重绘时上移的行数才准
    printf '\033[?25l\033[?7l'
    ui_menu_draw
    while true; do
        ui_key
        case "$UI_KEY" in
            up|left|k)        ui_sel=$(( (ui_sel + ui_n - 1) % ui_n )) ;;
            down|right|tab|j) ui_sel=$(( (ui_sel + 1) % ui_n )) ;;
            [1-9])
                if (( UI_KEY <= ui_n )); then
                    ui_sel=$((UI_KEY - 1))
                fi
                ;;
            enter) break ;;
            eof) ui_sel=$((ui_def - 1)); ui_rc=1; break ;;
            *) continue ;;
        esac
        printf '\033[%dA' "$ui_n"
        ui_menu_draw
    done
    printf '\033[%dA\033[J' "$ui_up"
    if (( ui_up > ui_n )); then
        printf '%s%s?%s %s  %s✓%s %s\n' "$UI_INDENT" "$UI_BOLD" "$UI_OFF" "$ui_q" "$UI_OK" "$UI_OFF" "${ui_items[ui_sel]}"
    else
        printf '%s  %s✓%s %s\n' "$UI_INDENT" "$UI_OK" "$UI_OFF" "${ui_items[ui_sel]}"
    fi
    ui_restore
    ui_trap_off
    printf -v "$ui_var" '%s' "$((ui_sel + 1))"
    return "$ui_rc"
}

# 是 / 否两个选项横排;放得下时和问题同一行,否则另起一行(由 ui_yn 调用)
ui_yn_draw() {
    local ui_opts
    if (( ui_sel == 0 )); then
        ui_opts="${UI_SEL}❯ 是${UI_OFF}    否"
    else
        ui_opts="  是  ${UI_SEL}❯ 否${UI_OFF}"
    fi
    if (( ui_inline )); then
        printf '\r\033[2K%s%s?%s %s  %s' "$UI_INDENT" "$UI_BOLD" "$UI_OFF" "$ui_q" "$ui_opts"
    else
        printf '\r\033[2K%s  %s' "$UI_INDENT" "$ui_opts"
    fi
}

# ui_yn <问题> <默认 Y|N>:回答「是」返回 0。输入结束时按默认值
ui_yn() {
    local ui_q="$1" ui_hint ui_ans ui_sel ui_inline=1 ui_answer
    if (( UI_TTY )); then
        if [[ "$2" == "Y" ]]; then ui_sel=0; else ui_sel=1; fi
        ui_cols
        ui_width "$UI_INDENT? $ui_q  ❯ 是    否 "
        if (( UI_WIDTH >= UI_COLS )); then
            ui_inline=0
            printf '%s%s?%s %s\n' "$UI_INDENT" "$UI_BOLD" "$UI_OFF" "$ui_q"
        fi
        ui_trap_on
        printf '\033[?25l'
        ui_yn_draw
        while true; do
            ui_key
            case "$UI_KEY" in
                up|down|left|right|tab|h|j|k|l) ui_sel=$((1 - ui_sel)) ;;
                y|Y) ui_sel=0; break ;;
                n|N) ui_sel=1; break ;;
                enter) break ;;
                eof) if [[ "$2" == "Y" ]]; then ui_sel=0; else ui_sel=1; fi; break ;;
                *) continue ;;
            esac
            ui_yn_draw
        done
        if (( ui_sel == 0 )); then ui_answer="是"; else ui_answer="否"; fi
        if (( ui_inline )); then
            printf '\r\033[2K%s%s?%s %s  %s✓%s %s\n' "$UI_INDENT" "$UI_BOLD" "$UI_OFF" "$ui_q" "$UI_OK" "$UI_OFF" "$ui_answer"
        else
            printf '\r\033[2K%s  %s✓%s %s\n' "$UI_INDENT" "$UI_OK" "$UI_OFF" "$ui_answer"
        fi
        ui_restore
        ui_trap_off
        return "$ui_sel"
    fi
    if [[ "$2" == "Y" ]]; then ui_hint="[Y/n]"; else ui_hint="[y/N]"; fi
    while true; do
        printf '%s%s?%s %s %s ' "$UI_INDENT" "$UI_BOLD" "$UI_OFF" "$ui_q" "$ui_hint"
        if ! IFS= read -r ui_ans; then
            printf '\n'
            ui_eof
            ui_ans=""
        fi
        case "$(ui_trim "$ui_ans")" in
            "")
                if [[ "$2" == "Y" ]]; then return 0; else return 1; fi
                ;;
            y|Y|yes|Yes|YES) return 0 ;;
            n|N|no|No|NO)    return 1 ;;
            *) printf '%s  请输入 y 或 n。\n' "$UI_INDENT" ;;
        esac
    done
}

# ui_line <变量名> <提示>:读一行,去掉首尾空白。终端里用 readline,可以左右移动光标修改。
# 输入结束时为空并返回 1
ui_line() {
    local ui_reply="" ui_prompt ui_rc=0
    if (( UI_TTY )); then
        # \001 \002 包住颜色码,readline 才不会把它们算进提示符宽度
        ui_prompt="$UI_INDENT"$'\001'"$UI_BOLD"$'\002'"?"$'\001'"$UI_OFF"$'\002'" $2"
        IFS= read -e -r -p "$ui_prompt" ui_reply || { printf '\n'; ui_eof; ui_reply=""; ui_rc=1; }
    else
        printf '%s%s?%s %s' "$UI_INDENT" "$UI_BOLD" "$UI_OFF" "$2"
        IFS= read -r ui_reply || { printf '\n'; ui_eof; ui_reply=""; ui_rc=1; }
    fi
    printf -v "$1" '%s' "$(ui_trim "$ui_reply")"
    return "$ui_rc"
}

# ui_secret <变量名> <提示>:输入不回显。输入结束时为空并返回 1
ui_secret() {
    local ui_reply="" ui_rc=0
    printf '%s%s?%s %s' "$UI_INDENT" "$UI_BOLD" "$UI_OFF" "$2"
    IFS= read -rs ui_reply || { ui_eof; ui_reply=""; ui_rc=1; }
    printf '\n'
    printf -v "$1" '%s' "$(ui_trim "$ui_reply")"
    return "$ui_rc"
}

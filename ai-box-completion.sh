# ai-box 命令补全(bash + zsh 通用)
#
# 安装:在 ~/.zshrc(或 ~/.bashrc)里加一行:
#     source ~/ai-sandbox/ai-box-completion.sh
# 然后重开终端 / `source` 一下即可。
#
# 效果:
#   aibox <TAB>          -> 补全子命令(cc/codex/list/enter/update ...)
#   aibox enter <TAB>    -> 补全「正在运行的容器名」和「项目名」
#   aibox update <TAB>   -> 补全 cc / codex
#
# 说明:补全候选来自 `container ls -q`(只列运行中的),和 aibox enter 的匹配口径一致;
#       项目名由容器名 ai-<项目>-<6位时间戳> 反推。enter 也支持纯数字编号,那个太短、
#       无需补全,这里只补全名字。

# 运行中的 aibox 容器名(完整名)
_aibox_running() {
    container ls -q 2>/dev/null | grep '^ai-'
}
# 由完整名反推项目名(去掉 ai- 前缀与末尾 -<6位数字>)
_aibox_projects() {
    _aibox_running | sed -E 's/^ai-(.*)-[0-9]{6}$/\1/'
}
# enter 的候选 = 完整容器名 + 项目名,去重
_aibox_enter_candidates() {
    { _aibox_running; _aibox_projects; } | sort -u
}

# 主补全函数(bash 原生;zsh 经 bashcompinit 复用同一套)
_aibox_complete() {
    local cur prev
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    if [[ "$COMP_CWORD" -eq 1 ]]; then
        COMPREPLY=( $(compgen -W "cc claude codex list ls enter stop logs clear prune start build update version status help" -- "$cur") )
        return 0
    fi
    case "$prev" in
        # 接容器目标的子命令:补全运行中的容器名 / 项目名
        enter|logs)
                COMPREPLY=( $(compgen -W "$(_aibox_enter_candidates)" -- "$cur") ) ;;
        stop)   COMPREPLY=( $(compgen -W "$(_aibox_enter_candidates) --all" -- "$cur") ) ;;
        update) COMPREPLY=( $(compgen -W "cc codex" -- "$cur") ) ;;
        build)  COMPREPLY=( $(compgen -W "--no-cache" -- "$cur") ) ;;
        *)      COMPREPLY=() ;;
    esac
    return 0
}

if [[ -n "${ZSH_VERSION:-}" ]]; then
    # zsh:借 bashcompinit 复用上面的 bash 补全函数
    autoload -Uz +X compinit bashcompinit 2>/dev/null
    # 已初始化过 compinit 的环境不重复跑(避免拖慢启动 / 重复告警)
    (( ${+functions[compdef]} )) || compinit -u 2>/dev/null
    bashcompinit 2>/dev/null
fi

# bash 与 zsh(bashcompinit 提供 complete)都走这行
complete -F _aibox_complete aibox ai-box 2>/dev/null

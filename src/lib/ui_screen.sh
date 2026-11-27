if [[ -t 1 ]]; then
  C_G=$'\e[32m'; C_Y=$'\e[33m'; C_R=$'\e[31m'; C_B=$'\e[1m'; C_D=$'\e[90m'; C_0=$'\e[0m'
else
  C_G=''; C_Y=''; C_R=''; C_B=''; C_D=''; C_0=''
fi

log()  { printf '%s[%s]%s %s\n' "${C_B}" "${SCRIPT_NAME}" "${C_0}" "$*"; }
warn() { printf '%s[%s]%s %s\n' "${C_Y}" "${SCRIPT_NAME}" "${C_0}" "$*" >&2; }
die()  { printf '%s[%s]%s %s\n' "${C_R}" "${SCRIPT_NAME}" "${C_0}" "$*" >&2; exit 1; }

err_trap() { die "行 ${1}: ${2}"; }

# 动作级失败：打印原因后返回 1，由调用方中止当前动作/流程。
# 与 die 的区别：die 用于启动前置检查与输入中断（进程已无法继续），
# die_action 用于动作内的安全检查（TUI 必须活下来，用户可改完再来）。
die_action() { warn "$*"; return 1; }

# 动作隔离：菜单里的动作一律经 act 调用。
# 关掉 errexit 与 ERR trap 只作用于本次动作——TUI 必须活下来，
# 动作内的每一步危险操作都有显式 `|| die_action` / `if !` 判错（与 08-swap 的段落内判错同源）。
act() {
  local rc=0 had_e=0
  case "$-" in *e*) had_e=1 ;; esac
  set +e
  trap - ERR
  "$@" || rc=$?
  trap 'err_trap "${LINENO}" "${BASH_COMMAND}"' ERR
  # 只恢复调用前的状态：菜单动作内可能再嵌套 act，不能把 -e 强推给外层
  if (( had_e )); then set -e; fi
  return "${rc}"
}
trap 'err_trap "${LINENO}" "${BASH_COMMAND}"' ERR

# Ctrl-C：写操作可能只做了一半，提示按当前系统状态收敛
ui_abort() {
  printf '\n%s[中断]%s 已停止。若刚做过写操作，配置可能只改了一半；重新进入 TUI 会按当前系统状态收敛。\n' \
    "${C_Y}" "${C_0}" >&2
  exit 130
}
trap 'ui_abort' INT

# ============ 屏幕契约 ============
# 仅在 stdout 是 TTY 且 TERM 可用、非 dumb 时清屏。动作输出、错误诊断与闸门提示
# 在用户按键确认前不清屏；非法输入不整页重绘。
SCR_CLEAR=0
if [[ -t 1 ]]; then
  case "${TERM:-}" in
    ''|dumb|unknown) SCR_CLEAR=0 ;;
    *) SCR_CLEAR=1 ;;
  esac
fi

scr_clear() {
  if (( SCR_CLEAR )); then printf '\e[H\e[2J'; fi
  return 0
}

scr_pause() {   # scr_pause [提示]：等用户看完输出再继续
  local msg="${1:-按回车继续…}" _x
  printf '%s%s%s' "${C_D}" "${msg}" "${C_0}"
  read -r _x || true
  return 0
}

page_wait() {   # page_wait [提示]：确认看完输出 -> 清屏 -> 回上层
  scr_pause "${1:-按回车返回…}"
  scr_clear
  return 0
}


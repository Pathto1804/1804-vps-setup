# ============ 交互原语 ============
# 提示后缀口径（四种，全脚本只允许这四种；中文圆括号，方括号只放输入类别/编号区间）：
#   有默认值  （回车=默认 X）   可留空  （可留空=留空的后果）
#   必填      （必填）          取消/返回（回车=取消）/（回车=返回）/（回车=暂不指定）
ask_yesno() {
  # 显示恒为小写 [y/n]，默认值写在圆括号里；输入大小写不限，只认 y/yes/n/no
  local prompt="$1" def="${2:-n}" ans hint
  case "${def}" in
    y|Y) def=y; hint="是" ;;
    *)   def=n; hint="否" ;;
  esac
  while :; do
    read -rp "${prompt} [y/n]（回车=${hint}） " ans || return 1
    ans="${ans:-${def}}"
    case "${ans,,}" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *)     printf '%s无效输入：请输入 y 或 n。%s\n' "${C_Y}" "${C_0}" >&2 ;;
    esac
  done
}

ask_input() {
  local prompt="$1" v="$2" val
  while :; do
    read -rp "${prompt}（必填）: " val || die "输入中断"
    if "${v}" "${val}"; then printf '%s' "${val}"; return 0; fi
  done
}

ask_input_def() {
  # ask_input_def <提示> <校验函数名> <默认值>——空输入取默认值
  local prompt="$1" v="$2" def="$3" val
  while :; do
    read -rp "${prompt}（回车=默认 ${def}）: " val || die "输入中断"
    val="${val:-${def}}"
    if "${v}" "${val}"; then printf '%s' "${val}"; return 0; fi
  done
}

ask_input_opt() {
  # ask_input_opt <提示> <校验函数名> <留空含义>——空输入返回空串（不是默认值）
  local prompt="$1" v="$2" blank="$3" val
  while :; do
    read -rp "${prompt}（可留空=${blank}）: " val || die "输入中断"
    if "${v}" "${val}"; then printf '%s' "${val}"; return 0; fi
  done
}

# ask_menu <提示> <最大编号> [零号含义]：结果写入全局 UI_REPLY（0..max）
# 空回车 = 0（子菜单返回）；非法输入原地重问，不重绘菜单
ask_menu() {
  local prompt="$1" max="$2" zero="${3:-返回主菜单}" input
  while :; do
    read -rp "${prompt} [0-${max}]（回车=${zero}）: " input || die "输入中断"
    input="${input:-0}"
    if [[ "${input}" =~ ^[0-9]+$ ]] && (( input <= max )); then
      # shellcheck disable=SC2034  # 由调用方读取
      UI_REPLY="${input}"; return 0
    fi
    warn "无效输入：请输入 0-${max}"
  done
}


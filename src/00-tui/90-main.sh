# ============ 主菜单 ============
draw_main_menu() {
  local sshp keys admin_ok=0
  auto_detect_admin
  sshp="$(sshd_port)"
  keys="$(ak_count)"
  fw_refresh
  scr_clear
  ui_rule
  printf '%s 1804 VPS Setup TUI%s %s（原生状态，无项目私有配置文件）%s\n' "${C_B}" "${C_0}" "${C_D}" "${C_0}"
  ui_sep
  if [[ -n "${sshp}" ]]; then ui_kv "SSH 端口" "${sshp}"; else ui_kv "SSH 端口" "$(ui_no '未知（sshd -T 失败）')"; fi
  case "$(fw_state)" in
    active) ui_kv "UFW" "$(ui_yes 'active ✓')" ;;
    未安装) ui_kv "UFW" "$(ui_no '未安装')" ;;
    *)      ui_kv "UFW" "$(ui_no "$(fw_state) ⚠")" ;;
  esac
  if [[ -n "${ADMIN_USER}" ]] && user_exists "${ADMIN_USER}"; then admin_ok=1; fi
  if (( admin_ok )); then ui_kv "管理员" "${ADMIN_USER}"
  elif [[ -n "${ADMIN_USER}" ]]; then ui_kv "管理员" "$(ui_no "${ADMIN_USER}（不存在）⚠")"
  else ui_kv "管理员" "${C_D}未确定（按需选择）${C_0}"; fi
  if (( admin_ok )) && [[ "${keys}" -gt 0 ]]; then ui_kv "公钥" "${keys} 把"
  elif (( admin_ok )); then ui_kv "公钥" "$(ui_no '0 把 ⚠')"
  else ui_kv "公钥" "${C_D}—${C_0}"; fi
  if f2b_installed; then
    if fail2ban-client status sshd >/dev/null 2>&1; then ui_kv "fail2ban" "$(ui_yes 'sshd jail 运行中 ✓')"
    else ui_kv "fail2ban" "$(ui_no '已安装，jail 未就绪 ⚠')"; fi
  else
    ui_kv "fail2ban" "$(ui_no '未安装')"
  fi
  ui_kv "Swap" "$(swap_summary)"
  ui_kv "BBR" "$(bbr_cc)"
  ui_kv "自动更新" "$(ua_state)"
  ui_sep
  ui_item 0 "标准初始化（按顺序引导全流程）"
  ui_item 1 "系统换源（LinuxMirrors 第三方脚本）"
  ui_item 2 "系统更新与基础工具"
  ui_item 3 "时区"
  ui_item 4 "用户、密码、sudo 和密钥"
  ui_item 5 "UFW 与 SSH"
  ui_item 6 "fail2ban"
  ui_item 7 "Swap"
  ui_item 8 "BBR"
  ui_item 9 "终检与报告"
  printf '  %sq%s) 退出\n' "${C_R}" "${C_0}"
  ui_sep
}

ask_main() {
  local input
  while :; do
    read -rp "选择 [0-9]（q=退出）: " input || die "输入中断"
    case "${input}" in
      q|Q) MAIN_REPLY="q"; return 0 ;;
      0|1|2|3|4|5|6|7|8|9) MAIN_REPLY="${input}"; return 0 ;;
      *) warn "无效输入：请输入 0-9，或 q 退出" ;;
    esac
  done
}

main() {
  require_root
  require_tty
  require_distro
  while :; do
    draw_main_menu
    ask_main
    case "${MAIN_REPLY}" in
      q) break ;;
      0)
        act do_standard_init || true
        page_wait "按回车返回主菜单…"
        ;;
      1) act mirror_info_menu ;;
      2) act base_menu ;;
      3) act timezone_menu ;;
      4) act user_menu ;;
      5) act fw_menu ;;
      6) act f2b_menu ;;
      7) scr_clear; act run_swap_menu || true ;;
      8) act bbr_menu ;;
      9) act verify_menu ;;
    esac
  done
  printf '\n%s再见。%s\n' "${C_D}" "${C_0}"
  return 0
}

main "$@"

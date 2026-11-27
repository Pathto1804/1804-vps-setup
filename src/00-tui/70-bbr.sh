# ============ 模块 8：BBR ============
# 只读模块：不内置、不写入任何 TCP 调优参数集，只显示当前状态与外部来源指引。
BBR_SITE="https://omnitt.com"

bbr_external_notes() {
  printf '  本程序不提供 BBR/TCP 调优参数集，也不会写入任何 sysctl 调优配置。\n'
  printf '  需要调优时按外部来源自行获取：%s\n' "${BBR_SITE}"
  printf '  本项目不提供、不维护该站点的脚本，也未对当前在线版本完成安全审计。\n'
  printf '  只有在你自行审阅并接受以 root 执行第三方代码的风险后才应用；应用前确认已创建 Snapshot。\n'
}

bbr_do_show() {
  printf '%s── 当前 sysctl 值 ──%s\n' "${C_D}" "${C_0}"
  sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc 2>/dev/null || warn "sysctl 查询失败"
  printf '\n%s── %s ──%s\n' "${C_D}" "${BBR_CONF}" "${C_0}"
  if [[ -f "${BBR_CONF}" ]]; then
    cat "${BBR_CONF}"
  else
    warn "未找到 ${BBR_CONF}（本程序不写入该文件；若已按外部说明自行应用，请确认路径）"
  fi
  return 0
}

bbr_menu() {
  local cc qc cfg_state
  while :; do
    cc="$(bbr_cc)"
    qc="$(bbr_qdisc)"
    if [[ -f "${BBR_CONF}" ]]; then cfg_state="已存在（非本程序写入）"; else cfg_state="$(ui_no '不存在')"; fi
    scr_clear
    ui_rule
    printf '%s BBR%s\n' "${C_B}" "${C_0}"
    ui_sep
    ui_kv "拥塞控制" "$( [[ "${cc}" == "bbr" ]] && printf '%s' "$(ui_yes 'bbr ✓')" || printf '%s' "$(ui_no "${cc}")" )"
    ui_kv "队列规则" "${qc}"
    ui_kv "配置文件" "${cfg_state}"
    ui_sep
    ui_item 1 "查看外部来源与风险说明"
    ui_item 2 "查看当前 sysctl 值与配置文件"
    ui_quit
    ui_sep
    ask_menu "选择操作" 2
    case "${UI_REPLY}" in
      0) return 0 ;;
      1) printf '\n'; bbr_external_notes ;;
      2) bbr_do_show ;;
    esac
    page_wait "按回车返回 BBR 菜单…"
  done
}


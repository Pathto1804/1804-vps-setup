# ============ 模块 6：fail2ban ============
f2b_write_jail() {   # <端口> <bantime> <findtime> <maxretry>；jail 就绪返回 0，否则返回 1
  local port="$1" bantime="$2" findtime="$3" maxretry="$4" jail_ok=0
  backup_file "${JAIL}" >/dev/null || true
  if ! printf '[sshd]\nenabled = true\nport = %s\nbackend = systemd\nbantime = %s\nfindtime = %s\nmaxretry = %s\n' \
    "${port}" "${bantime}" "${findtime}" "${maxretry}" > "${JAIL}"; then
    die_action "写入 ${JAIL} 失败"
    return 1
  fi
  systemctl enable fail2ban || warn "启用 fail2ban 开机自启失败，请检查 systemctl status fail2ban"
  if ! systemctl restart fail2ban; then
    die_action "重启 fail2ban 失败：systemctl status fail2ban / journalctl -u fail2ban -n 50"
    return 1
  fi
  # 验证：restart 返回 ≠ jail 就绪（fail2ban 读配置、起 systemd backend、建 socket 需 1~2s）
  # 立刻查询会误判"jail 未启动"，轮询等待
  for _ in $(seq 1 20); do
    if fail2ban-client status sshd >/dev/null 2>&1; then jail_ok=1; break; fi
    sleep 0.5
  done
  if [[ "${jail_ok}" -ne 1 ]]; then
    warn "fail2ban sshd jail 10 秒内未就绪，请检查：systemctl status fail2ban; journalctl -u fail2ban -n 50"
    return 1
  fi
  return 0
}

f2b_apply() {
  local port bantime findtime maxretry
  if ! f2b_installed; then
    log "安装 fail2ban……"
    if ! apt_install_pkgs fail2ban; then
      die_action "安装 fail2ban 失败（检查网络与软件源）"
      return 1
    fi
  fi
  # 端口闸门（fail closed）：读不到 sshd 实际端口就不写 jail——盯错端口是静默失效
  port="$(sshd_port)"
  if [[ -z "${port}" ]]; then
    warn "读不到 sshd 实际端口（sshd -T 失败），拒绝写入 ${JAIL}"
    warn "先确认 sshd -T 能跑（常见：/run/sshd 缺失，mkdir -p /run/sshd）"
    return 1
  fi
  bantime="$(ask_input_def "封禁时长 单位秒" v_posint "$(f2b_param bantime 86400)")" \
    || { warn "输入中断，未写入 ${JAIL}"; return 1; }
  findtime="$(ask_input_def "统计窗口 单位秒" v_posint "$(f2b_param findtime 600)")" \
    || { warn "输入中断，未写入 ${JAIL}"; return 1; }
  maxretry="$(ask_input_def "最大重试次数" v_posint "$(f2b_param maxretry 3)")" \
    || { warn "输入中断，未写入 ${JAIL}"; return 1; }
  if ! f2b_write_jail "${port}" "${bantime}" "${findtime}" "${maxretry}"; then
    return 1
  fi
  log "fail2ban sshd jail 已启用（端口 ${port} / ${maxretry} 次 / ${bantime}s）"
  fail2ban-client status sshd
  return 0
}

f2b_do_status() {
  local out
  printf '%s── jail.local（%s）──%s\n' "${C_D}" "${JAIL}" "${C_0}"
  if [[ -f "${JAIL}" ]]; then
    cat "${JAIL}"
  else
    warn "未找到 ${JAIL}（尚未应用配置）"
  fi
  printf '\n%s── fail2ban-client status sshd ──%s\n' "${C_D}" "${C_0}"
  if ! f2b_installed; then
    warn "未安装 fail2ban-client"
  else
    out="$(f2b_status_raw)"
    if [[ -n "${out}" ]]; then
      printf '%s\n' "${out}"
    else
      warn "查询失败：服务未运行或 sshd jail 未启用（systemctl status fail2ban）"
    fi
  fi
  printf '\n%s── 服务日志（最近 20 行）──%s\n' "${C_D}" "${C_0}"
  journalctl -u fail2ban -n 20 --no-pager 2>/dev/null || warn "无日志输出（journalctl 不可用）"
  return 0
}

f2b_do_params() {
  local cur_b cur_f cur_m v
  if ! f2b_installed; then
    warn "fail2ban 尚未安装：请先选 1 安装并初始化"
    return 0
  fi
  cur_b="$(f2b_param bantime 86400)"
  cur_f="$(f2b_param findtime 600)"
  cur_m="$(f2b_param maxretry 3)"
  log "当前参数（来自 ${JAIL}，缺失取默认）：bantime=${cur_b} / findtime=${cur_f} / maxretry=${cur_m}"
  v="$(ask_input_def "封禁时长 单位秒" v_posint "${cur_b}")" \
    || { warn "输入中断，未改动参数"; return 0; }
  local nb="$v"
  v="$(ask_input_def "统计窗口 单位秒" v_posint "${cur_f}")" \
    || { warn "输入中断，未改动参数"; return 0; }
  local nf="$v"
  v="$(ask_input_def "最大重试次数" v_posint "${cur_m}")" \
    || { warn "输入中断，未改动参数"; return 0; }
  local nm="$v"
  if [[ "${nb}" == "${cur_b}" && "${nf}" == "${cur_f}" && "${nm}" == "${cur_m}" ]]; then
    log "参数未变化，未改动 ${JAIL}"
    return 0
  fi
  if ask_yesno "立即写入 ${JAIL} 并重启 fail2ban？" y; then
    local port
    port="$(sshd_port)"
    if [[ -z "${port}" ]]; then
      warn "读不到 sshd 实际端口，拒绝写入 ${JAIL}"
      return 0
    fi
    f2b_write_jail "${port}" "${nb}" "${nf}" "${nm}" || return 0
    log "参数已应用：bantime=${nb} / findtime=${nf} / maxretry=${nm}"
    fail2ban-client status sshd || true
  else
    log "未应用：${JAIL} 仍是旧参数"
  fi
  return 0
}

f2b_do_ban() {
  local op ip
  if ! f2b_installed || ! fail2ban-client status sshd >/dev/null 2>&1; then
    warn "fail2ban 未运行或 sshd jail 未启用，先应用配置"
    return 0
  fi
  ui_item 1 "封禁 IP"
  ui_item 2 "解封 IP"
  ui_quit
  ask_menu "选择操作" 2
  op="${UI_REPLY}"
  [[ "${op}" == "0" ]] && return 0
  ip="$(ask_input "IP 地址" v_ip)" || { warn "输入中断，已取消"; return 0; }
  if [[ "${op}" == "1" ]]; then
    if ask_yesno "确认封禁 ${ip}？" n; then
      fail2ban-client set sshd banip "${ip}" || warn "封禁失败（该 IP 可能已在封禁列表中）"
      log "已请求封禁 ${ip}"
    else
      log "已取消"
    fi
  else
    fail2ban-client set sshd unbanip "${ip}" || warn "解封失败（该 IP 可能不在封禁列表中）"
    log "已请求解封 ${ip}"
  fi
  printf '\n'
  fail2ban-client status sshd || true
  return 0
}

f2b_menu() {
  local f2b_desc jail_desc p_desc port_desc a_port j_port st raw jb jf jm
  while :; do
    if ! f2b_installed; then
      f2b_desc="$(ui_no '未安装 ⚠')"
      jail_desc="$(ui_no '不可用（未安装 fail2ban）')"
    else
      st="$(systemctl is-active fail2ban 2>/dev/null)" || true
      if [[ "${st}" == "active" ]]; then f2b_desc="$(ui_yes 'active ✓')"; else f2b_desc="$(ui_no "${st:-未知} ⚠")"; fi
      raw="$(f2b_status_raw)"
      if [[ -n "${raw}" ]]; then
        jail_desc="$(ui_yes '运行中 ✓')（封禁 $(printf '%s\n' "${raw}" | awk '/Currently banned:/{c=$NF} END{print c+0}') 个）"
      else
        jail_desc="$(ui_no '未启用 ⚠')"
      fi
    fi
    jb="$(jail_val bantime)"; jf="$(jail_val findtime)"; jm="$(jail_val maxretry)"
    if [[ -z "${jb}" && -z "${jf}" && -z "${jm}" ]]; then
      p_desc="$(ui_no '未写入 jail.local ⚠')"
    else
      p_desc="bantime ${jb:-?} / findtime ${jf:-?} / maxretry ${jm:-?}"
    fi
    a_port="$(sshd_port)"
    j_port="$(jail_val port)"
    if [[ -z "${a_port}" ]]; then
      port_desc="$(ui_no 'sshd 实际端口未知 ⚠')（jail ${j_port:-未写入}）"
    elif [[ -z "${j_port}" ]]; then
      port_desc="$(ui_no 'jail 端口未写入 ⚠')（sshd 实际 ${a_port}）"
    elif [[ "${j_port}" == "${a_port}" ]]; then
      port_desc="${j_port} = sshd 实际 ✓"
    else
      port_desc="$(ui_no "jail ${j_port} != sshd 实际 ${a_port} ⚠")"
    fi
    scr_clear
    ui_rule
    printf '%s fail2ban · sshd jail%s\n' "${C_B}" "${C_0}"
    ui_sep
    ui_kv "服务" "${f2b_desc}"
    ui_kv "jail 状态" "${jail_desc}"
    ui_kv "参数" "${p_desc}"
    ui_kv "端口" "${port_desc}"
    ui_sep
    ui_item 1 "应用 / 重新应用配置（安装 + 写 jail.local + 重启 + 验证）"
    ui_item 2 "查看状态详情（jail.local / 封禁列表 / 服务日志）"
    ui_item 3 "修改参数（封禁时长 / 统计窗口 / 重试次数）"
    ui_item 4 "封禁 / 解封 IP"
    ui_quit
    ui_sep
    ask_menu "选择操作" 4
    case "${UI_REPLY}" in
      0) return 0 ;;
      1) act f2b_apply || true ;;
      2) act f2b_do_status ;;
      3) act f2b_do_params ;;
      4) act f2b_do_ban ;;
    esac
    page_wait "按回车返回 fail2ban 菜单…"
  done
}


# ============ 模块 9：终检与报告 ============
V_RED=0
V_YEL=0
V_OK=0
declare -a V_LINES=()
chk_ok()    { V_OK=$((V_OK+1));  V_LINES+=("✓ $*"); printf '  %s✓%s %s\n' "${C_G}" "${C_0}" "$*"; }
chk_bad()   { V_RED=$((V_RED+1)); V_LINES+=("✗ $*"); printf '  %s✗%s %s\n' "${C_R}" "${C_0}" "$*"; }
chk_warn()  { V_YEL=$((V_YEL+1)); V_LINES+=("! $*"); printf '  %s!%s %s\n' "${C_Y}" "${C_0}" "$*"; }

run_verify() {
  # 只读：全部结论来自当前系统状态，不从任何缓存推断历史端口/历史选择
  local actual pwd_auth root_login jail_raw j_port cc disk_usage
  V_RED=0; V_YEL=0; V_OK=0; V_LINES=()

  log "1804 VPS Setup 终检"
  printf '\n'

  # ---- sshd 实际生效值 ----
  actual="$(sshd_port)"
  if ! command -v sshd >/dev/null 2>&1; then
    chk_bad "未找到 sshd，无法校验端口/认证策略"
  elif [[ -z "${actual}" ]]; then
    chk_bad "sshd 实际端口无法读取（sshd -T 失败）"
  else
    pwd_auth="$(eff_val "$(ssh_eff)" passwordauthentication)"
    root_login="$(eff_val "$(ssh_eff)" permitrootlogin)"
    chk_ok "sshd 实际端口 = ${actual}"
    if [[ "${pwd_auth}" == "no" ]]; then chk_ok "passwordauthentication = no"; else chk_bad "passwordauthentication = ${pwd_auth:-未知}（须为 no）"; fi
    if [[ "${root_login}" == "no" ]]; then chk_ok "permitrootlogin = no"; else chk_bad "permitrootlogin = ${root_login:-未知}（须为 no）"; fi
  fi

  # ---- ufw ----
  fw_refresh
  if ! command -v ufw >/dev/null 2>&1; then
    chk_bad "ufw 未安装"
  elif [[ "$(fw_state)" != "active" ]]; then
    chk_bad "ufw 未启用"
  else
    chk_ok "ufw 已启用（规则 $(fw_rule_count) 条）"
    if [[ -n "${actual}" ]] && fw_has_rule "${actual}/tcp"; then
      chk_ok "ufw 已放行当前 SSH 端口 ${actual}/tcp"
    else
      chk_bad "ufw 未放行当前 SSH 端口 ${actual:-?}/tcp"
    fi
    # 不再从缓存推断历史旧端口：规则全量在报告里，由人工核对
    chk_warn "历史端口无法自动判定：请人工核对下方规则中不再需要的历史 SSH 端口已移除（本程序不保存旧端口）"
  fi

  # ---- fail2ban ----
  if ! command -v fail2ban-client >/dev/null 2>&1; then
    chk_bad "fail2ban 未安装"
  elif systemctl is-active --quiet fail2ban && fail2ban-client status sshd >/dev/null 2>&1; then
    chk_ok "fail2ban sshd jail 运行中"
    # jail 端口：未写 port 时 fail2ban 用默认端口 22
    jail_raw="$(jail_val port)"
    jail_raw="${jail_raw//[[:space:]]/}"
    if [[ ! -f "${JAIL}" || -z "${actual}" ]]; then
      chk_warn "无法确认 jail 端口与 sshd 一致（缺 jail.local 或读不到 sshd 端口），请人工核对 ${JAIL}"
    elif [[ "${jail_raw:-22}" == "${actual}" ]]; then
      chk_ok "jail.local 端口与 sshd 一致（${actual}）"
    elif [[ -z "${jail_raw}" ]]; then
      chk_bad "jail.local 未写 port：fail2ban 盯默认端口 22，而 sshd 在 ${actual}——该端口的爆破拦不住"
    elif [[ "${jail_raw}" =~ ^[0-9]+$ ]]; then
      chk_bad "jail.local 端口 ${jail_raw} != sshd 实际端口 ${actual}：fail2ban 封的是 ${jail_raw} 的流量"
    else
      chk_warn "jail.local 的 port 写法（${jail_raw}）非纯数字，无法判定是否覆盖 ${actual}"
    fi
  else
    chk_bad "fail2ban 未运行或 sshd jail 未启用"
  fi

  # ---- 自动安全更新 ----
  if ua_enabled; then chk_ok "unattended-upgrades 已启用"; else chk_bad "unattended-upgrades 未正确配置（检查 ${UA_FILE}）"; fi
  if command -v needrestart >/dev/null 2>&1; then
    chk_ok "needrestart 已安装（升级后会提示重启受影响服务）"
  else
    chk_bad "needrestart 未安装（自动更新后服务不重启，libc/openssl 补丁不生效）"
  fi

  # ---- 黄灯项 ----
  if swap_active; then chk_ok "swap 已启用"; else chk_warn "swap 未启用（如内存充裕可接受）"; fi
  cc="$(bbr_cc)"
  if [[ "${cc}" == "bbr" ]]; then chk_ok "BBR 已启用"; else chk_warn "BBR 未启用（当前 ${cc:-未知}）"; fi
  if ntp_active; then chk_ok "NTP 时间同步正常"; else chk_warn "NTP 未激活"; fi
  disk_usage="$(df -P / | awk 'NR==2{gsub(/%/,""); print $5}')"
  if [[ "${disk_usage:-100}" -lt 90 ]]; then chk_ok "根分区使用率 ${disk_usage}%"; else chk_warn "根分区使用率 ${disk_usage:-?}%（≥90%）"; fi
  if [[ -f /var/run/reboot-required ]]; then chk_warn "存在 reboot-required，建议重启"; else chk_ok "无需重启"; fi

  # ---- 报告：只由实时检查结果生成 ----
  local hostn date_str os_name
  hostn="$(hostname)"
  date_str="$(date '+%Y-%m-%d %H:%M:%S')"
  os_name="$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2)" || true
  {
    printf '# 1804 VPS Setup 终检报告\n\n'
    printf -- '- 主机： %s\n' "${hostn}"
    printf -- '- 时间： %s\n' "${date_str}"
    printf -- '- 发行版： %s\n' "${os_name:-未知}"
    echo ""
    printf '## 当前系统状态（实时读取，非缓存）\n\n'
    printf -- '- SSH 端口（sshd -T）： %s\n' "${actual:-未知}"
    printf -- '- AllowUsers（sshd -T）： %s\n' "$(eff_val "$(ssh_eff)" allowusers)"
    printf -- '- 管理员用户（本次进程）： %s\n' "${ADMIN_USER:-未确定}"
    printf -- '- ufw： %s（入站默认 %s / 出站默认 %s，规则 %s 条）\n' "$(fw_state)" "$(fw_default_in)" "$(fw_default_out)" "$(fw_rule_count)"
    printf -- '- fail2ban： %s；jail port = %s\n' "$(systemctl is-active fail2ban 2>/dev/null || true)" "${jail_raw:-未写入}"
    printf -- '- swap： %s；swappiness = %s\n' "$(swap_summary)" "$(swappiness_now)"
    printf -- '- BBR： %s；qdisc = %s\n' "$(bbr_cc)" "$(bbr_qdisc)"
    printf -- '- 自动安全更新： %s\n' "$(ua_state)"
    echo ""
    printf '## ufw 规则（人工核对：不再需要的历史 SSH 端口应已移除）\n\n'
    if [[ "$(fw_state)" == "active" ]]; then
      printf '```\n%s\n```\n' "${FW_RAW}"
    else
      printf '```\n%s\n```\n' "${FW_ADDED}"
    fi
    echo ""
    printf '## 检查结果（通过 %s / 红灯 %s / 提示 %s）\n\n' "${V_OK}" "${V_RED}" "${V_YEL}"
    if (( ${#V_LINES[@]} > 0 )); then
      printf '%s\n' "${V_LINES[@]}"
    fi
  } > "${REPORT}" || true

  printf '\n'
  if [[ -s "${REPORT}" ]]; then
    log "报告已写入 ${REPORT}"
  else
    warn "报告写入失败（${REPORT}）：检查 /root 是否可写；检查结果仍在上方屏幕输出中"
  fi
  if [[ "${V_RED}" -gt 0 ]]; then
    warn "存在 ${V_RED} 项红灯：安全基线未达成"
    return 1
  fi
  log "无红灯。核对报告后在云平台创建最终 Snapshot。"
  return 0
}

verify_menu() {
  while :; do
    fw_refresh
    scr_clear
    ui_rule
    printf '%s 终检与报告%s\n' "${C_B}" "${C_0}"
    ui_sep
    ui_kv "报告路径" "${REPORT}"
    ui_kv "报告状态" "$( [[ -f "${REPORT}" ]] && printf '已存在（%s）' "$(date -r "${REPORT}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '时间未知')" || printf '尚未生成' )"
    ui_kv "SSH 端口" "$(sshd_port)"
    ui_kv "ufw" "$(fw_state)"
    ui_sep
    ui_item 1 "运行终检并生成报告（只读检查）"
    ui_item 2 "查看当前报告"
    ui_quit
    ui_sep
    ask_menu "选择操作" 2
    case "${UI_REPLY}" in
      0) return 0 ;;
      1) act run_verify || true ;;
      2)
        if [[ -f "${REPORT}" ]]; then cat "${REPORT}"; else warn "报告尚未生成"; fi
        ;;
    esac
    page_wait "按回车返回终检菜单…"
  done
}
mirror_instructions() {
  printf '  第三方来源：SuperManito 的 LinuxMirrors（%s）\n' "${LINUXMIRRORS_URL}"
  printf '  免责声明：本项目不提供或维护该脚本，也未对当前在线版本完成全量安全审计。\n'
  printf '  只有在你自行审阅并接受以 root 执行第三方代码的风险后才运行。\n'
  printf '  运行前确认已创建 Snapshot；对应命令：\n'
  printf '    bash <(curl -fsSL %s)\n' "${LINUXMIRRORS_URL}"
  printf '  若随后继续本流程，请在第三方脚本中选择不升级软件包；本流程稍后会处理升级。\n'
}

mirror_execute_linuxmirrors() {
  local tmp rc=0
  if ! command -v curl >/dev/null 2>&1; then
    warn "缺少 curl 命令，无法自动拉取换源脚本"
    if ! ask_yesno "现在安装 curl？" y; then
      die_action "已取消（请先安装 curl 或手动换源）"
      return 1
    fi
    apt_update_index || return 1
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y curl; then
      die_action "安装 curl 失败"
      return 1
    fi
  fi
  tmp="$(mktemp /tmp/linuxmirrors.XXXXXX.sh)" || { die_action "创建临时脚本失败"; return 1; }
  log "拉取 ${LINUXMIRRORS_URL}"
  if ! curl -fsSL -o "${tmp}" "${LINUXMIRRORS_URL}" || [[ ! -s "${tmp}" ]]; then
    rm -f -- "${tmp}"
    die_action "下载换源脚本失败（检查网络或手动执行上方命令）"
    return 1
  fi
  bash "${tmp}" || rc=$?
  rm -f -- "${tmp}"
  if (( rc != 0 )); then
    die_action "换源脚本退出异常（exit ${rc}）"
    return 1
  fi
  log "系统换源脚本执行完成"
  return 0
}

mirror_info_menu() {
  scr_clear
  ui_rule
  printf '%s 系统换源（LinuxMirrors 第三方脚本）%s\n' "${C_B}" "${C_0}"
  ui_sep
  mirror_instructions
  ui_sep
  if ask_yesno "已阅读以上免责声明并自愿承担风险，是否立即执行换源命令？" n; then
    mirror_execute_linuxmirrors || true
  else
    log "未自动执行；如需手动运行可复制上方命令"
  fi
  page_wait "按回车返回主菜单…"
}

timezone_do_set() {
  local current tz backup_dir choice label
  local -a zones=(
    "Asia/Shanghai"
    "UTC"
    "Asia/Tokyo"
    "Asia/Singapore"
    "Europe/London"
    "America/New_York"
  )
  current="$(cur_tz)"
  printf '当前时区：%s\n' "${current}"
  printf '常用时区：\n'
  local i
  for i in "${!zones[@]}"; do
    label="${zones[i]}"
    (( i == 0 )) && label+="（推荐）"
    printf '  %d) %s\n' "$((i + 1))" "${label}"
  done
  ask_menu "选择时区" "${#zones[@]}" "取消"
  choice="${UI_REPLY}"
  if [[ "${choice}" == "0" ]]; then
    log "已取消时区修改"
    return 0
  fi
  tz="${zones[$((choice - 1))]}"
  if ! timezone_valid "${tz}"; then
    die_action "系统不支持所选时区：${tz}"
    return 1
  fi
  if [[ "${tz}" == "${current}" ]]; then
    log "时区已是 ${tz}，未修改"
    return 0
  fi
  if ! ask_yesno "确认将时区从 ${current} 改为 ${tz}？" n; then
    log "已取消时区修改"
    return 0
  fi
  backup_dir="$(backup_file /etc/localtime)" || {
    die_action "备份 /etc/localtime 失败，未修改时区"
    return 1
  }
  if [[ -z "${backup_dir}" || ( ! -e "${backup_dir}/localtime" && ! -L "${backup_dir}/localtime" ) ]]; then
    die_action "未能确认 /etc/localtime 备份，未修改时区"
    return 1
  fi
  if ! timedatectl set-timezone "${tz}"; then
    die_action "timedatectl 设置时区失败；原时区为 ${current}，备份位于 ${backup_dir}"
    return 1
  fi
  current="$(cur_tz)"
  if [[ "${current}" != "${tz}" ]]; then
    die_action "时区设置后复查为 ${current}，预期 ${tz}；备份位于 ${backup_dir}"
    return 1
  fi
  log "时区已设置为 ${tz}（复查通过）；原值备份位于 ${backup_dir}"
}


timezone_menu() {
  local current
  while :; do
    current="$(cur_tz)"
    scr_clear
    ui_rule
    printf '%s 时区%s\n' "${C_B}" "${C_0}"
    ui_sep
    ui_kv "当前时区" "${current}"
    ui_kv "NTP" "$(ntp_active && printf 'active' || printf '未 active')"
    ui_sep
    ui_item 1 "修改时区（从常用时区中选择）"
    ui_quit
    ui_sep
    ask_menu "选择操作" 1
    case "${UI_REPLY}" in
      0) return 0 ;;
      1) act timezone_do_set ;;
    esac
    page_wait "按回车返回时区菜单…"
  done
}

# ============ 标准初始化（主菜单 0） ============
step_banner() { printf '\n%s== 步骤 %s · %s ==%s\n' "${C_B}" "$1" "$2" "${C_0}"; }

flow_abort() {   # 中止剩余步骤（不跳过闸门、不做后续写入）
  warn "标准初始化已中止：$*"
  warn "已完成的步骤保留在系统里；重新进入主菜单 0 会按当前系统状态续接。"
  return 1
}

do_standard_init() {
  local cur target tz change_sources=0 size_mb
  scr_clear
  ui_rule
  printf '%s 标准初始化%s\n' "${C_B}" "${C_0}"
  ui_sep
  printf '  按步骤引导：系统更新 → 时区/NTP → 用户/密钥 → UFW/SSH → fail2ban → Swap → BBR → 终检\n'
  printf '  %s每一步只修改未达标项；任何安全检查失败都会中止剩余步骤。%s\n' "${C_D}" "${C_0}"
  ui_sep
  if ask_yesno "标准初始化开始前是否换源（将在 Snapshot 确认后展示命令并询问执行）？" n; then
    change_sources=1
  fi


  # ---- 步骤 1：环境概览 + Snapshot 闸门 ----
  step_banner 1 "环境概览与云平台确认"
  printf '  发行版： %s\n' "$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2)" || true
  printf '  CPU：    %s 核\n' "$(nproc 2>/dev/null || printf '未知')"
  printf '  内存：   %s\n' "$(free -h 2>/dev/null | awk '/^Mem:/{print $2}')" || true
  printf '  磁盘：   %s\n' "$(df -h / 2>/dev/null | awk 'NR==2{print $2"（已用 "$5"）"}')" || true
  cur="$(sshd_port)"
  printf '  SSH 端口： %s\n' "${cur:-$(ui_no '未知（sshd -T 失败）')}"
  printf '\n'
  printf '  %s在开始前请确认：%s\n' "${C_Y}" "${C_0}"
  printf '    1) 已在云平台创建初始 Snapshot（锁死后唯一退路）\n'
  printf '    2) 已知晓云平台安全组当前放行的 SSH 端口\n'
  printf '    3) 本地已准备好 SSH 密钥\n'
  if ! ask_yesno "以上三项都已确认，开始系统修改？" n; then
    return 1
  fi
  if (( change_sources )); then
    printf '\n%s== 可选准备步骤 · 系统换源 ==%s\n' "${C_B}" "${C_0}"
    mirror_instructions
    if ask_yesno "已阅读以上免责声明并自愿承担风险，是否立即执行换源命令？" n; then
      mirror_execute_linuxmirrors || { flow_abort "换源脚本未成功完成，未继续系统更新"; return 1; }
    else
      scr_pause "未自动执行；如你在另一终端手动换源，完成后按回车（Ctrl-C 中止）…"
      if ! ask_yesno "换源已完成（且第三方脚本未升级软件包），继续系统更新？" n; then
        flow_abort "未确认换源完成，未继续系统更新"
        return 1
      fi
    fi
  fi


  # ---- 步骤 2：系统更新与基础工具 ----
  step_banner 2 "系统更新与基础工具"
  apt_update_index || { flow_abort "apt 索引刷新失败，未继续后续步骤"; return 1; }
  apt_full_upgrade || { flow_abort "系统升级失败，未继续后续步骤"; return 1; }
  install_missing_base || { flow_abort "必要包安装失败，未继续后续步骤"; return 1; }
  base_do_extra || { flow_abort "可选工具安装失败，未继续后续步骤"; return 1; }
  ua_enable || { flow_abort "自动安全更新启用失败，未继续后续步骤"; return 1; }
  maybe_reboot

  # ---- 步骤 3：时区与 NTP ----
  step_banner 3 "时区与 NTP"
  tz="$(cur_tz)"
  printf '  当前时区： %s\n' "${tz}"
  if ! timezone_valid "${tz}"; then
    flow_abort "当前时区无效或无法读取；请回主菜单 3 设置有效时区后重跑"
    return 1
  fi
  if ntp_active; then
    printf '  NTP： %s\n' "$(ui_yes 'active ✓')"
    log "有效时区与 NTP 已满足"
  else
    printf '  NTP： %s\n' "$(ui_no '未激活 ⚠')"
    warn "本程序不修改 NTP。请在另一个终端处理并检查 timedatectl；时区菜单只修改时区。"
    scr_pause "完成后按回车重新检测（Ctrl-C 中止）…"
    if ! ntp_active; then
      flow_abort "NTP 仍未 active，未继续后续步骤"
      return 1
    fi
    log "有效时区与 NTP 已达标"
  fi


  # ---- 步骤 4：管理员账号、密码、sudo、公钥 ----
  step_banner 4 "管理员账号与密钥"
  resolve_admin_user --allow-new || { flow_abort "未指定管理员账号，未继续"; return 1; }
  if user_exists "${ADMIN_USER}"; then
    log "用户 ${ADMIN_USER} 已存在"
    if ! usermod -aG sudo "${ADMIN_USER}"; then
      flow_abort "把 ${ADMIN_USER} 加入 sudo 组失败，未继续"
      return 1
    fi
  else
    log "创建用户 ${ADMIN_USER}"
    if ! adduser --gecos "" "${ADMIN_USER}"; then
      flow_abort "创建用户 ${ADMIN_USER} 失败（见上方 adduser 输出），未继续"
      return 1
    fi
    if ! user_exists "${ADMIN_USER}"; then
      flow_abort "adduser 返回成功但 ${ADMIN_USER} 仍不存在，未继续"
      return 1
    fi
    if ! usermod -aG sudo "${ADMIN_USER}"; then
      flow_abort "用户 ${ADMIN_USER} 已创建，但加入 sudo 组失败，未继续"
      return 1
    fi
    log "已创建 ${ADMIN_USER} 并加入 sudo 组"
  fi
  if [[ "$(pw_state "${ADMIN_USER}")" == "P" ]]; then
    log "登录密码已设置（已满足）"
  else
    warn "用户 ${ADMIN_USER} 尚无可用密码"
    if ask_yesno "现在设置登录密码？" y; then
      if ! user_do_password; then
        flow_abort "登录密码未设置成功，未继续"
        return 1
      fi
    else
      warn "跳过密码：仅密钥登录仍可用，但 sudo 需要密码或免密"
    fi
  fi
  log "sudo 免密当前有效状态：$(sudo_state "${ADMIN_USER}")"
  if ask_yesno "开启 sudo 免密（NOPASSWD）？" n; then
    if ! user_do_sudo; then
      flow_abort "sudo 免密配置未成功，未继续"
      return 1
    fi
  fi
  if [[ "$(ak_count)" -eq 0 ]]; then
    warn "authorized_keys 中没有公钥——禁用密码后你将无法登录"
    if ! ask_yesno "现在追加公钥？" y; then
      flow_abort "没有公钥，继续会锁死登录"
      return 1
    fi
    if ! user_do_key_add; then
      flow_abort "写入公钥失败，未继续"
      return 1
    fi
    if [[ "$(ak_count)" -eq 0 ]]; then
      flow_abort "仍未写入公钥，继续会锁死登录"
      return 1
    fi
  else
    log "authorized_keys 已有 $(ak_count) 把公钥（已满足）"
  fi
  if ssh_root_only_allowusers; then
    flow_abort "sshd 有效 AllowUsers 仅允许 root；当前策略阻止 ${ADMIN_USER} 登录，未进行 SSH 加固"
    printf '  请先确保非 root 用户 %s 在现有 AllowUsers 规则中获准登录，保留当前 root 会话，验证该用户的密钥登录后再重跑。\n' "${ADMIN_USER}"
    return 1
  fi
  cur="$(sshd_port)"
  if [[ -z "${cur}" ]]; then
    flow_abort "无法读取当前 SSH 端口，未继续管理员登录验证"
    return 1
  fi
  printf '\n'
  printf '  %s闸门：%s保持当前 root 会话开启；在新终端执行：\n' "${C_Y}" "${C_0}"
  printf '    ssh -o PreferredAuthentications=publickey -o PasswordAuthentication=no -p %s %s@<host>\n' "${cur}" "${ADMIN_USER}"
  printf '  密钥认证成功后，在新终端执行 sudo -v；命令退出码为 0 才通过。密码提示属于 sudo，不是 SSH 登录密码回退。\n'
  if ! ask_yesno "已用上述命令通过密钥登录，并以 sudo -v 验证 sudo？" n; then
    flow_abort "未确认密钥登录与 sudo 均可用，未继续 UFW/SSH 加固"
    return 1
  fi

  # ---- 步骤 5：UFW 先于 sshd ----
  step_banner 5 "UFW 与 SSH 加固"
  cur="$(sshd_port)"
  if [[ -z "${cur}" ]]; then
    flow_abort "读不到 sshd 当前端口（sshd -T 失败）"
    return 1
  fi
  if [[ "${cur}" == "22" || "${cur}" == "2222" ]]; then
    log "sshd 当前端口 ${cur}（常用端口），建议改用自定义端口"
    target="$(ask_input_def "目标 SSH 端口 1024-65535，避开 22/2222" v_ssh_port "$(rand_port)")" \
      || { flow_abort "输入中断，未取得目标 SSH 端口"; return 1; }
  else
    target="${cur}"
    log "sshd 已在自定义端口 ${cur}：沿用该端口"
  fi
  fw_prepare_for_ssh "${cur}" "${target}" || return 1
  if ! ssh_harden "${target}"; then
    flow_abort "SSH 加固未通过闸门，未继续 fail2ban"
    return 1
  fi

  # ---- 步骤 6：fail2ban ----
  step_banner 6 "fail2ban"
  if f2b_installed && fail2ban-client status sshd >/dev/null 2>&1 \
     && [[ "$(jail_val port)" == "$(sshd_port)" ]]; then
    log "fail2ban sshd jail 已就绪且端口一致（已满足）"
  else
    if ! f2b_apply; then
      flow_abort "fail2ban 未就绪或 jail 端口不一致，未继续后续步骤"
      return 1
    fi
  fi

  # ---- 步骤 7：Swap（自动：按内存定档 + swappiness=10） ----
  step_banner 7 "Swap"
  if swap_active; then
    log "swap 已启用（$(swap_summary)），跳过创建"
  else
    size_mb="$(swap_recommend_mb)"
    printf '  当前内存： %s；swap 未启用\n' "$(free -h 2>/dev/null | awk '/^Mem:/{print $2}')"
    printf '  将创建：   /swapfile %sM，写入 fstab 持久化，并设 vm.swappiness=10\n' "${size_mb}"
    if ask_yesno "按以上默认自动创建 swap？" y; then
      if ! run_swap_auto "${size_mb}"; then
        if swap_active; then
          warn "swap 已启用，但自动流程未全部完成（见上方说明）；可回菜单 7 复查 swappiness"
        else
          warn "Swap 未创建成功（见上方说明），继续后续步骤；可用菜单 7 手动处理"
        fi
      fi
    else
      log "跳过 Swap（内存充裕时可接受）"
    fi
  fi

  # ---- 步骤 8：BBR（只读：参数由用户自行从外部获取） ----
  step_banner 8 "BBR 与 TCP 调优"
  printf '  当前拥塞控制： %s（qdisc %s）\n' "$(bbr_cc)" "$(bbr_qdisc)"
  bbr_external_notes
  if ask_yesno "已按外部说明自行应用完成？" n; then
    printf '  重新检测：拥塞控制 = %s（qdisc %s）\n' "$(bbr_cc)" "$(bbr_qdisc)"
    if [[ "$(bbr_cc)" == "bbr" ]]; then
      log "BBR 已启用"
    else
      warn "拥塞控制仍为 $(bbr_cc)：终检会把 BBR 标黄，可稍后回来复查"
    fi
  else
    log "跳过 BBR（本程序不写入任何 sysctl 调优参数）"
  fi

  # ---- 步骤 9：自动更新复核 + Docker 提示 + 终检 ----
  step_banner 9 "自动更新复核、Docker 提示与终检"
  if ua_enabled; then log "自动安全更新：已启用（已满足）"; else warn "自动安全更新未启用：可回主菜单 2 启用"; fi
  printf '\n'
  printf '  %sDocker（仅提示，本程序不安装）：%s\n' "${C_D}" "${C_0}"
  printf '    bash <(curl -fsSL https://linuxmirrors.cn/docker.sh)\n'
  printf '    该脚本会问"是否关闭防火墙"——%s必须选否%s，否则前面配好的 ufw 会被关掉。\n' "${C_Y}" "${C_0}"
  printf '    docker 组权限等价于 root，与"禁 root 登录"的目标冲突，知情即可。\n'
  printf '\n'
  if run_verify; then
    log "标准初始化完成"
  else
    warn "终检存在红灯：按报告逐项修复后可在主菜单 9 重跑终检"
  fi
  printf '\n'
  printf '  %s最后一步：到云平台核对安全组，并创建最终 Snapshot。%s\n' "${C_Y}" "${C_0}"
  return 0
}


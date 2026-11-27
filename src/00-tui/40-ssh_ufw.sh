# ============ 模块 5：UFW 与 SSH ============
do_scan_dropins() {
  # cloud-init 常见：drop-in 覆盖项。sshd 配置先出现者优先，01- 之前的文件会压过本项目配置
  local f
  [[ -d "${SSHD_D}" ]] || return 0
  for f in "${SSHD_D}"/*.conf; do
    [[ -f "${f}" ]] || continue
    [[ "${f}" == "${HARD}" ]] && continue
    if grep -q '^PasswordAuthentication' "${f}" 2>/dev/null; then
      if [[ "${f}" < "${HARD}" ]]; then
        warn "警告：${f} 排序在 01- 之前且含 PasswordAuthentication，会压过本程序的配置。"
      else
        warn "提示：${f} 含 PasswordAuthentication，但排序在 01- 之后，被 01- 压住、不会生效。"
      fi
    fi
  done
  return 0
}

sshd_allowusers_tokens() {   # 从 sshd -T 提取存在的非 root AllowUsers 列表（空格分隔）
  local eff raw tok u
  local -a out=()
  eff="$(ssh_eff)"
  [[ -n "${eff}" ]] || return 0
  raw="$(awk 'tolower($1)=="allowusers"{for(i=2;i<=NF;i++) print $i}' <<<"${eff}")"
  while IFS= read -r tok; do
    [[ -n "${tok}" ]] || continue
    u="${tok%%@*}"
    [[ -n "${u}" && "${u}" != "root" ]] || continue
    user_exists "${u}" || continue
    out+=("${tok}")
  done <<< "${raw}"
  (( ${#out[@]} > 0 )) && printf '%s' "${out[*]}"
  return 0
}

sshd_allowusers_raw() {   # 从 sshd -T 提取完整 allowusers 列表（空格分隔，含顺序）
  awk 'tolower($1)=="allowusers"{for(i=2;i<=NF;i++) printf "%s%s", (n++?" ":""), $i}' <<<"$1"
}

resolve_harden_allowusers() {   # 解析加固要写入的 AllowUsers，写入 HARDEN_ALLOWUSERS
  local existing_au
  local -a au_arr=()
  HARDEN_ALLOWUSERS=""
  existing_au="$(sshd_allowusers_tokens)"
  if [[ -n "${existing_au}" ]]; then
    read -ra au_arr <<< "${existing_au}"
  fi
  if (( ${#au_arr[@]} >= 2 )); then
    if ask_yesno "检测到当前 sshd 已配置多个非 root AllowUsers（${existing_au}），沿用该白名单？" y; then
      HARDEN_ALLOWUSERS="${existing_au}"
      return 0
    fi
  fi
  if [[ -z "${ADMIN_USER}" ]] || ! user_exists "${ADMIN_USER}" || ! user_is_nonroot "${ADMIN_USER}"; then
    resolve_admin_user || true
  fi
  need_admin || return 1
  if ! getent passwd "${ADMIN_USER}" >/dev/null 2>&1; then
    die_action "系统用户 ${ADMIN_USER} 不存在。AllowUsers 写它会让所有账号（含当前会话）下次登录被拒"
    return 1
  fi
  if ! user_is_nonroot "${ADMIN_USER}"; then
    die_action "SSH 加固必须使用非 root 管理员账号（UID 0 禁止）"
    return 1
  fi
  HARDEN_ALLOWUSERS="${ADMIN_USER}"
  return 0
}

ufw_precheck() {   # ufw_precheck <当前端口> <目标端口>：UFW active 时强制检查放行；否则要求显式确认外部防火墙
  local cur="$1" target="$2" st
  if command -v ufw >/dev/null 2>&1; then
    fw_refresh
    st="$(fw_state)"
  else
    st="未安装"
  fi
  if [[ "${st}" == "active" ]]; then
    if ! fw_has_rule "${target}/tcp"; then
      die_action "ufw 已启用但未放行 ${target}/tcp。请先用本菜单 2 放行（铁律：UFW 先于 sshd）"
      return 1
    fi
    if [[ "${cur}" != "${target}" ]] && ! fw_has_rule "${cur}/tcp"; then
      die_action "迁移期间旧端口 ${cur}/tcp 必须保持放行（闸门二确认前不能断退路）。请先用本菜单 2 放行"
      return 1
    fi
    return 0
  fi
  warn "ufw 当前状态：${st}（本脚本不会自动放行外部防火墙 / nftables / iptables）"
  if [[ "${cur}" != "${target}" ]]; then
    warn "端口迁移期间须在云安全组或现有防火墙中同时放行新端口 ${target}/tcp，并暂留旧端口 ${cur}/tcp"
  else
    warn "须确保云安全组或现有防火墙已放行 ${target}/tcp"
  fi
  if ! ask_yesno "确认已在云安全组或其他防火墙放行 ${target}/tcp，继续 SSH 加固？" n; then
    warn "已取消：请先放行目标端口或启用 UFW 后再加固"
    return 1
  fi
  return 0
}

ssh_harden() {   # ssh_harden <目标端口>：写 drop-in + 双闸门；成功 0，拒绝 1
  local target="$1" cur actual listening ports migration=0 HARDEN_ALLOWUSERS="" eff_now login_hint_user gate1_prompt
  [[ -f "${SSHD_CFG}" ]] || { die_action "未找到 ${SSHD_CFG}"; return 1; }
  grep -qiE '^[[:space:]]*Include[[:space:]]' "${SSHD_CFG}" || \
    { die_action "需先在 sshd_config 启用 Include drop-in（本流程依赖 drop-in 覆盖）"; return 1; }
  resolve_harden_allowusers || return 1

  # 旧端口：写 drop-in 之前读到的实际监听端口，只保存在本次流程变量里
  cur="$(sshd_port)"
  if [[ -z "${cur}" ]]; then
    die_action "无法读取 sshd 当前端口（sshd -T 失败）。手动跑 sshd -T 看报错（常见：/run/sshd 缺失，mkdir -p /run/sshd）"
    return 1
  fi
  [[ "${cur}" != "${target}" ]] && migration=1
  if (( migration == 1 )); then
    log "端口迁移：sshd 当前 ${cur} → 目标 ${target}"
  else
    log "sshd 已在端口 ${target}：只重写加固配置，无端口迁移"
  fi

  ufw_precheck "${cur}" "${target}" || return 1

  # 已达标就不重写、也不过闸门：原生配置已是目标状态时，重写只会多一次无意义备份
  local desired
  printf -v desired 'Port %s\nPermitRootLogin no\nPasswordAuthentication no\nPubkeyAuthentication yes\nAllowUsers %s\nMaxAuthTries 3' \
    "${target}" "${HARDEN_ALLOWUSERS}"
  eff_now="$(ssh_eff)"
  if [[ -f "${HARD}" ]] && [[ "$(cat "${HARD}")" == "${desired}" ]] \
     && grep -qx 'passwordauthentication no' <<<"${eff_now}" \
     && grep -qx 'permitrootlogin no' <<<"${eff_now}" \
     && grep -qx "port ${target}" <<<"${eff_now}" \
     && [[ "$(sshd_allowusers_raw "${eff_now}")" == "${HARDEN_ALLOWUSERS,,}" ]] \
     && grep -qx 'maxauthtries 3' <<<"${eff_now}"; then
    log "SSH 加固已满足：${HARD} 与 sshd -T 生效值均已达标，未重写配置、未重启 sshd"
    return 0
  fi
  do_scan_dropins

  backup_file "${HARD}" >/dev/null || true
  if ! printf '%s\n' "${desired}" > "${HARD}"; then
    die_action "写入 ${HARD} 失败"
    return 1
  fi

  # sshd -t 语法校验（失败即退出，防止坏配置压死 ssh）
  if ! sshd -t; then
    die_action "sshd -t 校验失败。请检查 ${HARD}；可用备份还原：${BK_ROOT}/"
    return 1
  fi

  # sshd -T 验证实际生效值
  actual="$(sshd_port)"
  if [[ "${actual}" != "${target}" ]]; then
    die_action "sshd -T 实际端口 ${actual:-未知} != 期望 ${target}"
    warn "多半是 ${SSHD_D}/ 下的覆盖文件抢了优先权（先出现者优先）；请检查后重试"
    return 1
  fi
  log "sshd -T 确认：端口 ${actual}、debug 通过"

  # 闸门一：密钥登录验证（铁律 2）
  if [[ "${HARDEN_ALLOWUSERS}" == *" "* ]]; then
    gate1_prompt="已确认白名单用户（${HARDEN_ALLOWUSERS}）均可通过密钥登录且具备 sudo 权限吗？"
  else
    gate1_prompt="已用新终端验证过 ${HARDEN_ALLOWUSERS%%@*} 的密钥登录吗？"
  fi
  if ! ask_yesno "${gate1_prompt}" n; then
    warn "先验证密钥登录再加固。本程序尚未 reload ssh，当前 ssh 配置未变，可安全返回"
    return 1
  fi

  # Ubuntu 22.10+ 等默认用 ssh.socket 套接字激活：监听端口由 socket 单元决定，
  # sshd_config 的 Port 不生效（sshd -T 只读配置文件，会"骗人"）。统一转回标准
  # ssh.service 模式，让端口、AllowUsers 等策略真正生效。
  if systemctl is-enabled ssh.socket >/dev/null 2>&1 || systemctl is-active ssh.socket >/dev/null 2>&1; then
    log "检测到 ssh.socket 套接字激活，切换回标准 ssh.service 模式（否则新端口不生效）"
    if ! { systemctl disable --now ssh.socket && systemctl enable ssh.service; }; then
      die_action "切换 ssh.socket → ssh.service 失败，未重启 sshd（配置已写但未生效）"
      return 1
    fi
  fi
  systemctl restart ssh || { die_action "ssh 启动失败（sshd -t 已过，多为权限/服务名问题）；备份在 ${BK_ROOT}/"; return 1; }
  log "sshd 已生效：新端口 ${target}"

  # 自检：端口监听（systemctl restart 返回 ≠ 端口已绑定，轮询等待 bind 完成）
  if command -v ss >/dev/null 2>&1; then
    listening=0
    for _ in $(seq 1 10); do
      # 先取全量输出再匹配：grep -q 早退会让 ss 收 SIGPIPE，pipefail 下把成功误判为失败
      ports="$(ss_listen_ports)"
      if grep -qE "[:.]${target}$" <<<"${ports}"; then listening=1; break; fi
      sleep 0.3
    done
    if [[ "${listening}" -ne 1 ]]; then
      warn "3 秒内未见端口 ${target} 监听，请手动检查：ss -tlnp | grep ${target}"
    fi
  fi

  login_hint_user="${ADMIN_USER:-${HARDEN_ALLOWUSERS%% *}}"
  login_hint_user="${login_hint_user%%@*}"
  printf '\n'
  log "保持【本会话】不断开！请操作："
  log "  1) 新开终端：ssh -p ${target} ${login_hint_user}@<host>  —— 必须密钥登录成功且 root 被拒"
  if (( migration == 1 )); then
    log "  2) 同步云平台安全组：关 ${cur}、开 ${target}（只能你手动做）"
  else
    log "  2) 确认云平台安全组已放行 ${target}（若已启用 ufw 则本机 ufw 已放行）"
  fi
  printf '\n'

  # 闸门二：新终端验证（铁律 3）
  if ! ask_yesno "新终端已用新端口成功登录？" n; then
    warn "未确认新端口可用。当前 ${cur}/tcp 放行规则保持不动以保旧会话可回退。"
    warn "恢复指引：若已锁死，用云控制台/VNC 登录后还原 ${BK_ROOT}/ 下备份，再 systemctl reload ssh"
    return 1
  fi
  if (( migration == 1 )) && command -v ufw >/dev/null 2>&1; then
    fw_refresh
    if [[ "$(fw_state)" == "active" ]] && fw_has_rule "${cur}/tcp"; then
      # || true：删不存在的规则时 ufw 返回 1，不该因此把整个流程判失败
      ufw delete allow "${cur}/tcp" || warn "删除 ${cur}/tcp 规则失败，请手动执行：ufw delete allow ${cur}/tcp"
      log "已移除 ${cur}/tcp 临时放行规则（ufw）"
    fi
  fi
  printf '\n'
  log "SSH 加固完成。提醒：云安全组（或外部防火墙）若仍放行 ${cur}，请手动关闭。"
  log "云厂商预置用户（如 ubuntu/admin）若不在 AllowUsers 内已被屏蔽；确认不用可手动删除。"
  return 0
}

fw_allow_business_port() {   # fw_allow_business_port <端口>：放行 tcp；每次先刷新规则快照，已存在则不重复添加
  local p="$1"
  fw_refresh
  if fw_has_rule "${p}/tcp"; then
    log "已存在 ${p}/tcp 放行规则（未重复添加）"
    return 0
  fi
  ufw allow "${p}/tcp" || { die_action "放行业务端口 ${p}/tcp 失败"; return 1; }
  log "已放行 ${p}/tcp"
  return 0
}

fw_prepare_for_ssh() {   # fw_prepare_for_ssh <当前端口> <目标端口>
  local cur="$1" target="$2" p ports fresh=0
  command -v ufw >/dev/null 2>&1 || { die_action "未找到 ufw，请先安装基础工具（菜单 2）"; return 1; }
  fw_refresh
  if [[ "$(fw_state)" != "active" ]]; then
    fresh=1
    log "配置 UFW：默认拒绝入站，允许出站"
    ufw default deny incoming || { die_action "设置 ufw 默认入站策略失败"; return 1; }
    ufw default allow outgoing || { die_action "设置 ufw 默认出站策略失败"; return 1; }
  fi
  if [[ "${cur}" != "${target}" ]] && ! fw_has_rule "${cur}/tcp"; then
    ufw allow "${cur}/tcp" || { die_action "放行当前 SSH 端口 ${cur}/tcp 失败"; return 1; }
    fw_refresh
    log "已临时放行当前 SSH 端口 ${cur}/tcp（迁移期间保退路，闸门二确认后才删除）"
  fi
  if ! fw_has_rule "${target}/tcp"; then
    ufw allow "${target}/tcp" || { die_action "放行目标 SSH 端口 ${target}/tcp 失败"; return 1; }
    fw_refresh
    log "已放行目标 SSH 端口 ${target}/tcp"
  fi
  # 业务端口只在首次初始化（ufw 尚未启用）时询问一次；后续运行不按任何清单收敛，
  # 现存规则由「UFW 与 SSH」菜单直接查看与增删。
  if (( fresh )); then
    if ask_yesno "放行 80/443（HTTP/HTTPS，仅 tcp）？" n; then
      fw_allow_business_port 80 || return 1
      fw_allow_business_port 443 || return 1
    else
      log "不放行 80/443"
    fi
    if ! ports="$(ask_input_opt "还需放行的端口 逗号分隔，仅 tcp，例如 8080,8443" v_ports_list "不放行")"; then
      die_action "未取得端口列表，已停止 UFW 配置（可回菜单 5 手动添加）"
      return 1
    fi
    for p in ${ports//,/ }; do
      [[ -n "${p}" ]] || continue
      fw_allow_business_port "${p}" || return 1
    done
  else
    log "ufw 已启用：不询问业务端口，现有规则保持不变（可在菜单 5 中直接增删）"
  fi
  fw_refresh
  # 铁律：确认目标端口已放行才允许启用防火墙
  # 顺序不能反：若规则真缺失，先 enable 会当场切断当前 SSH 会话，报错信息都送不到用户手里
  if ! fw_has_rule "${target}/tcp"; then
    die_action "ufw 中未见 ${target}/tcp 放行规则，拒绝启用（防锁死）。请检查 ufw 输出后重试"
    return 1
  fi
  if [[ "$(fw_state)" != "active" ]]; then
    ufw --force enable || { die_action "启用 ufw 失败"; return 1; }
    log "UFW 已启用（默认拒绝入站：仅上述端口可达）"
  else
    log "UFW 已启用且规则就绪（已满足，未改动现有规则）"
  fi
  return 0
}

fw_do_status() {
  fw_refresh
  log "ufw 状态："
  printf '%s\n' "${FW_VERB}"
  printf '\n'
  if [[ "$(fw_state)" == "active" ]]; then
    log "规则（编号，删除按编号）："
    printf '%s\n' "${FW_RAW}"
  else
    # 未启用时 ufw 不给带编号的列表（status numbered 为空），但规则确实已在 user.rules 里
    log "ufw 未启用：以下为已添加的规则（无编号，启用后才能按编号删除）："
    printf '%s\n' "${FW_ADDED}"
  fi
  return 0
}

fw_do_allow() {
  local op ports protos src p proto
  ui_item 1 "tcp"
  ui_item 2 "udp"
  ui_item 3 "tcp+udp"
  ui_quit
  ask_menu "选择协议" 3
  op="${UI_REPLY}"
  [[ "${op}" == "0" ]] && return 0
  ports=""
  while :; do
    read -rp "端口（1-65535，逗号分隔可多个）（回车=返回）: " ports || die "输入中断"
    [[ -z "${ports}" ]] && return 0
    if v_ports_list "${ports}"; then break; fi
  done
  src=""
  if ask_yesno "限制来源 IP（如 1.2.3.4 或 10.0.0.0/8）？" n; then
    while :; do
      read -rp "来源地址（回车=返回）: " src || die "输入中断"
      [[ -n "${src}" ]] && break
      return 0
    done
  fi
  case "${op}" in
    1) protos="tcp" ;;
    2) protos="udp" ;;
    *) protos="tcp udp" ;;
  esac
  for p in ${ports//,/ }; do
    for proto in ${protos}; do
      if [[ -n "${src}" ]]; then
        ufw allow from "${src}" to any port "${p}" proto "${proto}" || { die_action "放行 ${p}/${proto} 失败"; return 0; }
      else
        ufw allow "${p}/${proto}" || { die_action "放行 ${p}/${proto} 失败"; return 0; }
      fi
      log "已放行 ${p}/${proto}${src:+（仅 ${src}）}"
    done
  done
  fw_refresh
  return 0
}

fw_do_delete() {
  local num count port rule sshp
  fw_refresh
  # 未启用时 ufw 不提供带编号的规则列表（status numbered 为空），而 `ufw --force delete N`
  # 是按 user.rules 顺序取第 N 条——编号无从核对，宁可不做也不删错规则
  if [[ "$(fw_state)" != "active" ]]; then
    warn "ufw 未启用，拿不到规则编号，无法按编号删除"
    log "可选：先启用防火墙再回来删除；或用 'ufw show added' 查看，再执行 'ufw delete allow <规则>'"
    return 0
  fi
  count="$(fw_rule_count)"
  printf '%s' "${FW_RAW}"
  printf '\n'
  if [[ "${count}" == "0" ]]; then log "当前没有可删除的规则"; return 0; fi
  num=""
  while :; do
    read -rp "删除第几条？[1-${count}]（回车=返回）: " num || die "输入中断"
    [[ -z "${num}" ]] && return 0
    if [[ "${num}" =~ ^[0-9]+$ ]] && (( num >= 1 )) && (( num <= count )); then break; fi
    warn "无效输入：请输入 1-${count}"
  done
  rule="$(fw_rule_line "${num}")"
  if [[ -z "${rule}" ]]; then warn "未找到编号 ${num} 的规则（列表可能已变化）"; return 0; fi
  port="${rule%%[[:space:]]*}"
  sshp="$(sshd_port)"
  printf '将删除：[%s] %s\n' "${num}" "${rule}"
  if [[ "${port}" == "${sshp}/tcp" ]]; then
    warn "这是当前 SSH 端口的放行规则：删除会立刻断开当前连接，若没有其他端口可用就是锁死"
  fi
  if ask_yesno "确认删除这条规则？" n; then
    # || true：编号可能已被并发改动，ufw 拒绝删除时不该中断脚本
    ufw --force delete "${num}" || warn "删除编号 ${num} 失败（列表可能已变化），请重开菜单核对"
    log "已删除编号 ${num}"
    fw_refresh
  fi
  return 0
}

fw_do_toggle() {
  local sshp
  fw_refresh
  if [[ "$(fw_state)" == "active" ]]; then
    warn "禁用 ufw 后所有端口对公网暴露（只剩 sshd 自身策略）；重启后也不会自动启用"
    if ask_yesno "确认禁用 ufw？" n; then
      ufw disable || { die_action "禁用 ufw 失败"; return 0; }
      log "ufw 已禁用"
    else
      log "保持启用"
    fi
    return 0
  fi
  sshp="$(sshd_port)"
  if [[ -z "${sshp}" ]]; then
    warn "无法确定 SSH 端口（sshd -T 读不到），拒绝启用（防锁死）"
    return 0
  fi
  if ! fw_has_rule "${sshp}/tcp"; then
    log "启用前先补放行 SSH 端口 ${sshp}/tcp（铁律：UFW 先于 sshd）"
    ufw allow "${sshp}/tcp" || { die_action "放行 ${sshp}/tcp 失败"; return 0; }
    fw_refresh
  fi
  if ask_yesno "启用 ufw（默认拒绝入站）？" y; then
    ufw --force enable || { die_action "启用 ufw 失败"; return 0; }
    log "ufw 已启用"
  fi
  return 0
}

fw_do_default() {
  local which val
  fw_refresh
  log "当前默认策略：入站 $(fw_default_in) / 出站 $(fw_default_out)"
  ui_item 1 "入站 incoming"
  ui_item 2 "出站 outgoing"
  ui_quit
  ask_menu "改哪一项" 2
  which="${UI_REPLY}"
  [[ "${which}" == "0" ]] && return 0
  ui_item 1 "allow（放行）"
  ui_item 2 "deny（拒绝）"
  ui_quit
  ask_menu "设为" 2
  val="${UI_REPLY}"
  [[ "${val}" == "0" ]] && return 0
  case "${val}" in
    1) val="allow" ;;
    *) val="deny" ;;
  esac
  if [[ "${which}" == "1" && "${val}" == "allow" ]]; then
    warn "入站默认放行 = 防火墙基本失效（只剩未放行项被挡不住），仅在调试时用"
    if ! ask_yesno "确认把入站默认策略改为 allow？" n; then return 0; fi
    ufw default allow incoming || { die_action "修改入站默认策略失败"; return 0; }
  elif [[ "${which}" == "1" ]]; then
    ufw default deny incoming || { die_action "修改入站默认策略失败"; return 0; }
  elif [[ "${val}" == "allow" ]]; then
    ufw default allow outgoing || { die_action "修改出站默认策略失败"; return 0; }
  else
    ufw default deny outgoing || { die_action "修改出站默认策略失败"; return 0; }
  fi
  fw_refresh
  log "默认策略已更新：入站 $(fw_default_in) / 出站 $(fw_default_out)"
  return 0
}

fw_do_show_sshd() {
  local eff
  eff="$(ssh_eff)"
  printf '%s── sshd 实际生效值（sshd -T）──%s\n' "${C_D}" "${C_0}"
  if [[ -z "${eff}" ]]; then
    warn "sshd -T 失败，手动排查：sshd -T（常见：/run/sshd 缺失）"
  else
    printf '%s\n' "${eff}" | grep -E '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication|permitemptypasswords|maxauthtries|allowusers|kbdinteractiveauthentication|challengeresponseauthentication) ' || true
  fi
  printf '\n%s── 加固文件 ──%s\n' "${C_D}" "${C_0}"
  if [[ -f "${HARD}" ]]; then
    cat "${HARD}"
  else
    warn "未找到 ${HARD}（尚未执行加固）"
  fi
  printf '\n%s── drop-in 覆盖检查 ──%s\n' "${C_D}" "${C_0}"
  do_scan_dropins
  return 0
}

fw_do_change_port() {
  local cur target
  cur="$(sshd_port)"
  if [[ -z "${cur}" ]]; then
    warn "读不到 sshd 当前端口（sshd -T 失败），无法安全改端口"
    return 0
  fi
  target="$(ask_input_def "新 SSH 端口 1024-65535，避开 22/2222" v_ssh_port "$(rand_port)")" \
    || { warn "输入中断，已取消改端口"; return 0; }
  if [[ "${target}" == "${cur}" ]]; then
    log "与当前生效端口相同，无需迁移"
    return 0
  fi
  if command -v ufw >/dev/null 2>&1; then
    fw_refresh
    if [[ "$(fw_state)" == "active" ]] && ! fw_has_rule "${target}/tcp"; then
      if ! ask_yesno "ufw 未放行 ${target}/tcp，先放行再加固？" y; then return 0; fi
      ufw allow "${target}/tcp" || { die_action "放行 ${target}/tcp 失败"; return 0; }
      fw_refresh
      log "已放行 ${target}/tcp"
    fi
  fi
  ssh_harden "${target}" || return 0
  return 0
}

fw_do_restore() {
  # 从 /root/vps-init-backups/ 恢复 01-hardening.conf（恢复前先备份当前文件，可再回滚）
  local -a backs=()
  local d i pick prev newport cur
  if [[ -d "${BK_ROOT}" ]]; then
    while IFS= read -r d; do
      [[ -f "${d}01-hardening.conf" ]] && backs+=("${d}")
    done < <(ls -1d "${BK_ROOT}"/*/ 2>/dev/null | sort -r)
  fi
  if [[ "${#backs[@]}" -eq 0 ]]; then
    log "没有 01-hardening.conf 的备份（备份目录：${BK_ROOT}）"
    return 0
  fi
  printf '可用备份（新 → 旧）：\n'
  i=1
  for d in "${backs[@]}"; do
    printf '  %d) %s\n' "${i}" "${d%/}"
    i=$((i + 1))
  done
  pick=""
  while :; do
    read -rp "恢复第几份？[1-${#backs[@]}]（回车=返回）: " pick || die "输入中断"
    [[ -z "${pick}" ]] && return 0
    if [[ "${pick}" =~ ^[0-9]+$ ]] && (( pick >= 1 )) && (( pick <= ${#backs[@]} )); then break; fi
    warn "无效输入：请输入 1-${#backs[@]}"
  done
  d="${backs[$((pick - 1))]}"
  printf '将用 %s01-hardening.conf 覆盖 %s，内容：\n' "${d}" "${HARD}"
  cat "${d}01-hardening.conf"
  if ! ask_yesno "确认恢复？" n; then return 0; fi
  prev="$(backup_file "${HARD}")"
  if ! cp -a "${d}01-hardening.conf" "${HARD}"; then
    die_action "复制备份文件到 ${HARD} 失败"
    return 0
  fi
  if ! sshd -t; then
    warn "恢复后的文件语法校验失败，已还原恢复前的版本"
    if [[ -n "${prev}" ]]; then cp -a "${prev}/01-hardening.conf" "${HARD}"; fi
    return 0
  fi
  log "已恢复 ${HARD}"

  # 铁律：端口变了要先确保 ufw 放行，再重启 sshd
  newport="$(awk '/^[Pp]ort[[:space:]]/ {p=$2} END{print p}' "${HARD}" | tr -d '\r')" || true
  cur="$(sshd_port)"
  if [[ -n "${newport}" && "${newport}" != "${cur}" ]]; then
    log "备份文件指定端口 ${newport}（当前 sshd 生效端口 ${cur}）"
    if command -v ufw >/dev/null 2>&1; then
      fw_refresh
      if [[ "$(fw_state)" == "active" ]] && ! fw_has_rule "${newport}/tcp"; then
        warn "ufw 未放行 ${newport}/tcp，现在重启 sshd 会锁死"
        if ask_yesno "先放行 ${newport}/tcp 再继续？" y; then
          ufw allow "${newport}/tcp" || { die_action "放行 ${newport}/tcp 失败，未重启 sshd"; return 0; }
          fw_refresh
          log "已放行 ${newport}/tcp"
        else
          warn "已中止，未重启 sshd；该文件将在下次 sshd 重启时生效（届时务必先放行端口）"
          return 0
        fi
      elif [[ "$(fw_state)" != "active" ]]; then
        warn "ufw 未启用：若现在重启 sshd，请确保云安全组或其他防火墙已放行 ${newport}/tcp"
      fi
    else
      warn "未安装 ufw：若现在重启 sshd，请确保云安全组或其他防火墙已放行 ${newport}/tcp"
    fi
  fi
  if ask_yesno "现在重启 ssh 让恢复的配置生效？" n; then
    systemctl restart ssh || { die_action "ssh 重启失败；备份在 ${BK_ROOT}/"; return 0; }
    warn "本会话不要断开：立刻新开终端验证登录，通过前别关旧窗口"
  else
    log "未重启，恢复的配置将在下次 sshd 重启时生效"
  fi
  return 0
}

fw_menu() {
  local eff e_root e_pwd e_users e_tries hard_users sshp
  auto_detect_admin
  while :; do
    fw_refresh
    sshp="$(sshd_port)"
    eff="$(ssh_eff)"
    e_root="$(eff_val "${eff}" permitrootlogin)"
    e_pwd="$(eff_val "${eff}" passwordauthentication)"
    e_users="$(eff_val "${eff}" allowusers)"
    e_tries="$(eff_val "${eff}" maxauthtries)"
    hard_users=""
    [[ -f "${HARD}" ]] && hard_users="$(sed -n 's/^AllowUsers[[:space:]]\+//p' "${HARD}" | tr -d '\r')"
    if [[ -n "${hard_users}" && -n "${ADMIN_USER:-}" && "${hard_users}" != "${ADMIN_USER}" ]]; then
      e_users="${e_users} ${C_Y}（本进程管理员为 ${ADMIN_USER}，改用单用户加固后将覆盖）${C_0}"
    fi
    scr_clear
    ui_rule
    printf '%s UFW 与 SSH · %s%s%s\n' "${C_B}" "${C_G}" "${ADMIN_USER:-未指定}" "${C_0}"
    ui_sep
    case "$(fw_state)" in
      active) ui_kv "防火墙" "$(ui_yes 'active ✓')" ;;
      未安装) ui_kv "防火墙" "$(ui_no '未安装 ufw ⚠')" ;;
      *)      ui_kv "防火墙" "$(ui_no "$(fw_state) ⚠")" ;;
    esac
    ui_kv "默认策略" "入站 $(fw_default_in) / 出站 $(fw_default_out)"
    ui_kv "规则数" "$(fw_rule_count)"
    if [[ -n "${sshp}" ]]; then
      if [[ "$(fw_state)" == "active" ]]; then
        if fw_has_rule "${sshp}/tcp"; then
          ui_kv "SSH 端口" "${sshp}（ufw 已放行 ✓）"
        else
          ui_kv "SSH 端口" "${sshp}（$(ui_no 'ufw 未放行 ⚠')）"
        fi
      else
        ui_kv "SSH 端口" "${sshp}（ufw $(fw_state)，依赖外部防火墙）"
      fi
    else
      ui_kv "SSH 端口" "$(ui_no '未知（sshd -T 失败）⚠')"
    fi
    ui_sep
    ui_kv "root 登录" "${e_root}"
    ui_kv "密码登录" "${e_pwd}"
    ui_kv "AllowUsers" "${e_users}"
    ui_kv "MaxAuthTries" "${e_tries}"
    ui_kv "加固文件" "$( [[ -f "${HARD}" ]] && printf '已写入 ✓' || printf '%s' "$(ui_no '未写入 ⚠')" )"
    ui_sep
    ui_item 1 "查看 UFW 状态与规则"
    ui_item 2 "添加放行规则"
    ui_item 3 "删除规则（按编号）"
    ui_item 4 "启用 / 禁用防火墙"
    ui_item 5 "修改默认策略（入站 / 出站）"
    ui_item 6 "应用 SSH 加固（沿用当前生效端口，双闸门）"
    ui_item 7 "修改 SSH 端口并加固（双闸门）"
    ui_item 8 "查看 sshd 生效值与加固文件"
    ui_item 9 "从备份恢复 01-hardening.conf"
    ui_quit
    ui_sep
    ask_menu "选择操作" 9
    case "${UI_REPLY}" in
      0) return 0 ;;
      1) act fw_do_status ;;
      2) act fw_do_allow ;;
      3) act fw_do_delete ;;
      4) act fw_do_toggle ;;
      5) act fw_do_default ;;
      6)
        sshp="$(sshd_port)"
        if [[ -z "${sshp}" ]]; then
          warn "读不到 sshd 当前端口，无法加固"
        else
          act ssh_harden "${sshp}" || true
        fi
        ;;
      7) act fw_do_change_port ;;
      8) act fw_do_show_sshd ;;
      9) act fw_do_restore ;;
    esac
    page_wait "按回车返回 UFW 与 SSH 菜单…"
  done
}


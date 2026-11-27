# ============ 模块 2：系统更新与基础工具 ============
APT_UPDATED=0

apt_list_has_index() {
  compgen -G "/var/lib/apt/lists/*_Packages*" >/dev/null 2>&1 \
    || compgen -G "/var/lib/apt/lists/*_InRelease" >/dev/null 2>&1 \
    || compgen -G "/var/lib/apt/lists/*_Release" >/dev/null 2>&1
}

apt_install_pkgs() {   # apt_install_pkgs <pkg...>: 缺索引或安装失败时自动刷新索引一次，支持单独运行
  if (( ! APT_UPDATED )) && ! apt_list_has_index; then
    log "检测到本地 apt 索引为空，先刷新索引"
    apt_update_index || return 1
  fi
  if DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"; then
    return 0
  fi
  if (( ! APT_UPDATED )); then
    warn "安装失败，尝试先刷新 apt 索引后重试"
    apt_update_index || return 1
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" && return 0
  fi
  return 1
}

install_missing_base() {
  local miss
  miss="$(missing_pkgs ${BASE})"
  if [[ -z "${miss}" ]]; then
    log "必要包已全部安装（已满足）"
    return 0
  fi
  printf '缺少必要包：%s\n' "${miss}"
  if ! ask_yesno "确认安装以上必要包？" n; then
    log "已取消安装必要包"
    return 1
  fi
  log "安装缺失包：${miss}"
  # shellcheck disable=SC2086
  if ! apt_install_pkgs ${miss}; then
    die_action "安装失败：${miss}（检查网络/源后重试）"
    return 1
  fi
  return 0
}


ua_enable() {
  if ua_enabled; then
    log "自动安全更新：已满足，跳过写入"
  else
    backup_file "${UA_FILE}" >/dev/null || true
    if ! printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' > "${UA_FILE}"; then
      die_action "写入 ${UA_FILE} 失败"
      return 1
    fi
    chmod 644 "${UA_FILE}" || warn "chmod 644 ${UA_FILE} 失败，权限可能不符合预期"
    log "自动安全更新已启用（${UA_FILE}）"
  fi
  systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || \
    warn "apt-daily 定时器启用失败，请手动检查：systemctl status apt-daily.timer"
  return 0
}

maybe_reboot() {
  if [[ ! -f /var/run/reboot-required ]]; then
    log "无需重启"
    return 0
  fi
  warn "检测到需要重启（通常为内核更新）"
  if ask_yesno "现在重启吗？重启后重新登录并继续" y; then
    log "即将重启，重启后重新进入 TUI 继续"
    systemctl reboot || { die_action "重启命令失败，请手动执行 reboot"; return 0; }
    exit 0
  fi
  warn "跳过重启：后续安全基线建立在旧内核上，建议尽快手动重启"
  return 0
}

apt_update_index() {
  log "apt-get update"
  if ! DEBIAN_FRONTEND=noninteractive apt-get update; then
    die_action "apt-get update 失败（检查网络与软件源）"
    return 1
  fi
  APT_UPDATED=1
  return 0
}

apt_full_upgrade() {
  local n
  n="$(apt_pending_count)"
  if [[ "${n}" -eq 0 ]]; then
    log "无待升级/移除项（已满足）"
    return 0
  fi
  log "待处理事务 ${n} 项，执行 full-upgrade"
  if ! DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y; then
    die_action "full-upgrade 失败（检查磁盘空间与软件源）"
    return 1
  fi
  return 0
}

base_do_update() {
  apt_update_index || return 1
  apt_full_upgrade || return 1
  maybe_reboot
  return 0
}

base_do_extra() {
  local sel miss
  read -rp "额外工具（空格分隔；none=不装）（回车=默认 ${TOOLS_EXTRA_DEFAULT}）: " sel || die "输入中断"
  sel="${sel:-${TOOLS_EXTRA_DEFAULT}}"
  [[ "${sel}" == "none" ]] && sel=""
  if [[ -z "${sel}" ]]; then
    log "未选择额外工具"
    return 0
  fi
  miss="$(missing_pkgs ${sel})"
  if [[ -z "${miss}" ]]; then
    log "所选工具已全部安装（已满足）"
    return 0
  fi
  log "安装：${miss}"
  # shellcheck disable=SC2086
  if ! apt_install_pkgs ${miss}; then
    die_action "安装失败：${miss}（检查网络/源后重试）"
    return 1
  fi
  return 0
}

base_menu() {
  local n miss extra_state
  while :; do
    n="$(apt_pending_count)"
    miss="$(missing_pkgs ${BASE})"
    extra_state=""
    local p
    for p in ${TOOLS_EXTRA_DEFAULT}; do
      if pkg_installed "${p}"; then extra_state+="${p}✓ "; else extra_state+="${p}✗ "; fi
    done
    scr_clear
    ui_rule
    printf '%s 系统更新与基础工具%s\n' "${C_B}" "${C_0}"
    ui_sep
    ui_kv "待处理" "$( [[ "${n}" -eq 0 ]] && printf '无（已是最新）' || printf '%s 项待升级/移除' "${n}" )"
    ui_kv "必要包" "$( [[ -z "${miss}" ]] && printf '齐全 ✓' || printf '缺：%s' "${miss}" )"
    ui_kv "可选工具" "${extra_state:-无}"
    ui_kv "自动更新" "$(ua_state)"
    ui_kv "重启标记" "$( [[ -f /var/run/reboot-required ]] && printf '需要重启 ⚠' || printf '无' )"
    ui_sep
    ui_item 1 "刷新索引并升级系统"
    ui_item 2 "补齐必要包"
    ui_item 3 "选择并安装可选工具"
    ui_item 4 "启用自动安全更新"
    ui_quit
    ui_sep
    ask_menu "选择操作" 4
    case "${UI_REPLY}" in
      0) return 0 ;;
      1) act base_do_update ;;
      2) act install_missing_base ;;
      3) act base_do_extra ;;
      4) act ua_enable ;;
    esac
    page_wait "按回车返回系统更新菜单…"
  done
}


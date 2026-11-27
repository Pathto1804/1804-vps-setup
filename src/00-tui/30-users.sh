# ============ 模块 4：用户、密码、sudo 和密钥 ============
user_do_password() {
  local op out rc=0
  need_admin || return 1
  ui_item 1 "自己输入（转发 passwd）"
  ui_item 2 "生成随机密码（22 位，仅显示一次）"
  ui_quit
  ask_menu "选择" 2
  op="${UI_REPLY}"
  [[ "${op}" == "0" ]] && return 0
  if [[ "${op}" == "2" ]]; then
    local pw
    pw="$(gen_random_pw)"
    if (( ${#pw} < 20 )); then
      die_action "生成随机密码失败（长度 ${#pw}），未改动账户"
      return 1
    fi
    printf '%s生成的密码（仅显示这一次，请立即保存到密码管理器）：%s%s%s\n' "${C_Y}" "${C_B}" "${pw}" "${C_0}"
    # 捕获 chpasswd 的输出：失败原因在它的 stderr（常见：PAM 拒收弱密码、rootfs 只读、用户不存在）
    out="$(printf '%s:%s\n' "${ADMIN_USER}" "${pw}" | chpasswd 2>&1)" || rc=$?
    unset pw
    if (( rc != 0 )); then
      die_action "设置密码失败（chpasswd 退出码 ${rc}）：${out:-无输出}"
      return 1
    fi
    if [[ "$(pw_state "${ADMIN_USER}")" != "P" ]]; then
      die_action "chpasswd 返回 0，但 passwd -S 仍显示未设置密码；请手动执行 passwd ${ADMIN_USER}"
      return 1
    fi
    printf '%s密码已设置（passwd -S 已确认）%s\n' "${C_G}" "${C_0}"
  else
    if ! passwd "${ADMIN_USER}"; then
      die_action "passwd 未完成（退出码非零）：密码未改动或强度不足被拒，见上方输出"
      return 1
    fi
    if [[ "$(pw_state "${ADMIN_USER}")" != "P" ]]; then
      warn "passwd 已返回，但 passwd -S 仍显示未设置密码，请再执行一次 passwd ${ADMIN_USER}"
      return 1
    fi
  fi
  return 0
}

gen_random_pw() {
  # 22 位随机密码（大小写+数字）；openssl 不可用时退回 /dev/urandom
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-22
  else
    # 不能写 `tr -dc ... < /dev/urandom | head -c 22`：head 读够就退出，tr 收到 SIGPIPE（141），
    # 在 set -o pipefail 下 `pw="$(gen_random_pw)"` 赋值失败 → set -e 直接中止脚本
    head -c 256 /dev/urandom | tr -dc 'A-Za-z0-9' | cut -c1-22
  fi
}

user_do_sudo() {
  local u f st new
  need_admin || return 1
  u="${ADMIN_USER}"
  f="/etc/sudoers.d/${u}"
  st="$(sudo_state "${u}")"
  case "${st}" in
    unknown) warn "无法查询 ${u} 的 sudo 有效权限（sudo -l 失败），拒绝切换"; return 1 ;;
    yes) new="no" ;;
    *)   new="yes" ;;
  esac
  log "sudo 免密当前有效状态：${st}（本项目管理的文件：${f}）"
  if ! ask_yesno "把 sudo 免密从 ${st} 切换为 ${new}？" n; then return 0; fi
  if [[ "${new}" == "yes" ]]; then
    backup_file "${f}" >/dev/null || true
    if ! printf '%s ALL=(ALL) NOPASSWD: ALL\n' "${u}" > "${f}"; then
      die_action "写入 ${f} 失败（检查 /etc/sudoers.d 是否可写、磁盘是否只读）"
      return 1
    fi
    if ! { chmod 0440 "${f}" && chown root:root "${f}" && visudo -c >/dev/null 2>&1; }; then
      rm -f "${f}"
      die_action "sudoers 校验失败（权限或语法），已删除 ${f}；请勿破坏 sudo"
      return 1
    fi
    st="$(sudo_state "${u}")"
    if [[ "${st}" != "yes" ]]; then
      die_action "已写入 ${f} 但 sudo -l 仍显示 NOPASSWD 未生效（${st}）：确认 /etc/sudoers 里 includedir 未被注释"
      return 1
    fi
    log "已开启免密并通过 sudo -l 确认：${f}"
  else
    if [[ -f "${f}" ]]; then
      backup_file "${f}" >/dev/null || true
      rm -f "${f}"
      if ! visudo -c >/dev/null 2>&1; then
        die_action "删除 ${f} 后 sudoers 校验失败，请立即检查 /etc/sudoers.d/"
        return 1
      fi
      log "已删除本项目管理的 ${f}"
    else
      log "本项目未管理 ${f}（免密可能来自其他 sudoers 规则），不删除其他文件"
    fi
    st="$(sudo_state "${u}")"
    if [[ "${st}" == "yes" ]]; then
      warn "重新查询后 ${u} 的 NOPASSWD 仍然有效：其他 sudoers 规则仍在放行免密（本程序未改动它们）"
    elif [[ "${st}" == "unknown" ]]; then
      warn "重新查询 sudo 权限失败，无法确认免密是否已关闭，请手动核对 sudoers"
    else
      log "重新查询确认：${u} 已无 NOPASSWD 免密"
    fi
  fi
  return 0
}

user_do_key_add() {
  local line added=0 ak
  local -a newl=()
  need_admin || return 1
  printf '粘贴公钥（每行一个，输入空行结束）：\n'
  while IFS= read -r line; do
    [[ -z "${line}" ]] && break
    if ! v_pubkey "${line}" >/dev/null 2>&1; then
      warn "跳过非法公钥行：${line:0:40}"
      continue
    fi
    newl+=("${line}")
  done
  if (( ${#newl[@]} == 0 )); then
    log "没有新增公钥（输入为空或全部非法）"
    return 0
  fi
  ak="$(ak_path)"
  [[ -n "${ak}" ]] || { die_action "无法解析 ${ADMIN_USER} 的主目录"; return 1; }
  AK_LINES=()
  if [[ -f "${ak}" ]]; then
    mapfile -t AK_LINES < "${ak}"
  fi
  local k
  for k in "${newl[@]}"; do
    AK_LINES+=("${k}")
    added=$((added + 1))
  done
  if [[ -f "${ak}" ]]; then
    backup_file "${ak}" >/dev/null || true
  fi
  ak_write_lines || return 1
  local now
  now="$(ak_count)"
  log "已追加 ${added} 个公钥到 ${ak}（当前共 ${now} 把）"
  return 0
}

user_do_key_del() {
  local ak pick del i n=0
  local -a raw=() idx=()
  need_admin || return 1
  ak="$(ak_path)"
  [[ -n "${ak}" ]] || { die_action "无法解析 ${ADMIN_USER} 的主目录"; return 1; }
  if [[ ! -f "${ak}" ]]; then
    log "尚无 ${ak}"
    return 0
  fi
  mapfile -t raw < "${ak}"
  printf '当前 authorized_keys 中的行：\n'
  for i in "${!raw[@]}"; do
    [[ -n "${raw[i]}" ]] || continue
    idx+=("${i}")
    n=$((n + 1))
    printf '  %d) %s...%s\n' "${n}" "${raw[i]:0:32}" "${raw[i]: -16}"
  done
  if (( n == 0 )); then
    log "文件为空，无可删除的行"
    return 0
  fi
  while :; do
    read -rp "删除第几行？[1-${n}]（回车=取消）: " pick || die "输入中断"
    [[ -z "${pick}" ]] && return 0
    if [[ "${pick}" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= n )); then break; fi
    warn "无效输入：请输入 1-${n}"
  done
  del="${idx[pick - 1]}"
  printf '将删除：%s\n' "${raw[del]}"
  if ! ask_yesno "确认删除这一行？" n; then return 0; fi
  AK_LINES=()
  for i in "${!raw[@]}"; do
    [[ "${i}" == "${del}" ]] && continue
    AK_LINES+=("${raw[i]}")
  done
  backup_file "${ak}" >/dev/null || true
  ak_write_lines || return 1
  log "已删除 1 行，其余行与权限保持不变（当前 $(ak_count) 把）"
  return 0
}

user_do_switch() {
  local u previous="${ADMIN_USER}"
  select_admin_user --allow-new || return 0
  u="${ADMIN_USER}"
  if user_exists "${u}"; then
    log "用户 ${u} 已存在，切换为管理目标"
  else
    if ! ask_yesno "用户 ${u} 不存在，创建并加入 sudo 组？" y; then
      ADMIN_USER="${previous}"
      return 0
    fi
    if ! adduser --gecos "" "${u}"; then
      ADMIN_USER="${previous}"
      die_action "创建用户 ${u} 失败（见上方 adduser 输出）"
      return 1
    fi
    if ! user_exists "${u}"; then
      ADMIN_USER="${previous}"
      die_action "adduser 返回成功但 ${u} 仍不存在，未切换管理目标"
      return 1
    fi
    if ! usermod -aG sudo "${u}"; then
      ADMIN_USER="${previous}"
      die_action "用户 ${u} 已创建，但加入 sudo 组失败；请手动 usermod -aG sudo ${u}"
      return 1
    fi
    log "已创建 ${u} 并加入 sudo 组"
  fi
  ADMIN_USER="${u}"
  return 0
}


user_do_show_keys() {
  local ak
  ak="$(ak_path)"
  if [[ -z "${ak}" || ! -f "${ak}" ]]; then
    log "尚无 ${ak:-authorized_keys}"
    return 0
  fi
  printf '%s── %s ──%s\n' "${C_D}" "${ak}" "${C_0}"
  local line i=0
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    i=$((i + 1))
    printf '  %d) %s\n' "${i}" "${line}"
  done < "${ak}"
  printf '%s' "${C_D}"
  ls -l "${ak}" 2>/dev/null || true
  printf '%s' "${C_0}"
  return 0
}

ensure_user_target() {
  if [[ -n "${ADMIN_USER}" ]] && user_exists "${ADMIN_USER}" && user_is_nonroot "${ADMIN_USER}"; then
    return 0
  fi
  user_do_switch || return 1
  need_admin
}

user_run_with_admin() {
  local fn="$1"
  ensure_user_target || return 0
  "${fn}"
}

user_menu() {
  local pw sudo_st keys
  auto_detect_admin
  while :; do
    if [[ -n "${ADMIN_USER}" ]] && user_exists "${ADMIN_USER}"; then
      pw="$(pw_state "${ADMIN_USER}")"
      sudo_st="$(sudo_state "${ADMIN_USER}")"
      keys="$(ak_count)"
    else
      pw=""; sudo_st=""; keys=""
    fi
    scr_clear
    ui_rule
    if [[ -n "${ADMIN_USER}" ]] && user_exists "${ADMIN_USER}"; then
      printf '%s 用户、密码、sudo 与密钥 · %s%s%s\n' "${C_B}" "${C_G}" "${ADMIN_USER}" "${C_0}"
    elif [[ -n "${ADMIN_USER}" ]]; then
      printf '%s 用户、密码、sudo 与密钥 · %s%s（不存在）%s\n' "${C_B}" "${C_Y}" "${ADMIN_USER}" "${C_0}"
    else
      printf '%s 用户、密码、sudo 与密钥 · %s未指定%s\n' "${C_B}" "${C_Y}" "${C_0}"
    fi
    ui_sep
    if [[ -z "${ADMIN_USER}" ]] || ! user_exists "${ADMIN_USER}"; then
      ui_kv "登录密码" "$(ui_no '—（先选 1 指定或执行操作时选择）')"
      ui_kv "sudo 免密" "$(ui_no '—（先选 1 指定或执行操作时选择）')"
      ui_kv "公钥" "$(ui_no '—（先选 1 指定或执行操作时选择）')"
    else
      if [[ "${pw}" == "P" ]]; then ui_kv "登录密码" "$(ui_yes '已设置 ✓')"
      elif [[ "${pw}" == "L" || "${pw}" == "NP" ]]; then ui_kv "登录密码" "$(ui_no '未设置 ⚠')"
      else ui_kv "登录密码" "${pw}"; fi
      case "${sudo_st}" in
        yes)     ui_kv "sudo 免密" "$(ui_yes '开（NOPASSWD 生效）')" ;;
        no)      ui_kv "sudo 免密" "关（需密码）" ;;
        *)       ui_kv "sudo 免密" "$(ui_no '未知（sudo -l 查询失败）')" ;;
      esac
      if [[ "${keys}" -gt 0 ]]; then ui_kv "公钥" "${keys} 把"
      else ui_kv "公钥" "$(ui_no '0 把 ⚠')"; fi
    fi
    ui_sep
    ui_item 1 "切换 / 新建管理员用户"
    ui_item 2 "设置或修改登录密码"
    ui_item 3 "sudo 免密 开 / 关"
    ui_item 4 "追加公钥"
    ui_item 5 "删除公钥（按行）"
    ui_item 6 "查看 authorized_keys"
    ui_quit
    ui_sep
    ask_menu "选择操作" 6
    case "${UI_REPLY}" in
      0) return 0 ;;
      1) act user_do_switch ;;
      2) act user_run_with_admin user_do_password ;;
      3) act user_run_with_admin user_do_sudo ;;
      4) act user_run_with_admin user_do_key_add ;;
      5) act user_run_with_admin user_do_key_del ;;
      6) act user_run_with_admin user_do_show_keys ;;
    esac
    page_wait "按回车返回用户菜单…"
  done
}


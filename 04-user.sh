#!/usr/bin/env bash
# VPS 初始化 · 04 创建管理员用户 + 公钥
# 自包含 + 幂等 + 交互闸门。用法：sudo bash 04-user.sh
# 项目：https://raw.githubusercontent.com/Pathto1804/myVPS/main/04-user.sh

set -euo pipefail
# 命令替换默认不继承 errexit：不开这个，$(ask_input ...) 里的 die 只终止子 shell，
# 空值会被照常写进 conf。开启后交互读取遇 EOF/Ctrl-D 即中止脚本。（bash >= 4.4）
shopt -s inherit_errexit

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
CONF="/root/.vps-init.conf"
BK_ROOT="/root/vps-init-backups"

if [[ -t 1 ]]; then
  C_G=$'\e[32m'; C_Y=$'\e[33m'; C_R=$'\e[31m'; C_B=$'\e[1m'; C_D=$'\e[90m'; C_0=$'\e[0m'
else
  C_G=''; C_Y=''; C_R=''; C_B=''; C_D=''; C_0=''
fi

log()  { printf '%s[%s]%s %s\n' "${C_B}" "${SCRIPT_NAME}" "${C_0}" "$*"; }
warn() { printf '%s[%s]%s %s\n' "${C_Y}" "${SCRIPT_NAME}" "${C_0}" "$*" >&2; }
die()  { printf '%s[%s]%s %s\n' "${C_R}" "${SCRIPT_NAME}" "${C_0}" "$*" >&2; exit 1; }

err_trap() { die "行 ${1}: ${2}"; }
trap 'err_trap "${LINENO}" "${BASH_COMMAND}"' ERR

require_root()   { [[ "${EUID}" -eq 0 ]] || die "需要 root 运行，请用：sudo bash ${SCRIPT_NAME}"; }
require_tty()    { [[ -t 0 ]] || die "需要交互终端运行，不支持无人值守（防锁死设计）"; }
require_distro() {
  local id
  id="$(. /etc/os-release 2>/dev/null && printf '%s' "${ID:-}")"
  [[ "${id}" == "debian" || "${id}" == "ubuntu" ]] || die "仅支持 Debian/Ubuntu，当前发行版：${id:-未知}"
}

ask_yesno() {
  local prompt="$1" def="${2:-n}" ans hint
  case "${def}" in
    y|Y) def=y; hint="[Y/n]" ;;
    *)   def=n; hint="[y/N]" ;;
  esac
  while :; do
    read -rp "${prompt} ${hint} " ans || return 1
    ans="${ans:-${def}}"
    case "${ans,,}" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *)     printf '%s无效输入：请输入 y 或 n。\n' "${C_Y}" >&2 ;;
    esac
  done
}

ask_input() {
  local prompt="$1" v="$2" val
  while :; do
    read -rp "${prompt} " val || die "输入中断"
    if "${v}" "${val}"; then printf '%s' "${val}"; return 0; fi
  done
}

backup_file() {
  local path="$1" stamp dir
  [[ -e "${path}" ]] || { printf ''; return 0; }
  stamp="$(date +%Y%m%d-%H%M%S)"
  dir="${BK_ROOT}/${stamp}"
  mkdir -p "${dir}"
  cp -a "${path}" "${dir}/"
  printf '%s已备份 %s -> %s/\n' "${C_G}" "${path}" "${dir}" >&2
  printf '%s' "${dir}"
}

# ============ 交互原语（04/05/07 一致，修改需同步三处；sync_check 比对） ============
# 显示宽度写入全局 DW：CJK/全角按 2 列，不依赖 wc 或 locale 子进程
_disp_w() {
  local s="$1" i=0 w=0 c n
  while (( i < ${#s} )); do
    c="${s:i:1}"
    printf -v n '%d' "'${c}"
    (( n < 0 )) && n=$(( -n ))
    if (( n < 128 )); then
      w=$((w+1)); i=$((i+1))
    elif (( n <= 255 )); then
      # C locale：按 UTF-8 字节序列长度推进，宽字符仍按 2 列
      if (( n >= 240 )); then w=$((w+2)); i=$((i+4))
      elif (( n >= 224 )); then w=$((w+2)); i=$((i+3))
      elif (( n >= 192 )); then w=$((w+1)); i=$((i+2))
      else w=$((w+1)); i=$((i+1)); fi
    else
      if (( (n>=0x1100&&n<=0x115F) || (n>=0x2E80&&n<=0xA4CF) || (n>=0xAC00&&n<=0xD7A3) \
             || (n>=0xF900&&n<=0xFAFF) || (n>=0xFE30&&n<=0xFE6F) || (n>=0xFF00&&n<=0xFF60) \
             || (n>=0xFFE0&&n<=0xFFE6) )); then w=$((w+2)); else w=$((w+1)); fi
      i=$((i+1))
    fi
  done
  DW="${w}"
}
ui_sep()  { printf '%s\n' "${C_D}───────────────────────────────────${C_0}"; }
ui_rule() { printf '%s\n' "${C_D}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_0}"; }
ui_kv() {   # ui_kv <标签> <值>：标签列按显示宽度对齐到 12 列
  local label="$1" val="$2" pad
  _disp_w "${label}"; pad=$(( 12 - DW ))
  (( pad < 1 )) && pad=1
  printf '  %s%*s%s\n' "${label}" "${pad}" '' "${val}"
}
ui_item() {   # ui_item <编号> <说明>
  printf '  %s%s%s) %s\n' "${C_G}" "$1" "${C_0}" "$2"
}
ui_quit() {   # ui_quit：主菜单退出项的编号行（0 = 退出）
  printf '  %s0%s) 退出\n' "${C_R}" "${C_0}"
}
# ask_menu <提示> <最大编号> [零号含义=返回]：结果写入全局 UI_REPLY（0..max）
# 空回车 = 0（返回上一层/退出）；非法输入原地重问，不重绘菜单
ask_menu() {
  local prompt="$1" max="$2" zero="${3:-返回}" input
  while :; do
    read -rp "${prompt} [0-${max}]（回车=${zero}） " input || die "输入中断"
    input="${input:-0}"
    if [[ "${input}" =~ ^[0-9]+$ ]] && (( input <= max )); then
      # shellcheck disable=SC2034  # 由调用方读取
      UI_REPLY="${input}"; return 0
    fi
    warn "无效输入：请输入 0-${max}"
  done
}
# Ctrl-C：写操作可能只做了一半，提示幂等收敛
ui_abort() {
  printf '\n%s[中断]%s 已停止。若刚做过写操作，配置可能只改了一半；重跑本脚本会收敛（各步骤幂等）。\n' \
    "${C_Y}" "${C_0}" >&2
  exit 130
}
trap 'ui_abort' INT

conf_has()   { grep -q "^${1}=" "${CONF}" 2>/dev/null; }
conf_read()  { sed -n "s/^${1}='\\(.*\\)'\$/\\1/p" "${CONF}" 2>/dev/null | head -n 1 || true; }   # || true：conf 缺失或 head 早退（SIGPIPE）时输出空串，不中断
conf_write() {
  # conf 首次创建即 600（幂等：已 600 无变化）
  local k="$1" v="$2"
  v="${v//\'/\'\\\'\'}"
  touch "${CONF}" 2>/dev/null || :
  chmod 600 "${CONF}"
  printf "%s='%s'\n" "${k}" "${v}" >> "${CONF}"
}

conf_get() {
  local k="$1" prompt="$2" v="$3" val
  if conf_has "${k}"; then
    val="$(conf_read "${k}")"
    if "${v}" "${val}" >/dev/null 2>&1; then
      printf '%s%s 已配置（conf）\n' "${C_G}" "${k}" >&2
      printf '%s' "${val}"
      return 0
    fi
    warn "conf 中 ${k} 不合法，重新询问"
    sed -i "/^${k}=/d" "${CONF}" 2>/dev/null || :   # 清掉所有同名旧行（含非法值），防 head -1 永远读到坏值
  fi
  val="$(ask_input "${prompt}" "${v}")"
  conf_write "${k}" "${val}"
  printf '%s%s 已保存到 %s\n' "${C_G}" "${k}" "${CONF}" >&2
  printf '%s' "${val}"
}

conf_update() {
  # conf_update <KEY> <值>：已存在则替换该行，否则追加
  # 值经 sed 转义（\ & | 分隔符），防止注入破坏 sed 表达式
  local k="$1" v="$2"
  local esc
  esc="${v//\\/\\\\}"
  esc="${esc//|/\\|}"
  esc="${esc//&/\\&}"
  if conf_has "${k}"; then
    sed -i "s|^${k}=.*|${k}='${esc}'|" "${CONF}"
  else
    conf_write "${k}" "${v}"
  fi
}

# 公共校验器：合法返回 0，非法打印原因返回 1
v_any()      { return 0; }
v_yesno()    { [[ "$1" == "yes" || "$1" == "no" ]] || { printf '须为 yes 或 no\n' >&2; return 1; }; }
v_user() {
  [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { printf '用户名不合法（小写字母开头，允许 a-z 0-9 _ -）\n' >&2; return 1; }
  return 0
}
v_pubkey() {
  local line
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    [[ "${line}" =~ ^(ssh|ecdsa)- ]] || { printf '公钥应以 ssh- 或 ecdsa- 开头：%s\n' "${line:0:40}" >&2; return 1; }
  done <<< "$1"
  return 0
}


# ==================== 脚本主体 ====================

require_root
require_tty
require_distro

# 列出系统普通用户（UID>=1000 且有可用 shell），仅作换人时的参考提示
list_human_users() {
  local u uid shell
  while IFS=: read -r u _ uid _ _ _ shell; do
    [[ "${uid}" -ge 1000 ]] || continue
    [[ "${shell}" == */nologin || "${shell}" == */false ]] && continue
    [[ "${u}" != "${ADMIN_USER}" ]] && printf '%s ' "${u}"
  done < <(getent passwd)
}

# 选择目标用户：conf 有值时允许确认或换人（支持管理任意已有用户）
ADMIN_USER=""
if conf_has "ADMIN_USER"; then ADMIN_USER="$(conf_read "ADMIN_USER")"; fi
if v_user "${ADMIN_USER}" >/dev/null 2>&1; then
  if ask_yesno "管理用户 ${ADMIN_USER}（上次操作的用户）？" y; then
    :
  else
    printf '系统现有普通用户：%b\n' "$(list_human_users 2>/dev/null || true)"
    ADMIN_USER="$(ask_input "要管理的用户名（新建或已有均可）" v_user)"
    conf_update "ADMIN_USER" "${ADMIN_USER}"
    log "ADMIN_USER 已更新为 ${ADMIN_USER}"
    warn "注意：sudo 免密与公钥在 conf 中是全局键，切换用户后请核对菜单里显示的当前值再决定是否修改"
  fi
else
  ADMIN_USER="$(ask_input "要管理的用户名（新建或已有均可）" v_user)"
  conf_update "ADMIN_USER" "${ADMIN_USER}"
fi

# 不存在则创建；已存在则直接管理（补 sudo 组）
if id "${ADMIN_USER}" &>/dev/null; then
  log "用户 ${ADMIN_USER} 已存在，进入管理模式"
else
  log "创建用户 ${ADMIN_USER}"
  adduser --gecos "" "${ADMIN_USER}"
fi
usermod -aG sudo "${ADMIN_USER}"
log "已加入 sudo 组"

HOME_DIR="$(getent passwd "${ADMIN_USER}" | cut -d: -f6)"
[[ -n "${HOME_DIR}" ]] || die "无法解析 ${ADMIN_USER} 主目录"
log "主目录：${HOME_DIR}"
OWNER_GID="$(id -g "${ADMIN_USER}")"

# ---------- 动作：登录密码 ----------
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

apply_random_pw() {
  local pw
  pw="$(gen_random_pw)"
  printf '%s生成的密码（仅显示这一次，请立即保存到密码管理器）：%s%s%s\n' "${C_Y}" "${C_B}" "${pw}" "${C_0}"
  printf '%s:%s\n' "${ADMIN_USER}" "${pw}" | chpasswd
  printf '%s密码已设置\n' "${C_G}"
  unset pw
}

do_password() {
  ui_item 1 "自己输入（转发 passwd）"
  ui_item 2 "生成随机密码（22 位，仅显示一次）"
  printf '  %s0%s) 返回\n' "${C_R}" "${C_0}"
  ask_menu "选择" 2
  local op="${UI_REPLY}"
  if [[ "${op}" == "0" ]]; then return 0; fi
  if [[ "${op}" == "2" ]]; then
    apply_random_pw
  else
    passwd "${ADMIN_USER}"
  fi
}

# ---------- 动作：sudo 免密 开↔关 ----------
do_sudo() {
  local conf_nopw="" cur new
  if conf_has "SUDO_NOPASSWD"; then conf_nopw="$(conf_read "SUDO_NOPASSWD")"; fi
  [[ "${conf_nopw}" == "yes" || "${conf_nopw}" == "no" ]] || conf_nopw=""
  if [[ -f "/etc/sudoers.d/${ADMIN_USER}" ]]; then cur="yes"; else cur="no"; fi
  log "sudo 免密当前状态：conf=${conf_nopw:-未配置} / 系统：${cur}"
  if [[ "${cur}" == "yes" ]]; then new="no"; else new="yes"; fi
  if ! ask_yesno "把 sudo 免密从 ${cur} 切换为 ${new}？" n; then return 0; fi
  conf_update "SUDO_NOPASSWD" "${new}"
  if [[ "${new}" == "yes" ]]; then
    backup_file "/etc/sudoers.d/${ADMIN_USER}" >/dev/null
    printf '%s ALL=(ALL) NOPASSWD: ALL\n' "${ADMIN_USER}" > "/etc/sudoers.d/${ADMIN_USER}"
    chmod 0440 "/etc/sudoers.d/${ADMIN_USER}"
    chown root:root "/etc/sudoers.d/${ADMIN_USER}"
    if ! visudo -c >/dev/null 2>&1; then
      rm -f "/etc/sudoers.d/${ADMIN_USER}"
      die "sudoers 校验失败，已删除 /etc/sudoers.d/${ADMIN_USER}；请勿破坏 sudo"
    fi
    log "已开启免密：/etc/sudoers.d/${ADMIN_USER}"
  else
    if [[ -f "/etc/sudoers.d/${ADMIN_USER}" ]]; then
      backup_file "/etc/sudoers.d/${ADMIN_USER}" >/dev/null
      rm -f "/etc/sudoers.d/${ADMIN_USER}"
      if ! visudo -c >/dev/null 2>&1; then
        die "删除后 sudoers 校验失败，请立即检查 /etc/sudoers.d/"
      fi
      log "已关闭免密（sudo 恢复密码验证）"
    else
      log "sudo 使用密码（无 sudoers 文件，无需改动）"
    fi
  fi
}

# ---------- 动作：公钥管理（conf 为唯一事实源，改完立即重写 authorized_keys）----------
declare -a PUBKEYS=()
load_pubkeys_from_conf() {
  local i=1 k
  while :; do
    k="SSH_PUBKEY_${i}"
    if conf_has "${k}"; then
      PUBKEYS+=("$(conf_read "${k}")")
      i=$((i + 1))
    else
      break
    fi
  done
}
load_pubkeys_from_conf

save_pubkeys_to_conf() {
  while :; do
    if grep -q "^SSH_PUBKEY_[0-9]*=" "${CONF}" 2>/dev/null; then
      sed -i "/^SSH_PUBKEY_[0-9]*=/d" "${CONF}"
    else
      break
    fi
  done
  local idx=1
  for k in "${PUBKEYS[@]}"; do
    conf_write "SSH_PUBKEY_${idx}" "${k}"
    idx=$((idx + 1))
  done
}

rewrite_authorized_keys() {
  SSH_DIR="${HOME_DIR}/.ssh"
  mkdir -p "${SSH_DIR}"
  chmod 700 "${SSH_DIR}"
  AK="${SSH_DIR}/authorized_keys"
  AK_TMP="${AK}.tmp.$$"
  install -m 600 -o "${ADMIN_USER}" -g "${OWNER_GID}" /dev/null "${AK_TMP}"
  if [[ -f "${AK}" ]]; then
    backup_file "${AK}" >/dev/null
  fi
  for k in "${PUBKEYS[@]}"; do
    printf '%s\n' "${k}" >> "${AK_TMP}"
  done
  mv "${AK_TMP}" "${AK}"
  chown "${ADMIN_USER}:${OWNER_GID}" "${SSH_DIR}" "${AK}"
  chmod 700 "${SSH_DIR}"; chmod 600 "${AK}"
}

do_pubkey() {
  local op line raw added i k pick del
  while :; do
    printf '%s公钥管理 · conf 已配置 %s 个%s\n' "${C_D}" "${#PUBKEYS[@]}" "${C_0}"
    ui_item 1 "追加公钥"
    ui_item 2 "删除公钥"
    printf '  %s0%s) 返回\n' "${C_R}" "${C_0}"
    ask_menu "选择操作" 2
    op="${UI_REPLY}"
    if [[ "${op}" == "0" ]]; then return 0; fi
    if [[ "${op}" == "1" ]]; then
      printf '粘贴公钥（每行一个，输入空行结束）：\n'
      raw=""
      while IFS= read -r line; do
        [[ -z "${line}" ]] && break
        raw+="${line}"$'\n'
      done
      added=0
      while IFS= read -r line; do
        [[ -n "${line}" ]] || continue
        if ! v_pubkey "${line}" >/dev/null 2>&1; then
          warn "跳过非法公钥行：${line:0:40}..."
          continue
        fi
        PUBKEYS+=("${line}")
        added=$((added + 1))
      done <<< "${raw}"
      if [[ "${added}" -gt 0 ]]; then
        save_pubkeys_to_conf
        rewrite_authorized_keys
        log "已追加 ${added} 个公钥"
      else
        log "没有新增公钥（输入为空或全部非法）"
      fi
    else
      if [[ "${#PUBKEYS[@]}" -eq 0 ]]; then
        log "conf 中没有可删除的公钥"
        continue
      fi
      printf '当前已配置的公钥：\n'
      i=1
      for k in "${PUBKEYS[@]}"; do
        printf '  %d) %s...%s\n' "${i}" "${k:0:24}" "${k: -12}"
        i=$((i + 1))
      done
      pick=""
      while :; do
        read -rp "删除第几把？[1-${#PUBKEYS[@]}]（回车=取消） " pick || die "输入中断"
        [[ -z "${pick}" ]] && break
        if [[ "${pick}" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#PUBKEYS[@]} )); then break; fi
        warn "无效输入：请输入 1-${#PUBKEYS[@]}"
      done
      if [[ -n "${pick:-}" ]]; then
        del="${PUBKEYS[$((pick - 1))]}"
        printf '将删除：%s\n' "${del}"
        if ask_yesno "确认删除这把公钥？" n; then
          local tmp=()
          for k in "${PUBKEYS[@]}"; do
            [[ "${k}" == "${del}" ]] || tmp+=("${k}")
          done
          PUBKEYS=("${tmp[@]}")
          save_pubkeys_to_conf
          rewrite_authorized_keys
          log "已删除 1 个公钥"
        fi
      fi
    fi
  done
}

# ---------- 主菜单：选一件事做一件事，0 退出 ----------
while :; do
  PW_STATUS="$(passwd -S "${ADMIN_USER}" 2>/dev/null | awk '{print $2}')"
  if [[ "${PW_STATUS}" == "P" ]]; then
    PW_DESC="${C_G}已设置 ✓${C_0}"
  else
    PW_DESC="${C_Y}未设置 ⚠${C_0}"
  fi
  if [[ -f "/etc/sudoers.d/${ADMIN_USER}" ]]; then
    SUDO_DESC="${C_G}开（免密）${C_0}"
  else
    SUDO_DESC="关（需密码）"
  fi
  if [[ "${#PUBKEYS[@]}" -gt 0 ]]; then
    PK_DESC="${#PUBKEYS[@]} 个"
  else
    PK_DESC="${C_Y}0 个 ⚠${C_0}"
  fi
  ui_rule
  printf '%s 用户管理 · %s%s\n' "${C_B}" "${C_G}" "${ADMIN_USER}"
  ui_sep
  ui_kv "登录密码" "${PW_DESC}"
  ui_kv "sudo 免密" "${SUDO_DESC}"
  ui_kv "公钥" "${PK_DESC}"
  ui_sep
  ui_item 1 "设置/修改登录密码"
  ui_item 2 "sudo 免密 开↔关"
  ui_item 3 "管理公钥（追加/删除）"
  ui_quit
  ui_sep
  ask_menu "选择操作" 3 "退出"
  OP="${UI_REPLY}"
  case "${OP}" in
    0) break ;;
    1) do_password ;;
    2) do_sudo ;;
    3) do_pubkey ;;
  esac
done

if [[ "${PW_STATUS:-}" != "P" ]]; then
  warn "未设置密码：sudo 使用密码模式时该用户将无法验证，请尽快手动 passwd ${ADMIN_USER}"
fi
log "第 4 步完成"
log "闸门：新开终端验证 ssh ${ADMIN_USER}@<host> 密钥登录 + sudo -v；通过前禁止执行 05/06"

#!/usr/bin/env bash
# VPS 初始化 · 07 fail2ban（菜单式管理）
# 自包含 + 幂等 + 交互闸门。用法：sudo bash 07-fail2ban.sh
# 首次运行自动安装 fail2ban 并写 jail.local（sshd jail 监听新端口），之后进入维护菜单。
# 项目：https://raw.githubusercontent.com/Pathto1804/myVPS/main/07-fail2ban.sh

set -euo pipefail
# 命令替换默认不继承 errexit：不开这个，$(ask_input ...) 里的 die 只终止子 shell，
# 空值会被照常写进 conf。开启后交互读取遇 EOF/Ctrl-D 即中止脚本。（bash >= 4.4）
shopt -s inherit_errexit

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
CONF="/root/.vps-init.conf"
BK_ROOT="/root/vps-init-backups"
# 备份目录保留份数（超出删最旧；bk_prune 只匹配 YYYYmmdd-HHMMSS 目录）
BK_KEEP=20

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
ask_input_def() {
  # ask_input_def <提示> <校验函数名> <默认值>——空输入取默认值
  local prompt="$1" v="$2" def="$3" val
  while :; do
    read -rp "${prompt} [回车=建议: ${def}] " val || die "输入中断"
    val="${val:-${def}}"
    if "${v}" "${val}"; then printf '%s' "${val}"; return 0; fi
  done
}

backup_file() {
  local path="$1" stamp dir newest base
  [[ -e "${path}" ]] || { printf ''; return 0; }
  base="$(basename "${path}")"
  # 最新一份内容相同则不新建目录，只把它的时间戳刷新为当前时刻
  # （不刷新会被后续备份挤成最旧，20 次后被裁剪逻辑删掉）
  newest="$(find "${BK_ROOT}" -mindepth 1 -maxdepth 1 -type d \
    -regextype posix-extended -regex '.*/[0-9]{8}-[0-9]{6}' 2>/dev/null | sort | tail -n 1)" || true
  if [[ -n "${newest}" && -f "${newest}/${base}" ]] && cmp -s "${path}" "${newest}/${base}"; then
    stamp="$(date +%Y%m%d-%H%M%S)"
    dir="${BK_ROOT}/${stamp}"
    if [[ "${dir}" != "${newest}" ]]; then
      mkdir -p "${dir}"
      mv "${newest}/${base}" "${dir}/${base}"
      # 只在原目录已空时移除，绝不删掉同目录里的其他备份
      rmdir -- "${newest}" 2>/dev/null || true
    fi
    bk_prune
    printf '%s%s 内容未变，复用备份 %s/%s%s\n' "${C_G}" "${path}" "${BK_ROOT}" "${stamp}" "${C_0}" >&2
    printf '%s' "${dir}"
    return 0
  fi
  stamp="$(date +%Y%m%d-%H%M%S)"
  dir="${BK_ROOT}/${stamp}"
  mkdir -p "${dir}"
  cp -a "${path}" "${dir}/"
  bk_prune
  printf '%s已备份 %s -> %s/%s\n' "${C_G}" "${path}" "${dir}" "${C_0}" >&2
  printf '%s' "${dir}"
}

# bk_prune：只保留最近 BK_KEEP 份时间戳备份目录
# 只删严格匹配 YYYYmmdd-HHMMSS 的目录，BK_ROOT 下的其他内容一律不碰
bk_prune() {
  local -a dirs=()
  local i
  [[ -d "${BK_ROOT}" ]] || return 0
  mapfile -t dirs < <(find "${BK_ROOT}" -mindepth 1 -maxdepth 1 -type d \
    -regextype posix-extended -regex '.*/[0-9]{8}-[0-9]{6}' 2>/dev/null | sort)
  (( ${#dirs[@]} > BK_KEEP )) || return 0
  for (( i = 0; i < ${#dirs[@]} - BK_KEEP; i++ )); do
    rm -rf -- "${dirs[$i]}"
  done
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

v_ssh_port() {
  local p="$1"
  [[ "${p}" =~ ^[0-9]+$ ]]           || { printf '端口须为数字\n' >&2; return 1; }
  (( p >= 1024 && p <= 65535 ))      || { printf '端口需在 1024-65535\n' >&2; return 1; }
  [[ "${p}" != "22" && "${p}" != "2222" ]] || { printf '避开常用端口 22/2222\n' >&2; return 1; }
  return 0
}
v_posint() { [[ "$1" =~ ^[0-9]+$ ]] || { printf '须为正整数\n' >&2; return 1; }; }
v_ip() {
  # 仅 IPv4（a.b.c.d）；fail2ban 的 banip/unbanip 也接受 IPv6，本脚本不处理
  local ip="$1" IFS=. parts p
  [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { printf 'IP 格式须为 a.b.c.d\n' >&2; return 1; }
  IFS=. read -r -a parts <<< "${ip}"
  for p in "${parts[@]}"; do
    (( 10#${p} <= 255 )) || { printf 'IP 每段须在 0-255\n' >&2; return 1; }
  done
  return 0
}

conf_val() {   # 读 conf 值；缺失输出空串
  local v=""
  if conf_has "$1"; then v="$(conf_read "$1")"; fi
  printf '%s' "${v}"
}

sshd_port() {   # sshd 实际生效端口；读不到输出空串
  # 不用 `awk '/^port /{print $2; exit}'`：awk 提前退出会让 sshd 收到 SIGPIPE（141），
  # 在 set -o pipefail 下整条管道非零 → 赋值失败 → ERR trap 裸奔退出。
  local p
  p="$(sshd -T 2>/dev/null | awk '/^port /{p=$2} END{print p}' | tr -d '\r')" || true
  [[ "${p}" =~ ^[0-9]+$ ]] || { printf ''; return 0; }
  printf '%s' "${p}"
}

# ==================== fail2ban 辅助 ====================

JAIL="/etc/fail2ban/jail.local"

f2b_installed() { command -v fail2ban-client >/dev/null 2>&1; }

jail_val() {   # 从 jail.local 读键值；文件或键缺失输出空串
  # 不用 `awk ... exit` / `| head -1`：上游收 SIGPIPE（141）在 pipefail 下会让赋值失败
  local v=""
  if [[ -f "${JAIL}" ]]; then
    v="$(awk -F'[[:space:]]*=[[:space:]]*' -v k="${1}" '$1==k{v=$2} END{print v}' "${JAIL}" | tr -d '\r')" || true
  fi
  printf '%s' "${v}"
}

f2b_status_raw() {   # `fail2ban-client status sshd` 原始输出；未就绪输出空串
  local out
  out="$(fail2ban-client status sshd 2>/dev/null)" || true
  printf '%s' "${out}"
}

# ==================== 动作：应用 ====================

f2b_resolve_port() {   # 成功输出写进 jail.local 的端口；读不到 sshd 实际端口或与配置不一致时告警并 return 1
  # fail closed：宁可拒绝写 jail，也不让 fail2ban 去盯一个 sshd 没监听的端口（那样是静默失效）
  local actual conf_port
  actual="$(sshd_port)"
  if [[ -z "${actual}" ]]; then
    warn "读不到 sshd 实际端口（sshd -T 失败），无法校验 jail 端口，拒绝写入。先确认 sshd -T 能跑（常见：/run/sshd 缺失，mkdir -p /run/sshd）"
    return 1
  fi
  if ! v_ssh_port "${actual}" >/dev/null 2>&1; then
    warn "sshd 实际端口 ${actual} 不是本脚本认可的新端口（1024-65535 且非 22/2222）：先完成 05/06 再回来配 fail2ban"
    return 1
  fi
  conf_port="$(conf_val SSH_PORT)"
  if ! v_ssh_port "${conf_port}" >/dev/null 2>&1; then
    # conf 无可用端口（如未跑 05/06 或 conf 被删）：默认取 sshd 实际端口——jail 必须盯它
    conf_port="$(ask_input_def "jail 监听端口（须与 sshd 实际一致）" v_ssh_port "${actual}")"
  fi
  if [[ "${conf_port}" != "${actual}" ]]; then
    warn "sshd 实际端口 ${actual} != 配置 ${conf_port}。请先完成 05/06（jail 端口必须与实际端口一致）"
    return 1
  fi
  printf '%s' "${conf_port}"
}

f2b_write_jail() {   # <端口> <bantime> <findtime> <maxretry>；jail 就绪返回 0，否则返回 1
  local port="$1" bantime="$2" findtime="$3" maxretry="$4" jail_ok=0
  backup_file "${JAIL}" >/dev/null || true
  printf '[sshd]\nenabled = true\nport = %s\nbackend = systemd\nbantime = %s\nfindtime = %s\nmaxretry = %s\n' \
    "${port}" "${bantime}" "${findtime}" "${maxretry}" > "${JAIL}"
  systemctl enable fail2ban
  systemctl restart fail2ban
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

do_apply() {
  local port bantime findtime maxretry
  log "安装 fail2ban……"
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y fail2ban
  # 端口闸门：读不到 sshd 实际端口或与配置不一致时拒绝写入（f2b_resolve_port 已告警）
  # 不用 return 1：菜单分支里返回非零会被 set -e 当成脚本级失败；完成与否由退出前的 jail 状态判定
  port="$(f2b_resolve_port)" || { warn "未写入 ${JAIL}：端口校验未通过（原因见上），修复后回菜单 1 重试"; return 0; }
  bantime="$(conf_get_def "F2B_BANTIME" "封禁时长（秒）" 86400)"
  findtime="$(conf_get_def "F2B_FINDTIME" "统计窗口（秒）" 600)"
  maxretry="$(conf_get_def "F2B_MAXRETRY" "最大重试次数" 3)"
  f2b_write_jail "${port}" "${bantime}" "${findtime}" "${maxretry}" || exit 1
  log "fail2ban sshd jail 已启用（端口 ${port} / ${maxretry} 次 / ${bantime}s）"
  fail2ban-client status sshd
}

conf_get_def() {
  # conf_get_def <键> <提示> <默认值>——conf 有合法值则直接采用，否则带默认值询问并写盘
  local key="$1" prompt="$2" val
  if conf_has "${key}"; then
    val="$(conf_read "${key}")"
    if v_posint "${val}" >/dev/null 2>&1; then
      printf '%s%s 已配置（conf）\n' "${C_G}" "${key}" >&2
      printf '%s' "${val}"; return 0
    fi
    warn "conf 中 ${key} 不合法，重新询问"
    sed -i "/^${key}=/d" "${CONF}" 2>/dev/null || :   # 清掉非法旧行，防 head -1 永远读到坏值
  fi
  val="$(ask_input_def "${prompt}" v_posint "$3")"
  conf_write "${key}" "${val}"
  printf '%s%s 已保存\n' "${C_G}" "${key}" >&2
  printf '%s' "${val}"
}

# ==================== 动作：维护 ====================

do_status() {
  local out
  printf '%s\n' "${C_D}── jail.local（${JAIL}）──${C_0}"
  if [[ -f "${JAIL}" ]]; then
    cat "${JAIL}"
  else
    warn "未找到 ${JAIL}（尚未执行菜单 1）"
  fi
  printf '\n%s\n' "${C_D}── fail2ban-client status sshd ──${C_0}"
  if ! f2b_installed; then
    warn "未安装 fail2ban-client（先执行菜单 1）"
  else
    out="$(f2b_status_raw)"
    if [[ -n "${out}" ]]; then
      printf '%s\n' "${out}"
    else
      warn "查询失败：服务未运行或 sshd jail 未启用（systemctl status fail2ban）"
    fi
  fi
  printf '\n%s\n' "${C_D}── 服务日志（最近 20 行）──${C_0}"
  journalctl -u fail2ban -n 20 --no-pager 2>/dev/null || warn "无日志输出（journalctl 不可用）"
}

do_params() {
  local cur_b cur_f cur_m v
  cur_b="$(conf_val F2B_BANTIME)"
  cur_f="$(conf_val F2B_FINDTIME)"
  cur_m="$(conf_val F2B_MAXRETRY)"
  # conf 缺失时以 jail.local 实际值为准，再退到默认激进档
  [[ -n "${cur_b}" ]] || cur_b="$(jail_val bantime)"
  [[ -n "${cur_b}" ]] || cur_b=86400
  [[ -n "${cur_f}" ]] || cur_f="$(jail_val findtime)"
  [[ -n "${cur_f}" ]] || cur_f=600
  [[ -n "${cur_m}" ]] || cur_m="$(jail_val maxretry)"
  [[ -n "${cur_m}" ]] || cur_m=3
  log "当前参数：bantime=${cur_b} / findtime=${cur_f} / maxretry=${cur_m}"
  v="$(ask_input_def "封禁时长（秒）" v_posint "${cur_b}")"
  conf_update "F2B_BANTIME" "${v}"
  v="$(ask_input_def "统计窗口（秒）" v_posint "${cur_f}")"
  conf_update "F2B_FINDTIME" "${v}"
  v="$(ask_input_def "最大重试次数" v_posint "${cur_m}")"
  conf_update "F2B_MAXRETRY" "${v}"
  log "已写入 ${CONF}：F2B_BANTIME/F2B_FINDTIME/F2B_MAXRETRY"
  if ask_yesno "立即应用到 jail.local 并重启 fail2ban？" y; then
    do_apply
  else
    log "未应用：jail.local 仍是旧参数，菜单 1 可随时应用"
  fi
}

do_ban() {
  local op ip
  if ! f2b_installed || ! fail2ban-client status sshd >/dev/null 2>&1; then
    warn "fail2ban 未运行或 sshd jail 未启用，先执行菜单 1"
    return 0
  fi
  ui_item 1 "封禁 IP"
  ui_item 2 "解封 IP"
  printf '  %s0%s) 返回\n' "${C_R}" "${C_0}"
  ask_menu "选择操作" 2
  op="${UI_REPLY}"
  [[ "${op}" == "0" ]] && return 0
  ip="$(ask_input "IP 地址" v_ip)"
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
}

# ==================== 脚本主体 ====================

require_root
require_tty
require_distro

# 首次运行不自动安装：只提示未配置，由用户从菜单选 1
# 这里不写"完成"字样：配置是否真的生效由退出前的 jail 状态判定
if ! conf_has "F2B_BANTIME"; then
  warn "首次运行：fail2ban 尚未按本脚本策略配置，请从菜单 1 开始（会安装 fail2ban 并写 jail.local）"
  log "进入维护菜单（按 0 退出）"
fi

while :; do
  if ! f2b_installed; then
    F2B_DESC="${C_Y}未安装 ⚠${C_0}"
    JAIL_DESC="${C_Y}不可用（未安装 fail2ban）${C_0}"
  else
    F2B_STATE="$(systemctl is-active fail2ban 2>/dev/null)" || true
    if [[ "${F2B_STATE}" == "active" ]]; then
      F2B_DESC="${C_G}active ✓${C_0}"
    else
      F2B_DESC="${C_Y}${F2B_STATE:-未知} ⚠${C_0}"
    fi
    ST_RAW="$(f2b_status_raw)"
    if [[ -n "${ST_RAW}" ]]; then
      JAIL_DESC="${C_G}运行中 ✓${C_0}（封禁 $(printf '%s\n' "${ST_RAW}" | awk '/Currently banned:/{c=$NF} END{print c+0}') 个）"
    else
      JAIL_DESC="${C_Y}未启用 ⚠${C_0}"
    fi
  fi

  J_BANTIME="$(jail_val bantime)"
  J_FINDTIME="$(jail_val findtime)"
  J_MAXRETRY="$(jail_val maxretry)"
  C_BANTIME="$(conf_val F2B_BANTIME)"
  C_FINDTIME="$(conf_val F2B_FINDTIME)"
  C_MAXRETRY="$(conf_val F2B_MAXRETRY)"
  if [[ -z "${J_BANTIME}" && -z "${J_FINDTIME}" && -z "${J_MAXRETRY}" ]]; then
    P_DESC="${C_Y}未写入 jail.local ⚠${C_0}"
  else
    P_DESC="bantime ${J_BANTIME:-?} / findtime ${J_FINDTIME:-?} / maxretry ${J_MAXRETRY:-?}"
    if [[ -n "${C_BANTIME}" && "${C_BANTIME}" != "${J_BANTIME}" ]] \
       || [[ -n "${C_FINDTIME}" && "${C_FINDTIME}" != "${J_FINDTIME}" ]] \
       || [[ -n "${C_MAXRETRY}" && "${C_MAXRETRY}" != "${J_MAXRETRY}" ]]; then
      P_DESC="${P_DESC} ${C_Y}（conf 已改，按 1 应用）${C_0}"
    fi
  fi

  A_PORT="$(sshd_port)"
  J_PORT="$(jail_val port)"
  if [[ -z "${A_PORT}" ]]; then
    PORT_DESC="${C_Y}sshd 实际端口未知 ⚠${C_0}（sshd -T 失败；jail ${J_PORT:-未写入}）"
  elif [[ -z "${J_PORT}" ]]; then
    PORT_DESC="${C_Y}jail 端口未写入 ⚠${C_0}（sshd 实际 ${A_PORT}）"
  elif [[ "${J_PORT}" == "${A_PORT}" ]]; then
    PORT_DESC="${J_PORT} = sshd 实际 ${C_G}✓${C_0}"
  else
    PORT_DESC="${C_Y}jail ${J_PORT} != sshd 实际 ${A_PORT} ⚠${C_0}"
  fi

  ui_rule
  printf '%s fail2ban · sshd jail\n' "${C_B}"
  ui_sep
  ui_kv "服务" "${F2B_DESC}"
  ui_kv "jail 状态" "${JAIL_DESC}"
  ui_kv "参数" "${P_DESC}"
  ui_kv "端口" "${PORT_DESC}"
  ui_sep
  ui_item 1 "应用 / 重新应用配置（安装 fail2ban + 写 jail.local + 重启 + 验证）"
  ui_item 2 "查看状态详情（jail.local 内容 / 封禁列表 / 服务日志）"
  ui_item 3 "修改参数（封禁时长 / 统计窗口 / 重试次数 → conf，可选立即应用）"
  ui_item 4 "封禁 / 解封 IP"
  ui_quit
  ui_sep
  ask_menu "选择操作" 4 "退出"
  OP="${UI_REPLY}"
  case "${OP}" in
    0) break ;;
    1) do_apply ;;
    2) do_status ;;
    3) do_params ;;
    4) do_ban ;;
  esac
done

# 完成语以实际状态为准：jail 未就绪、或 jail 端口与 sshd 实际端口不一致，都不算第 7 步完成
# （退出码 1；同样状态下 12-verify.sh 也会报红）
J_PORT="$(jail_val port)"
A_PORT="$(sshd_port)"
if f2b_installed && fail2ban-client status sshd >/dev/null 2>&1 \
   && [[ -n "${J_PORT}" && "${J_PORT}" == "${A_PORT}" ]]; then
  log "第 7 步完成"
else
  warn "第 7 步未完成：fail2ban sshd jail 未就绪，或 jail 端口（${J_PORT:-未写入}）与 sshd 实际端口（${A_PORT:-未知}）不一致"
  warn "  回菜单 1 应用配置；仍失败看 systemctl status fail2ban / journalctl -u fail2ban -n 50"
  exit 1
fi

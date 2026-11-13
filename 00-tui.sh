#!/usr/bin/env bash
# VPS 初始化 · 00 单入口 TUI
# 自包含 + 原生状态 + 交互闸门。用法：sudo -i 后 bash <(curl -fsSL .../00-tui.sh)
# 启动即进入主菜单：只做环境前置检查与状态探测，不安装软件、不初始化系统、不写文件。
# 状态一律读系统原生来源（sshd -T / ss -tlnp / ufw / authorized_keys / fail2ban-client /
# /proc/swaps / sysctl / 20auto-upgrades），不保存项目私有运行态。
# 项目：https://raw.githubusercontent.com/Pathto1804/myVPS/main/00-tui.sh

set -euo pipefail
# 命令替换默认不继承 errexit：不开这个，$(ask_input ...) 里的 die 只终止子 shell，
# 空值会被照常写进系统配置。开启后交互读取遇 EOF/Ctrl-D 即中止脚本。（bash >= 4.4）
shopt -s inherit_errexit

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
BK_ROOT="/root/vps-init-backups"
# 备份目录保留份数（超出删最旧；bk_prune 只匹配 YYYYmmdd-HHMMSS 目录）
BK_KEEP=20
REPORT="/root/vps-init-report.md"
UA_FILE="/etc/apt/apt.conf.d/20auto-upgrades"
SSHD_CFG="/etc/ssh/sshd_config"
SSHD_D="/etc/ssh/sshd_config.d"
HARD="${SSHD_D}/01-hardening.conf"
JAIL="/etc/fail2ban/jail.local"
BBR_CONF="/etc/sysctl.d/99-bbr.conf"

BASE="sudo ca-certificates curl wget gnupg ufw fail2ban unattended-upgrades vim nano unzip htop needrestart ncdu mtr-tiny bind9-dnsutils"
TOOLS_EXTRA_DEFAULT="jq tmux lsof rsync zip"

# 本次进程内的管理员用户（不落盘；来源见 resolve_admin_user）
ADMIN_USER=""
# authorized_keys 原子替换的临时文件；异常退出时清掉半成品
AK_TMP=""
declare -a AK_LINES=()

if [[ -t 1 ]]; then
  C_G=$'\e[32m'; C_Y=$'\e[33m'; C_R=$'\e[31m'; C_B=$'\e[1m'; C_D=$'\e[90m'; C_0=$'\e[0m'
else
  C_G=''; C_Y=''; C_R=''; C_B=''; C_D=''; C_0=''
fi

log()  { printf '%s[%s]%s %s\n' "${C_B}" "${SCRIPT_NAME}" "${C_0}" "$*"; }
warn() { printf '%s[%s]%s %s\n' "${C_Y}" "${SCRIPT_NAME}" "${C_0}" "$*" >&2; }
die()  { printf '%s[%s]%s %s\n' "${C_R}" "${SCRIPT_NAME}" "${C_0}" "$*" >&2; exit 1; }

err_trap() { die "行 ${1}: ${2}"; }

# 动作级失败：打印原因后返回 1，由调用方中止当前动作/流程。
# 与 die 的区别：die 用于启动前置检查与输入中断（进程已无法继续），
# die_action 用于动作内的安全检查（TUI 必须活下来，用户可改完再来）。
die_action() { warn "$*"; return 1; }

# 动作隔离：菜单里的动作一律经 act 调用。
# 关掉 errexit 与 ERR trap 只作用于本次动作——TUI 必须活下来，
# 动作内的每一步危险操作都有显式 `|| die_action` / `if !` 判错（与 08-swap 的段落内判错同源）。
act() {
  local rc=0 had_e=0
  case "$-" in *e*) had_e=1 ;; esac
  set +e
  trap - ERR
  "$@" || rc=$?
  trap 'err_trap "${LINENO}" "${BASH_COMMAND}"' ERR
  # 只恢复调用前的状态：菜单动作内可能再嵌套 act，不能把 -e 强推给外层
  if (( had_e )); then set -e; fi
  return "${rc}"
}
trap 'err_trap "${LINENO}" "${BASH_COMMAND}"' ERR
trap 'if [[ -n "${AK_TMP}" ]]; then rm -f -- "${AK_TMP}"; fi' EXIT

# Ctrl-C：写操作可能只做了一半，提示按当前系统状态收敛
ui_abort() {
  printf '\n%s[中断]%s 已停止。若刚做过写操作，配置可能只改了一半；重新进入 TUI 会按当前系统状态收敛。\n' \
    "${C_Y}" "${C_0}" >&2
  exit 130
}
trap 'ui_abort' INT

# ============ 屏幕契约 ============
# 仅在 stdout 是 TTY 且 TERM 可用、非 dumb 时清屏。动作输出、错误诊断与闸门提示
# 在用户按键确认前不清屏；非法输入不整页重绘。
SCR_CLEAR=0
if [[ -t 1 ]]; then
  case "${TERM:-}" in
    ''|dumb|unknown) SCR_CLEAR=0 ;;
    *) SCR_CLEAR=1 ;;
  esac
fi

scr_clear() {
  if (( SCR_CLEAR )); then printf '\e[H\e[2J'; fi
  return 0
}

scr_pause() {   # scr_pause [提示]：等用户看完输出再继续
  local msg="${1:-按回车继续…}" _x
  printf '%s%s%s' "${C_D}" "${msg}" "${C_0}"
  read -r _x || true
  return 0
}

page_wait() {   # page_wait [提示]：确认看完输出 -> 清屏 -> 回上层
  scr_pause "${1:-按回车返回…}"
  scr_clear
  return 0
}

# ============ 环境前置检查 ============
require_root()   { [[ "${EUID}" -eq 0 ]] || die "需要 root 运行，请用：sudo bash ${SCRIPT_NAME}"; }
require_tty()    { [[ -t 0 ]] || die "需要交互终端运行，不支持无人值守（防锁死设计）"; }
require_distro() {
  local id
  id="$(. /etc/os-release 2>/dev/null && printf '%s' "${ID:-}")"
  [[ "${id}" == "debian" || "${id}" == "ubuntu" ]] || die "仅支持 Debian/Ubuntu，当前发行版：${id:-未知}"
}

# ============ 交互原语 ============
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

# ask_menu <提示> <最大编号> [零号含义]：结果写入全局 UI_REPLY（0..max）
# 空回车 = 0（子菜单返回）；非法输入原地重问，不重绘菜单
ask_menu() {
  local prompt="$1" max="$2" zero="${3:-返回主菜单}" input
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

# ============ 备份 ============
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

# ============ 公共校验器：合法返回 0，非法打印原因返回 1 ============
v_ssh_port() {
  local p="$1"
  [[ "${p}" =~ ^[0-9]+$ ]]           || { printf '端口须为数字\n' >&2; return 1; }
  (( p >= 1024 && p <= 65535 ))      || { printf '端口需在 1024-65535\n' >&2; return 1; }
  [[ "${p}" != "22" && "${p}" != "2222" ]] || { printf '避开常用端口 22/2222\n' >&2; return 1; }
  return 0
}
v_user() {
  [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { printf '用户名不合法（小写字母开头，允许 a-z 0-9 _ -）\n' >&2; return 1; }
  return 0
}
v_ports_list() {
  local s="$1" p
  [[ -z "${s}" ]] && return 0
  for p in ${s//,/ }; do
    [[ "${p}" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 )) || { printf '端口列表含非法项：%s\n' "${p}" >&2; return 1; }
  done
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
v_pubkey() {
  local line
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    [[ "${line}" =~ ^(ssh|ecdsa)- ]] || { printf '公钥应以 ssh- 或 ecdsa- 开头：%s\n' "${line:0:40}" >&2; return 1; }
  done <<< "$1"
  return 0
}

# ============ 状态探测：sshd ============
ssh_eff() {   # sshd -T 全量输出；失败输出空串
  local out
  out="$(sshd -T 2>/dev/null)" || true
  printf '%s' "${out}"
}

eff_val() {   # eff_val <ssh_eff 输出> <键名>：取该键生效值，缺失显示「未知」
  local out="$1" key="$2" v
  v="$(printf '%s\n' "${out}" | awk -v k="${key}" 'tolower($1)==k{v=$2} END{print v}')" || true
  printf '%s' "${v:-未知}"
}

sshd_port() {   # sshd 实际生效端口；读不到输出空串
  # 不用 `awk '/^port /{print $2; exit}'`：awk 提前退出会让 sshd 收到 SIGPIPE（141），
  # 在 set -o pipefail 下整条管道非零 → 赋值失败 → ERR trap 裸奔退出。
  local p
  p="$(sshd -T 2>/dev/null | awk '/^port /{p=$2} END{print p}' | tr -d '\r')" || true
  [[ "${p}" =~ ^[0-9]+$ ]] || { printf ''; return 0; }
  printf '%s' "${p}"
}

rand_port() { shuf -i 10000-65535 -n 1 2>/dev/null || printf '%s' 54321; }

ss_listen_ports() {   # 监听端口的本地地址列（如 0.0.0.0:2222）
  local out
  out="$(ss -tln 2>/dev/null | awk '{print $4}')" || true
  printf '%s' "${out}"
}

# ============ 状态探测：ufw ============
fw_status_numbered() {   # `ufw status numbered` 原始输出（含 Status 与带编号的规则；注意它不含 Default 行）
  # 不写成 `ufw status | grep -q`：grep 匹配即退出会让 ufw 收 SIGPIPE（141），
  # 在 set -o pipefail 下把「有规则」误判成「无规则」
  local out
  out="$(ufw status numbered 2>/dev/null)" || true
  printf '%s' "${out}"
}
fw_status_plain() {   # `ufw status` 原始输出（规则行的第一个字段就是 "端口/协议"，用于精确匹配）
  local out
  out="$(ufw status 2>/dev/null)" || true
  printf '%s' "${out}"
}
fw_status_verbose() {   # `ufw status verbose` 原始输出（唯一带 Default/Logging 行的输出）
  local out
  out="$(ufw status verbose 2>/dev/null)" || true
  printf '%s' "${out}"
}
fw_added() {   # `ufw show added` 原始输出（规则行形如 "ufw allow 22/tcp"）
  # 唯一在 ufw 未启用时也列规则的来源：未启用时 `ufw status` 只回 "Status: inactive"、
  # 一条规则都不列，但规则实际已写入 /etc/ufw/user.rules。首次初始化的自检必须靠它。
  local out
  out="$(ufw show added 2>/dev/null)" || true
  printf '%s' "${out}"
}
FW_RAW=""    # 带编号规则快照（删除要按 ufw 自己的编号；仅 ufw 启用时有意义）
FW_PLAIN=""  # 规则快照（精确匹配用）
FW_VERB=""   # 默认策略/日志快照
FW_ADDED=""  # `ufw show added` 快照（未启用时的规则来源）
fw_refresh() {
  if ! command -v ufw >/dev/null 2>&1; then
    FW_RAW=""; FW_PLAIN=""; FW_VERB=""; FW_ADDED=""
    return 0
  fi
  FW_RAW="$(fw_status_numbered)"; FW_PLAIN="$(fw_status_plain)"; FW_VERB="$(fw_status_verbose)"
  if [[ "$(fw_state)" == "active" ]]; then FW_ADDED=""; else FW_ADDED="$(fw_added)"; fi
  return 0
}
fw_first_line() { printf '%s' "${1%%$'\n'*}"; }   # 取首行：代替 `| head -n 1`（head 早退会 SIGPIPE 上游）
fw_state() {   # active / inactive / 未安装 / 未知
  if ! command -v ufw >/dev/null 2>&1; then printf '未安装'; return 0; fi
  local s
  s="$(sed -n 's/^Status: \(.*\)$/\1/p' <<<"${FW_RAW}")"
  printf '%s' "$(fw_first_line "${s:-未知}")"
}
fw_default_in() {
  local s
  s="$(sed -n 's/^Default: \([a-z]*\) (incoming).*/\1/p' <<<"${FW_VERB}")"
  printf '%s' "$(fw_first_line "${s:-未知}")"
}
fw_default_out() {
  local s
  s="$(sed -n 's/^Default: [a-z]* (incoming), \([a-z]*\) (outgoing).*/\1/p' <<<"${FW_VERB}")"
  printf '%s' "$(fw_first_line "${s:-未知}")"
}
fw_rule_count() {
  local n
  n="$(grep -cE '^\[[[:space:]]*[0-9]+\]' <<<"${FW_RAW}" || true)"
  printf '%s' "${n:-0}"
}
fw_has_rule() {   # fw_has_rule <端口/协议>：ufw 启用时读 status，未启用时读 show added（调用前需 fw_refresh）
  # 用「首字段全等」而非 grep -w：端口范围规则 1000:2000/tcp 会被 -w 误判为含 1000/tcp
  [[ -n "$1" ]] || return 1
  if [[ "$(fw_state)" == "active" ]]; then
    awk -v s="$1" '$1==s{f=1} END{exit !f}' <<<"${FW_PLAIN}"
  else
    # 未启用时 status 不列规则，改查 show added：同时匹配 `ufw allow 22/tcp`
    # 与 `ufw allow from <来源> to any port 22 proto tcp` 两种形态
    local port proto
    port="${1%%/*}"; proto="${1##*/}"
    grep -qE "^ufw (allow|limit) (${1}|from .* to any port ${port} proto ${proto})\$" <<<"${FW_ADDED}"
  fi
}
fw_rule_line() {   # fw_rule_line <编号>：输出该编号规则的文本（去掉 "[ n] " 前缀），无则空
  local n="$1" s
  s="$(sed -n "s/^\[[[:space:]]*${n}\][[:space:]]*//p" <<<"${FW_RAW}")"
  fw_first_line "${s}"
}

# ============ 状态探测：用户 / sudo / 公钥 ============
user_home() { getent passwd "$1" | cut -d: -f6; }
user_gid()  { id -g "$1"; }

human_users() {   # 可登录普通用户（UID 1000..59999 且 shell 可用）
  local u uid shell
  while IFS=: read -r u _ uid _ _ _ shell; do
    [[ "${uid}" =~ ^[0-9]+$ ]] || continue
    (( uid >= 1000 && uid < 60000 )) || continue
    [[ "${shell}" == */nologin || "${shell}" == */false ]] && continue
    printf '%s\n' "${u}"
  done < <(getent passwd)
}

admin_from_allowusers() {   # 有效 AllowUsers 中「唯一且存在」的用户；否则输出空
  local eff raw tok
  local -a users=()
  eff="$(ssh_eff)"
  [[ -n "${eff}" ]] || return 0
  raw="$(awk 'tolower($1)=="allowusers"{for(i=2;i<=NF;i++) print $i}' <<<"${eff}")"
  while IFS= read -r tok; do
    [[ -n "${tok}" ]] || continue
    tok="${tok%%@*}"          # AllowUsers 允许 user@host 形式
    [[ -n "${tok}" ]] || continue
    users+=("${tok}")
  done <<< "${raw}"
  (( ${#users[@]} == 1 )) || return 0
  id "${users[0]}" >/dev/null 2>&1 || return 0
  printf '%s' "${users[0]}"
}

resolve_admin_user() {
  # 优先：本进程已确定且账号存在；其次：有效 AllowUsers 的唯一用户；最后：交互选择
  local u
  local -a cands=()
  if [[ -n "${ADMIN_USER}" ]] && id "${ADMIN_USER}" >/dev/null 2>&1; then
    return 0
  fi
  u="$(admin_from_allowusers)"
  if [[ -n "${u}" ]]; then
    ADMIN_USER="${u}"
    log "从 sshd 有效 AllowUsers 取到管理员账号：${ADMIN_USER}"
    return 0
  fi
  mapfile -t cands < <(human_users)
  printf '系统现有可登录用户：\n'
  if (( ${#cands[@]} > 0 )); then
    local i=1 c
    for c in "${cands[@]}"; do
      printf '  %d) %s\n' "${i}" "${c}"
      i=$((i + 1))
    done
  else
    printf '  （无）\n'
  fi
  while :; do
    read -rp "管理员用户名（输入上面的编号，或直接输入用户名）: " u || die "输入中断"
    if [[ "${u}" =~ ^[0-9]+$ ]] && (( u >= 1 && u <= ${#cands[@]} )); then
      ADMIN_USER="${cands[u - 1]}"
      return 0
    fi
    if v_user "${u}" >/dev/null 2>&1; then
      ADMIN_USER="${u}"
      return 0
    fi
    warn "无效输入：请输入 1-${#cands[@]} 的编号，或合法用户名（小写字母开头）"
  done
}

pw_state() {   # P / L / NP / 未知
  local s
  s="$(passwd -S "$1" 2>/dev/null | awk '{print $2}')" || true
  printf '%s' "${s:-未知}"
}

sudo_state() {   # yes / no / unknown —— 用有效权限查询，不用文件存在性推断
  local u="$1" out rc=0
  command -v sudo >/dev/null 2>&1 || { printf 'unknown'; return 0; }
  out="$(LC_ALL=C sudo -l -U "${u}" 2>&1)" || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    if grep -q 'may not run sudo' <<<"${out}"; then printf 'no'; return 0; fi
    printf 'unknown'; return 0
  fi
  if grep -qE '^[[:space:]]+\(.*\)[[:space:]]+.*NOPASSWD:' <<<"${out}"; then
    printf 'yes'
  else
    printf 'no'
  fi
}

ak_path() {   # 管理员用户的 authorized_keys 路径；解析失败输出空
  local h
  h="$(user_home "${ADMIN_USER}")" || true
  [[ -n "${h}" ]] || { printf ''; return 0; }
  printf '%s/.ssh/authorized_keys' "${h}"
}

ak_count() {   # authorized_keys 中的有效公钥行数
  local ak n
  ak="$(ak_path)"
  [[ -n "${ak}" && -f "${ak}" ]] || { printf '0'; return 0; }
  n="$(grep -cE '^(ssh|ecdsa)-' "${ak}" || true)"
  printf '%s' "${n:-0}"
}

ak_write_lines() {   # 用 AK_LINES 原子替换 authorized_keys（保留属主与 700/600 权限）
  local u="${ADMIN_USER}" h gid ak tmp
  h="$(user_home "${u}")" || true
  [[ -n "${h}" ]] || { die_action "无法解析 ${u} 的主目录"; return 1; }
  gid="$(user_gid "${u}")"
  ak="${h}/.ssh/authorized_keys"
  if ! { mkdir -p "${h}/.ssh" && chmod 700 "${h}/.ssh"; }; then
    die_action "无法准备 ${h}/.ssh（检查目录属主与权限）"
    return 1
  fi
  tmp="${ak}.tmp.$$"
  AK_TMP="${tmp}"
  if ! install -m 600 -o "${u}" -g "${gid}" /dev/null "${tmp}"; then
    die_action "无法在 ${h}/.ssh 创建临时文件（检查属主与权限）"
    return 1
  fi
  if (( ${#AK_LINES[@]} > 0 )); then
    printf '%s\n' "${AK_LINES[@]}" > "${tmp}"
  fi
  if ! { chown "${u}:${gid}" "${tmp}" && chmod 600 "${tmp}" && mv -f "${tmp}" "${ak}"; }; then
    die_action "替换 ${ak} 失败（临时文件已清理）"
    return 1
  fi
  AK_TMP=""        # 已落位，EXIT trap 不再清理
  chown "${u}:${gid}" "${h}/.ssh" "${ak}" 2>/dev/null || true
  chmod 700 "${h}/.ssh"
  chmod 600 "${ak}"
  return 0
}

# ============ 状态探测：fail2ban ============
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

f2b_param() {   # f2b_param <键> <默认值>：jail.local 有值优先，否则用默认
  local v
  v="$(jail_val "$1")"
  if [[ -n "${v}" ]]; then printf '%s' "${v}"; else printf '%s' "$2"; fi
}

# ============ 状态探测：其他 ============
swap_active() { [[ -n "$(swapon --show 2>/dev/null)" ]]; }
swap_summary() {
  local s
  s="$(free -h 2>/dev/null | awk '/^Swap:/{print $2}')" || true
  if [[ -z "${s}" || "${s}" == "0B" || "${s}" == "0" ]]; then printf '未启用'; else printf '%s' "${s}"; fi
}
swappiness_now() {
  local v
  v="$(sysctl -n vm.swappiness 2>/dev/null | tr -d '\r')" || true
  printf '%s' "${v:-未知}"
}
bbr_cc() {
  local v
  v="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | tr -d '\r')" || true
  printf '%s' "${v:-未知}"
}
bbr_qdisc() {
  local v
  v="$(sysctl -n net.core.default_qdisc 2>/dev/null | tr -d '\r')" || true
  printf '%s' "${v:-未知}"
}
ua_enabled() {
  [[ -f "${UA_FILE}" ]] || return 1
  grep -q 'APT::Periodic::Update-Package-Lists "[1-9]' "${UA_FILE}" || return 1
  grep -q 'APT::Periodic::Unattended-Upgrade "[1-9]' "${UA_FILE}" || return 1
  return 0
}
ua_state() { if ua_enabled; then printf '已启用'; else printf '未启用'; fi; }
ntp_active() {
  local out
  out="$(timedatectl 2>/dev/null)" || true
  grep -q 'NTP service: active' <<<"${out}"
}
cur_tz() {
  local out
  out="$(timedatectl show -p Timezone --value 2>/dev/null)" || true
  printf '%s' "${out:-未知}"
}
pkg_installed() {
  local st
  st="$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" || true
  [[ "${st}" == *"install ok installed"* ]]
}
missing_pkgs() {   # 输出未安装的包名（空格分隔）
  local p
  for p in "$@"; do
    pkg_installed "${p}" || printf '%s ' "${p}"
  done
}
apt_pending_count() {
  local out n
  out="$(DEBIAN_FRONTEND=noninteractive apt-get -s full-upgrade 2>/dev/null)" || true
  n="$(grep -cE '^(Inst|Remv) ' <<<"${out}" || true)"
  printf '%s' "${n:-0}"
}

# ============ 交互原语（显示层） ============
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
ui_item() { printf '  %s%s%s) %s\n' "${C_G}" "$1" "${C_0}" "$2"; }
ui_quit() { printf '  %s0%s) 返回主菜单\n' "${C_R}" "${C_0}"; }
ui_yes()  { printf '%s%s%s' "${C_G}" "$1" "${C_0}"; }
ui_no()   { printf '%s%s%s' "${C_Y}" "$1" "${C_0}"; }

# ============ 模块 1：系统更新与基础工具 ============
install_missing_base() {
  local miss
  miss="$(missing_pkgs ${BASE})"
  if [[ -z "${miss}" ]]; then
    log "必要包已全部安装（已满足）"
    return 0
  fi
  log "安装缺失包：${miss}"
  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y ${miss}; then
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
  read -rp "额外工具（空格分隔；回车=默认 ${TOOLS_EXTRA_DEFAULT}；输入 none=不装）: " sel || die "输入中断"
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
  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y ${miss}; then
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

# ============ 模块 2：用户、密码、sudo 和密钥 ============
user_do_password() {
  local op
  ui_item 1 "自己输入（转发 passwd）"
  ui_item 2 "生成随机密码（22 位，仅显示一次）"
  ui_quit
  ask_menu "选择" 2
  op="${UI_REPLY}"
  [[ "${op}" == "0" ]] && return 0
  if [[ "${op}" == "2" ]]; then
    local pw
    pw="$(gen_random_pw)"
    printf '%s生成的密码（仅显示这一次，请立即保存到密码管理器）：%s%s%s\n' "${C_Y}" "${C_B}" "${pw}" "${C_0}"
    if ! printf '%s:%s\n' "${ADMIN_USER}" "${pw}" | chpasswd; then
      die_action "设置密码失败（chpasswd 返回非零）"
      return 0
    fi
    printf '%s密码已设置\n' "${C_G}"
    unset pw
  else
    passwd "${ADMIN_USER}"
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
  local u="${ADMIN_USER}" f st new
  f="/etc/sudoers.d/${u}"
  st="$(sudo_state "${u}")"
  case "${st}" in
    unknown) warn "无法查询 ${u} 的 sudo 有效权限（sudo -l 失败），拒绝切换"; return 0 ;;
    yes) new="no" ;;
    *)   new="yes" ;;
  esac
  log "sudo 免密当前有效状态：${st}（本项目管理的文件：${f}）"
  if ! ask_yesno "把 sudo 免密从 ${st} 切换为 ${new}？" n; then return 0; fi
  if [[ "${new}" == "yes" ]]; then
    backup_file "${f}" >/dev/null || true
    if ! printf '%s ALL=(ALL) NOPASSWD: ALL\n' "${u}" > "${f}"; then
      die_action "写入 ${f} 失败"
      return 0
    fi
    if ! { chmod 0440 "${f}" && chown root:root "${f}" && visudo -c >/dev/null 2>&1; }; then
      rm -f "${f}"
      warn "sudoers 校验失败（权限或语法），已删除 ${f}；请勿破坏 sudo"
      return 0
    fi
    log "已开启免密：${f}"
  else
    if [[ -f "${f}" ]]; then
      backup_file "${f}" >/dev/null || true
      rm -f "${f}"
      if ! visudo -c >/dev/null 2>&1; then
        warn "删除后 sudoers 校验失败，请立即检查 /etc/sudoers.d/"
        return 0
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
  [[ -n "${ak}" ]] || { warn "无法解析 ${ADMIN_USER} 的主目录"; return 0; }
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
  ak_write_lines || return 0
  log "已追加 ${added} 个公钥到 ${ak}"
  return 0
}

user_do_key_del() {
  local ak pick del i n=0
  local -a raw=() idx=()
  ak="$(ak_path)"
  [[ -n "${ak}" ]] || { warn "无法解析 ${ADMIN_USER} 的主目录"; return 0; }
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
    read -rp "删除第几行？[1-${n}]（回车=取消） " pick || die "输入中断"
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
  ak_write_lines || return 0
  log "已删除 1 行，其余行与权限保持不变"
  return 0
}

user_do_switch() {
  local u
  local -a cands=()
  mapfile -t cands < <(human_users)
  printf '系统现有可登录用户：\n'
  if (( ${#cands[@]} > 0 )); then
    local i=1 c
    for c in "${cands[@]}"; do printf '  %d) %s\n' "${i}" "${c}"; i=$((i + 1)); done
  else
    printf '  （无）\n'
  fi
  while :; do
    read -rp "目标用户名（编号或用户名）: " u || die "输入中断"
    if [[ "${u}" =~ ^[0-9]+$ ]] && (( u >= 1 && u <= ${#cands[@]} )); then
      u="${cands[u - 1]}"
      break
    fi
    if v_user "${u}" >/dev/null 2>&1; then break; fi
    warn "无效输入：请输入 1-${#cands[@]} 的编号，或合法用户名"
  done
  if id "${u}" >/dev/null 2>&1; then
    log "用户 ${u} 已存在，切换为管理目标"
  else
    if ! ask_yesno "用户 ${u} 不存在，创建并加入 sudo 组？" y; then return 0; fi
    adduser --gecos "" "${u}" || { die_action "创建用户 ${u} 失败"; return 0; }
    usermod -aG sudo "${u}" || { die_action "把 ${u} 加入 sudo 组失败"; return 0; }
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

user_menu() {
  local pw sudo_st keys
  resolve_admin_user
  while :; do
    pw="$(pw_state "${ADMIN_USER}")"
    sudo_st="$(sudo_state "${ADMIN_USER}")"
    keys="$(ak_count)"
    scr_clear
    ui_rule
    printf '%s 用户、密码、sudo 与密钥 · %s%s\n' "${C_B}" "${C_G}" "${ADMIN_USER}"
    ui_sep
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
      2) act user_do_password ;;
      3) act user_do_sudo ;;
      4) act user_do_key_add ;;
      5) act user_do_key_del ;;
      6) act user_do_show_keys ;;
    esac
    page_wait "按回车返回用户菜单…"
  done
}

# ============ 模块 3：UFW 与 SSH ============
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

ufw_precheck() {   # ufw_precheck <当前端口> <目标端口>：铁律一，目标端口须已放行；迁移期旧端口也须保留
  local cur="$1" target="$2"
  command -v ufw >/dev/null 2>&1 || return 0
  fw_refresh
  if [[ "$(fw_state)" != "active" ]]; then
    die_action "ufw 未启用。请先用本菜单 1 配置并启用防火墙（铁律：UFW 先于 sshd）"
    return 1
  fi
  if ! fw_has_rule "${target}/tcp"; then
    die_action "ufw 已启用但未放行 ${target}/tcp。请先用本菜单 1 放行（铁律：UFW 先于 sshd）"
    return 1
  fi
  if [[ "${cur}" != "${target}" ]] && ! fw_has_rule "${cur}/tcp"; then
    die_action "迁移期间旧端口 ${cur}/tcp 必须保持放行（闸门二确认前不能断退路）。请先用本菜单 1 放行"
    return 1
  fi
  return 0
}

ssh_harden() {   # ssh_harden <目标端口>：写 drop-in + 双闸门；成功 0，拒绝 1
  local target="$1" cur actual listening ports migration=0
  [[ -f "${SSHD_CFG}" ]] || { die_action "未找到 ${SSHD_CFG}"; return 1; }
  grep -q '^Include' "${SSHD_CFG}" || \
    { die_action "需先在 sshd_config 启用 Include drop-in（本流程依赖 drop-in 覆盖）"; return 1; }
  if ! id "${ADMIN_USER}" >/dev/null 2>&1; then
    die_action "系统用户 ${ADMIN_USER} 不存在。AllowUsers 写它会让所有账号（含当前会话）下次登录被拒"
    return 1
  fi

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
    "${target}" "${ADMIN_USER}"
  if [[ -f "${HARD}" ]] && [[ "$(cat "${HARD}")" == "${desired}" ]] \
     && grep -qx 'passwordauthentication no' <<<"$(ssh_eff)" \
     && grep -qx 'permitrootlogin no' <<<"$(ssh_eff)" \
     && grep -qx "port ${target}" <<<"$(ssh_eff)" \
     && grep -qx "allowusers ${ADMIN_USER}" <<<"$(ssh_eff)" \
     && grep -qx 'maxauthtries 3' <<<"$(ssh_eff)"; then
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
  if ! ask_yesno "已在「用户」菜单后用新终端验证过 ${ADMIN_USER} 的密钥登录吗？" n; then
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

  printf '\n'
  log "保持【本会话】不断开！请操作："
  log "  1) 新开终端：ssh -p ${target} ${ADMIN_USER}@<host>  —— 必须密钥登录成功且 root 被拒"
  if (( migration == 1 )); then
    log "  2) 同步云平台安全组：关 ${cur}、开 ${target}（只能你手动做）"
  else
    log "  2) 确认云平台安全组已放行 ${target}（本机 ufw 已放行）"
  fi
  printf '\n'

  # 闸门二：新终端验证（铁律 3）
  if ! ask_yesno "新终端已用新端口成功登录？" n; then
    warn "未确认新端口可用。当前 ${cur}/tcp 放行规则保持不动以保旧会话可回退。"
    warn "恢复指引：若已锁死，用云控制台/VNC 登录后还原 ${BK_ROOT}/ 下备份，再 systemctl reload ssh"
    return 1
  fi
  if (( migration == 1 )); then
    fw_refresh
    if fw_has_rule "${cur}/tcp"; then
      # || true：删不存在的规则时 ufw 返回 1，不该因此把整个流程判失败
      ufw delete allow "${cur}/tcp" || warn "删除 ${cur}/tcp 规则失败，请手动执行：ufw delete allow ${cur}/tcp"
      log "已移除 ${cur}/tcp 临时放行规则（ufw）"
    fi
  fi
  printf '\n'
  log "SSH 加固完成。提醒：云安全组若仍放行 ${cur}，请手动关闭。"
  log "云厂商预置用户（如 ubuntu/admin）仍存在但已被 AllowUsers 屏蔽；确认不用可手动删除。"
  return 0
}

fw_prepare_for_ssh() {   # fw_prepare_for_ssh <当前端口> <目标端口>
  local cur="$1" target="$2" p ports fresh=0
  command -v ufw >/dev/null 2>&1 || { die_action "未找到 ufw，请先安装基础工具（菜单 1）"; return 1; }
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
    ports="$(ask_input "本次要额外放行的业务端口（逗号分隔，如 80,443；回车=不放行）" v_ports_list)"
    for p in ${ports//,/ }; do
      [[ -n "${p}" ]] || continue
      ufw allow "${p}/tcp" || { die_action "放行业务端口 ${p}/tcp 失败"; return 1; }
      log "已放行业务端口 ${p}/tcp"
    done
  else
    log "ufw 已启用：不询问业务端口，现有规则保持不变（可在菜单 3 中直接增删）"
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
    read -rp "端口（1-65535，逗号分隔可多个；回车=返回） " ports || die "输入中断"
    [[ -z "${ports}" ]] && return 0
    if v_ports_list "${ports}"; then break; fi
  done
  src=""
  if ask_yesno "限制来源 IP（如 1.2.3.4 或 10.0.0.0/8）？" n; then
    while :; do
      read -rp "来源地址（回车=返回） " src || die "输入中断"
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
    read -rp "删除第几条？[1-${count}]（回车=返回） " num || die "输入中断"
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
  target="$(ask_input_def "新 SSH 端口（1024-65535，避开 22/2222）" v_ssh_port "$(rand_port)")"
  if [[ "${target}" == "${cur}" ]]; then
    log "与当前生效端口相同，无需迁移"
    return 0
  fi
  command -v ufw >/dev/null 2>&1 || { warn "未安装 ufw，先安装基础工具（菜单 1）"; return 0; }
  fw_refresh
  if [[ "$(fw_state)" != "active" ]]; then
    warn "ufw 未启用：先在本菜单 1 配置并启用防火墙（铁律：UFW 先于 sshd）"
    return 0
  fi
  if ! fw_has_rule "${target}/tcp"; then
    if ! ask_yesno "ufw 未放行 ${target}/tcp，先放行再加固？" y; then return 0; fi
    ufw allow "${target}/tcp" || { die_action "放行 ${target}/tcp 失败"; return 0; }
    fw_refresh
    log "已放行 ${target}/tcp"
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
    read -rp "恢复第几份？[1-${#backs[@]}]（回车=返回） " pick || die "输入中断"
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
    fw_refresh
    if command -v ufw >/dev/null 2>&1 && ! fw_has_rule "${newport}/tcp"; then
      warn "ufw 未放行 ${newport}/tcp，现在重启 sshd 会锁死"
      if ask_yesno "先放行 ${newport}/tcp 再继续？" y; then
        ufw allow "${newport}/tcp" || { die_action "放行 ${newport}/tcp 失败，未重启 sshd"; return 0; }
        fw_refresh
        log "已放行 ${newport}/tcp"
      else
        warn "已中止，未重启 sshd；该文件将在下次 sshd 重启时生效（届时务必先放行端口）"
        return 0
      fi
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
  resolve_admin_user
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
    if [[ -n "${hard_users}" && "${hard_users}" != "${ADMIN_USER}" ]]; then
      e_users="${e_users} ${C_Y}（本进程管理员为 ${ADMIN_USER}，应用加固后改为它）${C_0}"
    fi
    scr_clear
    ui_rule
    printf '%s UFW 与 SSH · %s%s\n' "${C_B}" "${C_G}" "${ADMIN_USER}"
    ui_sep
    case "$(fw_state)" in
      active) ui_kv "防火墙" "$(ui_yes 'active ✓')" ;;
      未安装) ui_kv "防火墙" "$(ui_no '未安装 ufw ⚠')" ;;
      *)      ui_kv "防火墙" "$(ui_no "$(fw_state) ⚠")" ;;
    esac
    ui_kv "默认策略" "入站 $(fw_default_in) / 出站 $(fw_default_out)"
    ui_kv "规则数" "$(fw_rule_count)"
    if [[ -n "${sshp}" ]]; then
      if [[ "$(fw_state)" == "active" ]] && fw_has_rule "${sshp}/tcp"; then
        ui_kv "SSH 端口" "${sshp}（ufw 已放行 ✓）"
      else
        ui_kv "SSH 端口" "${sshp}（ufw 未放行 ⚠）"
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

# ============ 模块 4：fail2ban ============
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
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban; then
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
  bantime="$(ask_input_def "封禁时长（秒）" v_posint "$(f2b_param bantime 86400)")"
  findtime="$(ask_input_def "统计窗口（秒）" v_posint "$(f2b_param findtime 600)")"
  maxretry="$(ask_input_def "最大重试次数" v_posint "$(f2b_param maxretry 3)")"
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
  cur_b="$(f2b_param bantime 86400)"
  cur_f="$(f2b_param findtime 600)"
  cur_m="$(f2b_param maxretry 3)"
  log "当前参数（来自 ${JAIL}，缺失取默认）：bantime=${cur_b} / findtime=${cur_f} / maxretry=${cur_m}"
  v="$(ask_input_def "封禁时长（秒）" v_posint "${cur_b}")"
  local nb="$v"
  v="$(ask_input_def "统计窗口（秒）" v_posint "${cur_f}")"
  local nf="$v"
  v="$(ask_input_def "最大重试次数" v_posint "${cur_m}")"
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

# ============ 模块 5：Swap（子 shell 内运行，选项与 trap 不外泄） ============
# 由来：本段原为独立发布版脚本，保留其自有 helper 与 set -uo pipefail（不启用 -e）；
# 私有函数/变量统一 swap_ 前缀，由无参数 run_swap_menu 在子 shell 中调用。
SWAP_FSTAB="/etc/fstab"
SWAP_SYSCTL_CONF="/etc/sysctl.d/99-swappiness.conf"
SWAP_SWAPPINESS_RE='^([0-9]|[1-9][0-9]|100)$'
SWAP_MIN_MB=64
SWAP_WARN_FREE_MB=2048
SWAP_ANSWER=""
SWAP_PARTIAL_FILE=""
SWAP_FSTAB_BAK=""
SWAP_FSTAB_BAK_COUNT=0
SWAP_FSTAB_BASELINE=0

swap_info() { printf '%s\n' "$*"; }
swap_ok()   { printf '%s%s%s\n' "${C_G}" "$*" "${C_0}"; }
swap_warn() { printf '%s%s[警告]%s %s\n' "${C_Y}" "${C_B}" "${C_0}" "$*" >&2; }
swap_err()  { printf '%s%s[错误]%s %s\n' "${C_R}" "${C_B}" "${C_0}" "$*" >&2; }
swap_die()  { swap_err "$*"; exit 1; }

swap_cleanup() {
  local rc=$?
  if [[ -n "${SWAP_PARTIAL_FILE}" ]]; then
    swapoff "${SWAP_PARTIAL_FILE}" 2>/dev/null || true
    rm -f -- "${SWAP_PARTIAL_FILE}"
    swap_err "操作未完成，已清理残留文件: ${SWAP_PARTIAL_FILE}"
    if [[ -n "${SWAP_FSTAB_BAK}" && -f "${SWAP_FSTAB_BAK}" ]]; then
      swap_err "如 fstab 异常，可用备份恢复: cp -a ${SWAP_FSTAB_BAK} ${SWAP_FSTAB}"
    fi
  fi
  exit "${rc}"
}

# 约定: swap_ask_option / swap_ask_value 把结果写入 SWAP_ANSWER；swap_confirm 只用返回码。
swap_ask_option() {   # "提示" "选项1" "选项2" ... -> SWAP_ANSWER = 选中项；空回车 = 空串（取消）
  local prompt="$1"; shift
  local opts=("$@") i input max
  max=${#opts[@]}
  while true; do
    printf '\n%s%s%s\n' "${C_B}" "${prompt}" "${C_0}"
    for i in "${!opts[@]}"; do
      printf '  %d) %s\n' "$((i + 1))" "${opts[$i]}"
    done
    printf '请输入编号 [1-%d]（回车=取消）: ' "${max}"
    read -r input || swap_die "输入中断，退出"
    input="${input//[[:space:]]/}"
    if [[ -z "${input}" ]]; then
      SWAP_ANSWER=""
      return 0
    fi
    if [[ "${input}" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= max )); then
      SWAP_ANSWER="${opts[input - 1]}"
      return 0
    fi
    swap_warn "无效输入: ${input}（请输入 1-${max} 的编号）"
  done
}

swap_ask_value() {   # "提示" "校验正则" "默认值(可空)"
  local prompt="$1" regex="$2" default="${3-}" input
  while true; do
    if [[ -n "${default}" ]]; then
      printf '%s [默认: %s]: ' "${prompt}" "${default}"
    else
      printf '%s: ' "${prompt}"
    fi
    read -r input || swap_die "输入中断，退出"
    input="${input:-${default}}"
    if [[ "${input}" =~ ${regex} ]]; then
      SWAP_ANSWER="${input}"
      return 0
    fi
    swap_warn "输入无效，请重新输入"
  done
}

swap_confirm() {   # "问题" [y|n 默认值]
  local prompt="$1" default="${2:-y}" ans
  while true; do
    if [[ "${default}" == "y" ]]; then
      printf '%s [Y/n]: ' "${prompt}"
    else
      printf '%s [y/N]: ' "${prompt}"
    fi
    read -r ans || swap_die "输入中断，退出"
    ans="${ans:-${default}}"
    case "${ans}" in
      [Yy]*) return 0 ;;
      [Nn]*) return 1 ;;
      *) swap_warn "请输入 y 或 n" ;;
    esac
  done
}

swap_get_mem_mb()     { free -m | awk '/^Mem:/{print $2}'; }
swap_get_mem_h()      { free -h | awk '/^Mem:/{print $2}'; }
swap_get_swappiness() { sysctl -n vm.swappiness 2>/dev/null || echo '?'; }

swap_get_swappiness_default() {
  local v
  v=$(swap_get_swappiness)
  [[ "${v}" =~ ^[0-9]+$ ]] && echo "${v}" || echo 10
}

swap_active_files() { awk 'NR>1 && $2=="file"{print $1}' /proc/swaps; }
swap_is_active() { awk -v p="$1" 'NR>1 && $2=="file" && $1==p{f=1} END{exit (f?0:1)}' /proc/swaps; }
swap_show_free_h() { free -h | sed -n '1,3p' | sed 's/^/  /'; }
swap_get_fstype_of() { findmnt -n -o FSTYPE "$1" 2>/dev/null; }
swap_get_avail_mb() { df -BM --output=avail "$1" | awk 'NR==2{gsub(/M$/,"");print}'; }
swap_fstab_entries() { awk '$3=="swap"{print $1}' "${SWAP_FSTAB}" 2>/dev/null; }
swap_fstab_has() { awk -v p="$1" '$1==p{f=1} END{exit (f?0:1)}' "${SWAP_FSTAB}" 2>/dev/null; }

swap_fstab_backup() {
  SWAP_FSTAB_BAK_COUNT=$((SWAP_FSTAB_BAK_COUNT + 1))
  local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
  mkdir -p -- "${BK_ROOT}/${stamp}" || swap_die "创建备份目录 ${BK_ROOT}/${stamp} 失败"
  if (( SWAP_FSTAB_BAK_COUNT > 1 )); then
    SWAP_FSTAB_BAK="${BK_ROOT}/${stamp}/fstab.${SWAP_FSTAB_BAK_COUNT}"
  else
    SWAP_FSTAB_BAK="${BK_ROOT}/${stamp}/fstab"
  fi
  # 同秒且同目录已有 fstab（上一次运行留下的）时顺延序号，绝不覆盖旧备份
  while [[ -e "${SWAP_FSTAB_BAK}" ]]; do
    SWAP_FSTAB_BAK_COUNT=$((SWAP_FSTAB_BAK_COUNT + 1))
    SWAP_FSTAB_BAK="${BK_ROOT}/${stamp}/fstab.${SWAP_FSTAB_BAK_COUNT}"
  done
  cp -a -- "${SWAP_FSTAB}" "${SWAP_FSTAB_BAK}" || swap_die "备份 ${SWAP_FSTAB} 失败"
  # 只保留最近 BK_KEEP 份时间戳目录（与主程序同一策略，本段不进公共块故本地内联）
  local -a dirs=(); local i
  mapfile -t dirs < <(find "${BK_ROOT}" -mindepth 1 -maxdepth 1 -type d \
    -regextype posix-extended -regex '.*/[0-9]{8}-[0-9]{6}' 2>/dev/null | sort)
  if (( ${#dirs[@]} > BK_KEEP )); then
    for (( i = 0; i < ${#dirs[@]} - BK_KEEP; i++ )); do rm -rf -- "${dirs[$i]}"; done
  fi
  swap_info "已备份 fstab -> ${SWAP_FSTAB_BAK}"
}

swap_fstab_prepare() {
  swap_fstab_backup
  findmnt --verify >/dev/null 2>&1
  SWAP_FSTAB_BASELINE=$?
}

swap_fstab_verify_or_restore() {
  local rc
  findmnt --verify >/dev/null 2>&1
  rc=$?
  if (( rc != 0 )); then
    if (( SWAP_FSTAB_BASELINE == 0 )); then
      swap_err "fstab 校验失败，正在从备份恢复..."
      cat "${SWAP_FSTAB_BAK}" > "${SWAP_FSTAB}" || swap_die "恢复 ${SWAP_FSTAB} 失败，请手动执行: cp -a ${SWAP_FSTAB_BAK} ${SWAP_FSTAB}"
      swap_die "fstab 已恢复原状，操作中止"
    else
      swap_warn "fstab 校验发现问题，但修改前基线同样异常（非本次修改引起），请手动检查: ${SWAP_FSTAB}"
    fi
  fi
}

swap_fstab_append() {
  swap_fstab_prepare
  printf '%s none swap sw 0 0\n' "$1" >> "${SWAP_FSTAB}" || swap_die "写入 ${SWAP_FSTAB} 失败"
  swap_fstab_verify_or_restore
}

swap_fstab_remove() {
  local tmp
  swap_fstab_prepare
  tmp=$(mktemp) || swap_die "创建临时文件失败"
  awk -v p="$1" '$1 != p' "${SWAP_FSTAB}" > "${tmp}" || { rm -f "${tmp}"; swap_die "处理 ${SWAP_FSTAB} 失败"; }
  cat "${tmp}" > "${SWAP_FSTAB}" || { rm -f "${tmp}"; swap_die "写回 ${SWAP_FSTAB} 失败，请手动检查备份: ${SWAP_FSTAB_BAK}"; }
  rm -f "${tmp}"
  swap_fstab_verify_or_restore
}

swap_size_to_mb() {
  local s="$1" n u
  if [[ "${s}" =~ ^([0-9]+)([GgMm]?)$ ]]; then
    n=$((10#${BASH_REMATCH[1]}))
    u="${BASH_REMATCH[2],,}"
    if [[ "${u}" == "g" ]]; then
      echo $((n * 1024))
    else
      echo "${n}"
    fi
    return 0
  fi
  return 1
}

swap_recommend_mb() {
  local mem
  mem=$(swap_get_mem_mb)
  [[ "${mem}" =~ ^[0-9]+$ ]] || mem=2048
  if (( mem <= 2048 )); then echo 2048; else echo 4096; fi
}

swap_write_swappiness() {
  local val="$1"
  mkdir -p /etc/sysctl.d
  if [[ -f "${SWAP_SYSCTL_CONF}" ]] && grep -q '^vm\.swappiness' "${SWAP_SYSCTL_CONF}" 2>/dev/null; then
    sed -i "s/^vm\.swappiness.*/vm.swappiness = ${val}/" "${SWAP_SYSCTL_CONF}"
  else
    printf 'vm.swappiness = %s\n' "${val}" >> "${SWAP_SYSCTL_CONF}"
  fi
  sysctl -p "${SWAP_SYSCTL_CONF}" >/dev/null || swap_die "应用 swappiness 失败"
  swap_ok "swappiness 已设置为 ${val}（写入 ${SWAP_SYSCTL_CONF}）"
}

swap_delete_file() {
  local path="$1"
  if swap_is_active "${path}"; then
    swap_info "正在停用 ${path}（若 swap 正被使用可能需要一些时间）..."
    if ! swapoff "${path}" 2>/dev/null; then
      swap_err "swapoff 失败: ${path}"
      return 1
    fi
  fi
  rm -f -- "${path}" || { swap_err "删除文件失败: ${path}"; return 1; }
  if swap_fstab_has "${path}"; then
    swap_fstab_remove "${path}"
  fi
  swap_ok "已删除 ${path}"
}

swap_status_line() {
  local mem swap
  mem=$(swap_get_mem_h)
  swap=$(free -h | awk '/^Swap:/{print $2}')
  if [[ -z "${swap}" || "${swap}" == "0B" || "${swap}" == "0" ]]; then
    swap="未启用"
  fi
  printf '内存: %s | Swap: %s | swappiness: %s' "${mem}" "${swap}" "$(swap_get_swappiness)"
}

swap_do_status() {
  local -a files entries
  printf '\n%s========== Swap 状态 ==========%s\n' "${C_B}" "${C_0}"
  swap_info "内存使用:"
  swap_show_free_h
  echo
  mapfile -t files < <(swap_active_files)
  if ((${#files[@]} > 0)); then
    swap_info "已启用的 swap:"
    # 注意: 不带 --output，默认列即 NAME TYPE SIZE USED PRIO
    swapon --show | sed 's/^/  /'
  else
    swap_info "已启用的 swap: 无"
  fi
  echo
  if [[ -f "${SWAP_SYSCTL_CONF}" ]]; then
    swap_info "swappiness 当前值: $(swap_get_swappiness)（配置文件: ${SWAP_SYSCTL_CONF}）"
  else
    swap_info "swappiness 当前值: $(swap_get_swappiness)（无独立配置文件，使用系统默认）"
  fi
  echo
  mapfile -t entries < <(swap_fstab_entries)
  if ((${#entries[@]} > 0)); then
    swap_info "fstab 中的 swap 条目:"
    printf '  %s\n' "${entries[@]}"
  else
    swap_info "fstab 中的 swap 条目: 无"
  fi
  echo
  swap_info "根分区空间:"
  df -h / | sed -n '2p' | sed 's/^/  /'
}

swap_do_create() {
  local -a active size_opts
  local f mb mark rec_mb mem_h size_label size_mb path dir fstype avail_mb
  local cur_sw new_sw=""

  mapfile -t active < <(swap_active_files)
  if ((${#active[@]} > 0)); then
    swap_warn "检测到已启用的 swap 文件:"
    printf '  %s\n' "${active[@]}"
    if swap_confirm "替换 = 先删除以上 swap 文件，再创建新的。是否继续替换?" "y"; then
      for f in "${active[@]}"; do
        swap_delete_file "${f}" || swap_die "替换失败: 无法删除旧 swap 文件 ${f}"
      done
    else
      swap_info "已取消。"
      return 0
    fi
  fi

  rec_mb=$(swap_recommend_mb)
  mem_h=$(swap_get_mem_h)
  for mb in 1024 2048 4096 8192; do
    mark=""
    (( mb == rec_mb )) && mark="（推荐）"
    size_opts+=("$((mb / 1024))G${mark}")
  done
  size_opts+=("自定义大小")

  swap_ask_option "请选择 Swap 大小（物理内存: ${mem_h}）" "${size_opts[@]}"
  size_label=$SWAP_ANSWER
  [[ -z "${size_label}" ]] && { swap_info "已取消。"; return 0; }
  case "${size_label}" in
    "1G"*) size_mb=1024 ;;
    "2G"*) size_mb=2048 ;;
    "4G"*) size_mb=4096 ;;
    "8G"*) size_mb=8192 ;;
    *)
      while true; do
        swap_ask_value "自定义大小（如 2G、512M，纯数字按 MB 计算）" '^[0-9]+[GgMm]?$' "1024"
        size_mb=$(swap_size_to_mb "$SWAP_ANSWER") || { swap_warn "无法解析大小"; continue; }
        if (( size_mb < SWAP_MIN_MB )); then
          swap_warn "Swap 至少需要 ${SWAP_MIN_MB}MB"
          continue
        fi
        break
      done
      ;;
  esac

  while true; do
    swap_ask_value "Swap 文件路径" '^/[A-Za-z0-9._/-]+$' '/swapfile'
    path=$SWAP_ANSWER
    if [[ "${path}" == *".."* || "${path}" == */ ]]; then
      swap_warn "路径不合法（不能包含 .. 或以 / 结尾）"
      continue
    fi
    dir=$(dirname -- "${path}")
    if [[ ! -d "${dir}" ]]; then
      swap_warn "目录不存在: ${dir}"
      continue
    fi
    if [[ -e "${path}" ]]; then
      swap_warn "文件已存在: ${path}（请换一个路径，或先用「删除」功能清理）"
      continue
    fi
    break
  done

  fstype=$(swap_get_fstype_of "${dir}")
  case "${fstype}" in
    btrfs|zfs)
      swap_die "文件系统 ${fstype} 不支持常规方式的 swap 文件（${dir} 所在分区），本程序不处理。"
      ;;
    "")
      swap_warn "无法识别 ${dir} 的文件系统类型，将继续尝试。"
      ;;
  esac

  avail_mb=$(swap_get_avail_mb "${dir}")
  [[ "${avail_mb}" =~ ^[0-9]+$ ]] || swap_die "无法获取磁盘剩余空间"
  if (( size_mb > avail_mb )); then
    swap_err "空间不足: 需要 ${size_mb}M，该分区仅剩 ${avail_mb}M"
    return 1
  fi
  if (( avail_mb - size_mb < SWAP_WARN_FREE_MB )); then
    swap_warn "创建后该分区剩余空间仅 $((avail_mb - size_mb))M（不足 ${SWAP_WARN_FREE_MB}M），系统运行可能紧张"
    swap_confirm "仍要继续?" "n" || { swap_info "已取消。"; return 0; }
  fi

  cur_sw=$(swap_get_swappiness_default)
  if swap_confirm "是否同时调整 swappiness（当前: ${cur_sw}）?" "y"; then
    swap_ask_value "swappiness 值（0-100，VPS 常用 10）" "${SWAP_SWAPPINESS_RE}" "10"
    new_sw=$SWAP_ANSWER
  fi

  printf '\n%s== 即将执行 ==%s\n' "${C_B}" "${C_0}"
  printf '  Swap 文件:   %s (%sM)\n' "${path}" "${size_mb}"
  printf '  文件系统:    %s\n' "${fstype:-未知}"
  printf '  开机持久化:  写入 %s\n' "${SWAP_FSTAB}"
  if [[ -n "${new_sw}" ]]; then
    printf '  swappiness:  %s -> %s\n' "${cur_sw}" "${new_sw}"
  fi
  printf '%s=============%s\n' "${C_B}" "${C_0}"
  swap_confirm "确认执行?" "y" || { swap_info "已取消。"; return 0; }

  SWAP_PARTIAL_FILE="${path}"

  swap_info "1/5 创建文件（${size_mb}M）..."
  if ! fallocate -l "${size_mb}M" "${path}" 2>/dev/null; then
    swap_warn "fallocate 不可用（${fstype:-该文件系统}可能不支持），改用 dd 逐块写入，无进度显示，请耐心等待..."
    dd if=/dev/zero of="${path}" bs=1M count="${size_mb}" status=none 2>/dev/null \
      || swap_die "创建文件失败"
  fi

  swap_info "2/5 设置权限（600）..."
  chmod 600 "${path}" || swap_die "chmod 失败"

  swap_info "3/5 格式化为 swap..."
  mkswap "${path}" >/dev/null || swap_die "mkswap 失败"

  swap_info "4/5 启用 swap..."
  if ! swapon "${path}" 2>/dev/null; then
    local virt
    virt=$(systemd-detect-virt 2>/dev/null || true)
    case "${virt}" in
      openvz|lxc)
        swap_err "swapon 失败: 当前运行在 ${virt} 容器中，内核不允许自行启用 swap。"
        swap_err "此类 VPS 无法使用本流程创建 swap（如需 swap 请联系服务商）。"
        ;;
      *)
        swap_err "swapon 失败（未知原因），可运行 dmesg | tail 查看内核日志。"
        ;;
    esac
    swap_die "已清理，未对系统留下改动"
  fi
  swap_ok "  swap 已启用"

  swap_info "5/5 写入 fstab 实现开机持久化..."
  if swap_fstab_has "${path}"; then
    swap_warn "${SWAP_FSTAB} 已存在 ${path} 的条目，跳过写入"
  else
    swap_fstab_append "${path}"
  fi

  SWAP_PARTIAL_FILE=""

  if [[ -n "${new_sw}" ]]; then
    swap_write_swappiness "${new_sw}"
  fi

  printf '\n'
  swap_ok "完成！当前内存状态:"
  swap_show_free_h
  printf '\n'
  return 0
}

swap_do_swappiness() {
  local cur val
  printf '\n%s========== 调整 swappiness ==========%s\n' "${C_B}" "${C_0}"
  cur=$(swap_get_swappiness)
  swap_info "当前值: ${cur}（0 = 尽量不用 swap，100 = 积极使用；VPS 一般推荐 10）"
  if [[ -f "${SWAP_SYSCTL_CONF}" ]]; then
    swap_info "配置文件: ${SWAP_SYSCTL_CONF}"
  else
    swap_info "尚无独立配置文件，将创建: ${SWAP_SYSCTL_CONF}"
  fi
  swap_ask_value "新的 swappiness 值（0-100）" "${SWAP_SWAPPINESS_RE}" "$(swap_get_swappiness_default)"
  val=$SWAP_ANSWER
  if [[ "${val}" == "$(swap_get_swappiness)" ]]; then
    swap_info "与当前值相同，未修改。"
    return 0
  fi
  swap_write_swappiness "${val}"
  swap_info "验证: 当前生效值 = $(swap_get_swappiness)"
  return 0
}

swap_do_delete() {
  local -a files
  local f prompt
  printf '\n%s========== 关闭并删除 Swap ==========%s\n' "${C_B}" "${C_0}"

  # 候选 = 已启用的 swap 文件 + fstab 有条目、文件存在但未启用的残留
  mapfile -t files < <(swap_active_files)
  while read -r f; do
    [[ -n "${f}" ]] || continue
    [[ -f "${f}" ]] || continue
    swap_is_active "${f}" || files+=("${f}")
  done < <(swap_fstab_entries)
  if ((${#files[@]} == 0)); then
    swap_info "没有可删除的 swap 文件（无已启用的，也无 fstab 残留条目）。"
    return 0
  fi

  if awk 'NR>1 && $2=="partition"' /proc/swaps | grep -q .; then
    swap_info "注: 检测到 swap 分区，本程序只处理 swap 文件，不会触碰分区。"
  fi

  for f in "${files[@]}"; do
    printf '\n'
    if swap_is_active "${f}"; then
      prompt="确认删除 ${f} ?（停用 + 删除文件 + 移除 fstab 条目）"
    else
      prompt="确认清理 ${f} ?（当前未启用，仅删除文件 + 移除 fstab 条目）"
    fi
    if swap_confirm "${prompt}" "n"; then
      swap_delete_file "${f}" || swap_err "删除 ${f} 失败，已跳过"
    fi
  done

  mapfile -t files < <(swap_active_files)
  if ((${#files[@]} == 0)) && [[ -f "${SWAP_SYSCTL_CONF}" ]] \
     && swap_confirm "是否同时移除 swappiness 配置（${SWAP_SYSCTL_CONF}）?" "n"; then
    rm -f -- "${SWAP_SYSCTL_CONF}"
    sysctl -w vm.swappiness=60 >/dev/null
    swap_ok "已移除 ${SWAP_SYSCTL_CONF}；运行时 swappiness 已设为 60（Debian/Ubuntu 默认值），重启后同样生效"
  fi
  return 0
}

swap_menu() {
  trap 'swap_cleanup' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  while true; do
    scr_clear
    ui_rule
    printf '%s Swap 管理%s\n' "${C_B}" "${C_0}"
    ui_sep
    printf '  %s\n' "$(swap_status_line)"
    ui_sep
    ui_item 1 "查看 Swap 状态"
    ui_item 2 "创建 / 替换 Swap"
    ui_item 3 "调整 swappiness"
    ui_item 4 "关闭并删除 Swap"
    ui_quit
    ui_sep
    # 选项列表已在上面画过，这里只读编号（不重复列一遍）
    swap_pick=""
    while :; do
      printf '请选择操作 [0-4]（回车=返回主菜单）: '
      read -r swap_pick || swap_die "输入中断，退出"
      swap_pick="${swap_pick//[[:space:]]/}"
      [[ -z "${swap_pick}" ]] && swap_pick=0
      if [[ "${swap_pick}" =~ ^[0-9]+$ ]] && (( swap_pick <= 4 )); then break; fi
      swap_warn "无效输入: ${swap_pick}（请输入 0-4 的编号）"
    done
    case "${swap_pick}" in
      0) return 0 ;;
      1) swap_do_status ;;
      2) swap_do_create || true ;;
      3) swap_do_swappiness || true ;;
      4) swap_do_delete || true ;;
    esac
    scr_pause "按回车返回 Swap 菜单…"
  done
}

run_swap_menu() {
  # 子 shell 内关闭 -e 与 ERR trap，安装原有 EXIT/INT/TERM 清理语义；选项与 trap 不外泄
  (
    set +e
    set -uo pipefail
    trap - ERR
    swap_menu
  )
}

# ============ 模块 6：BBR ============
# 目标配置：BBR + fq + TCP 调优（外部获取的调参集，逐行可审；参数为作者本机特调）
read -r -d '' BBR_CONTENT <<'EOF' || true
kernel.pid_max = 65535
kernel.panic = 1
kernel.sysrq = 1
kernel.core_pattern = core_%e
kernel.printk = 3 4 1 3
kernel.numa_balancing = 0
kernel.sched_autogroup_enabled = 0

vm.swappiness = 10
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
vm.panic_on_oom = 1
vm.overcommit_memory = 1
vm.min_free_kbytes = 64194

net.core.default_qdisc = fq
net.core.netdev_max_backlog = 2000
net.core.rmem_max = 8388608
net.core.wmem_max = 8388608
net.core.rmem_default = 87380
net.core.wmem_default = 65536
net.core.somaxconn = 256
net.core.optmem_max = 32768

net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_max_tw_buckets = 32768
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fack = 0

net.ipv4.tcp_rmem = 8192 87380 748300
net.ipv4.tcp_wmem = 8192 65536 374150
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_notsent_lowat = 4096
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 3
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_no_metrics_save = 0

net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_max_orphans = 65536
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_abort_on_overflow = 0
net.ipv4.tcp_stdurg = 0
net.ipv4.tcp_rfc1337 = 0
net.ipv4.tcp_syncookies = 1

net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.ip_no_pmtu_disc = 0
net.ipv4.route.gc_timeout = 100
net.ipv4.neigh.default.gc_stale_time = 120
net.ipv4.neigh.default.gc_thresh3 = 8192
net.ipv4.neigh.default.gc_thresh2 = 4096
net.ipv4.neigh.default.gc_thresh1 = 1024

net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.arp_announce = 2
net.ipv4.conf.default.arp_announce = 2
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.default.arp_ignore = 1
EOF

bbr_apply() {
  local cc qc
  # 幂等：内容一致则跳过写入
  if [[ -f "${BBR_CONF}" ]] && diff -q <(printf '%s\n' "${BBR_CONTENT}") "${BBR_CONF}" >/dev/null 2>&1; then
    log "配置已存在且一致：${BBR_CONF}，跳过写入"
  else
    backup_file "${BBR_CONF}" >/dev/null || true
    if ! printf '%s\n' "${BBR_CONTENT}" > "${BBR_CONF}"; then
      die_action "写入 ${BBR_CONF} 失败"
      return 1
    fi
    log "已写入 ${BBR_CONF}"
  fi
  # 应用；个别键在当前内核不存在时（如 tcp_fack 已移除）仅警告
  if ! sysctl -p "${BBR_CONF}"; then
    warn "部分键应用失败（新版内核可能已移除个别键，如 tcp_fack），请核对上方报错行"
  fi
  cc="$(bbr_cc)"
  qc="$(bbr_qdisc)"
  if [[ "${cc}" != "bbr" ]]; then
    warn "tcp_congestion_control = ${cc:-未知}，非 bbr；请检查内核版本（需 >= 4.9）"
    return 1
  fi
  if [[ "${qc}" != "fq" ]]; then
    warn "default_qdisc = ${qc:-未知}，非 fq（BBR 仍工作，但推荐 fq）"
  fi
  log "BBR 已启用（congestion_control=${cc}, qdisc=${qc}）"
  return 0
}

bbr_do_show() {
  printf '%s── 当前 sysctl 值 ──%s\n' "${C_D}" "${C_0}"
  sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc 2>/dev/null || warn "sysctl 查询失败"
  printf '\n%s── %s ──%s\n' "${C_D}" "${BBR_CONF}" "${C_0}"
  if [[ -f "${BBR_CONF}" ]]; then
    cat "${BBR_CONF}"
  else
    warn "未找到 ${BBR_CONF}（尚未应用调优配置）"
  fi
  return 0
}

bbr_menu() {
  local cc qc cfg_state
  while :; do
    cc="$(bbr_cc)"
    qc="$(bbr_qdisc)"
    if [[ -f "${BBR_CONF}" ]]; then cfg_state="已写入"; else cfg_state="$(ui_no '未写入')"; fi
    scr_clear
    ui_rule
    printf '%s BBR 与 TCP 调优%s\n' "${C_B}" "${C_0}"
    ui_sep
    ui_kv "拥塞控制" "$( [[ "${cc}" == "bbr" ]] && printf '%s' "$(ui_yes 'bbr ✓')" || printf '%s' "$(ui_no "${cc}")" )"
    ui_kv "队列规则" "${qc}"
    ui_kv "配置文件" "${cfg_state}"
    ui_sep
    printf '  %s注意：本程序的调优参数是作者本机特调，不一定适合你的线路与内存。%s\n' "${C_Y}" "${C_0}"
    ui_sep
    ui_item 1 "应用 BBR + TCP 调优（写 ${BBR_CONF}）"
    ui_item 2 "查看当前 sysctl 值与配置文件"
    ui_quit
    ui_sep
    ask_menu "选择操作" 2
    case "${UI_REPLY}" in
      0) return 0 ;;
      1)
        if ask_yesno "确认应用作者特调的 BBR/TCP 参数？" n; then
          act bbr_apply || true
        else
          log "已取消，未改动 sysctl 配置"
        fi
        ;;
      2) bbr_do_show ;;
    esac
    page_wait "按回车返回 BBR 菜单…"
  done
}

# ============ 模块 7：终检与报告 ============
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

  log "VPS 初始化终检"
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
    printf '# VPS 初始化终检报告\n\n'
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

# ============ 标准初始化（主菜单 0） ============
step_banner() { printf '\n%s== 步骤 %s · %s ==%s\n' "${C_B}" "$1" "$2" "${C_0}"; }

flow_abort() {   # 中止剩余步骤（不跳过闸门、不做后续写入）
  warn "标准初始化已中止：$*"
  warn "已完成的步骤保留在系统里；重新进入主菜单 0 会按当前系统状态续接。"
  return 1
}

do_standard_init() {
  local cur target tz
  scr_clear
  ui_rule
  printf '%s 标准初始化%s\n' "${C_B}" "${C_0}"
  ui_sep
  printf '  按步骤引导：系统更新 → 时区/NTP → 用户/密钥 → UFW/SSH → fail2ban → Swap → BBR → 终检\n'
  printf '  %s每一步只修改未达标项；任何安全检查失败都会中止剩余步骤。%s\n' "${C_D}" "${C_0}"
  ui_sep

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

  # ---- 步骤 2：系统更新与基础工具 ----
  step_banner 2 "系统更新与基础工具"
  apt_update_index || { flow_abort "apt 索引刷新失败，未继续后续步骤"; return 1; }
  apt_full_upgrade || { flow_abort "系统升级失败，未继续后续步骤"; return 1; }
  install_missing_base || { flow_abort "必要包安装失败，未继续后续步骤"; return 1; }
  base_do_extra || { flow_abort "可选工具安装失败，未继续后续步骤"; return 1; }
  ua_enable || { flow_abort "自动安全更新启用失败，未继续后续步骤"; return 1; }
  maybe_reboot

  # ---- 步骤 3：时区与 NTP（手动步骤，只检查不代改） ----
  step_banner 3 "时区与 NTP"
  tz="$(cur_tz)"
  printf '  当前时区： %s\n' "${tz}"
  if ntp_active; then printf '  NTP： %s\n' "$(ui_yes 'active ✓')"; else printf '  NTP： %s\n' "$(ui_no '未激活 ⚠')"; fi
  if [[ "${tz}" != "Asia/Shanghai" ]] || ! ntp_active; then
    warn "时区或 NTP 未达标。本程序不改这两项系统设置，请手动执行："
    printf '    timedatectl set-timezone Asia/Shanghai\n'
    printf '    timedatectl                      # 确认 NTP service: active\n'
    scr_pause "完成后按回车重新检测（Ctrl-C 中止）…"
    tz="$(cur_tz)"
    if [[ "${tz}" != "Asia/Shanghai" ]] || ! ntp_active; then
      flow_abort "时区仍为 ${tz} 或 NTP 仍未 active，未继续后续步骤"
      return 1
    fi
    log "时区与 NTP 已达标"
  else
    log "时区与 NTP 已满足"
  fi

  # ---- 步骤 4：管理员账号、密码、sudo、公钥 ----
  step_banner 4 "管理员账号与密钥"
  resolve_admin_user
  if id "${ADMIN_USER}" >/dev/null 2>&1; then
    log "用户 ${ADMIN_USER} 已存在"
    usermod -aG sudo "${ADMIN_USER}"
  else
    log "创建用户 ${ADMIN_USER}"
    adduser --gecos "" "${ADMIN_USER}"
    usermod -aG sudo "${ADMIN_USER}"
    log "已加入 sudo 组"
  fi
  if [[ "$(pw_state "${ADMIN_USER}")" == "P" ]]; then
    log "登录密码已设置（已满足）"
  else
    warn "用户 ${ADMIN_USER} 尚无可用密码"
    if ask_yesno "现在设置登录密码？" y; then
      user_do_password
    fi
  fi
  log "sudo 免密当前有效状态：$(sudo_state "${ADMIN_USER}")"
  if ask_yesno "开启 sudo 免密（NOPASSWD）？" n; then
    user_do_sudo
  fi
  if [[ "$(ak_count)" -eq 0 ]]; then
    warn "authorized_keys 中没有公钥——禁用密码后你将无法登录"
    if ! ask_yesno "现在追加公钥？" y; then
      flow_abort "没有公钥，继续会锁死登录"
      return 1
    fi
    user_do_key_add
    if [[ "$(ak_count)" -eq 0 ]]; then
      flow_abort "仍未写入公钥，继续会锁死登录"
      return 1
    fi
  else
    log "authorized_keys 已有 $(ak_count) 把公钥（已满足）"
  fi
  printf '\n'
  printf '  %s闸门：%s请新开一个终端执行 ssh %s@<host>，确认密钥登录成功且 sudo -v 通过。\n' \
    "${C_Y}" "${C_0}" "${ADMIN_USER}"
  if ! ask_yesno "已在新终端用密钥登录该账号并通过 sudo -v？" n; then
    flow_abort "未确认密钥登录可用，未继续 UFW/SSH 加固"
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
    target="$(ask_input_def "目标 SSH 端口（1024-65535，避开 22/2222）" v_ssh_port "$(rand_port)")"
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

  # ---- 步骤 7：Swap（可选，默认跳过） ----
  step_banner 7 "Swap"
  if swap_active; then
    log "swap 已启用（$(swap_summary)），跳过创建"
  else
    log "swap 未启用"
    if ask_yesno "现在进入 Swap 创建流程？" n; then
      run_swap_menu || true
    else
      log "跳过 Swap（内存充裕时可接受）"
    fi
  fi

  # ---- 步骤 8：BBR（可选，默认不应用） ----
  step_banner 8 "BBR 与 TCP 调优"
  printf '  当前拥塞控制： %s（qdisc %s）\n' "$(bbr_cc)" "$(bbr_qdisc)"
  printf '  %s本程序的调优参数是作者本机特调，不一定适合你的机器。%s\n' "${C_Y}" "${C_0}"
  if ask_yesno "应用 BBR + TCP 调优？" n; then
    bbr_apply || warn "BBR 应用未完全成功，终检会按当前状态提示"
  else
    log "跳过 BBR（不改动 sysctl 配置）"
  fi

  # ---- 步骤 9：自动更新复核 + Docker 提示 + 终检 ----
  step_banner 9 "自动更新复核、Docker 提示与终检"
  if ua_enabled; then log "自动安全更新：已启用（已满足）"; else warn "自动安全更新未启用：可回主菜单 1 启用"; fi
  printf '\n'
  printf '  %sDocker（仅提示，本程序不安装）：%s\n' "${C_D}" "${C_0}"
  printf '    bash <(curl -fsSL https://linuxmirrors.cn/docker.sh)\n'
  printf '    该脚本会问"是否关闭防火墙"——%s必须选否%s，否则前面配好的 ufw 会被关掉。\n' "${C_Y}" "${C_0}"
  printf '    docker 组权限等价于 root，与"禁 root 登录"的目标冲突，知情即可。\n'
  printf '\n'
  if run_verify; then
    log "标准初始化完成"
  else
    warn "终检存在红灯：按报告逐项修复后可在主菜单 7 重跑终检"
  fi
  printf '\n'
  printf '  %s最后一步：到云平台核对安全组，并创建最终 Snapshot。%s\n' "${C_Y}" "${C_0}"
  return 0
}

# ============ 主菜单 ============
draw_main_menu() {
  local sshp keys
  sshp="$(sshd_port)"
  keys="$(ak_count)"
  fw_refresh
  scr_clear
  ui_rule
  printf '%s VPS 初始化 TUI%s %s（原生状态，无项目私有配置文件）%s\n' "${C_B}" "${C_0}" "${C_D}" "${C_0}"
  ui_sep
  if [[ -n "${sshp}" ]]; then ui_kv "SSH 端口" "${sshp}"; else ui_kv "SSH 端口" "$(ui_no '未知（sshd -T 失败）')"; fi
  case "$(fw_state)" in
    active) ui_kv "UFW" "$(ui_yes 'active ✓')" ;;
    未安装) ui_kv "UFW" "$(ui_no '未安装')" ;;
    *)      ui_kv "UFW" "$(ui_no "$(fw_state) ⚠")" ;;
  esac
  if [[ -n "${ADMIN_USER}" ]]; then ui_kv "管理员" "${ADMIN_USER}"; else ui_kv "管理员" "${C_D}未确定（进入用户菜单时选择）${C_0}"; fi
  if [[ -n "${ADMIN_USER}" && "${keys}" -gt 0 ]]; then ui_kv "公钥" "${keys} 把"
  elif [[ -n "${ADMIN_USER}" ]]; then ui_kv "公钥" "$(ui_no '0 把 ⚠')"
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
  ui_item 1 "系统更新与基础工具"
  ui_item 2 "用户、密码、sudo 和密钥"
  ui_item 3 "UFW 与 SSH"
  ui_item 4 "fail2ban"
  ui_item 5 "Swap"
  ui_item 6 "BBR"
  ui_item 7 "终检与报告"
  printf '  %sq%s) 退出\n' "${C_R}" "${C_0}"
  ui_sep
}

ask_main() {
  local input
  while :; do
    read -rp "选择 [0-7]（q 退出）: " input || die "输入中断"
    case "${input}" in
      q|Q) MAIN_REPLY="q"; return 0 ;;
      0|1|2|3|4|5|6|7) MAIN_REPLY="${input}"; return 0 ;;
      *) warn "无效输入：请输入 0-7，或 q 退出" ;;
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
      1) act base_menu ;;
      2) act user_menu ;;
      3) act fw_menu ;;
      4) act f2b_menu ;;
      5) scr_clear; act run_swap_menu || true ;;
      6) act bbr_menu ;;
      7) act verify_menu ;;
    esac
  done
  printf '\n%s再见。%s\n' "${C_D}" "${C_0}"
  return 0
}

main "$@"

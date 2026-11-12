#!/usr/bin/env bash
# VPS 初始化 · 09 BBR + TCP 调优
# 自包含 + 幂等。用法：sudo bash 09-bbr.sh
# 项目：https://raw.githubusercontent.com/Pathto1804/myVPS/main/09-bbr.sh
set -euo pipefail
# 命令替换默认不继承 errexit：不开这个，$(ask_input ...) 里的 die 只终止子 shell，
# 空值会被照常写进 conf。开启后交互读取遇 EOF/Ctrl-D 即中止脚本。（bash >= 4.4）
shopt -s inherit_errexit

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
BK_ROOT="/root/vps-init-backups"
# 备份目录保留份数（超出删最旧；bk_prune 只匹配 YYYYmmdd-HHMMSS 目录）
BK_KEEP=20

if [[ -t 1 ]]; then
  C_G=$'\e[32m'; C_Y=$'\e[33m'; C_R=$'\e[31m'; C_B=$'\e[1m'; C_0=$'\e[0m'
else
  C_G=''; C_Y=''; C_R=''; C_B=''; C_0=''
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

# ==================== 脚本主体 ====================

require_root
require_tty
require_distro

SYSCTL_CONF="/etc/sysctl.d/99-bbr.conf"

# 目标配置：BBR + fq + TCP 调优（外部获取的调参集，逐行可审）
read -r -d '' CONF_CONTENT <<'EOF' || true
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

# 幂等：内容一致则跳过写入
if [[ -f "${SYSCTL_CONF}" ]] && diff -q <(printf '%s\n' "${CONF_CONTENT}") "${SYSCTL_CONF}" >/dev/null 2>&1; then
  log "配置已存在且一致：${SYSCTL_CONF}，跳过写入"
else
  backup_file "${SYSCTL_CONF}" >/dev/null
  printf '%s\n' "${CONF_CONTENT}" > "${SYSCTL_CONF}"
  log "已写入 ${SYSCTL_CONF}"
fi

# 应用；个别键在当前内核不存在时（如 tcp_fack 已移除）仅警告
if ! sysctl -p "${SYSCTL_CONF}"; then
  warn "部分键应用失败（新版内核可能已移除个别键，如 tcp_fack），请核对上方报错行"
fi

# 验证核心项
CC="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | tr -d '\r')"
QC="$(sysctl -n net.core.default_qdisc 2>/dev/null | tr -d '\r')"
[[ "${CC}" == "bbr" ]] || die "tcp_congestion_control = ${CC:-未知}，非 bbr；请检查内核版本（需 >= 4.9）"
[[ "${QC}" == "fq" ]]  || warn "default_qdisc = ${QC:-未知}，非 fq（BBR 仍工作，但推荐 fq）"

log "BBR 已启用（congestion_control=${CC}, qdisc=${QC}）"
log "第 9 步完成"

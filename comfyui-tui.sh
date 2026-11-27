#!/usr/bin/env bash
# ComfyUI 部署 TUI · 与 00-tui.sh 并列的第二入口
# 自包含 + 原生状态 + 动作隔离。用法：sudo -i 后 bash <(curl -fsSL .../comfyui-tui.sh)
# 默认访问方式：--listen 0.0.0.0 --port 8188；菜单 7 可切换为仅回环 + SSH 隧道。
# 不保存项目私有状态：GPU/驱动读 nvidia-smi，环境读 miniforge/env，服务读 systemd 或 /start.d，
# 端口读 ss，防火墙读 ufw，ComfyUI 读 git；用户输入的偏好只存在于本次进程。

set -euo pipefail
# 命令替换默认不继承 errexit：不开这个，$(ask_input ...) 里的 die 只终止子 shell，
# 空值会被照常写进系统配置。开启后交互读取遇 EOF/Ctrl-D 即中止脚本。（bash >= 4.4）
shopt -s inherit_errexit

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
ROOT_HOME="$(getent passwd root 2>/dev/null | cut -d: -f6)" || ROOT_HOME="/root"
[[ -n "${ROOT_HOME}" ]] || ROOT_HOME="/root"
BK_ROOT="/root/vps-init-backups"
BK_KEEP=20

COMFY_BASE="git curl wget vim build-essential tmux htop ca-certificates ffmpeg libgl1 libglib2.0-0 aria2 nvtop ncdu pciutils"
MINIFORGE_URL="https://mirrors.tuna.tsinghua.edu.cn/github-release/conda-forge/miniforge/LatestRelease/Miniforge3-Linux-x86_64.sh"
MINIFORGE_FALLBACK="https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh"
CONDA_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/anaconda/cloud"
PIP_MIRROR="https://mirrors.aliyun.com/pypi/simple/"
PIP_MIRROR_FALLBACK="https://pypi.tuna.tsinghua.edu.cn/simple"
CPU_INDEX="https://download.pytorch.org/whl/cpu"
CPU_INDEX_FALLBACK="https://mirror.nju.edu.cn/pytorch/whl/cpu"

MINIFORGE_DIR="${ROOT_HOME}/miniforge3"
CONDA_BIN="${MINIFORGE_DIR}/bin/conda"
MAMBA_BIN="${MINIFORGE_DIR}/bin/mamba"
ENV_DIR="${MINIFORGE_DIR}/envs/comfyui"
ENV_PY="${ENV_DIR}/bin/python"
ENV_BIN="${ENV_DIR}/bin"
COMFY_DIR="${ROOT_HOME}/ComfyUI"
COMFY_REPO="https://github.com/Comfy-Org/ComfyUI.git"
COMFY_REPO_PROXY="https://ghproxy.net/https://github.com/Comfy-Org/ComfyUI.git"

SERVICE_NAME="comfyui"
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
STARTD_DIR="/start.d"
STARTD_FILE="${STARTD_DIR}/comfyui.sh"
PORT=8188

# 本次进程内的选择；不落盘
CPU_MODE=0
ACCESS_MODE=""
PY_VER="3.13"
TMPD=""
UI_REPLY=""
DW=0
declare -a COMFY_ARGS=()

if [[ -t 1 ]]; then
  C_G=$'\e[32m'; C_Y=$'\e[33m'; C_R=$'\e[31m'; C_B=$'\e[1m'; C_D=$'\e[90m'; C_0=$'\e[0m'
else
  C_G=''; C_Y=''; C_R=''; C_B=''; C_D=''; C_0=''
fi

log()  { printf '%s[%s]%s %s\n' "${C_B}" "${SCRIPT_NAME}" "${C_0}" "$*"; }
warn() { printf '%s[%s]%s %s\n' "${C_Y}" "${SCRIPT_NAME}" "${C_0}" "$*" >&2; }
die()  { printf '%s[%s]%s %s\n' "${C_R}" "${SCRIPT_NAME}" "${C_0}" "$*" >&2; exit 1; }

err_trap() { die "行 ${1}: ${2}"; }
die_action() { warn "$*"; return 1; }

act() {
  local rc=0 had_e=0
  case "$-" in *e*) had_e=1 ;; esac
  set +e
  trap - ERR
  "$@" || rc=$?
  trap 'err_trap "${LINENO}" "${BASH_COMMAND}"' ERR
  if (( had_e )); then set -e; fi
  return "${rc}"
}
trap 'err_trap "${LINENO}" "${BASH_COMMAND}"' ERR

cleanup() {
  if [[ -n "${TMPD}" && -d "${TMPD}" ]]; then
    rm -rf -- "${TMPD}"
  fi
}
trap cleanup EXIT

ui_abort() {
  printf '\n%s[中断]%s 已停止。若刚做过写操作，配置可能只改了一半；重新进入 TUI 会按当前系统状态收敛。\n' \
    "${C_Y}" "${C_0}" >&2
  exit 130
}
trap 'ui_abort' INT

# ============ 屏幕契约 ============
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

scr_pause() {
  local msg="${1:-按回车继续…}" _x
  printf '%s%s%s' "${C_D}" "${msg}" "${C_0}"
  read -r _x || true
  return 0
}

page_wait() {
  scr_pause "${1:-按回车返回…}"
  scr_clear
  return 0
}

# ============ 环境前置检查 ============
require_root() { [[ "${EUID}" -eq 0 ]] || die "需要 root 运行，请用：sudo -i 后重跑"; }
require_tty() { [[ -t 0 ]] || die "需要交互终端运行，不支持无人值守"; }
require_x86_64() { [[ "$(uname -m)" == "x86_64" ]] || die "仅支持 x86_64，当前：$(uname -m)"; }

distro_id() { awk -F= '/^ID=/{gsub(/"/,"",$2); print $2; exit}' /etc/os-release 2>/dev/null; }
distro_version() { awk -F= '/^VERSION_ID=/{gsub(/"/,"",$2); print $2; exit}' /etc/os-release 2>/dev/null; }
distro_pretty() { awk -F= '/^PRETTY_NAME=/{gsub(/"/,"",$2); print $2; exit}' /etc/os-release 2>/dev/null; }
distro_major() { local v; v="$(distro_version)"; printf '%s' "${v%%.*}"; }

require_distro() {
  local id major
  id="$(distro_id)"; major="$(distro_major)"
  case "${id}" in
    ubuntu) (( ${major:-0} >= 20 )) || die "需要 Ubuntu 20.04+，当前：$(distro_version)" ;;
    debian) (( ${major:-0} >= 11 )) || die "需要 Debian 11+，当前：$(distro_version)" ;;
    *) die "仅支持 Debian/Ubuntu，当前：${id:-未知}" ;;
  esac
}

is_ubuntu() { [[ "$(distro_id)" == "ubuntu" ]]; }
is_debian() { [[ "$(distro_id)" == "debian" ]]; }

# ============ 交互原语 ============
ask_yesno() {
  local prompt="$1" def="${2:-n}" ans hint
  case "${def}" in
    y|Y) def=y; hint="是" ;;
    *)   def=n; hint="否" ;;
  esac
  while :; do
    read -rp "${prompt} [y/n]（回车=${hint}） " ans || return 1
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
    read -rp "${prompt}（必填）: " val || die "输入中断"
    if "${v}" "${val}"; then printf '%s' "${val}"; return 0; fi
  done
}

ask_input_def() {
  local prompt="$1" v="$2" def="$3" val
  while :; do
    read -rp "${prompt}（回车=默认 ${def}）: " val || die "输入中断"
    val="${val:-${def}}"
    if "${v}" "${val}"; then printf '%s' "${val}"; return 0; fi
  done
}

ask_menu() {
  local prompt="$1" max="$2" zero="${3:-返回主菜单}" input
  while :; do
    read -rp "${prompt} [0-${max}]（回车=${zero}）: " input || die "输入中断"
    input="${input:-0}"
    if [[ "${input}" =~ ^[0-9]+$ ]] && (( input <= max )); then
      UI_REPLY="${input}"; return 0
    fi
    warn "无效输入：请输入 0-${max}"
  done
}

# 校验器
v_nonempty() { [[ -n "$1" ]] || { printf '不能为空\n' >&2; return 1; }; }
v_pyver() { [[ "$1" =~ ^3\.(12|13)$ ]] || { printf '仅支持 3.12 / 3.13\n' >&2; return 1; }; }
v_action() { [[ "$1" =~ ^(start|stop|restart|status)$ ]] || { printf '仅支持 start/stop/restart/status\n' >&2; return 1; }; }
v_dir() { [[ -d "$1" ]] || { printf '目录不存在：%s\n' "$1" >&2; return 1; }; }

# 显示宽度：CJK/全角按 2 列
_disp_w() {
  local s="$1" i=0 w=0 c n
  while (( i < ${#s} )); do
    c="${s:i:1}"
    printf -v n '%d' "'${c}"
    (( n < 0 )) && n=$(( -n ))
    if (( n < 128 )); then
      w=$((w+1)); i=$((i+1))
    elif (( n <= 255 )); then
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
ui_kv() {
  local label="$1" val="$2" pad
  _disp_w "${label}"; pad=$(( 12 - DW ))
  (( pad < 1 )) && pad=1
  printf '  %s%*s%s\n' "${label}" "${pad}" '' "${val}"
}
ui_item() { printf '  %s%s%s) %s\n' "${C_G}" "$1" "${C_0}" "$2"; }
ui_quit() { printf '  %s0%s) 返回主菜单\n' "${C_R}" "${C_0}"; }
ui_yes()  { printf '%s%s%s' "${C_G}" "$1" "${C_0}"; }
ui_no()   { printf '%s%s%s' "${C_Y}" "$1" "${C_0}"; }

# ============ 备份 ============
backup_file() {
  local path="$1" stamp dir newest base
  [[ -e "${path}" ]] || { printf ''; return 0; }
  base="$(basename "${path}")"
  newest="$(find "${BK_ROOT}" -mindepth 1 -maxdepth 1 -type d \
    -regextype posix-extended -regex '.*/[0-9]{8}-[0-9]{6}' 2>/dev/null | sort | tail -n 1)" || true
  if [[ -n "${newest}" && -f "${newest}/${base}" ]] && cmp -s "${path}" "${newest}/${base}"; then
    stamp="$(date +%Y%m%d-%H%M%S)"
    dir="${BK_ROOT}/${stamp}"
    if [[ "${dir}" != "${newest}" ]]; then
      mkdir -p "${dir}"
      mv "${newest}/${base}" "${dir}/${base}"
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

# ============ 包管理 ============
pkg_installed() {
  local st
  st="$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" || true
  [[ "${st}" == *"install ok installed"* ]]
}
missing_pkgs() {
  local p
  for p in "$@"; do
    pkg_installed "${p}" || printf '%s ' "${p}"
  done
}
apt_update_index() {
  log "apt-get update"
  if ! DEBIAN_FRONTEND=noninteractive apt-get update; then
    die_action "apt-get update 失败（检查网络与软件源）"
    return 1
  fi
  return 0
}

install_base_packages() {
  local miss
  local -a miss_arr=()
  local -a pkgs=()
  read -r -a pkgs <<< "${COMFY_BASE}"
  miss="$(missing_pkgs "${pkgs[@]}")"
  if [[ -z "${miss}" ]]; then
    log "ComfyUI 基础包已全部安装（已满足）"
    return 0
  fi
  printf '缺少基础包：%s\n' "${miss}"
  if ! ask_yesno "确认安装以上基础包？" y; then
    die_action "已取消安装基础包"
    return 1
  fi
  apt_update_index || return 1
  read -r -a miss_arr <<< "${miss}"
  log "安装：${miss}"
  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "${miss_arr[@]}"; then
    die_action "安装失败：${miss}（检查网络/源后重试）"
    return 1
  fi
  return 0
}

base_missing_summary() {
  local miss n
  local -a pkgs=()
  read -r -a pkgs <<< "${COMFY_BASE}"
  miss="$(missing_pkgs "${pkgs[@]}")"
  if [[ -z "${miss}" ]]; then
    printf '已满足'
    return 0
  fi
  n="$(wc -w <<< "${miss}")"
  printf '缺 %s 项' "${n}"
}

# ============ 状态探测 ============
gpu_hardware_present() {
  local out
  if command -v lspci >/dev/null 2>&1; then
    out="$(lspci 2>/dev/null || true)"
    if [[ "${out}" == *NVIDIA* ]]; then return 0; fi
  fi
  [[ -e /dev/nvidiactl || -e /dev/nvidia0 ]]
}
gpu_driver_ready() {
  command -v nvidia-smi >/dev/null 2>&1 || return 1
  nvidia-smi -L >/dev/null 2>&1
}
gpu_name() {
  local out
  out="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null || true)"
  printf '%s' "${out%%$'\n'*}"
}
gpu_driver_version() {
  local out
  out="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null || true)"
  printf '%s' "${out%%$'\n'*}"
}
gpu_cuda_version() {
  local out
  out="$(nvidia-smi 2>/dev/null || true)"
  awk '/CUDA Version/ {for (i=1;i<=NF;i++) if ($i=="CUDA" && $(i+1)=="Version:") {print $(i+2); exit}}' <<< "${out}"
}
cuda_major() { local v="$1"; printf '%s' "${v%%.*}"; }

disk_avail_gb() {
  local out
  out="$(df -Pk "${ROOT_HOME}" 2>/dev/null || true)"
  awk 'NR==2 {printf "%d", $4/1024/1024}' <<< "${out}"
}

port_listening() {
  local out
  out="$(ss -tln 2>/dev/null || true)"
  [[ "${out}" == *":${PORT}"* ]]
}

fw_installed() { command -v ufw >/dev/null 2>&1; }
fw_raw() { ufw status 2>/dev/null || true; }
fw_active() {
  local out
  out="$(fw_raw)"
  [[ "${out}" == Status:\ active* ]]
}
fw_has_port() {
  local out
  out="$(fw_raw)"
  [[ "${out}" == *"${PORT}/tcp"* ]]
}

systemd_present() { [[ "$(ps -p 1 -o comm= 2>/dev/null || true)" == "systemd" ]]; }
unit_exists() { [[ -f "${UNIT_FILE}" ]]; }
startd_exists() { [[ -d "${STARTD_DIR}" ]]; }
startd_configured() { startd_exists && [[ -f "${STARTD_FILE}" ]]; }
service_active() {
  if unit_exists && systemd_present; then
    [[ "$(systemctl is-active "${SERVICE_NAME}" 2>/dev/null || true)" == "active" ]]
  else
    return 1
  fi
}
service_enabled() {
  if unit_exists && systemd_present; then
    [[ "$(systemctl is-enabled "${SERVICE_NAME}" 2>/dev/null || true)" == "enabled" ]]
  else
    return 1
  fi
}

config_file() {
  if [[ -f "${UNIT_FILE}" ]]; then printf '%s' "${UNIT_FILE}"
  elif [[ -f "${STARTD_FILE}" ]]; then printf '%s' "${STARTD_FILE}"
  fi
}
current_access_mode() {
  local f
  f="$(config_file)"
  if [[ -z "${f}" ]]; then printf 'listen'; return 0; fi
  if grep -q -- '--listen' "${f}"; then printf 'listen'; else printf 'tunnel'; fi
}
config_has_cpu() {
  local f
  f="$(config_file)"
  [[ -n "${f}" ]] && grep -q -- '--cpu' "${f}"
}

env_py() { HOME="${ROOT_HOME}" "${ENV_PY}" "$@"; }
miniforge_ok() {
  [[ -x "${CONDA_BIN}" ]] && "${CONDA_BIN}" --version >/dev/null 2>&1
}
env_ok() {
  [[ -x "${ENV_PY}" ]] && env_py --version >/dev/null 2>&1
}
env_python_version() {
  if env_ok; then env_py --version 2>&1; else printf '未创建'; fi
}
comfy_ok() { [[ -d "${COMFY_DIR}/.git" ]]; }
comfy_commit() {
  if comfy_ok; then git -C "${COMFY_DIR}" rev-parse --short HEAD 2>/dev/null || true; fi
}
pip_version() {
  local pkg="$1" out
  [[ -x "${ENV_PY}" ]] || return 0
  out="$(env_py -m pip show "${pkg}" 2>/dev/null || true)"
  awk '/^Version:/ {print $2; exit}' <<< "${out}"
}

public_ip() {
  local url out
  for url in https://api.ipify.org https://ifconfig.me https://ipinfo.io/ip; do
    out="$(curl -4 -fsS --max-time 5 "${url}" 2>/dev/null || true)"
    out="${out//[$'\r\n']/}"
    if [[ "${out}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      printf '%s' "${out}"; return 0
    fi
  done
  return 1
}

mirror_check() {
  local label="$1" url="$2"
  if curl -fsI --max-time 12 -o /dev/null "${url}" 2>/dev/null; then
    log "镜像可达：${label}"
  else
    warn "镜像不可达：${label}（${url}）"
    return 1
  fi
}

# ============ 驱动 ============
nvidia_repo_name() {
  local id major
  id="$(distro_id)"; major="$(distro_major)"
  case "${id}:${major}" in
    ubuntu:20) printf 'ubuntu2004' ;;
    ubuntu:22) printf 'ubuntu2204' ;;
    ubuntu:24) printf 'ubuntu2404' ;;
    debian:11) printf 'debian11' ;;
    debian:12) printf 'debian12' ;;
    debian:13) printf 'debian13' ;;
    *) return 1 ;;
  esac
}

nvidia_repo_setup() {
  local repo keyring
  if ! command -v wget >/dev/null 2>&1; then
    die_action "wget 未安装，先完成菜单 2 的基础包安装"
    return 1
  fi
  repo="$(nvidia_repo_name)" || { die_action "当前发行版不支持 NVIDIA 官方源"; return 1; }
  keyring="${TMPD}/cuda-keyring.deb"
  if ! wget -O "${keyring}" "https://developer.download.nvidia.com/compute/cuda/repos/${repo}/x86_64/cuda-keyring_1.1-1_all.deb"; then
    die_action "下载 cuda-keyring 失败"
    return 1
  fi
  if ! dpkg -i "${keyring}"; then
    rm -f "${keyring}"
    die_action "安装 cuda-keyring 失败"
    return 1
  fi
  rm -f "${keyring}"
  apt_update_index || return 1
  return 0
}

driver_install_path_a() {
  local out max
  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y ubuntu-drivers-common; then
    die_action "安装 ubuntu-drivers-common 失败"
    return 1
  fi
  out="$(ubuntu-drivers devices 2>/dev/null || true)"
  printf '%s\n' "${out}"
  max="$(sed -n 's/.*nvidia-driver-\([0-9][0-9]*\).*/\1/p' <<< "${out}" | sort -n | tail -n 1)"
  if [[ -z "${max}" ]] || (( max < 580 )); then
    warn "系统源最高驱动：${max:-未知}（低于 580），改走 NVIDIA 官方源"
    driver_install_path_b || return 1
    return 0
  fi
  if ! ask_yesno "安装系统推荐驱动 nvidia-driver-${max}？" y; then
    die_action "已取消驱动安装"
    return 1
  fi
  if ! DEBIAN_FRONTEND=noninteractive ubuntu-drivers install; then
    die_action "ubuntu-drivers install 失败"
    return 1
  fi
  return 0
}

driver_install_path_b() {
  nvidia_repo_setup || return 1
  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y nvidia-open; then
    warn "nvidia-open 安装失败。Volta 及更老 GPU 可改用手动命令：sudo apt install -y cuda-drivers"
    return 1
  fi
  return 0
}

driver_install_action() {
  local choice="2"
  if is_ubuntu; then
    printf '  1) Ubuntu 系统源（优先，版本需 >=580）\n'
    printf '  2) NVIDIA 官方源（nvidia-open）\n'
    choice="$(ask_input_def "选择驱动来源" v_choice_driver "1")" || return 1
  else
    log "Debian 无 ubuntu-drivers，直接使用 NVIDIA 官方源"
  fi
  case "${choice}" in
    1) driver_install_path_a || return 1 ;;
    2) driver_install_path_b || return 1 ;;
    *) die_action "无效选择"; return 1 ;;
  esac
  warn "驱动已安装：必须重启后新版驱动才会生效"
  return 0
}
v_choice_driver() { [[ "$1" =~ ^(1|2)$ ]] || { printf '请输入 1 或 2\n' >&2; return 1; }; }

cuda_toolkit_install() {
  if ! command -v nvcc >/dev/null 2>&1; then
    warn "未检测到 nvcc；安装 cuda-toolkit 仅用于本地编译 sageattention/flash-attn 等插件"
  fi
  if ! ask_yesno "安装系统级 cuda-toolkit（体积较大）？" n; then
    log "已取消 cuda-toolkit 安装"
    return 0
  fi
  nvidia_repo_setup || return 1
  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y cuda-toolkit; then
    die_action "cuda-toolkit 安装失败"
    return 1
  fi
  local bashrc="${ROOT_HOME}/.bashrc"
  backup_file "${bashrc}" >/dev/null || true
  if ! grep -qF '/usr/local/cuda/bin' "${bashrc}" 2>/dev/null; then
    printf '\nexport PATH=/usr/local/cuda/bin:$PATH\nexport LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH\n' >> "${bashrc}" || {
      die_action "写入 ${bashrc} 失败"; return 1;
    }
  fi
  log "cuda-toolkit 已安装；重新登录 SSH 后 nvcc 指向 /usr/local/cuda"
  return 0
}

# 返回：0 继续；1 失败；2 驱动已安装，必须重启后续跑
detect_or_install_driver() {
  local cv major
  if gpu_hardware_present; then
    CPU_MODE=0
    if gpu_driver_ready; then
      cv="$(gpu_cuda_version)"
      major="$(cuda_major "${cv}")"
      if [[ -n "${major}" ]] && (( major >= 13 )); then
        log "GPU：$(gpu_name)；驱动 $(gpu_driver_version)；CUDA ${cv}（满足）"
        return 0
      fi
      warn "驱动 CUDA ${cv:-未知} 低于 13.0（驱动 <580），v1 不支持 cu126 回退"
      if ! ask_yesno "现在安装/升级驱动？安装后必须重启" y; then
        die_action "驱动不足，已中止。请先升级到 580+ 或换带新版驱动的镜像"
        return 1
      fi
      driver_install_action || return 1
      return 2
    fi
    warn "检测到 NVIDIA 硬件，但 nvidia-smi 不可用（驱动未安装或未加载）"
    if ask_yesno "现在安装驱动？安装后必须重启" y; then
      driver_install_action || return 1
      return 2
    fi
    if ask_yesno "不装驱动，改用 CPU 测试模式继续？" n; then
      CPU_MODE=1
      return 0
    fi
    die_action "已中止"
    return 1
  fi
  if ask_yesno "未检测到 NVIDIA GPU，进入 CPU 测试模式？" n; then
    CPU_MODE=1
    return 0
  fi
  die_action "没有 GPU 且未选择 CPU 模式，已中止"
  return 1
}

reboot_now() {
  if ! ask_yesno "现在重启服务器？未保存的工作会丢失" n; then
    log "已取消重启"
    return 0
  fi
  log "即将重启"
  systemctl reboot 2>/dev/null || reboot || { die_action "重启命令失败，请手动执行 reboot"; return 1; }
  return 0
}

# ============ Miniforge / Python ============
condarc_write() {
  local f="${ROOT_HOME}/.condarc" cur
  cur="$(cat "${f}" 2>/dev/null || true)"
  if [[ "${cur}" == *"${CONDA_MIRROR}"* ]]; then
    log ".condarc 已指向清华镜像（已满足）"
    return 0
  fi
  if [[ -e "${f}" ]]; then
    backup_file "${f}" >/dev/null || true
    if ! ask_yesno "覆盖现有 .condarc（将备份）？" y; then
      warn "保留现有 .condarc；mamba 可能仍走旧源"
      return 0
    fi
  fi
  cat > "${f}" <<EOF
channels:
  - conda-forge
show_channel_urls: true
custom_channels:
  conda-forge: ${CONDA_MIRROR}
EOF
  log "已写入 ${f}（清华 conda-forge 镜像）"
  return 0
}

conda_init_bash() {
  local bashrc="${ROOT_HOME}/.bashrc"
  backup_file "${bashrc}" >/dev/null || true
  if ! HOME="${ROOT_HOME}" "${CONDA_BIN}" init bash; then
    warn "conda init bash 失败；脚本仍用绝对路径调用 conda"
  fi
  return 0
}

miniforge_install() {
  local installer
  if ! command -v wget >/dev/null 2>&1; then
    die_action "wget 未安装，先完成菜单 2 的基础包安装"
    return 1
  fi
  if miniforge_ok; then
    log "Miniforge 已安装（已满足）：$("${CONDA_BIN}" --version 2>/dev/null || true)"
    conda_init_bash
    condarc_write || return 1
    return 0
  fi
  installer="${TMPD}/miniforge.sh"
  log "下载 Miniforge（清华镜像）"
  if ! wget -c -O "${installer}" "${MINIFORGE_URL}"; then
    warn "清华 Miniforge 下载失败"
    if ! ask_yesno "改用 GitHub 官方地址重试？" y; then
      die_action "已取消 Miniforge 安装"
      return 1
    fi
    if ! wget -c -O "${installer}" "${MINIFORGE_FALLBACK}"; then
      die_action "Miniforge 下载失败"
      return 1
    fi
  fi
  if [[ ! -s "${installer}" ]]; then
    die_action "Miniforge 安装包为空"
    return 1
  fi
  if ! bash "${installer}" -b -u -p "${MINIFORGE_DIR}"; then
    die_action "Miniforge 安装失败"
    return 1
  fi
  rm -f "${installer}"
  if ! miniforge_ok; then
    die_action "Miniforge 安装后不可用"
    return 1
  fi
  conda_init_bash
  condarc_write || return 1
  log "Miniforge 安装完成：$("${CONDA_BIN}" --version 2>/dev/null || true)"
  return 0
}

env_create() {
  local ver="${1:-${PY_VER}}"
  if env_ok; then
    log "Python 环境已存在（已满足）：$(env_python_version)"
    return 0
  fi
  local runner="${MAMBA_BIN}"
  [[ -x "${runner}" ]] || runner="${CONDA_BIN}"
  log "创建 conda 环境 comfyui（Python ${ver}）"
  if ! HOME="${ROOT_HOME}" "${runner}" create -n comfyui "python=${ver}" -y; then
    die_action "创建 comfyui 环境失败（检查 condarc 镜像与网络）"
    return 1
  fi
  if ! env_ok; then
    die_action "环境创建后 ${ENV_PY} 不可用"
    return 1
  fi
  return 0
}

env_recreate() {
  local ver
  warn "重建会删除现有 comfyui 环境（模型与 ComfyUI 代码不受影响）"
  if ! ask_yesno "确认重建 comfyui 环境？" n; then
    log "已取消重建"
    return 0
  fi
  ver="$(ask_input_def "Python 版本" v_pyver "${PY_VER}")" || return 1
  if env_ok; then
    if ! HOME="${ROOT_HOME}" "${CONDA_BIN}" env remove -n comfyui -y; then
      die_action "删除环境失败"
      return 1
    fi
  fi
  env_create "${ver}" || return 1
  return 0
}

# ============ ComfyUI / PyTorch ============
pip_config_write() {
  local f="${ROOT_HOME}/.config/pip/pip.conf" cur
  if ! env_ok; then
    die_action "Python 环境未就绪，先完成菜单 4"
    return 1
  fi
  cur="$(env_py -m pip config get global.index-url 2>/dev/null || true)"
  if [[ "${cur}" == "${PIP_MIRROR}" ]]; then
    log "pip 已指向阿里云镜像（已满足）"
    return 0
  fi
  if [[ -e "${f}" ]]; then backup_file "${f}" >/dev/null || true; fi
  if ! env_py -m pip config set global.index-url "${PIP_MIRROR}"; then
    die_action "写入 pip 镜像配置失败"
    return 1
  fi
  log "pip 全局源已设为 ${PIP_MIRROR}"
  return 0
}

pip_install_fallback() {
  local desc="$1"
  shift
  if env_py -m pip install "$@"; then
    return 0
  fi
  warn "${desc} 安装失败（阿里 PyPI）"
  if ! ask_yesno "改用清华 PyPI 重试？" y; then
    return 1
  fi
  env_py -m pip install --index-url "${PIP_MIRROR_FALLBACK}" "$@"
}

comfy_clone_or_pull() {
  if ! command -v git >/dev/null 2>&1; then
    die_action "git 未安装，先完成菜单 2 的基础包安装"
    return 1
  fi
  if [[ -d "${COMFY_DIR}" && ! -d "${COMFY_DIR}/.git" ]]; then
    die_action "${COMFY_DIR} 存在但不是 git 仓库，拒绝覆盖"
    return 1
  fi
  if comfy_ok; then
    local before after
    before="$(git -C "${COMFY_DIR}" rev-parse --short HEAD 2>/dev/null || true)"
    if ! git -C "${COMFY_DIR}" pull --ff-only; then
      warn "git pull 失败（可能有本地改动或分支分叉）；保留当前代码继续"
      return 0
    fi
    after="$(git -C "${COMFY_DIR}" rev-parse --short HEAD 2>/dev/null || true)"
    log "ComfyUI：${before} -> ${after:-未知}"
    return 0
  fi
  log "克隆 ComfyUI 到 ${COMFY_DIR}"
  if ! git clone "${COMFY_REPO}" "${COMFY_DIR}"; then
    warn "GitHub clone 失败"
    if ! ask_yesno "使用 ghproxy 代理重试 clone？" n; then
      die_action "已取消 ComfyUI 克隆"
      return 1
    fi
    if ! git clone "${COMFY_REPO_PROXY}" "${COMFY_DIR}"; then
      die_action "ComfyUI 克隆失败"
      return 1
    fi
  fi
  return 0
}

torch_report() {
  local out
  if ! env_ok; then return 1; fi
  out="$(env_py -c 'import torch, torchvision; print(torch.__version__); print(torch.version.cuda or ""); print(torch.cuda.is_available())' 2>/dev/null || true)"
  printf '%s' "${out}"
}

parse_torch_report() {
  ver=""; cuda=""; avail=""
  { IFS= read -r ver; IFS= read -r cuda; IFS= read -r avail; } <<< "$1" || true
}

torch_install() {
  local ver cuda avail out
  if ! env_ok; then
    die_action "Python 环境未就绪，先完成菜单 4"
    return 1
  fi
  if (( CPU_MODE == 0 )) && ! gpu_driver_ready; then
    if gpu_hardware_present; then
      die_action "GPU 驱动未就绪，请先完成菜单 3"
      return 1
    fi
    if ask_yesno "未检测到可用 GPU，安装 CPU 版 PyTorch？" n; then
      CPU_MODE=1
    else
      die_action "已取消"
      return 1
    fi
  fi
  out="$(torch_report || true)"
  if [[ -n "${out}" ]]; then
    parse_torch_report "${out}"
    if (( CPU_MODE )); then
      if [[ "${ver}" == *"+cpu"* || -z "${cuda}" ]]; then
        log "已安装 CPU 版 PyTorch ${ver}（已满足）"
        return 0
      fi
    elif [[ "$(cuda_major "${cuda}")" == "13" && "${avail}" == "True" ]]; then
      log "已安装 CUDA 13 PyTorch ${ver}（已满足）"
      return 0
    fi
    warn "现有 PyTorch 与目标模式不匹配：${ver} / CUDA ${cuda:-无}"
    if ! ask_yesno "重新安装 PyTorch？" y; then
      return 0
    fi
    log "卸载旧 torch / torchvision 后重装"
    env_py -m pip uninstall -y torch torchvision >/dev/null 2>&1 || true
  fi
  if (( CPU_MODE )); then
    log "安装 CPU 版 torch / torchvision（官方 CPU 索引）"
    if ! env_py -m pip install torch torchvision --index-url "${CPU_INDEX}"; then
      warn "官方 CPU 索引失败"
      if ! ask_yesno "改用南京大学 CPU 镜像重试？" y; then
        die_action "PyTorch 安装失败"
        return 1
      fi
      if ! env_py -m pip install torch torchvision --index-url "${CPU_INDEX_FALLBACK}"; then
        die_action "PyTorch 安装失败"
        return 1
      fi
    fi
  else
    log "安装 CUDA 13 版 torch / torchvision（阿里 PyPI，预计下载约 3GB）"
    if ! ask_yesno "确认安装 PyTorch？" y; then
      die_action "已取消"
      return 1
    fi
    if ! pip_install_fallback "PyTorch" torch torchvision; then
      die_action "PyTorch 安装失败（检查 pip 镜像与网络）"
      return 1
    fi
  fi
  out="$(torch_report)"
  if [[ -z "${out}" ]]; then
    die_action "PyTorch 安装后 import 失败"
    return 1
  fi
  parse_torch_report "${out}"
  if (( CPU_MODE )); then
    log "PyTorch ${ver}（CPU）可用"
    return 0
  fi
  if [[ "$(cuda_major "${cuda}")" != "13" || "${avail}" != "True" ]]; then
    die_action "PyTorch ${ver} / CUDA ${cuda:-无} / cuda.is_available=${avail}，与驱动不匹配"
    return 1
  fi
  log "PyTorch ${ver}（CUDA ${cuda}）可用"
  return 0
}

requirements_install() {
  local f
  if ! comfy_ok; then
    die_action "ComfyUI 未安装，先完成菜单 5 的 clone"
    return 1
  fi
  for f in "${COMFY_DIR}/requirements.txt" "${COMFY_DIR}/manager_requirements.txt"; do
    if [[ ! -f "${f}" ]]; then
      die_action "缺少依赖清单：${f}"
      return 1
    fi
  done
  log "安装 ComfyUI requirements"
  if ! pip_install_fallback "ComfyUI requirements" -r "${COMFY_DIR}/requirements.txt"; then
    die_action "ComfyUI requirements 安装失败"
    return 1
  fi
  log "安装 Manager requirements"
  if ! pip_install_fallback "Manager requirements" -r "${COMFY_DIR}/manager_requirements.txt"; then
    die_action "Manager requirements 安装失败"
    return 1
  fi
  return 0
}

smoke_test() {
  local -a args=(main.py --quick-test-for-ci --enable-manager)
  if (( CPU_MODE )); then args+=(--cpu); fi
  if ! comfy_ok || ! env_ok; then
    die_action "ComfyUI 或 Python 环境未就绪"
    return 1
  fi
  if service_active || port_listening; then
    log "服务或 8188 已在运行，跳过前台冒烟测试（终检会验证 HTTP）"
    return 0
  fi
  log "冒烟测试：ComfyUI 启动检查"
  if ! ( cd "${COMFY_DIR}" && HOME="${ROOT_HOME}" timeout 180 "${ENV_PY}" "${args[@]}" ); then
    die_action "ComfyUI 冒烟测试失败（查看上方报错）"
    return 1
  fi
  log "冒烟测试通过"
  return 0
}

# ============ 访问方式 / 防火墙 ============
ensure_fw_8188() {
  if ! fw_installed; then
    warn "UFW 未安装：8188 的可达性完全由云安全组决定"
    return 0
  fi
  if ! fw_active; then
    warn "UFW 未启用：8188 的可达性完全由云安全组决定（建议先跑 00-tui.sh 做安全基线）"
    return 0
  fi
  if fw_has_port; then
    log "UFW 已放行 8188/tcp（已满足）"
    return 0
  fi
  if ask_yesno "UFW 放行 8188/tcp？来源不限制，建议在云安全组限制为你自己的 IP" y; then
    if ! ufw allow "${PORT}/tcp"; then
      die_action "ufw allow ${PORT}/tcp 失败"
      return 1
    fi
    log "已放行 8188/tcp"
  else
    warn "未放行 8188：UFW active 时公网将无法访问"
  fi
  return 0
}

# ============ 开机自启 ============
build_comfy_args() {
  COMFY_ARGS=(--enable-manager)
  if [[ "${ACCESS_MODE}" == "listen" ]]; then
    COMFY_ARGS+=(--listen 0.0.0.0 --port "${PORT}")
  fi
  if (( CPU_MODE )); then
    COMFY_ARGS+=(--cpu)
  fi
}

sync_runtime_mode() {
  if ! gpu_hardware_present; then
    CPU_MODE=1
  fi
  if config_has_cpu; then
    CPU_MODE=1
  fi
}

ensure_comfy_args() {
  if (( ${#COMFY_ARGS[@]} > 0 )); then
    return 0
  fi
  if [[ -z "${ACCESS_MODE}" ]]; then
    ACCESS_MODE="$(current_access_mode)"
  fi
  sync_runtime_mode
  build_comfy_args
}

write_systemd_unit() {
  if ! systemd_present; then
    die_action "当前 PID 1 不是 systemd，不能写 systemd 服务"
    return 1
  fi
  if ! env_ok || ! comfy_ok; then
    die_action "Python 环境或 ComfyUI 未就绪，不能写自启配置"
    return 1
  fi
  ensure_comfy_args
  backup_file "${UNIT_FILE}" >/dev/null || true
  cat > "${UNIT_FILE}" <<EOF
[Unit]
Description=ComfyUI Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${COMFY_DIR}
ExecStart=${ENV_PY} ${COMFY_ARGS[*]}
Restart=always
RestartSec=10
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF
  if ! systemctl daemon-reload; then
    die_action "systemctl daemon-reload 失败"
    return 1
  fi
  if ! systemctl enable "${SERVICE_NAME}"; then
    die_action "systemctl enable ${SERVICE_NAME} 失败"
    return 1
  fi
  if ! systemctl restart "${SERVICE_NAME}"; then
    die_action "systemctl restart ${SERVICE_NAME} 失败"
    return 1
  fi
  return 0
}

write_startd_script() {
  if ! startd_exists; then
    die_action "未检测到 ${STARTD_DIR}，不能写容器自启脚本"
    return 1
  fi
  if ! env_ok || ! comfy_ok; then
    die_action "Python 环境或 ComfyUI 未就绪，不能写自启配置"
    return 1
  fi
  ensure_comfy_args
  backup_file "${STARTD_FILE}" >/dev/null || true
  cat > "${STARTD_FILE}" <<EOF
#!/bin/bash
export PATH="${ENV_BIN}:\$PATH"
cd "${COMFY_DIR}" || exit 1
exec "${ENV_PY}" ${COMFY_ARGS[*]}
EOF
  if ! chmod +x "${STARTD_FILE}"; then
    die_action "chmod +x ${STARTD_FILE} 失败"
    return 1
  fi
  log "已写入 ${STARTD_FILE}；容器平台重启实例后生效"
  return 0
}

autostart_write() {
  if [[ -z "${ACCESS_MODE}" ]]; then
    ACCESS_MODE="$(current_access_mode)"
  fi
  if (( CPU_MODE == 0 )) && gpu_hardware_present && ! gpu_driver_ready; then
    if ask_yesno "GPU 驱动未就绪，按 CPU 模式写入启动参数？" n; then
      CPU_MODE=1
    else
      warn "将写入 GPU 启动参数；服务可能无法启动"
    fi
  fi
  build_comfy_args
  if systemd_present; then
    write_systemd_unit || return 1
  elif startd_exists; then
    write_startd_script || return 1
  else
    warn "未检测到 systemd 或 /start.d；跳过自启配置"
    return 0
  fi
  return 0
}

autostart_remove() {
  if ! ask_yesno "删除 ComfyUI 开机自启配置？" n; then
    log "已取消"
    return 0
  fi
  if unit_exists; then
    backup_file "${UNIT_FILE}" >/dev/null || true
    systemctl disable --now "${SERVICE_NAME}" >/dev/null 2>&1 || true
    rm -f "${UNIT_FILE}" || { die_action "删除 ${UNIT_FILE} 失败"; return 1; }
    systemctl daemon-reload >/dev/null 2>&1 || true
    log "已删除 systemd 服务"
  fi
  if startd_configured; then
    backup_file "${STARTD_FILE}" >/dev/null || true
    rm -f "${STARTD_FILE}" || { die_action "删除 ${STARTD_FILE} 失败"; return 1; }
    log "已删除 /start.d 自启脚本"
  fi
  return 0
}

service_restart() {
  if unit_exists && systemd_present; then
    if ! systemctl restart "${SERVICE_NAME}"; then
      die_action "重启 ${SERVICE_NAME} 失败；查看 journalctl -u ${SERVICE_NAME}"
      return 1
    fi
    log "服务已重启"
    return 0
  fi
  if startd_configured; then
    warn "容器平台无 systemd；重启实例后由 ${STARTD_FILE} 接管"
    return 0
  fi
  warn "服务尚未配置"
  return 0
}

service_action() {
  local action
  action="$(ask_input_def "动作" v_action "status")" || return 1
  if ! unit_exists || ! systemd_present; then
    if startd_configured; then
      warn "容器平台无 systemd；请重启实例，或手动执行 ${STARTD_FILE}"
      return 0
    fi
    warn "服务尚未配置"
    return 0
  fi
  case "${action}" in
    start)   systemctl start "${SERVICE_NAME}" ;;
    stop)    systemctl stop "${SERVICE_NAME}" ;;
    restart) systemctl restart "${SERVICE_NAME}" ;;
    status)  systemctl status "${SERVICE_NAME}" --no-pager || true ;;
  esac
  local rc=$?
  if [[ "${action}" == "status" ]]; then
    return 0
  fi
  if (( rc != 0 )); then
    die_action "systemctl ${action} ${SERVICE_NAME} 失败"
    return 1
  fi
  return 0
}

wait_http_up() {
  local i
  for (( i = 0; i < 60; i++ )); do
    if port_listening && curl -fsS --max-time 3 "http://127.0.0.1:${PORT}/" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

show_access_info() {
  local mode ip
  mode="$(current_access_mode)"
  ip="$(public_ip || true)"
  printf '  访问方式：%s\n' "${mode}"
  if [[ "${mode}" == "listen" ]]; then
    printf '  公网地址：http://%s:%s\n' "${ip:-<公网IP>}" "${PORT}"
    printf '  备用隧道：ssh -N -L %s:127.0.0.1:%s root@%s\n' "${PORT}" "${PORT}" "${ip:-<公网IP>}"
  else
    printf '  本地隧道：ssh -N -L %s:127.0.0.1:%s root@%s\n' "${PORT}" "${PORT}" "${ip:-<公网IP>}"
    printf '  然后打开：http://127.0.0.1:%s\n' "${PORT}"
  fi
  printf '  说明：以上为出口 IP；若平台使用独立 EIP，以控制台为准。\n'
  printf '  云安全组：需放行 %s/tcp，来源建议限制为你的 IP/32\n' "${PORT}"
  printf '  Manager：listen 模式下界面装插件会被拦截；需要时菜单 7 切隧道\n'
}

# ============ 终检 ============
V_OK=0
V_WARN=0
V_FAIL=0
check_ok()   { printf '%s✓%s %s\n' "${C_G}" "${C_0}" "$*"; V_OK=$((V_OK+1)); }
check_warn() { printf '%s!%s %s\n' "${C_Y}" "${C_0}" "$*"; V_WARN=$((V_WARN+1)); }
check_fail() { printf '%s✗%s %s\n' "${C_R}" "${C_0}" "$*"; V_FAIL=$((V_FAIL+1)); }

verify_all() {
  local out ver cuda avail cv major
  sync_runtime_mode
  V_OK=0; V_WARN=0; V_FAIL=0
  printf '\n%sComfyUI 终检%s\n' "${C_B}" "${C_0}"
  ui_sep

  if (( CPU_MODE )); then
    check_warn "CPU 测试模式（无 GPU 或已显式选择）"
  else
    if gpu_driver_ready; then
      cv="$(gpu_cuda_version)"; major="$(cuda_major "${cv}")"
      if [[ -n "${major}" ]] && (( major >= 13 )); then
        check_ok "GPU $(gpu_name)；驱动 $(gpu_driver_version)；CUDA ${cv}"
      else
        check_fail "GPU CUDA ${cv:-未知} < 13.0（驱动 <580）"
      fi
    else
      check_fail "nvidia-smi 不可用"
    fi
  fi

  if miniforge_ok; then check_ok "Miniforge：$("${CONDA_BIN}" --version 2>/dev/null || true)"
  else check_fail "Miniforge 未安装"; fi

  if env_ok; then check_ok "Python 环境：$(env_python_version)"
  else check_fail "comfyui 环境未创建"; fi

  if comfy_ok; then check_ok "ComfyUI：$(comfy_commit)"
  else check_fail "ComfyUI 未克隆"; fi

  if env_ok; then
    local mgr_ver
    out="$(torch_report)"
    if [[ -n "${out}" ]]; then
      parse_torch_report "${out}"
      if (( CPU_MODE )); then
        check_ok "PyTorch ${ver}（CPU）"
      elif [[ "$(cuda_major "${cuda}")" == "13" && "${avail}" == "True" ]]; then
        check_ok "PyTorch ${ver}；CUDA ${cuda}；cuda.is_available=True"
      else
        check_fail "PyTorch ${ver:-未知}；CUDA ${cuda:-无}；cuda.is_available=${avail:-未知}"
      fi
    else
      check_fail "PyTorch import 失败"
    fi
    mgr_ver="$(pip_version comfyui_manager)"
    if [[ -n "${mgr_ver}" ]]; then
      check_ok "ComfyUI-Manager：${mgr_ver}"
    else
      check_warn "comfyui_manager 未安装（重跑菜单 5 的依赖安装）"
    fi
  fi

  if unit_exists && systemd_present; then
    if service_active; then check_ok "systemd 服务 active"
    else check_fail "systemd 服务未运行"; fi
    if service_enabled; then check_ok "systemd 开机自启 enabled"
    else check_warn "systemd 开机自启未启用"; fi
  elif startd_configured; then
    check_ok "/start.d 自启脚本已配置"
  else
    check_fail "未配置开机自启"
  fi

  if port_listening; then check_ok "端口 ${PORT} 正在监听"
  else check_fail "端口 ${PORT} 未监听"; fi

  if curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/" >/dev/null 2>&1; then
    check_ok "HTTP 127.0.0.1:${PORT} 可访问"
  else
    check_fail "HTTP 127.0.0.1:${PORT} 不可访问"
  fi

  if [[ "$(current_access_mode)" == "listen" ]]; then
    if ! fw_installed; then
      check_warn "UFW 未安装；放行 ${PORT} 只能靠云安全组"
    elif ! fw_active; then
      check_warn "UFW 未启用；放行 ${PORT} 只能靠云安全组"
    elif fw_has_port; then
      check_ok "UFW 已放行 ${PORT}/tcp"
    else
      check_fail "UFW active 但未放行 ${PORT}/tcp"
    fi
  fi

  ui_sep
  printf '结果：%s%d 绿%s / %s%d 黄%s / %s%d 红%s\n' \
    "${C_G}" "${V_OK}" "${C_0}" "${C_Y}" "${V_WARN}" "${C_0}" "${C_R}" "${V_FAIL}" "${C_0}"
  show_access_info
  (( V_FAIL == 0 ))
}

# ============ 标准部署 ============
step_banner() { printf '\n%s== 步骤 %s：%s ==%s\n' "${C_B}" "$1" "$2" "${C_0}"; }

preflight_deploy() {
  local gb
  log "环境：$(distro_pretty)；$(uname -m)"
  printf '\n%s默认访问方式为 --listen 0.0.0.0:%s，ComfyUI 无鉴权。%s\n' "${C_Y}" "${PORT}" "${C_0}"
  printf '请确保已在云平台创建 Snapshot，并准备好在安全组放行 %s/tcp。\n' "${PORT}"
  if ! ask_yesno "已创建 Snapshot 并知晓公网暴露风险？" n; then
    die_action "已取消部署"
    return 1
  fi

  gb="$(disk_avail_gb)"
  if [[ -z "${gb}" ]]; then
    warn "无法读取磁盘剩余空间"
  elif (( gb < 10 )); then
    die_action "磁盘可用 ${gb}GB，低于 10GB 安全线，已中止"
    return 1
  elif (( gb < 30 )); then
    warn "磁盘可用 ${gb}GB，低于建议的 30GB；模型下载前请扩容"
    if ! ask_yesno "仍然继续？" n; then
      die_action "已取消"
      return 1
    fi
  else
    log "磁盘可用 ${gb}GB"
  fi

  if ! command -v curl >/dev/null 2>&1; then
    warn "curl 未安装，跳过镜像预检（菜单 2 会安装基础包）"
    return 0
  fi
  mirror_check "清华 Miniforge" "${MINIFORGE_URL}" || {
    if ! ask_yesno "Miniforge 镜像不可达，仍继续？" n; then return 1; fi
  }
  mirror_check "清华 conda-forge" "${CONDA_MIRROR}/conda-forge/linux-64/repodata.json" || {
    if ! ask_yesno "conda 镜像不可达，仍继续？" n; then return 1; fi
  }
  mirror_check "阿里 PyPI" "${PIP_MIRROR}" || {
    if ! ask_yesno "pip 镜像不可达，仍继续？" n; then return 1; fi
  }
  return 0
}

do_standard_deploy() {
  local rc=0
  step_banner 1 "预检：发行版、快照、磁盘、镜像"
  preflight_deploy || { warn "标准部署已中止"; return 1; }

  step_banner 2 "基础工具与底层库"
  install_base_packages || { warn "标准部署已中止"; return 1; }

  step_banner 3 "GPU 与驱动"
  detect_or_install_driver || rc=$?
  if (( rc == 2 )); then
    warn "驱动已安装：请执行 reboot，重启后重新运行本脚本继续"
    return 0
  fi
  if (( rc != 0 )); then
    warn "GPU/驱动步骤失败，标准部署已中止"
    return 1
  fi
  if (( CPU_MODE )); then
    log "CPU 测试模式（不安装 CUDA 版 PyTorch）"
  fi

  step_banner 4 "Miniforge 与 conda 镜像"
  miniforge_install || { warn "标准部署已中止"; return 1; }

  step_banner 5 "Python 3.13 环境"
  env_create "3.13" || { warn "标准部署已中止"; return 1; }

  step_banner 6 "ComfyUI 代码"
  comfy_clone_or_pull || { warn "标准部署已中止"; return 1; }

  step_banner 7 "pip 镜像、PyTorch 与依赖"
  pip_config_write || { warn "标准部署已中止"; return 1; }
  torch_install || { warn "标准部署已中止"; return 1; }
  requirements_install || { warn "标准部署已中止"; return 1; }

  step_banner 8 "冒烟测试"
  smoke_test || { warn "标准部署已中止"; return 1; }

  step_banner 9 "访问方式：默认 listen 0.0.0.0:${PORT}"
  ACCESS_MODE="listen"
  ensure_fw_8188 || warn "UFW 放行失败；公网访问可能不可用"

  step_banner 10 "开机自启"
  autostart_write || { warn "自启配置失败"; return 1; }
  if unit_exists && systemd_present; then
    if wait_http_up; then
      log "服务已在 127.0.0.1:${PORT} 响应"
    else
      warn "服务 60 秒内未响应；查看 journalctl -u ${SERVICE_NAME} -n 100"
    fi
  elif startd_configured; then
    log "容器平台：请重启实例，${STARTD_FILE} 会自动拉起 ComfyUI；重启后运行菜单 9 终检"
  fi

  step_banner 11 "终检"
  if ! verify_all; then
    warn "终检存在红项；按上方提示修复后可重跑终检"
  fi
  printf '\n%sComfyUI 标准部署完成%s\n' "${C_B}" "${C_0}"
  return 0
}

# ============ 菜单：检查 ============
status_menu() {
  scr_clear
  ui_rule
  printf '%s ComfyUI 环境检查%s\n' "${C_B}" "${C_0}"
  ui_sep
  printf '系统：%s\n' "$(distro_pretty)"
  printf '\n[GPU]\n'
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi 2>&1 || true
  else
    printf 'nvidia-smi 未安装\n'
  fi
  printf '\n[CUDA Toolkit]\n'
  if command -v nvcc >/dev/null 2>&1; then nvcc --version 2>&1 || true; else printf 'nvcc 未安装\n'; fi
  printf '\n[磁盘 / 内存]\n'
  df -h "${ROOT_HOME}" 2>&1 || true
  free -h 2>&1 || true
  printf '\n[Miniforge / Python]\n'
  if miniforge_ok; then "${CONDA_BIN}" --version 2>&1 || true; else printf 'Miniforge 未安装\n'; fi
  printf '环境：%s\n' "$(env_python_version)"
  if miniforge_ok; then HOME="${ROOT_HOME}" "${CONDA_BIN}" env list 2>&1 || true; fi
  printf '\n[ComfyUI]\n'
  if comfy_ok; then
    git -C "${COMFY_DIR}" log -1 --oneline 2>&1 || true
    printf '分支：%s\n' "$(git -C "${COMFY_DIR}" branch --show-current 2>/dev/null || true)"
  else
    printf '未安装\n'
  fi
  printf '\n[PyTorch]\n'
  printf 'torch：%s\n' "$(pip_version torch)"
  printf 'torchvision：%s\n' "$(pip_version torchvision)"
  printf 'comfyui_manager：%s\n' "$(pip_version comfyui_manager)"
  printf '\n[服务 / 端口 / 防火墙]\n'
  if unit_exists && systemd_present; then
    systemctl status "${SERVICE_NAME}" --no-pager 2>&1 || true
  elif startd_configured; then
    printf '/start.d 自启脚本已配置\n'
  else
    printf '服务未配置\n'
  fi
  ss -tlnp 2>&1 | grep -E ":${PORT}\b|State" || true
  ufw status 2>&1 || true
  printf '\n[镜像连通性]\n'
  mirror_check "清华 Miniforge" "${MINIFORGE_URL}" || true
  mirror_check "清华 conda-forge" "${CONDA_MIRROR}/conda-forge/linux-64/repodata.json" || true
  mirror_check "阿里 PyPI" "${PIP_MIRROR}" || true
  ui_sep
  page_wait "按回车返回主菜单…"
}

# ============ 菜单：基础包与镜像 ============
base_menu() {
  local reply
  while :; do
    scr_clear
    ui_rule
    printf '%s 基础工具与镜像%s\n' "${C_B}" "${C_0}"
    ui_sep
    ui_kv "基础包" "$(base_missing_summary)"
    ui_sep
    ui_item 1 "安装缺失的基础包"
    ui_item 2 "配置 conda 清华镜像"
    ui_item 3 "配置 pip 阿里镜像"
    ui_item 4 "测试镜像连通性"
    ui_quit
    ui_sep
    ask_menu "选择" 4
    reply="${UI_REPLY}"
    case "${reply}" in
      0) return 0 ;;
      1) act install_base_packages || true; scr_pause ;;
      2) act condarc_write || true; scr_pause ;;
      3) act pip_config_write || true; scr_pause ;;
      4) act mirror_check_all || true; scr_pause ;;
    esac
  done
}

mirror_check_all() {
  mirror_check "清华 Miniforge" "${MINIFORGE_URL}" || true
  mirror_check "清华 conda-forge" "${CONDA_MIRROR}/conda-forge/linux-64/repodata.json" || true
  mirror_check "阿里 PyPI" "${PIP_MIRROR}" || true
  mirror_check "清华 PyPI" "${PIP_MIRROR_FALLBACK}" || true
  mirror_check "PyTorch 官方 CPU 索引" "${CPU_INDEX}/torch/" || true
  return 0
}

# ============ 菜单：GPU 驱动 ============
gpu_menu() {
  local reply
  while :; do
    scr_clear
    ui_rule
    printf '%s GPU 驱动与 CUDA%s\n' "${C_B}" "${C_0}"
    ui_sep
    if gpu_hardware_present; then
      ui_kv "GPU" "$(gpu_name)"
      ui_kv "驱动" "$(gpu_driver_version)"
      ui_kv "CUDA" "$(gpu_cuda_version)"
    else
      ui_kv "GPU" "$(ui_no '未检测到')"
    fi
    ui_sep
    ui_item 1 "查看 nvidia-smi / nvcc"
    ui_item 2 "安装或升级驱动"
    ui_item 3 "安装 cuda-toolkit（可选）"
    ui_item 4 "重启服务器"
    ui_quit
    ui_sep
    ask_menu "选择" 4
    reply="${UI_REPLY}"
    case "${reply}" in
      0) return 0 ;;
      1) act gpu_status_page || true ;;
      2) act driver_install_action || true; scr_pause ;;
      3) act cuda_toolkit_install || true; scr_pause ;;
      4) act reboot_now || true ;;
    esac
  done
}

gpu_status_page() {
  nvidia-smi 2>&1 || true
  printf '\n'
  nvcc --version 2>&1 || true
  page_wait "按回车返回…"
}

# ============ 菜单：Miniforge / Python ============
env_menu() {
  local reply ver
  while :; do
    scr_clear
    ui_rule
    printf '%s Miniforge 与 Python 环境%s\n' "${C_B}" "${C_0}"
    ui_sep
    ui_kv "Miniforge" "$(miniforge_ok && printf '已安装' || printf '未安装')"
    ui_kv "Python" "$(env_python_version)"
    ui_kv "conda 镜像" "$(grep -qF "${CONDA_MIRROR}" "${ROOT_HOME}/.condarc" 2>/dev/null && printf '清华' || printf '未配置')"
    ui_sep
    ui_item 1 "安装 / 修复 Miniforge"
    ui_item 2 "配置 conda 清华镜像"
    ui_item 3 "创建 Python 环境（3.13 默认）"
    ui_item 4 "重建 Python 环境"
    ui_item 5 "查看 conda 环境"
    ui_quit
    ui_sep
    ask_menu "选择" 5
    reply="${UI_REPLY}"
    case "${reply}" in
      0) return 0 ;;
      1) act miniforge_install || true; scr_pause ;;
      2) act condarc_write || true; scr_pause ;;
      3) ver="$(ask_input_def "Python 版本" v_pyver "${PY_VER}")" || { warn "输入中断"; return 1; }
         act env_create "${ver}" || true; scr_pause ;;
      4) act env_recreate || true; scr_pause ;;
      5) act env_show || true ;;
    esac
  done
}

env_show() {
  if miniforge_ok; then
    "${CONDA_BIN}" env list 2>&1 || true
  else
    printf 'Miniforge 未安装\n'
  fi
  page_wait "按回车返回…"
}

# ============ 菜单：ComfyUI / PyTorch ============
comfy_menu() {
  local reply
  while :; do
    scr_clear
    ui_rule
    printf '%s ComfyUI 与 PyTorch%s\n' "${C_B}" "${C_0}"
    ui_sep
    ui_kv "ComfyUI" "$(comfy_commit)"
    ui_kv "torch" "$(pip_version torch)"
    ui_kv "torchvision" "$(pip_version torchvision)"
    ui_kv "Manager" "$(pip_version comfyui_manager)"
    ui_sep
    ui_item 1 "克隆 / 更新 ComfyUI"
    ui_item 2 "配置 pip 阿里镜像"
    ui_item 3 "安装 / 修复 PyTorch"
    ui_item 4 "安装 / 修复 requirements"
    ui_item 5 "完整更新（代码 + 依赖 + 重启）"
    ui_item 6 "查看版本"
    ui_quit
    ui_sep
    ask_menu "选择" 6
    reply="${UI_REPLY}"
    case "${reply}" in
      0) return 0 ;;
      1) act comfy_clone_or_pull || true; scr_pause ;;
      2) act pip_config_write || true; scr_pause ;;
      3) act torch_install || true; scr_pause ;;
      4) act requirements_install || true; scr_pause ;;
      5) act comfy_update || true; scr_pause ;;
      6) act comfy_versions || true ;;
    esac
  done
}

comfy_versions() {
  printf 'ComfyUI：%s\n' "$(comfy_commit)"
  printf 'Python：%s\n' "$(env_python_version)"
  printf 'torch：%s\n' "$(pip_version torch)"
  printf 'torchvision：%s\n' "$(pip_version torchvision)"
  printf 'comfyui_manager：%s\n' "$(pip_version comfyui_manager)"
  page_wait "按回车返回…"
}

comfy_update() {
  local before after
  if ! comfy_ok || ! env_ok; then
    die_action "ComfyUI 或环境未就绪"
    return 1
  fi
  before="$(git -C "${COMFY_DIR}" rev-parse --short HEAD 2>/dev/null || true)"
  if ! git -C "${COMFY_DIR}" pull --ff-only; then
    warn "git pull 失败；请先处理本地改动或分支分叉（git -C ${COMFY_DIR} status）"
    return 1
  fi
  after="$(git -C "${COMFY_DIR}" rev-parse --short HEAD 2>/dev/null || true)"
  log "ComfyUI：${before} -> ${after:-未知}"
  requirements_install || return 1
  service_restart || return 1
  warn "若服务异常，可回滚：git -C ${COMFY_DIR} checkout ${before} 后重装 requirements 并重启"
  return 0
}

# ============ 菜单：模型 ============
declare -a MODEL_DIRS=(checkpoints diffusion_models text_encoders vae loras controlnet upscale_models)

model_dirs_show() {
  local d base
  for d in "${MODEL_DIRS[@]}"; do
    base="${COMFY_DIR}/models/${d}"
    mkdir -p "${base}" || { die_action "创建 ${base} 失败"; return 1; }
    printf '%-20s %s\n' "${d}" "$(du -sh "${base}" 2>/dev/null | awk '{print $1}')"
  done
  return 0
}

download_modelscope() {
  local repo="$1" file="$2" dir="$3"
  if [[ ! -x "${ENV_BIN}/modelscope" ]]; then
    log "安装 modelscope"
    if ! env_py -m pip install -U modelscope; then
      die_action "modelscope 安装失败"
      return 1
    fi
  fi
  log "ModelScope 下载 ${repo}/${file}"
  if ! HOME="${ROOT_HOME}" "${ENV_BIN}/modelscope" download --model "${repo}" "${file}" --local_dir "${dir}"; then
    die_action "ModelScope 下载失败"
    return 1
  fi
  ls -lh "${dir}/${file}" 2>/dev/null || true
  return 0
}

download_hf() {
  local repo="$1" file="$2" dir="$3" cli
  if ! env_py -m pip show huggingface_hub >/dev/null 2>&1; then
    log "安装 huggingface_hub[cli] 与 hf_transfer"
    if ! env_py -m pip install -U "huggingface_hub[cli]" hf_transfer; then
      die_action "huggingface_hub 安装失败"
      return 1
    fi
  fi
  cli="${ENV_BIN}/hf"
  [[ -x "${cli}" ]] || cli="${ENV_BIN}/huggingface-cli"
  log "hf-mirror 下载 ${repo}/${file}"
  if ! HF_ENDPOINT="https://hf-mirror.com" HF_HUB_ENABLE_HF_TRANSFER=1 \
       HOME="${ROOT_HOME}" "${cli}" download "${repo}" "${file}" --local-dir "${dir}"; then
    die_action "hf-mirror 下载失败"
    return 1
  fi
  ls -lh "${dir}/${file}" 2>/dev/null || true
  return 0
}

download_aria2() {
  local url="$1" dir="$2" file="$3"
  if ! command -v aria2c >/dev/null 2>&1; then
    die_action "aria2c 未安装（基础包包含 aria2）"
    return 1
  fi
  log "aria2c 下载 ${file}"
  if ! aria2c -x 16 -s 16 -c -d "${dir}" -o "${file}" "${url}"; then
    die_action "aria2c 下载失败"
    return 1
  fi
  ls -lh "${dir}/${file}" 2>/dev/null || true
  return 0
}

copy_extra_model_paths() {
  local src="${COMFY_DIR}/extra_model_paths.yaml.example"
  local dst="${COMFY_DIR}/extra_model_paths.yaml"
  if [[ -f "${dst}" ]]; then
    warn "${dst} 已存在，未覆盖"
    return 0
  fi
  if [[ ! -f "${src}" ]]; then
    die_action "未找到模板 ${src}"
    return 1
  fi
  cp "${src}" "${dst}" || { die_action "复制模板失败"; return 1; }
  log "已复制 ${dst}；按数据盘路径编辑后重启服务"
  return 0
}

model_menu() {
  local reply repo file dir url
  while :; do
    scr_clear
    ui_rule
    printf '%s 模型目录与下载%s\n' "${C_B}" "${C_0}"
    ui_sep
    ui_item 1 "创建 / 查看模型目录"
    ui_item 2 "下载 SDXL Base（ModelScope）"
    ui_item 3 "下载 SDXL Base（hf-mirror）"
    ui_item 4 "aria2c 直链下载"
    ui_item 5 "自定义 ModelScope 仓库/文件"
    ui_item 6 "复制 extra_model_paths 模板"
    ui_quit
    ui_sep
    ask_menu "选择" 6
    reply="${UI_REPLY}"
    case "${reply}" in
      0) return 0 ;;
      1) act model_dirs_show || true; scr_pause ;;
      2) if ask_yesno "下载 SDXL Base（约 6.9GB）？" n; then
           act download_modelscope "AI-ModelScope/stable-diffusion-xl-base-1.0" "sd_xl_base_1.0.safetensors" "${COMFY_DIR}/models/checkpoints" || true
         fi
         scr_pause ;;
      3) if ask_yesno "下载 SDXL Base（约 6.9GB）？" n; then
           act download_hf "stabilityai/stable-diffusion-xl-base-1.0" "sd_xl_base_1.0.safetensors" "${COMFY_DIR}/models/checkpoints" || true
         fi
         scr_pause ;;
      4) url="$(ask_input "下载直链" v_nonempty)" || { warn "输入中断"; return 1; }
         file="$(ask_input "文件名" v_nonempty)" || { warn "输入中断"; return 1; }
         dir="$(ask_input_def "目标目录" v_dir "${COMFY_DIR}/models/checkpoints")" || { warn "输入中断"; return 1; }
         act download_aria2 "${url}" "${dir}" "${file}" || true; scr_pause ;;
      5) repo="$(ask_input "ModelScope 仓库（owner/name）" v_nonempty)" || { warn "输入中断"; return 1; }
         file="$(ask_input "文件名" v_nonempty)" || { warn "输入中断"; return 1; }
         dir="$(ask_input_def "目标目录" v_dir "${COMFY_DIR}/models/checkpoints")" || { warn "输入中断"; return 1; }
         act download_modelscope "${repo}" "${file}" "${dir}" || true; scr_pause ;;
      6) act copy_extra_model_paths || true; scr_pause ;;
    esac
  done
}

# ============ 菜单：访问方式 ============
access_menu() {
  local reply
  while :; do
    scr_clear
    ui_rule
    printf '%s 远程访问与防火墙%s\n' "${C_B}" "${C_0}"
    ui_sep
    ui_kv "当前方式" "$(current_access_mode)"
    ui_kv "UFW" "$(fw_active && printf 'active' || printf 'inactive/未安装')"
    ui_kv "8188" "$(fw_has_port && printf '已放行' || printf '未放行')"
    ui_sep
    printf '  %s默认监听 0.0.0.0:%s，无鉴权；公网直连风险自负。%s\n' "${C_Y}" "${PORT}" "${C_0}"
    ui_sep
    ui_item 1 "查看访问地址与隧道命令"
    ui_item 2 "设置为监听 0.0.0.0:${PORT}（公网直连）"
    ui_item 3 "设置为仅回环 + SSH 隧道"
    ui_item 4 "重启服务使配置生效"
    ui_quit
    ui_sep
    ask_menu "选择" 4
    reply="${UI_REPLY}"
    case "${reply}" in
      0) return 0 ;;
      1) act access_info_page || true; scr_pause ;;
      2) ACCESS_MODE="listen"; act apply_access_mode || true; scr_pause ;;
      3) ACCESS_MODE="tunnel"; act apply_access_mode || true; scr_pause ;;
      4) act service_restart || true; scr_pause ;;
    esac
  done
}

access_info_page() {
  show_access_info
  printf '\n'
  ufw status 2>&1 || true
  page_wait "按回车返回…"
}

apply_access_mode() {
  if [[ "${ACCESS_MODE}" == "listen" ]]; then
    ensure_fw_8188 || warn "UFW 放行失败"
  fi
  sync_runtime_mode
  autostart_write || return 1
  show_access_info
  return 0
}

# ============ 菜单：自启 ============
autostart_method() {
  if systemd_present; then
    printf 'systemd'
  elif startd_exists; then
    printf '/start.d'
  else
    printf '无（未检测到）'
  fi
}

service_summary() {
  if unit_exists && systemd_present; then
    local st
    st="$(systemctl is-active "${SERVICE_NAME}" 2>/dev/null || true)"
    printf '%s' "${st:-unknown}"
  elif startd_configured; then
    printf '/start.d 已配置'
  else
    printf '未配置'
  fi
}

autostart_summary() {
  if service_enabled; then
    printf 'enabled'
  elif unit_exists || { startd_configured; }; then
    printf '未启用'
  else
    printf '未配置'
  fi
}

autostart_menu() {
  local reply
  while :; do
    scr_clear
    ui_rule
    printf '%s 开机自启%s\n' "${C_B}" "${C_0}"
    ui_sep
    ui_kv "方式" "$(autostart_method)"
    ui_kv "服务" "$(service_summary)"
    ui_kv "自启" "$(autostart_summary)"
    ui_kv "CPU 参数" "$(config_has_cpu && printf '--cpu' || printf 'GPU')"
    ui_sep
    ui_item 1 "写入 / 更新自启配置（当前访问方式）"
    ui_item 2 "写入 systemd 服务"
    ui_item 3 "写入 /start.d 脚本"
    ui_item 4 "启动 / 停止 / 重启服务"
    ui_item 5 "切换 CPU / GPU 启动参数"
    ui_item 6 "删除自启配置"
    ui_quit
    ui_sep
    ask_menu "选择" 6
    reply="${UI_REPLY}"
    case "${reply}" in
      0) return 0 ;;
      1) act autostart_write || true; scr_pause ;;
      2) act write_systemd_unit || true; scr_pause ;;
      3) act write_startd_script || true; scr_pause ;;
      4) act service_action || true; scr_pause ;;
      5) act toggle_cpu_mode || true; scr_pause ;;
      6) act autostart_remove || true; scr_pause ;;
    esac
  done
}

toggle_cpu_mode() {
  if config_has_cpu; then
    CPU_MODE=0
    log "切换为 GPU 启动参数"
  else
    CPU_MODE=1
    log "切换为 CPU 启动参数（--cpu）"
  fi
  ACCESS_MODE="$(current_access_mode)"
  build_comfy_args
  if unit_exists; then
    write_systemd_unit || return 1
  elif startd_configured; then
    write_startd_script || return 1
  else
    warn "尚未配置自启，先在菜单 8 写入"
  fi
  return 0
}

# ============ 菜单：终检与维护 ============
verify_menu() {
  local reply
  while :; do
    scr_clear
    ui_rule
    printf '%s 终检与维护%s\n' "${C_B}" "${C_0}"
    ui_sep
    ui_item 1 "完整终检"
    ui_item 2 "更新 ComfyUI 与依赖"
    ui_item 3 "清理 pip / conda / journal 缓存"
    ui_item 4 "查看服务日志"
    ui_quit
    ui_sep
    ask_menu "选择" 4
    reply="${UI_REPLY}"
    case "${reply}" in
      0) return 0 ;;
      1) act verify_all || true; page_wait "按回车返回…" ;;
      2) act comfy_update || true; scr_pause ;;
      3) act cache_clean || true; scr_pause ;;
      4) act show_logs || true ;;
    esac
  done
}

cache_clean() {
  local size
  size="$(du -sh "${ROOT_HOME}/.cache/pip" 2>/dev/null | awk '{print $1}')"
  printf 'pip 缓存：%s\n' "${size:-未知}"
  if ask_yesno "清理 pip 缓存？" n; then
    env_py -m pip cache purge 2>/dev/null || warn "pip cache purge 失败"
  fi
  if ask_yesno "清理 conda 包缓存？" n; then
    HOME="${ROOT_HOME}" "${CONDA_BIN}" clean -a -y 2>/dev/null || warn "conda clean 失败"
  fi
  if systemd_present && ask_yesno "只保留最近 7 天 journal 日志（影响全系统日志）？" n; then
    journalctl --vacuum-time=7d 2>/dev/null || warn "journalctl vacuum 失败"
  fi
  return 0
}

show_logs() {
  if unit_exists && systemd_present; then
    journalctl -u "${SERVICE_NAME}" -n 100 --no-pager 2>&1 || true
  elif startd_exists && [[ -d "${STARTD_DIR}/log" ]]; then
    find "${STARTD_DIR}/log" -maxdepth 1 -type f -name '*comfyui*' -print -exec tail -n 100 {} \; 2>/dev/null || true
  else
    warn "没有可读的服务日志"
  fi
  page_wait "按回车返回…"
}

# ============ 主菜单 ============
gpu_header() {
  if gpu_driver_ready; then
    printf '%s / %s / CUDA %s' "$(gpu_name)" "$(gpu_driver_version)" "$(gpu_cuda_version)"
  elif gpu_hardware_present; then
    printf '%s' "$(ui_no '有 GPU，驱动未就绪 ⚠')"
  else
    printf '%s' "$(ui_no '未检测到 GPU（可用 CPU 测试）')"
  fi
}

service_header() {
  if unit_exists && systemd_present; then
    if service_active; then
      printf '%s' "$(ui_yes 'active')"
    else
      printf '%s' "$(ui_no 'inactive ⚠')"
    fi
    if service_enabled; then printf ' / enabled'; fi
    printf ' / %s' "$(current_access_mode)"
  elif startd_configured; then
    printf '/start.d / %s' "$(current_access_mode)"
  else
    printf '%s' "未配置"
  fi
}

fw_header() {
  if ! fw_installed; then
    printf '%s' "$(ui_no '未安装')"
    return 0
  fi
  if fw_active; then
    if fw_has_port; then printf '%s' "$(ui_yes 'active / 8188 已放行')"
    else printf '%s' "$(ui_no 'active / 8188 未放行 ⚠')"; fi
  else
    printf '%s' "$(ui_no 'inactive')"
  fi
}

draw_main_menu() {
  scr_clear
  ui_rule
  printf '%s ComfyUI 部署 TUI%s %s（原生状态，无项目私有配置）%s\n' \
    "${C_B}" "${C_0}" "${C_D}" "${C_0}"
  ui_sep
  ui_kv "GPU" "$(gpu_header)"
  ui_kv "磁盘" "$(disk_avail_gb) GB 可用"
  ui_kv "Miniforge" "$(miniforge_ok && printf '已安装' || printf '未安装')"
  ui_kv "Python" "$(env_python_version)"
  ui_kv "ComfyUI" "$(comfy_commit)"
  ui_kv "PyTorch" "$(pip_version torch)"
  ui_kv "服务" "$(service_header)"
  ui_kv "访问" "$(current_access_mode):${PORT}"
  ui_kv "UFW" "$(fw_header)"
  ui_sep
  ui_item 0 "ComfyUI 标准部署（按顺序引导全流程）"
  ui_item 1 "环境与依赖检查"
  ui_item 2 "基础工具与镜像"
  ui_item 3 "GPU 驱动与 CUDA"
  ui_item 4 "Miniforge 与 Python 环境"
  ui_item 5 "ComfyUI 与 PyTorch"
  ui_item 6 "模型目录与下载"
  ui_item 7 "远程访问与防火墙"
  ui_item 8 "开机自启"
  ui_item 9 "终检与维护"
  printf '  %sq%s) 退出\n' "${C_R}" "${C_0}"
  ui_sep
}

ask_main() {
  local input
  while :; do
    read -rp "选择 [0-9]（q=退出）: " input || die "输入中断"
    case "${input}" in
      q|Q) MAIN_REPLY="q"; return 0 ;;
      0|1|2|3|4|5|6|7|8|9) MAIN_REPLY="${input}"; return 0 ;;
      *) warn "无效输入：请输入 0-9，或 q 退出" ;;
    esac
  done
}

main() {
  require_root
  require_tty
  require_x86_64
  require_distro
  TMPD="$(mktemp -d /tmp/comfyui-tui.XXXXXX)" || die "创建临时目录失败"
  while :; do
    draw_main_menu
    ask_main
    case "${MAIN_REPLY}" in
      q) break ;;
      0) act do_standard_deploy || true; page_wait "按回车返回主菜单…" ;;
      1) act status_menu || true ;;
      2) act base_menu || true ;;
      3) act gpu_menu || true ;;
      4) act env_menu || true ;;
      5) act comfy_menu || true ;;
      6) act model_menu || true ;;
      7) act access_menu || true ;;
      8) act autostart_menu || true ;;
      9) act verify_menu || true ;;
    esac
  done
  printf '\n%s再见。%s\n' "${C_D}" "${C_0}"
  return 0
}

main "$@"
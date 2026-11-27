#!/usr/bin/env bash
# ComfyUI 部署 TUI · 与 00-tui.sh 并列的第二入口
# 自包含 + 原生状态 + 动作隔离。用法：sudo -i 后 bash <(curl -fsSL .../comfyui-tui.sh)
# 默认访问方式：--listen 0.0.0.0 --port 8188；菜单 7 可切换为仅回环 + SSH 隧道。
# 不保存项目私有状态：GPU/驱动读 nvidia-smi，环境读 miniforge/env，服务读 systemd 或 /start.d，
# 端口读 ss，防火墙读 ufw，ComfyUI 读 git；用户输入的偏好只存在于本次进程。

set -euo pipefail
# 命令替换默认不继承 errexit：开启后顶层命令替换继承 -e；
# act 动作内临时关闭 -e，所有 $(ask_input*) 调用点均须显式接 || return 1 拦截输入中断。（bash >= 4.4）
shopt -s inherit_errexit

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
ROOT_HOME="$(getent passwd root 2>/dev/null | cut -d: -f6)" || ROOT_HOME="/root"
[[ -n "${ROOT_HOME}" ]] || ROOT_HOME="/root"
BK_ROOT="/root/vps-init-backups"
BK_KEEP=20

COMFY_BASE="git curl wget vim build-essential tmux htop ca-certificates ffmpeg libgl1 libglib2.0-0 aria2 nvtop ncdu pciutils iproute2"
MINIFORGE_URL="https://mirrors.tuna.tsinghua.edu.cn/github-release/conda-forge/miniforge/LatestRelease/Miniforge3-Linux-x86_64.sh"
MINIFORGE_FALLBACK="https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh"
CONDA_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/anaconda/cloud"
PIP_MIRROR="https://mirrors.aliyun.com/pypi/simple/"
PIP_MIRROR_FALLBACK="https://pypi.tuna.tsinghua.edu.cn/simple"
CPU_INDEX="https://download.pytorch.org/whl/cpu"
CPU_INDEX_FALLBACK="https://mirror.nju.edu.cn/pytorch/whl/cpu"
LINUXMIRRORS_URL="https://linuxmirrors.cn/main.sh"

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
STARTD_LOG_DIR="${STARTD_DIR}/log"
STARTD_LOG_FILE="${STARTD_LOG_DIR}/comfyui.log"
PORT=8188

# 本次进程内的选择；不落盘
CPU_MODE=0
CPU_MODE_DECIDED=0
ACCESS_MODE=""
PY_VER="3.13"
CONDA_ENV_NAME="comfyui"
CUSTOM_TARGET_SET=0
DRIVER_CHANGED=0
AUTOSTART_CHANGED=0
TMPD=""
UI_REPLY=""
MAIN_REPLY=""
DW=0
declare -a COMFY_ARGS=()
declare -a COMFY_EXTRA_ARGS=()
declare -a CMD_WORDS=()

cleanup() {
  if [[ -n "${TMPD}" && -d "${TMPD}" ]]; then
    rm -rf -- "${TMPD}"
  fi
}
trap cleanup EXIT

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
require_root() { [[ "${EUID}" -eq 0 ]] || die "需要 root 运行，请用：sudo -i 后重跑"; }
require_tty() { [[ -t 0 ]] || die "需要交互终端运行，不支持无人值守"; }
require_x86_64() { [[ "$(uname -m)" == "x86_64" ]] || die "仅支持 x86_64，当前：$(uname -m)"; }

distro_id() { awk -F= '/^ID=/{gsub(/"/,"",$2); print $2; exit}' /etc/os-release 2>/dev/null || true; }
distro_version() { awk -F= '/^VERSION_ID=/{gsub(/"/,"",$2); print $2; exit}' /etc/os-release 2>/dev/null || true; }
distro_pretty() { awk -F= '/^PRETTY_NAME=/{gsub(/"/,"",$2); print $2; exit}' /etc/os-release 2>/dev/null || true; }
distro_major() { local v; v="$(distro_version)"; printf '%s' "${v%%.*}"; }

require_distro() {
  local id major
  id="$(distro_id)"; major="$(distro_major)"
  [[ "${major}" =~ ^[0-9]+$ ]] || major=0
  case "${id}" in
    ubuntu) (( 10#${major} >= 20 )) || die "需要 Ubuntu 20.04+，当前：$(distro_version)" ;;
    debian) (( 10#${major} >= 11 )) || die "需要 Debian 11+，当前：$(distro_version)" ;;
    *) die "仅支持 Debian/Ubuntu，当前：${id:-未知}" ;;
  esac
}

is_ubuntu() { [[ "$(distro_id)" == "ubuntu" ]]; }
is_debian() { [[ "$(distro_id)" == "debian" ]]; }

# 校验器
v_nonempty() { [[ -n "$1" ]] || { printf '不能为空\n' >&2; return 1; }; }
v_pyver() { [[ "$1" =~ ^3\.(12|13)$ ]] || { printf '仅支持 3.12 / 3.13\n' >&2; return 1; }; }
v_action() { [[ "$1" =~ ^(start|stop|restart|status)$ ]] || { printf '仅支持 start/stop/restart/status\n' >&2; return 1; }; }
v_dir() { [[ -d "$1" ]] || { printf '目录不存在：%s\n' "$1" >&2; return 1; }; }
v_pybin() {
  if [[ -x "$1" ]] && "$1" --version >/dev/null 2>&1; then return 0; fi
  printf '可执行 Python 无效：%s\n' "$1" >&2
  return 1
}
v_comfy_dir() { [[ -f "$1/main.py" ]] || { printf '未在该目录找到 main.py：%s\n' "$1" >&2; return 1; }; }

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
run_with_timeout() {
  local secs="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "${secs}" "$@"
  else
    "$@"
  fi
}

apt_run() {
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=60 "$@"
}

apt_clean_archives() {
  apt-get clean >/dev/null 2>&1 || true
}

apt_update_index() {
  log "apt-get update"
  if ! apt_run update; then
    die_action "apt-get update 失败（检查网络与软件源）"
    return 1
  fi
  return 0
}

ensure_cmd() {
  local cmd="$1" pkg="${2:-$1}"
  command -v "${cmd}" >/dev/null 2>&1 && return 0
  warn "缺少命令 ${cmd}（安装包：${pkg}）"
  if ! ask_yesno "现在单独安装 ${pkg}？" y; then
    die_action "缺少 ${cmd}，已取消（也可在菜单 2 安装基础包）"
    return 1
  fi
  apt_update_index || return 1
  if ! apt_run install -y "${pkg}"; then
    die_action "安装 ${pkg} 失败"
    return 1
  fi
  apt_clean_archives
  return 0
}

fetch_file() {
  local url="$1" out="$2" part="${2}.part"
  rm -f -- "${part}"
  if command -v curl >/dev/null 2>&1; then
    if curl -fSL --connect-timeout 15 --speed-limit 1024 --speed-time 30 -o "${part}" "${url}" && [[ -s "${part}" ]]; then
      mv -f -- "${part}" "${out}"
      return 0
    fi
    rm -f -- "${part}"
    return 1
  fi
  if command -v wget >/dev/null 2>&1; then
    if wget --timeout=20 --tries=3 -O "${part}" "${url}" && [[ -s "${part}" ]]; then
      mv -f -- "${part}" "${out}"
      return 0
    fi
    rm -f -- "${part}"
    return 1
  fi
  ensure_cmd curl curl || return 1
  if curl -fSL --connect-timeout 15 --speed-limit 1024 --speed-time 30 -o "${part}" "${url}" && [[ -s "${part}" ]]; then
    mv -f -- "${part}" "${out}"
    return 0
  fi
  rm -f -- "${part}"
  return 1
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
  if ! apt_run install -y "${miss_arr[@]}"; then
    die_action "安装失败：${miss}（检查网络/源后重试）"
    return 1
  fi
  apt_clean_archives
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
  run_with_timeout 5 nvidia-smi -L >/dev/null 2>&1
}
gpu_name() {
  local out
  out="$(run_with_timeout 5 nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null || true)"
  printf '%s' "${out%%$'\n'*}"
}
gpu_driver_version() {
  local out
  out="$(run_with_timeout 5 nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null || true)"
  printf '%s' "${out%%$'\n'*}"
}
gpu_cuda_version() {
  local out
  out="$(run_with_timeout 5 nvidia-smi 2>/dev/null || true)"
  awk '/CUDA Version/ {for (i=1;i<=NF;i++) if ($i=="CUDA" && $(i+1)=="Version:") {print $(i+2); exit}}' <<< "${out}"
}
cuda_major() { local v="$1"; printf '%s' "${v%%.*}"; }

disk_target_dir() {
  if [[ -d "${COMFY_DIR}" ]]; then
    printf '%s' "${COMFY_DIR}"
  else
    printf '%s' "${ROOT_HOME}"
  fi
}

disk_avail_gb() {
  local out target
  target="$(disk_target_dir)"
  out="$(df -Pk "${target}" 2>/dev/null || true)"
  awk 'NR==2 {printf "%d", $4/1024/1024}' <<< "${out}"
}

port_listening() {
  local out hex_port
  local -a tcp_files=()
  if command -v ss >/dev/null 2>&1; then
    out="$(ss -tln 2>/dev/null || true)"
    if [[ -n "${out}" ]]; then
      grep -Eq ":${PORT}([[:space:]]|$)" <<< "${out}" && return 0
      return 1
    fi
  fi
  [[ -r /proc/net/tcp ]] && tcp_files+=(/proc/net/tcp)
  [[ -r /proc/net/tcp6 ]] && tcp_files+=(/proc/net/tcp6)
  (( ${#tcp_files[@]} > 0 )) || return 1
  printf -v hex_port '%04X' "${PORT}"
  awk -v p=":${hex_port}" 'FNR>1 && $4=="0A" && toupper($2) ~ (p "$") {found=1; exit} END{exit !found}' \
    "${tcp_files[@]}" 2>/dev/null
}

fw_installed() { command -v ufw >/dev/null 2>&1; }
fw_raw() { ufw status 2>/dev/null || true; }
fw_added() { ufw show added 2>/dev/null || true; }
fw_active() {
  local out
  out="$(fw_raw)"
  [[ "${out}" == Status:\ active* ]]
}
fw_has_port() {
  local out added
  fw_installed || return 1
  out="$(fw_raw)"
  if [[ "${out}" == Status:\ active* ]]; then
    awk -v p="${PORT}" '
      ($1 == p "/tcp" || $1 == p) && ($2 == "ALLOW" || $2 == "LIMIT") { found=1; exit }
      END { exit !found }
    ' <<< "${out}"
  else
    added="$(fw_added)"
    grep -qE "^ufw (allow|limit) (${PORT}(/tcp)?|from .* to any port ${PORT}( proto tcp)?)\$" <<< "${added}"
  fi
}

systemd_present() {
  [[ -d /run/systemd/system ]] && return 0
  [[ "$(ps -p 1 -o comm= 2>/dev/null || true)" == "systemd" ]]
}
unit_exists() { [[ -f "${UNIT_FILE}" ]]; }
startd_exists() { [[ -d "${STARTD_DIR}" ]]; }
startd_configured() { startd_exists && [[ -x "${STARTD_FILE}" ]]; }
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

tokenize_cmdline() {
  local s="$1" i=0 len="${#1}" ch tok="" in_sq=0 in_dq=0 has_tok=0
  CMD_WORDS=()
  while (( i < len )); do
    ch="${s:i:1}"
    if (( in_sq )); then
      if [[ "${ch}" == "'" ]]; then in_sq=0; else tok+="${ch}"; fi
    elif (( in_dq )); then
      if [[ "${ch}" == '"' ]]; then
        in_dq=0
      elif [[ "${ch}" == '\' ]] && (( i + 1 < len )); then
        i=$((i+1)); tok+="${s:i:1}"
      else
        tok+="${ch}"
      fi
    else
      case "${ch}" in
        [[:space:]])
          if (( has_tok )); then CMD_WORDS+=("${tok}"); tok=""; has_tok=0; fi
          ;;
        "'") in_sq=1; has_tok=1 ;;
        '"') in_dq=1; has_tok=1 ;;
        '\')
          has_tok=1
          if (( i + 1 < len )); then i=$((i+1)); tok+="${s:i:1}"; fi
          ;;
        *) tok+="${ch}"; has_tok=1 ;;
      esac
    fi
    i=$((i+1))
  done
  if (( has_tok )); then CMD_WORDS+=("${tok}"); fi
}

config_file() {
  if systemd_present && [[ -f "${UNIT_FILE}" ]]; then printf '%s' "${UNIT_FILE}"
  elif [[ -f "${STARTD_FILE}" ]]; then printf '%s' "${STARTD_FILE}"
  elif [[ -f "${UNIT_FILE}" ]]; then printf '%s' "${UNIT_FILE}"
  fi
}

config_exec_line() {
  local f="${1:-$(config_file)}"
  [[ -n "${f}" && -f "${f}" ]] || return 0
  if [[ "${f}" == "${UNIT_FILE}" ]]; then
    awk '/^[[:space:]]*ExecStart=/{sub(/^[[:space:]]*ExecStart=[[:space:]]*/, ""); print; exit}' "${f}" 2>/dev/null || true
  else
    awk '
      /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
      /^[[:space:]]*exec[[:space:]]+/ { sub(/^[[:space:]]*exec[[:space:]]+/, ""); print; exit }
      /main\.py([[:space:]]|$)/ { sub(/^[[:space:]]+/, ""); print; exit }
    ' "${f}" 2>/dev/null || true
  fi
}

is_loopback_addr() {
  case "$1" in
    127.0.0.1|::1|localhost|127.0.0.1,::1|::1,127.0.0.1) return 0 ;;
    *) return 1 ;;
  esac
}

current_access_mode() {
  local f line idx=1 n tok next_tok
  f="$(config_file)"
  if [[ -z "${f}" ]]; then printf 'listen'; return 0; fi
  line="$(config_exec_line "${f}")"
  if [[ -z "${line}" ]]; then printf 'tunnel'; return 0; fi
  tokenize_cmdline "${line}"
  n="${#CMD_WORDS[@]}"
  while (( idx < n )); do
    tok="${CMD_WORDS[$idx]}"
    case "${tok}" in
      --listen=*)
        if is_loopback_addr "${tok#--listen=}"; then printf 'tunnel'; else printf 'listen'; fi
        return 0
        ;;
      --listen)
        if (( idx + 1 < n )) && [[ "${CMD_WORDS[$((idx+1))]}" != -* ]]; then
          next_tok="${CMD_WORDS[$((idx+1))]}"
          if is_loopback_addr "${next_tok}"; then printf 'tunnel'; else printf 'listen'; fi
        else
          printf 'listen'
        fi
        return 0
        ;;
    esac
    idx=$((idx+1))
  done
  printf 'tunnel'
}

config_has_cpu() {
  local f line idx=1 tok
  f="$(config_file)"
  [[ -n "${f}" ]] || return 1
  line="$(config_exec_line "${f}")"
  [[ -n "${line}" ]] || return 1
  tokenize_cmdline "${line}"
  while (( idx < ${#CMD_WORDS[@]} )); do
    tok="${CMD_WORDS[$idx]}"
    [[ "${tok}" == "--cpu" ]] && return 0
    idx=$((idx+1))
  done
  return 1
}

parse_config_port() {
  local f line idx=1 n tok val=""
  f="$(config_file)"
  [[ -n "${f}" ]] || return 0
  line="$(config_exec_line "${f}")"
  [[ -n "${line}" ]] || return 0
  tokenize_cmdline "${line}"
  n="${#CMD_WORDS[@]}"
  while (( idx < n )); do
    tok="${CMD_WORDS[$idx]}"
    case "${tok}" in
      --port=*) val="${tok#--port=}"; break ;;
      --port)
        if (( idx + 1 < n )) && [[ "${CMD_WORDS[$((idx+1))]}" != -* ]]; then
          val="${CMD_WORDS[$((idx+1))]}"
        fi
        break
        ;;
    esac
    idx=$((idx+1))
  done
  if [[ "${val}" =~ ^[0-9]+$ ]] && (( 10#${val} >= 1 && 10#${val} <= 65535 )); then
    printf '%s' "$((10#${val}))"
  fi
}

sync_env_bin() {
  ENV_BIN="$(dirname "${ENV_PY}")"
  if [[ "${ENV_PY}" == */envs/*/bin/python ]]; then
    ENV_DIR="${ENV_PY%/bin/python}"
    CONDA_ENV_NAME="$(basename "${ENV_DIR}")"
  fi
}

parse_unit_workdir() {
  local line
  [[ -f "${UNIT_FILE}" ]] || return 0
  line="$(awk '/^[[:space:]]*WorkingDirectory=/{sub(/^[[:space:]]*WorkingDirectory=[[:space:]]*/, ""); print; exit}' "${UNIT_FILE}" 2>/dev/null || true)"
  line="${line#\"}"
  line="${line%\"}"
  printf '%s' "${line}"
}

parse_startd_workdir() {
  local line
  [[ -f "${STARTD_FILE}" ]] || return 0
  line="$(awk '
    /^[[:space:]]*cd[[:space:]]+/ {
      sub(/^[[:space:]]*cd[[:space:]]+/, "")
      sub(/[[:space:]]*(\|\||&&|;).*$/, "")
      sub(/[[:space:]]+$/, "")
      if ( (substr($0,1,1)=="\"" && substr($0,length($0),1)=="\"") ||
           (substr($0,1,1)=="\x27" && substr($0,length($0),1)=="\x27") ) {
        $0 = substr($0, 2, length($0)-2)
      }
      print
      exit
    }
  ' "${STARTD_FILE}" 2>/dev/null || true)"
  printf '%s' "${line}"
}

parse_config_python() {
  local f line py=""
  f="$(config_file)"
  [[ -n "${f}" ]] || return 0
  line="$(config_exec_line "${f}")"
  [[ -n "${line}" ]] || return 0
  tokenize_cmdline "${line}"
  if (( ${#CMD_WORDS[@]} > 0 )); then
    py="${CMD_WORDS[0]}"
  fi
  if [[ -n "${py}" && -x "${py}" ]]; then
    printf '%s' "${py}"
  fi
}

discover_conda_bin() {
  local cand
  for cand in "${CONDA_BIN}" "${ROOT_HOME}/miniforge3/bin/conda" "${ROOT_HOME}/miniconda3/bin/conda" "${ROOT_HOME}/anaconda3/bin/conda" "/opt/conda/bin/conda"; do
    if [[ -x "${cand}" ]]; then
      printf '%s' "${cand}"
      return 0
    fi
  done
  cand="$(command -v conda 2>/dev/null || true)"
  if [[ -n "${cand}" && -x "${cand}" ]]; then
    printf '%s' "${cand}"
    return 0
  fi
  return 1
}

discover_native_context() {
  local d py cbin envline cfg_port
  cfg_port="$(parse_config_port || true)"
  [[ -n "${cfg_port}" ]] && PORT="${cfg_port}"
  (( CUSTOM_TARGET_SET )) && return 0

  # 1. ComfyUI 目录探测：已配置服务 -> 默认路径 -> 常见数据盘路径
  if systemd_present; then
    d="$(parse_unit_workdir)"
    [[ -n "${d}" && -d "${d}" ]] || d="$(parse_startd_workdir)"
  else
    d="$(parse_startd_workdir)"
    [[ -n "${d}" && -d "${d}" ]] || d="$(parse_unit_workdir)"
  fi
  if [[ -n "${d}" && -d "${d}" ]]; then
    COMFY_DIR="${d}"
  elif [[ -f "${ROOT_HOME}/ComfyUI/main.py" || -d "${ROOT_HOME}/ComfyUI/.git" ]]; then
    COMFY_DIR="${ROOT_HOME}/ComfyUI"
  else
    for d in "${ROOT_HOME}/autodl-tmp/ComfyUI" "/workspace/ComfyUI" "/data/ComfyUI" "/opt/ComfyUI"; do
      if [[ -f "${d}/main.py" ]]; then
        COMFY_DIR="${d}"
        break
      fi
    done
  fi

  # 2. conda 二进制探测
  cbin="$(discover_conda_bin || true)"
  if [[ -n "${cbin}" ]]; then
    CONDA_BIN="${cbin}"
    MINIFORGE_DIR="$(dirname "$(dirname "${CONDA_BIN}")")"
    if [[ -x "${MINIFORGE_DIR}/bin/mamba" ]]; then
      MAMBA_BIN="${MINIFORGE_DIR}/bin/mamba"
    fi
  fi

  # 3. Python 解释器探测：已配置服务 -> miniforge 默认 env -> ComfyUI/venv -> 已注册 conda env
  py="$(parse_config_python || true)"
  if [[ -z "${py}" ]]; then
    for d in \
      "${MINIFORGE_DIR}/envs/comfyui/bin/python" \
      "${ROOT_HOME}/miniforge3/envs/comfyui/bin/python" \
      "${COMFY_DIR}/venv/bin/python" \
      "${COMFY_DIR}/.venv/bin/python" \
      "${MINIFORGE_DIR}/envs/comfy/bin/python"
    do
      if [[ -x "${d}" ]]; then
        py="${d}"
        break
      fi
    done
  fi
  if [[ -z "${py}" && -f "${ROOT_HOME}/.conda/environments.txt" ]]; then
    while IFS= read -r envline; do
      [[ -n "${envline}" ]] || continue
      if [[ "${envline}" == */comfyui || "${envline}" == */comfy ]] && [[ -x "${envline}/bin/python" ]]; then
        py="${envline}/bin/python"
        break
      fi
    done < "${ROOT_HOME}/.conda/environments.txt"
  fi
  if [[ -n "${py}" && -x "${py}" ]]; then
    ENV_PY="${py}"
    sync_env_bin
  fi
  return 0
}

env_py() { HOME="${ROOT_HOME}" "${ENV_PY}" "$@"; }
conda_ok() {
  [[ -x "${CONDA_BIN}" ]] && "${CONDA_BIN}" --version >/dev/null 2>&1
}
miniforge_ok() { conda_ok; }
env_ok() {
  [[ -x "${ENV_PY}" ]] && env_py --version >/dev/null 2>&1
}
env_python_version() {
  if env_ok; then env_py --version 2>&1; else printf '未创建/未选择'; fi
}
comfy_present() { [[ -f "${COMFY_DIR}/main.py" ]]; }
comfy_git_ok() { [[ -d "${COMFY_DIR}/.git" ]]; }
comfy_ok() { comfy_present || comfy_git_ok; }
comfy_commit() {
  if comfy_git_ok; then git -C "${COMFY_DIR}" rev-parse --short HEAD 2>/dev/null || true; fi
}
comfy_summary() {
  local c
  if comfy_git_ok; then
    c="$(comfy_commit)"
    printf '%s (%s)' "${c:-git}" "${COMFY_DIR}"
  elif comfy_present; then
    printf '非Git (%s)' "${COMFY_DIR}"
  else
    printf '未安装'
  fi
}
pip_version() {
  local pkg="$1"
  [[ -x "${ENV_PY}" ]] || return 0
  HOME="${ROOT_HOME}" run_with_timeout 20 "${ENV_PY}" -c "import importlib.metadata as m; print(m.version('${pkg}'))" 2>/dev/null || true
}

manager_installed() {
  [[ -n "$(pip_version comfyui_manager)" ]]
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

# ============ 交互原语 ============
# 提示后缀口径（四种，全脚本只允许这四种；中文圆括号，方括号只放输入类别/编号区间）：
#   有默认值  （回车=默认 X）   可留空  （可留空=留空的后果）
#   必填      （必填）          取消/返回（回车=取消）/（回车=返回）/（回车=暂不指定）
ask_yesno() {
  # 显示恒为小写 [y/n]，默认值写在圆括号里；输入大小写不限，只认 y/yes/n/no
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
      *)     printf '%s无效输入：请输入 y 或 n。%s\n' "${C_Y}" "${C_0}" >&2 ;;
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
  # ask_input_def <提示> <校验函数名> <默认值>——空输入取默认值
  local prompt="$1" v="$2" def="$3" val
  while :; do
    read -rp "${prompt}（回车=默认 ${def}）: " val || die "输入中断"
    val="${val:-${def}}"
    if "${v}" "${val}"; then printf '%s' "${val}"; return 0; fi
  done
}

ask_input_opt() {
  # ask_input_opt <提示> <校验函数名> <留空含义>——空输入返回空串（不是默认值）
  local prompt="$1" v="$2" blank="$3" val
  while :; do
    read -rp "${prompt}（可留空=${blank}）: " val || die "输入中断"
    if "${v}" "${val}"; then printf '%s' "${val}"; return 0; fi
  done
}

# ask_menu <提示> <最大编号> [零号含义]：结果写入全局 UI_REPLY（0..max）
# 空回车 = 0（子菜单返回）；非法输入原地重问，不重绘菜单
ask_menu() {
  local prompt="$1" max="$2" zero="${3:-返回主菜单}" input
  while :; do
    read -rp "${prompt} [0-${max}]（回车=${zero}）: " input || die "输入中断"
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

nvidia_repo_configured() {
  grep -rnq "developer.download.nvidia.com/compute/cuda/repos" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null
}

driver_dpkg_owner() {
  local smi real out
  smi="$(command -v nvidia-smi 2>/dev/null || true)"
  [[ -n "${smi}" ]] || return 0
  real="$(readlink -f "${smi}" 2>/dev/null || printf '%s' "${smi}")"
  out="$(dpkg -S "${real}" 2>/dev/null || dpkg -S "${smi}" 2>/dev/null || true)"
  printf '%s' "${out%%:*}"
}

driver_installed_pkg() {
  local out pkg ver st first_driver=""
  out="$(dpkg-query -W -f='${Package}\t${Version}\t${Status}\n' 'nvidia-open' 'cuda-drivers' 'nvidia-driver-*' 2>/dev/null || true)"
  while IFS=$'\t' read -r pkg ver st; do
    [[ "${st}" == *"install ok installed"* ]] || continue
    if [[ "${pkg}" == "nvidia-open" || "${pkg}" == "cuda-drivers" ]]; then
      printf '%s' "${pkg}"
      return 0
    fi
    if [[ -z "${first_driver}" && "${pkg}" =~ ^nvidia-driver-[0-9]+(-open)?$ ]]; then
      first_driver="${pkg}"
    fi
  done <<< "${out}"
  printf '%s' "${first_driver}"
}

apt_pkg_policy() {
  local pkg="$1" out inst cand
  out="$(LC_ALL=C apt-cache policy "${pkg}" 2>/dev/null || true)"
  inst="$(awk '/^[[:space:]]*Installed:/ {print $2; exit}' <<< "${out}")"
  cand="$(awk '/^[[:space:]]*Candidate:/ {print $2; exit}' <<< "${out}")"
  [[ "${inst}" == "(none)" ]] && inst=""
  [[ "${cand}" == "(none)" ]] && cand=""
  printf '%s|%s' "${inst}" "${cand}"
}

driver_flavor_label() {
  local pkg owner
  pkg="$(driver_installed_pkg)"
  if [[ -n "${pkg}" ]]; then
    printf '%s (dpkg)' "${pkg}"
    return 0
  fi
  if gpu_driver_ready; then
    owner="$(driver_dpkg_owner)"
    if [[ -n "${owner}" ]]; then
      printf '%s (dpkg)' "${owner}"
    else
      printf '非dpkg(.run或宿主机透传)'
    fi
    return 0
  fi
  printf '未安装'
}

driver_guard_environment() {
  if ! systemd_present && gpu_driver_ready; then
    printf '\n'
    warn "检测到非 systemd 环境（疑似容器实例），且 nvidia-smi 已就绪。"
    printf '  容器的 GPU 驱动通常由宿主机提供，一般无需在容器内重装。\n\n'
    if ! ask_yesno "仍要在当前环境继续安装/升级驱动？" n; then
      log "已取消驱动操作"
      return 1
    fi
  fi
  if gpu_driver_ready && [[ -z "$(driver_dpkg_owner)" ]]; then
    printf '\n'
    warn "当前 nvidia-smi 不归属于任何 apt/dpkg 包（疑似 .run 手动安装或宿主机透传）。"
    printf '  - 直接通过 apt 安装/升级可能与现有内核模块冲突并破坏驱动。\n'
    printf '  - 继续前建议先确认已在云平台创建 Snapshot。\n\n'
    if ! ask_yesno "确认仍通过 apt 安装/升级驱动？" n; then
      die_action "已中止，避免覆盖非 dpkg 驱动"
      return 1
    fi
  fi
  return 0
}

nvidia_repo_setup() {
  local repo keyring
  if nvidia_repo_configured; then
    log "NVIDIA 官方源已配置（刷新索引）"
    apt_update_index || return 1
    return 0
  fi
  repo="$(nvidia_repo_name)" || { die_action "当前发行版不支持 NVIDIA 官方源"; return 1; }
  keyring="${TMPD}/cuda-keyring.deb"
  if ! fetch_file "https://developer.download.nvidia.com/compute/cuda/repos/${repo}/x86_64/cuda-keyring_1.1-1_all.deb" "${keyring}"; then
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

v_driver_branch() { [[ "$1" =~ ^[0-9]{3}$ ]] || { printf '请输入 3 位数字大版本号（如 580、590）\n' >&2; return 1; }; }
v_choice_three() { [[ "$1" =~ ^(1|2|3)$ ]] || { printf '请输入 1、2 或 3\n' >&2; return 1; }; }

pkg_ver_major() {
  local v="${1#*:}"
  v="${v%%.*}"
  v="${v%%-*}"
  printf '%s' "${v}"
}

driver_apt_install_pkg() {
  local pkg="$1" pol inst cand cand_major
  pol="$(apt_pkg_policy "${pkg}")"
  inst="${pol%%|*}"
  cand="${pol#*|}"
  if [[ -z "${cand}" ]]; then
    die_action "软件源中未找到 ${pkg}（检查分支号或 apt 源）"
    return 1
  fi
  cand_major="$(pkg_ver_major "${cand}")"
  if [[ "${cand_major}" =~ ^[0-9]+$ ]] && (( 10#${cand_major} < 580 )); then
    die_action "软件源中 ${pkg} 最高候选为 ${cand}（低于 580 / CUDA 13 门槛；旧发行版如 Ubuntu 20.04 / Debian 11 请升级到 Ubuntu 22.04+ 或 Debian 12+）"
    return 1
  fi
  if [[ -n "${inst}" && "${inst}" == "${cand}" ]]; then
    log "${pkg} 当前已是源内最新稳定版（${inst}）"
    if ! ask_yesno "是否仍强制重装 ${pkg}？" n; then
      DRIVER_CHANGED=0
      return 0
    fi
    if ! apt_run install -y --reinstall "${pkg}"; then
      die_action "重装 ${pkg} 失败"
      return 1
    fi
    apt_clean_archives
    DRIVER_CHANGED=1
    return 0
  fi
  printf '  目标包：%s（当前：%s -> 候选：%s）\n' "${pkg}" "${inst:-未安装}" "${cand}"
  if ! ask_yesno "确认安装/升级到 ${pkg} (${cand})？" y; then
    DRIVER_CHANGED=0
    log "已取消驱动安装/升级"
    return 0
  fi
  if ! apt_run install -y "${pkg}"; then
    die_action "安装/升级 ${pkg} 失败"
    return 1
  fi
  apt_clean_archives
  DRIVER_CHANGED=1
  return 0
}

driver_install_path_a() {
  local out max branches target_branch pkg pol inst cand suffix="" cur_pkg
  if ! command -v ubuntu-drivers >/dev/null 2>&1; then
    apt_update_index || return 1
    if ! apt_run install -y ubuntu-drivers-common; then
      die_action "安装 ubuntu-drivers-common 失败"
      return 1
    fi
  fi
  out="$(ubuntu-drivers devices 2>/dev/null || true)"
  printf '%s\n' "${out}"
  branches="$(sed -n 's/.*nvidia-driver-\([0-9][0-9]*\).*/\1/p' <<< "${out}" | sort -nu || true)"
  max="$(tail -n 1 <<< "${branches}")"
  if [[ -z "${max}" ]] || (( 10#${max} < 580 )); then
    warn "系统源最高驱动：${max:-未知}（低于 580），改走 NVIDIA 官方源"
    driver_install_path_b || return 1
    return 0
  fi
  cur_pkg="$(driver_installed_pkg)"
  if [[ "${cur_pkg}" == *-open ]]; then
    suffix="-open"
  fi
  local avail_branches
  avail_branches="$(awk '$1>=580{printf "%s ", $1}' <<< "${branches}")"
  target_branch="$(ask_input_def "Ubuntu 系统源目标大版本（可用 >=580：${avail_branches}）" v_driver_branch "${max}")" || return 1
  pkg="nvidia-driver-${target_branch}${suffix}"
  pol="$(apt_pkg_policy "${pkg}")"
  inst="${pol%%|*}"
  cand="${pol#*|}"
  if [[ -z "${cand}" && -n "${suffix}" ]]; then
    pkg="nvidia-driver-${target_branch}"
    pol="$(apt_pkg_policy "${pkg}")"
    inst="${pol%%|*}"
    cand="${pol#*|}"
  fi
  if [[ -n "${inst}" && "${inst}" == "${cand}" ]]; then
    log "Ubuntu 系统源 ${pkg} 已是最新（${inst}）"
    if ask_yesno "改用 NVIDIA 官方源检查是否有更新的稳定版本？" n; then
      driver_install_path_b || return 1
      return 0
    fi
    DRIVER_CHANGED=0
    return 0
  fi
  driver_apt_install_pkg "${pkg}" || return 1
  return 0
}

driver_install_path_b() {
  local cur_pkg pol_open pol_cuda def="1" mode branch pkg
  nvidia_repo_setup || return 1
  cur_pkg="$(driver_installed_pkg)"
  pol_open="$(apt_pkg_policy nvidia-open)"
  pol_cuda="$(apt_pkg_policy cuda-drivers)"
  printf '\n%sNVIDIA 官方源最新稳定候选：%s\n' "${C_B}" "${C_0}"
  printf '  1) nvidia-open  （开源内核模块，Turing+ 推荐） 当前: %-16s 候选: %s\n' "${pol_open%%|*}" "${pol_open#*|}"
  printf '  2) cuda-drivers （官方闭源/全兼容稳定版）        当前: %-16s 候选: %s\n' "${pol_cuda%%|*}" "${pol_cuda#*|}"
  printf '  3) 指定驱动大版本号（如 580 / 590）\n\n'
  if [[ "${cur_pkg}" == "cuda-drivers" ]]; then def="2"; fi
  mode="$(ask_input_def "选择安装/升级方式" v_choice_three "${def}")" || return 1
  case "${mode}" in
    1) pkg="nvidia-open" ;;
    2) pkg="cuda-drivers" ;;
    3)
      branch="$(ask_input_def "输入驱动大版本号（>=580）" v_driver_branch "580")" || return 1
      if (( 10#${branch} < 580 )); then
        die_action "v1 要求驱动 >=580，拒绝安装 ${branch}"
        return 1
      fi
      if ask_yesno "使用开源内核模块分支（nvidia-open-${branch}）？选 n 则装 cuda-drivers-${branch}" y; then
        pkg="nvidia-open-${branch}"
      else
        pkg="cuda-drivers-${branch}"
      fi
      ;;
  esac
  if ! driver_apt_install_pkg "${pkg}"; then
    if [[ "${pkg}" == nvidia-open* ]]; then
      warn "nvidia-open 安装失败。Volta 及更老 GPU 或部分云环境可改选 2) cuda-drivers"
    fi
    return 1
  fi
  return 0
}

driver_install_action() {
  local choice="2"
  DRIVER_CHANGED=0
  printf '  当前驱动：%s / %s（CUDA %s）\n' "$(gpu_driver_version)" "$(driver_flavor_label)" "$(gpu_cuda_version)"
  driver_guard_environment || return 1
  if is_ubuntu; then
    printf '  1) Ubuntu 系统源（支持 >=580 分支）\n'
    printf '  2) NVIDIA 官方源（最新稳定版 / 可选版本）\n'
    choice="$(ask_input_def "选择驱动来源" v_choice_driver "2")" || return 1
  else
    log "Debian 无 ubuntu-drivers，直接使用 NVIDIA 官方源"
  fi
  case "${choice}" in
    1) driver_install_path_a || return 1 ;;
    2) driver_install_path_b || return 1 ;;
    *) die_action "无效选择"; return 1 ;;
  esac
  if (( DRIVER_CHANGED )); then
    warn "驱动已安装/更新：必须重启后新版驱动才会生效"
  fi
  return 0
}
v_choice_driver() { [[ "$1" =~ ^(1|2)$ ]] || { printf '请输入 1 或 2\n' >&2; return 1; }; }

cuda_toolkit_install() {
  local nvcc_ver="未安装" pol inst cand
  if command -v nvcc >/dev/null 2>&1; then
    nvcc_ver="$(nvcc --version 2>/dev/null | awk '/release/ {for(i=1;i<=NF;i++) if($i=="release"){print $(i+1); exit}}' || true)"
    nvcc_ver="${nvcc_ver%,}"
  else
    warn "未检测到 nvcc；安装 cuda-toolkit 仅用于本地编译 sageattention/flash-attn 等插件"
  fi
  printf '  当前 nvcc：%s\n' "${nvcc_ver:-未知}"
  if ! ask_yesno "检查并安装/升级系统级 cuda-toolkit（体积较大）？" n; then
    log "已取消 cuda-toolkit 安装"
    return 0
  fi
  nvidia_repo_setup || return 1
  pol="$(apt_pkg_policy cuda-toolkit)"
  inst="${pol%%|*}"
  cand="${pol#*|}"
  printf '  cuda-toolkit 当前：%s -> 候选：%s\n' "${inst:-未安装}" "${cand:-未知}"
  if [[ -n "${inst}" && "${inst}" == "${cand}" ]]; then
    log "cuda-toolkit 已是最新（${inst}）"
    if ! ask_yesno "仍重装 cuda-toolkit？" n; then return 0; fi
  fi
  if ! apt_run install -y cuda-toolkit; then
    die_action "cuda-toolkit 安装失败"
    return 1
  fi
  apt_clean_archives
  local bashrc="${ROOT_HOME}/.bashrc"
  backup_file "${bashrc}" >/dev/null || true
  if ! grep -qF '/usr/local/cuda/bin' "${bashrc}" 2>/dev/null; then
    # shellcheck disable=SC2016
    {
      printf '\nexport PATH="/usr/local/cuda/bin${PATH:+:${PATH}}"\n'
      printf 'export LD_LIBRARY_PATH="/usr/local/cuda/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"\n'
    } >> "${bashrc}" || {
      die_action "写入 ${bashrc} 失败"; return 1;
    }
  fi
  log "cuda-toolkit 已安装/更新；重新登录 SSH 后 nvcc 指向 /usr/local/cuda"
  return 0
}

# 返回：0 继续；1 失败；2 驱动已安装或升级，必须重启后续跑
detect_or_install_driver() {
  local cv major
  DRIVER_CHANGED=0
  if gpu_hardware_present; then
    CPU_MODE=0
    CPU_MODE_DECIDED=1
    if gpu_driver_ready; then
      cv="$(gpu_cuda_version)"
      major="$(cuda_major "${cv}")"
      if [[ "${major}" =~ ^[0-9]+$ ]] && (( 10#${major} >= 13 )); then
        log "GPU：$(gpu_name)；驱动 $(gpu_driver_version) [$(driver_flavor_label)]；CUDA ${cv}"
        log "说明：当前满足最低要求（>=580 / CUDA 13.0+），是否已是最新稳定版需与软件源对比"
        if ! systemd_present; then
          log "当前为非 systemd 环境（疑似容器实例），驱动由宿主机提供，跳过容器内驱动升级"
        elif ask_yesno "是否联网检查软件源，对比当前驱动与最新稳定版并按需升级？" n; then
          driver_install_action || return 1
          if (( DRIVER_CHANGED )); then
            return 2
          fi
        fi
        return 0
      fi
      warn "驱动 CUDA ${cv:-未知} 低于 13.0（驱动 <580），v1 不支持 cu126 回退"
      if ! ask_yesno "现在安装/升级驱动？安装后必须重启" y; then
        die_action "驱动不足，已中止。请先升级到 580+ 或换带新版驱动的镜像"
        return 1
      fi
      driver_install_action || return 1
      (( DRIVER_CHANGED )) && return 2
      return 0
    fi
    warn "检测到 NVIDIA 硬件，但 nvidia-smi 不可用（驱动未安装或未加载）"
    if ask_yesno "现在安装驱动？安装后必须重启" y; then
      driver_install_action || return 1
      (( DRIVER_CHANGED )) && return 2
      return 0
    fi
    if ask_yesno "不装驱动，改用 CPU 测试模式继续？" n; then
      CPU_MODE=1
      CPU_MODE_DECIDED=1
      return 0
    fi
    die_action "已中止"
    return 1
  fi
  if ask_yesno "未检测到 NVIDIA GPU，进入 CPU 测试模式？" n; then
    CPU_MODE=1
    CPU_MODE_DECIDED=1
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
  local installer target_dir="${MINIFORGE_DIR}" want_new_miniforge=0
  if miniforge_ok; then
    if [[ "${MINIFORGE_DIR}" == "${ROOT_HOME}/miniforge3" ]]; then
      log "Miniforge 已安装（已满足）：$("${CONDA_BIN}" --version 2>/dev/null || true)"
      conda_init_bash
      condarc_write || return 1
      return 0
    fi
    warn "检测到系统已有其他 conda：${CONDA_BIN}（$("${CONDA_BIN}" --version 2>/dev/null || true)）"
    if ask_yesno "直接复用已有 conda（选 n 则另行安装 Miniforge 到 ${ROOT_HOME}/miniforge3）？" y; then
      conda_init_bash
      condarc_write || return 1
      return 0
    fi
    target_dir="${ROOT_HOME}/miniforge3"
    want_new_miniforge=1
  fi
  installer="${TMPD}/miniforge.sh"
  log "下载 Miniforge（清华镜像）"
  if ! fetch_file "${MINIFORGE_URL}" "${installer}"; then
    warn "清华 Miniforge 下载失败"
    if ! ask_yesno "改用 GitHub 官方地址重试？" y; then
      die_action "已取消 Miniforge 安装"
      return 1
    fi
    if ! fetch_file "${MINIFORGE_FALLBACK}" "${installer}"; then
      die_action "Miniforge 下载失败"
      return 1
    fi
  fi
  if [[ ! -s "${installer}" ]]; then
    die_action "Miniforge 安装包为空"
    return 1
  fi
  if ! bash "${installer}" -b -u -p "${target_dir}"; then
    die_action "Miniforge 安装失败"
    return 1
  fi
  rm -f "${installer}"
  if [[ ! -x "${target_dir}/bin/conda" ]] || ! "${target_dir}/bin/conda" --version >/dev/null 2>&1; then
    die_action "Miniforge 安装后不可用"
    return 1
  fi
  MINIFORGE_DIR="${target_dir}"
  CONDA_BIN="${MINIFORGE_DIR}/bin/conda"
  MAMBA_BIN="${MINIFORGE_DIR}/bin/mamba"
  ENV_DIR="${MINIFORGE_DIR}/envs/${CONDA_ENV_NAME}"
  ENV_PY="${ENV_DIR}/bin/python"
  sync_env_bin
  if (( want_new_miniforge )); then
    CUSTOM_TARGET_SET=1
  fi
  conda_init_bash
  condarc_write || return 1
  log "Miniforge 安装完成：$("${CONDA_BIN}" --version 2>/dev/null || true)"
  return 0
}

conda_update_action() {
  if ! conda_ok; then
    die_action "未检测到可用的 conda/Miniforge"
    return 1
  fi
  log "当前：$("${CONDA_BIN}" --version 2>/dev/null || true)"
  if ! ask_yesno "更新 base 环境中的 conda / mamba 到最新稳定版？" y; then
    log "已取消更新"
    return 0
  fi
  if ! HOME="${ROOT_HOME}" "${CONDA_BIN}" update -n base conda -y; then
    die_action "conda 更新失败"
    return 1
  fi
  if [[ -x "${MAMBA_BIN}" ]]; then
    HOME="${ROOT_HOME}" "${CONDA_BIN}" update -n base mamba -y || warn "mamba 更新未完成，不影响使用"
  fi
  log "更新后：$("${CONDA_BIN}" --version 2>/dev/null || true)"
  return 0
}

env_py_minor_ok() {
  env_ok || return 1
  env_py -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 12) else 1)' >/dev/null 2>&1
}

env_create() {
  local ver="${1:-${PY_VER}}"
  if ! conda_ok; then
    if env_ok && env_py_minor_ok; then
      log "Python 环境已存在（已满足）：$(env_python_version)"
      return 0
    fi
    die_action "未检测到 conda/Miniforge，请先安装或切换 Python 环境"
    return 1
  fi
  if env_ok; then
    if env_py_minor_ok; then
      log "Python 环境已存在（已满足）：$(env_python_version)"
      return 0
    fi
    warn "当前探测到的 Python 版本较低：$(env_python_version)（${ENV_PY}），推荐使用 Python 3.12+"
    if ask_yesno "仍保留当前 Python 环境继续？（选 n 则新建 conda 环境 comfyui Python ${ver}）" n; then
      return 0
    fi
    CONDA_ENV_NAME="comfyui"
    ENV_DIR="${MINIFORGE_DIR}/envs/${CONDA_ENV_NAME}"
    ENV_PY="${ENV_DIR}/bin/python"
    sync_env_bin
    CUSTOM_TARGET_SET=1
    if [[ -d "${ENV_DIR}" ]] && ! env_py_minor_ok; then
      HOME="${ROOT_HOME}" "${CONDA_BIN}" env remove -n "${CONDA_ENV_NAME}" -y || {
        die_action "清理旧 ${CONDA_ENV_NAME} 环境失败"; return 1;
      }
    fi
  fi
  local runner="${MAMBA_BIN}"
  [[ -x "${runner}" ]] || runner="${CONDA_BIN}"
  log "创建 conda 环境 ${CONDA_ENV_NAME}（Python ${ver}）"
  if ! HOME="${ROOT_HOME}" "${runner}" create -n "${CONDA_ENV_NAME}" "python=${ver}" -y; then
    die_action "创建 ${CONDA_ENV_NAME} 环境失败（检查 condarc 镜像与网络）"
    return 1
  fi
  ENV_DIR="${MINIFORGE_DIR}/envs/${CONDA_ENV_NAME}"
  ENV_PY="${ENV_DIR}/bin/python"
  sync_env_bin
  if ! env_ok; then
    die_action "环境创建后 ${ENV_PY} 不可用"
    return 1
  fi
  return 0
}

env_recreate() {
  local ver target_dir
  if ! conda_ok; then
    die_action "未检测到 conda/Miniforge，无法重建 conda 环境"
    return 1
  fi
  target_dir="${MINIFORGE_DIR}/envs/${CONDA_ENV_NAME}"
  warn "重建会删除 conda 环境 ${CONDA_ENV_NAME}（${target_dir}，模型与 ComfyUI 代码不受影响）"
  if ! ask_yesno "确认重建 ${CONDA_ENV_NAME} 环境？" n; then
    log "已取消重建"
    return 0
  fi
  ver="$(ask_input_def "Python 版本" v_pyver "${PY_VER}")" || return 1
  if [[ -d "${target_dir}" ]]; then
    if ! HOME="${ROOT_HOME}" "${CONDA_BIN}" env remove -n "${CONDA_ENV_NAME}" -y; then
      die_action "删除环境失败"
      return 1
    fi
  fi
  ENV_DIR="${target_dir}"
  ENV_PY="${ENV_DIR}/bin/python"
  sync_env_bin
  CUSTOM_TARGET_SET=1
  env_create "${ver}" || return 1
  return 0
}

select_python_target() {
  local cand_list=() line idx=1 choice custom
  if conda_ok && [[ -f "${ROOT_HOME}/.conda/environments.txt" ]]; then
    while IFS= read -r line; do
      [[ -n "${line}" && -x "${line}/bin/python" ]] && cand_list+=("${line}/bin/python")
    done < "${ROOT_HOME}/.conda/environments.txt"
  fi
  for line in "${COMFY_DIR}/venv/bin/python" "${COMFY_DIR}/.venv/bin/python" "$(command -v python3 2>/dev/null || true)"; do
    [[ -n "${line}" && -x "${line}" ]] || continue
    cand_list+=("${line}")
  done
  printf '当前 Python：%s (%s)\n' "${ENV_PY}" "$(env_python_version)"
  if (( ${#cand_list[@]} > 0 )); then
    printf '\n已探测到的候选 Python：\n'
    for line in "${cand_list[@]}"; do
      printf '  %d) %s (%s)\n' "${idx}" "${line}" "$("${line}" --version 2>&1 || true)"
      idx=$((idx+1))
    done
  fi
  printf '  可直接输入候选编号，或输入任意 python 可执行文件完整路径\n'
  custom="$(ask_input "选择编号或输入 Python 路径" v_nonempty)" || return 1
  if [[ "${custom}" =~ ^[0-9]+$ ]] && (( 10#${custom} >= 1 && 10#${custom} <= ${#cand_list[@]} )); then
    custom="${cand_list[$((10#${custom}-1))]}"
  fi
  if ! v_pybin "${custom}"; then
    die_action "Python 路径无效：${custom}"
    return 1
  fi
  ENV_PY="${custom}"
  sync_env_bin
  CUSTOM_TARGET_SET=1
  log "本次会话已切换 Python：${ENV_PY}（$(env_python_version)）"
  return 0
}

select_comfy_target() {
  local cand_list=() d idx=1 custom
  for d in "${ROOT_HOME}/ComfyUI" "${ROOT_HOME}/autodl-tmp/ComfyUI" "/workspace/ComfyUI" "/data/ComfyUI" "/opt/ComfyUI"; do
    [[ -f "${d}/main.py" ]] && cand_list+=("${d}")
  done
  printf '当前 ComfyUI 目录：%s（%s）\n' "${COMFY_DIR}" "$(comfy_summary)"
  if (( ${#cand_list[@]} > 0 )); then
    printf '\n已探测到的 ComfyUI 目录：\n'
    for d in "${cand_list[@]}"; do
      printf '  %d) %s\n' "${idx}" "${d}"
      idx=$((idx+1))
    done
  fi
  printf '  可输入候选编号，或输入任意包含 main.py 的 ComfyUI 目录路径\n'
  custom="$(ask_input "选择编号或输入 ComfyUI 目录" v_nonempty)" || return 1
  if [[ "${custom}" =~ ^[0-9]+$ ]] && (( 10#${custom} >= 1 && 10#${custom} <= ${#cand_list[@]} )); then
    custom="${cand_list[$((10#${custom}-1))]}"
  fi
  if ! v_comfy_dir "${custom}"; then
    die_action "目录无效（缺少 main.py）：${custom}"
    return 1
  fi
  COMFY_DIR="${custom%/}"
  CUSTOM_TARGET_SET=1
  log "本次会话已切换 ComfyUI 目录：${COMFY_DIR}（$(comfy_summary)）"
  return 0
}

# ============ ComfyUI / PyTorch ============
pip_config_write() {
  local f="${ROOT_HOME}/.config/pip/pip.conf" cur=""
  if env_ok; then
    cur="$(env_py -m pip config get global.index-url 2>/dev/null || true)"
  elif [[ -f "${f}" ]]; then
    cur="$(awk -F= '/^[[:space:]]*index-url[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "${f}" 2>/dev/null || true)"
  fi
  if [[ "${cur}" == "${PIP_MIRROR}" ]]; then
    log "pip 已指向阿里云镜像（已满足）"
    return 0
  fi
  if [[ -e "${f}" ]]; then
    backup_file "${f}" >/dev/null || true
    if ! ask_yesno "覆盖现有 pip 配置 ${f}（将备份）？" y; then
      warn "保留现有 pip 配置"
      return 0
    fi
  fi
  mkdir -p "$(dirname "${f}")" || { die_action "创建 pip 配置目录失败"; return 1; }
  cat > "${f}" <<EOF
[global]
index-url = ${PIP_MIRROR}
EOF
  log "pip 全局源已设为 ${PIP_MIRROR}（写入 ${f}）"
  return 0
}

pip_install() {
  env_py -m pip install --timeout 30 --retries 3 "$@"
}

pip_install_fallback() {
  local desc="$1"
  shift
  if pip_install "$@"; then
    return 0
  fi
  warn "${desc} 安装失败（阿里 PyPI）"
  if ! ask_yesno "改用清华 PyPI 重试？" y; then
    return 1
  fi
  pip_install --index-url "${PIP_MIRROR_FALLBACK}" "$@"
}

git_net() {
  GIT_TERMINAL_PROMPT=0 git -c http.lowSpeedLimit=1024 -c http.lowSpeedTime=30 "$@"
}

comfy_clone_or_pull() {
  ensure_cmd git git || return 1
  if [[ -d "${COMFY_DIR}" && ! -d "${COMFY_DIR}/.git" ]]; then
    if comfy_present; then
      warn "${COMFY_DIR} 已存在（非 git 目录，跳过 git pull 并保留现有代码）"
      return 0
    fi
    die_action "${COMFY_DIR} 存在且既无 .git 也无 main.py，拒绝覆盖"
    return 1
  fi
  if comfy_git_ok; then
    local before after
    before="$(git -C "${COMFY_DIR}" rev-parse --short HEAD 2>/dev/null || true)"
    if ! git_net -C "${COMFY_DIR}" pull --ff-only; then
      warn "git pull 失败（可能有本地改动或分支分叉）；保留当前代码继续"
      return 0
    fi
    after="$(git -C "${COMFY_DIR}" rev-parse --short HEAD 2>/dev/null || true)"
    log "ComfyUI：${before} -> ${after:-未知}"
    return 0
  fi
  log "克隆 ComfyUI 到 ${COMFY_DIR}"
  if ! git_net clone "${COMFY_REPO}" "${COMFY_DIR}"; then
    warn "GitHub clone 失败"
    if ! ask_yesno "使用 ghproxy 代理重试 clone？" n; then
      die_action "已取消 ComfyUI 克隆"
      return 1
    fi
    if ! git_net clone "${COMFY_REPO_PROXY}" "${COMFY_DIR}"; then
      die_action "ComfyUI 克隆失败"
      return 1
    fi
  fi
  return 0
}

torch_report() {
  local out
  if ! env_ok; then return 1; fi
  out="$(HOME="${ROOT_HOME}" run_with_timeout 30 "${ENV_PY}" -c 'import torch, torchvision; print(torch.__version__); print(torch.version.cuda or ""); print(torch.cuda.is_available())' 2>/dev/null || true)"
  printf '%s' "${out}"
}

parse_torch_report() {
  ver=""; cuda=""; avail=""
  { IFS= read -r ver; IFS= read -r cuda; IFS= read -r avail; } <<< "$1" || true
}

torch_install() {
  local allow_upgrade="${1:-0}" ver cuda avail out preinstall_no_driver=0 mode_choice
  if ! env_ok; then
    die_action "Python 环境未就绪，请先在菜单 4 创建或切换已有 Python 环境"
    return 1
  fi
  if (( CPU_MODE == 0 )) && ! gpu_driver_ready; then
    if gpu_hardware_present; then
      warn "检测到 NVIDIA GPU，但当前驱动未就绪（nvidia-smi 不可用）"
      printf '\n  1) 预装 CUDA 13 版 PyTorch（装完驱动并重启后再验证可用性）\n'
      printf '  2) 安装 CPU 版 PyTorch（仅测试用途）\n'
      printf '  3) 取消（先去菜单 3 安装驱动）\n\n'
      mode_choice="$(ask_input_def "选择处理方式" v_choice_three "3")" || return 1
      case "${mode_choice}" in
        1) preinstall_no_driver=1 ;;
        2) CPU_MODE=1 ;;
        3) die_action "已取消，请先完成菜单 3 的驱动安装"; return 1 ;;
      esac
    else
      if ask_yesno "未检测到可用 GPU，安装 CPU 版 PyTorch？" n; then
        CPU_MODE=1
      else
        die_action "已取消"
        return 1
      fi
    fi
  fi
  out="$(torch_report || true)"
  if [[ -n "${out}" ]]; then
    parse_torch_report "${out}"
    if (( CPU_MODE )); then
      if [[ "${ver}" == *"+cpu"* || -z "${cuda}" ]]; then
        if (( allow_upgrade )) && ask_yesno "当前已装 CPU 版 PyTorch ${ver}，是否升级到最新稳定版？" n; then
          if ! pip_install -U torch torchvision --index-url "${CPU_INDEX}"; then
            warn "官方 CPU 索引升级失败"
            if ask_yesno "改用南京大学 CPU 镜像重试？" y; then
              pip_install -U torch torchvision --index-url "${CPU_INDEX_FALLBACK}" || {
                die_action "PyTorch 升级失败"; return 1;
              }
            else
              die_action "PyTorch 升级失败"; return 1
            fi
          fi
          out="$(torch_report || true)"
          [[ -n "${out}" ]] && parse_torch_report "${out}"
          log "当前 PyTorch ${ver}（CPU）"
          return 0
        fi
        log "已安装 CPU 版 PyTorch ${ver}（已满足）"
        return 0
      fi
    elif [[ "$(cuda_major "${cuda}")" == "13" ]] && { (( preinstall_no_driver )) || [[ "${avail}" == "True" ]]; }; then
      if (( allow_upgrade )) && ask_yesno "当前已装 CUDA 13 PyTorch ${ver}，是否升级到最新稳定版（pip install -U）？" n; then
        if ! pip_install_fallback "PyTorch 升级" -U torch torchvision; then
          die_action "PyTorch 升级失败（检查 pip 镜像与网络）"
          return 1
        fi
        out="$(torch_report || true)"
        [[ -n "${out}" ]] || { die_action "PyTorch 升级后 import 失败"; return 1; }
        parse_torch_report "${out}"
        if (( preinstall_no_driver == 0 )) && [[ "$(cuda_major "${cuda}")" != "13" || "${avail}" != "True" ]]; then
          die_action "PyTorch ${ver} / CUDA ${cuda:-无} / cuda.is_available=${avail}，与驱动不匹配"
          return 1
        fi
        log "PyTorch 已升级为 ${ver}（CUDA ${cuda}）"
        return 0
      fi
      log "已安装 CUDA 13 PyTorch ${ver}（已满足）"
      return 0
    fi
    warn "现有 PyTorch 与目标模式不匹配：${ver} / CUDA ${cuda:-无} / avail=${avail:-未知}"
    if ! ask_yesno "卸载旧版并重新安装 PyTorch？" y; then
      die_action "保留不匹配的 PyTorch（${ver}），已中止当前步骤"
      return 1
    fi
    log "卸载旧 torch / torchvision 后重装"
    env_py -m pip uninstall -y torch torchvision >/dev/null 2>&1 || true
  fi
  if (( CPU_MODE )); then
    log "安装 CPU 版 torch / torchvision（官方 CPU 索引）"
    if ! pip_install torch torchvision --index-url "${CPU_INDEX}"; then
      warn "官方 CPU 索引失败"
      if ! ask_yesno "改用南京大学 CPU 镜像重试？" y; then
        die_action "PyTorch 安装失败"
        return 1
      fi
      if ! pip_install torch torchvision --index-url "${CPU_INDEX_FALLBACK}"; then
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
  out="$(torch_report || true)"
  if [[ -z "${out}" ]]; then
    die_action "PyTorch 安装后 import 失败"
    return 1
  fi
  parse_torch_report "${out}"
  if (( CPU_MODE )); then
    log "PyTorch ${ver}（CPU）可用"
    return 0
  fi
  if (( preinstall_no_driver )); then
    if [[ "$(cuda_major "${cuda}")" != "13" ]]; then
      die_action "预装的 PyTorch ${ver} / CUDA ${cuda:-无} 不是 CUDA 13 版本"
      return 1
    fi
    warn "已预装 PyTorch ${ver}（CUDA ${cuda}）；待安装驱动并重启后运行菜单 9 验证 cuda.is_available"
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
  if ! env_ok; then
    die_action "Python 环境未就绪，请先在菜单 4 创建或切换已有 Python 环境"
    return 1
  fi
  if ! comfy_present; then
    die_action "未在 ${COMFY_DIR} 检测到 ComfyUI（缺少 main.py），请先克隆或切换目录"
    return 1
  fi
  if [[ ! -f "${COMFY_DIR}/requirements.txt" ]]; then
    die_action "缺少依赖清单：${COMFY_DIR}/requirements.txt"
    return 1
  fi
  log "安装 ComfyUI requirements"
  if ! pip_install_fallback "ComfyUI requirements" -r "${COMFY_DIR}/requirements.txt"; then
    die_action "ComfyUI requirements 安装失败"
    return 1
  fi
  if [[ -f "${COMFY_DIR}/manager_requirements.txt" ]]; then
    log "安装 Manager requirements"
    if ! pip_install_fallback "Manager requirements" -r "${COMFY_DIR}/manager_requirements.txt"; then
      die_action "Manager requirements 安装失败"
      return 1
    fi
    if ! manager_installed; then
      warn "已执行 manager_requirements.txt，但仍未检测到 comfyui_manager 包"
    fi
  else
    warn "未找到 manager_requirements.txt，跳过内置 Manager 依赖"
  fi
  return 0
}

smoke_test() {
  local -a args=(main.py --quick-test-for-ci)
  if ! comfy_present || ! env_ok; then
    die_action "ComfyUI 或 Python 环境未就绪"
    return 1
  fi
  if manager_installed; then
    args+=(--enable-manager)
  else
    warn "未检测到 comfyui_manager，冒烟测试不带 --enable-manager"
  fi
  if (( CPU_MODE )); then args+=(--cpu); fi
  if service_active || [[ -n "$(comfy_running_pids)" ]]; then
    log "ComfyUI 已在运行，跳过前台冒烟测试（终检会验证 HTTP）"
    return 0
  fi
  log "冒烟测试：ComfyUI 启动检查"
  if ! ( cd "${COMFY_DIR}" && HOME="${ROOT_HOME}" run_with_timeout 180 "${ENV_PY}" "${args[@]}" ); then
    die_action "ComfyUI 冒烟测试失败（查看上方报错）"
    return 1
  fi
  log "冒烟测试通过"
  return 0
}

# ============ 访问方式 / 防火墙 ============
ensure_fw_8188() {
  if ! fw_installed; then
    if ! systemd_present; then
      warn "容器环境（非 systemd）未安装 UFW：${PORT} 的可达性由平台端口映射与云安全组决定"
      return 0
    fi
    warn "UFW 未安装：${PORT} 的可达性目前由云安全组决定（如需本机防火墙建议配合 00-tui.sh）"
    if ask_yesno "现在安装 UFW 并预放行 ${PORT}/tcp（不自动启用 UFW，避免影响 SSH）？" n; then
      apt_update_index || return 1
      if ! apt_run install -y ufw; then
        die_action "安装 ufw 失败"
        return 1
      fi
      apt_clean_archives
      if ufw allow "${PORT}/tcp"; then
        log "已安装 ufw 并预放行 ${PORT}/tcp（当前仍为 inactive，请用 00-tui.sh 放行 SSH 后再启用）"
      else
        warn "已安装 ufw，但预写入 ${PORT}/tcp 规则失败"
      fi
    fi
    return 0
  fi
  if ! fw_active; then
    warn "UFW 未启用：${PORT} 的可达性完全由云安全组决定（建议先跑 00-tui.sh 做安全基线）"
    return 0
  fi
  if fw_has_port; then
    log "UFW 已放行 ${PORT}/tcp（已满足）"
    return 0
  fi
  if ask_yesno "UFW 放行 ${PORT}/tcp？来源不限制，建议在云安全组限制为你自己的 IP" y; then
    if ! ufw allow "${PORT}/tcp"; then
      die_action "ufw allow ${PORT}/tcp 失败"
      return 1
    fi
    log "已放行 ${PORT}/tcp"
  else
    warn "未放行 ${PORT}：UFW active 时公网将无法访问"
  fi
  return 0
}

# ============ 开机自启 ============
systemd_quote_arg() {
  local s="$1"
  if [[ "${s}" =~ ^[A-Za-z0-9_./:=+@-]+$ ]]; then
    printf '%s' "${s}"
  else
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '"%s"' "${s}"
  fi
}

shell_quote_arg() {
  local s="$1"
  if [[ "${s}" =~ ^[A-Za-z0-9_./:=+@-]+$ ]]; then
    printf '%s' "${s}"
  else
    printf '%q' "${s}"
  fi
}

format_systemd_cmd() {
  local out="" arg first=1
  for arg in "$@"; do
    if (( first )); then
      out="$(systemd_quote_arg "${arg}")"
      first=0
    else
      out+=" $(systemd_quote_arg "${arg}")"
    fi
  done
  printf '%s' "${out}"
}

format_shell_args() {
  local out="" arg first=1
  for arg in "$@"; do
    if (( first )); then
      out="$(shell_quote_arg "${arg}")"
      first=0
    else
      out+=" $(shell_quote_arg "${arg}")"
    fi
  done
  printf '%s' "${out}"
}

extract_existing_extra_args() {
  local f line idx=1 n tok
  COMFY_EXTRA_ARGS=()
  f="$(config_file)"
  [[ -n "${f}" ]] || return 0
  line="$(config_exec_line "${f}")"
  [[ -n "${line}" ]] || return 0
  tokenize_cmdline "${line}"
  n="${#CMD_WORDS[@]}"
  while (( idx < n )); do
    tok="${CMD_WORDS[$idx]}"
    case "${tok}" in
      main.py|*/main.py|--enable-manager|--cpu|--listen=*|--port=*) ;;
      --listen|--port)
        if (( idx + 1 < n )) && [[ "${CMD_WORDS[$((idx+1))]}" != -* ]]; then
          idx=$((idx+1))
        fi
        ;;
      *) COMFY_EXTRA_ARGS+=("${tok}") ;;
    esac
    idx=$((idx+1))
  done
}

build_comfy_args() {
  extract_existing_extra_args
  COMFY_ARGS=(main.py)
  if manager_installed; then
    COMFY_ARGS+=(--enable-manager)
  else
    warn "未检测到 comfyui_manager，自启参数暂不带 --enable-manager"
  fi
  if [[ "${ACCESS_MODE}" == "listen" ]]; then
    COMFY_ARGS+=(--listen 0.0.0.0 --port "${PORT}")
  elif (( PORT != 8188 )); then
    COMFY_ARGS+=(--port "${PORT}")
  fi
  if (( CPU_MODE )); then
    COMFY_ARGS+=(--cpu)
  fi
  if (( ${#COMFY_EXTRA_ARGS[@]} > 0 )); then
    COMFY_ARGS+=("${COMFY_EXTRA_ARGS[@]}")
  fi
}

sync_runtime_mode() {
  if ! gpu_hardware_present; then
    CPU_MODE=1
  elif (( CPU_MODE_DECIDED == 0 )) && config_has_cpu; then
    CPU_MODE=1
  fi
}

ensure_comfy_args() {
  if [[ -z "${ACCESS_MODE}" ]]; then
    ACCESS_MODE="$(current_access_mode)"
  fi
  sync_runtime_mode
  build_comfy_args
}

write_systemd_unit() {
  local tmp_unit exec_cmd workdir_q env_path_q
  AUTOSTART_CHANGED=0
  if ! systemd_present; then
    die_action "当前 PID 1 不是 systemd，不能写 systemd 服务"
    return 1
  fi
  if ! env_ok || ! comfy_present; then
    die_action "Python 环境或 ComfyUI（main.py）未就绪，不能写自启配置"
    return 1
  fi
  ensure_comfy_args
  exec_cmd="$(format_systemd_cmd "${ENV_PY}" "${COMFY_ARGS[@]}")"
  workdir_q="$(systemd_quote_arg "${COMFY_DIR}")"
  env_path_q="$(systemd_quote_arg "PATH=${ENV_BIN}:/usr/local/cuda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")"
  tmp_unit="${TMPD}/comfyui.service.new"
  cat > "${tmp_unit}" <<EOF
[Unit]
Description=ComfyUI Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${workdir_q}
ExecStart=${exec_cmd}
Restart=always
RestartSec=10
Environment=${env_path_q}
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF
  if [[ -f "${UNIT_FILE}" ]] && cmp -s "${tmp_unit}" "${UNIT_FILE}"; then
    rm -f -- "${tmp_unit}"
    if ! service_enabled; then
      systemctl enable "${SERVICE_NAME}" || { die_action "systemctl enable ${SERVICE_NAME} 失败"; return 1; }
    fi
    if service_active; then
      log "systemd 服务配置未变化且已在运行（已满足）"
      return 0
    fi
    if ! systemctl start "${SERVICE_NAME}"; then
      die_action "systemctl start ${SERVICE_NAME} 失败"
      return 1
    fi
    return 0
  fi
  backup_file "${UNIT_FILE}" >/dev/null || true
  mv -f -- "${tmp_unit}" "${UNIT_FILE}" || { die_action "写入 ${UNIT_FILE} 失败"; return 1; }
  AUTOSTART_CHANGED=1
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
  local tmp_script args_str
  AUTOSTART_CHANGED=0
  if ! startd_exists; then
    die_action "未检测到 ${STARTD_DIR}，不能写容器自启脚本"
    return 1
  fi
  if ! env_ok || ! comfy_present; then
    die_action "Python 环境或 ComfyUI（main.py）未就绪，不能写自启配置"
    return 1
  fi
  ensure_comfy_args
  args_str="$(format_shell_args "${COMFY_ARGS[@]}")"
  tmp_script="${TMPD}/comfyui.sh.new"
  cat > "${tmp_script}" <<EOF
#!/bin/bash
export PATH="${ENV_BIN}:/usr/local/cuda/bin:\$PATH"
cd "${COMFY_DIR}" || exit 1
exec "${ENV_PY}" ${args_str}
EOF
  if [[ -f "${STARTD_FILE}" && -x "${STARTD_FILE}" ]] && cmp -s "${tmp_script}" "${STARTD_FILE}"; then
    rm -f -- "${tmp_script}"
    log "${STARTD_FILE} 配置未变化（已满足）"
    return 0
  fi
  backup_file "${STARTD_FILE}" >/dev/null || true
  mv -f -- "${tmp_script}" "${STARTD_FILE}" || { die_action "写入 ${STARTD_FILE} 失败"; return 1; }
  if ! chmod +x "${STARTD_FILE}"; then
    die_action "chmod +x ${STARTD_FILE} 失败"
    return 1
  fi
  AUTOSTART_CHANGED=1
  log "已写入 ${STARTD_FILE}；容器平台重启实例后生效"
  return 0
}

comfy_running_pids() {
  local p cwd comfy_real exe_base arg matched
  local -a argv=()
  comfy_real="$(readlink -f "${COMFY_DIR}" 2>/dev/null || printf '%s' "${COMFY_DIR}")"
  for p in /proc/[0-9]*; do
    [[ "${p##*/}" != "$$" && -r "${p}/cmdline" ]] || continue
    argv=()
    mapfile -d '' -t argv < "${p}/cmdline" 2>/dev/null || continue
    (( ${#argv[@]} >= 2 )) || continue
    exe_base="${argv[0]##*/}"
    [[ "${exe_base}" == "python" || "${exe_base}" == "python3" || "${exe_base}" =~ ^python3\.[0-9]+$ ]] || continue
    cwd="$(readlink -f "${p}/cwd" 2>/dev/null || true)"
    matched=0
    for arg in "${argv[@]:1}"; do
      if [[ "${arg}" == "${COMFY_DIR}/main.py" || "${arg}" == "${comfy_real}/main.py" ]]; then
        matched=1
        break
      fi
      if [[ "${arg}" == "main.py" || "${arg}" == "./main.py" ]] && [[ "${cwd}" == "${COMFY_DIR}" || "${cwd}" == "${comfy_real}" ]]; then
        matched=1
        break
      fi
    done
    (( matched )) && printf '%s\n' "${p##*/}"
  done
}

startd_stop() {
  local -a pids=()
  local i alive=0 p
  mapfile -t pids < <(comfy_running_pids)
  (( ${#pids[@]} > 0 )) || return 0
  kill "${pids[@]}" 2>/dev/null || true
  for (( i = 0; i < 10; i++ )); do
    alive=0
    for p in "${pids[@]}"; do
      if kill -0 "${p}" 2>/dev/null; then
        alive=1; break
      fi
    done
    (( alive == 0 )) && return 0
    sleep 1
  done
  kill -9 "${pids[@]}" 2>/dev/null || true
  return 0
}

startd_launch_bg() {
  local logf="${STARTD_LOG_FILE}" bg_pid
  local -a pids=()
  if ! startd_configured; then
    die_action "${STARTD_FILE} 尚未配置或缺少可执行权限"
    return 1
  fi
  mapfile -t pids < <(comfy_running_pids)
  if (( ${#pids[@]} > 0 )); then
    log "ComfyUI 已在运行（PID ${pids[*]}），跳过重复拉起"
    return 0
  fi
  if port_listening; then
    die_action "端口 ${PORT} 已被其他进程占用，无法拉起 ComfyUI（请检查 ss -tlnp | grep :${PORT}）"
    return 1
  fi
  if ! mkdir -p "${STARTD_LOG_DIR}" 2>/dev/null; then
    logf="/tmp/comfyui-startd.log"
  fi
  nohup "${STARTD_FILE}" </dev/null >>"${logf}" 2>&1 &
  bg_pid=$!
  sleep 1
  if ! kill -0 "${bg_pid}" 2>/dev/null; then
    die_action "后台启动 ComfyUI 失败；查看日志：${logf}"
    return 1
  fi
  log "已在后台启动 ComfyUI（PID ${bg_pid}，日志：${logf}）"
  return 0
}

autostart_write() {
  if [[ -z "${ACCESS_MODE}" ]]; then
    ACCESS_MODE="$(current_access_mode)"
  fi
  if (( CPU_MODE == 0 )) && gpu_hardware_present && ! gpu_driver_ready; then
    if ask_yesno "GPU 驱动未就绪，按 CPU 模式写入启动参数？" n; then
      CPU_MODE=1
      CPU_MODE_DECIDED=1
    else
      warn "将写入 GPU 启动参数；服务可能无法启动"
    fi
  fi
  if systemd_present; then
    write_systemd_unit || return 1
  elif startd_exists; then
    write_startd_script || return 1
  else
    warn "未检测到 systemd 或 /start.d；跳过开机自启配置"
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
  if startd_exists && [[ -f "${STARTD_FILE}" ]]; then
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
    startd_stop
    startd_launch_bg || return 1
    if wait_http_up; then
      log "服务已在 127.0.0.1:${PORT} 响应"
    else
      warn "服务 60 秒内未响应；查看 ${STARTD_LOG_FILE}"
    fi
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
      case "${action}" in
        start)
          startd_launch_bg || return 1
          if wait_http_up; then
            log "服务已在 127.0.0.1:${PORT} 响应"
          else
            warn "服务 60 秒内未响应；查看 ${STARTD_LOG_FILE}"
          fi
          ;;
        stop)
          startd_stop
          log "已停止 ComfyUI 后台进程"
          ;;
        restart)
          service_restart || return 1
          ;;
        status)
          local -a pids=()
          mapfile -t pids < <(comfy_running_pids)
          if (( ${#pids[@]} > 0 )); then
            log "运行中 PID：${pids[*]}"
          else
            warn "当前未检测到运行中的 ComfyUI 进程"
          fi
          if [[ -f "${STARTD_LOG_FILE}" ]]; then
            tail -n 20 "${STARTD_LOG_FILE}" 2>&1 || true
          fi
          ;;
      esac
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

comfy_http_ok() {
  local body
  body="$(curl -fsS --max-time 4 "http://127.0.0.1:${PORT}/system_stats" 2>/dev/null || true)"
  [[ "${body}" == *'"system"'* && "${body}" == *'"devices"'* ]]
}

wait_http_up() {
  local i
  for (( i = 0; i < 60; i++ )); do
    if port_listening && comfy_http_ok; then
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
  printf '\n'
  ui_sep
  printf '%s访问指引%s\n' "${C_B}" "${C_0}"
  printf '  访问方式：%s\n' "${mode}"
  if [[ "${mode}" == "listen" ]]; then
    printf '  公网地址：%shttp://%s:%s%s\n' "${C_G}" "${ip:-<公网IP>}" "${PORT}" "${C_0}"
    printf '  备用隧道：ssh -N -L %s:127.0.0.1:%s root@%s\n' "${PORT}" "${PORT}" "${ip:-<公网IP>}"
  else
    printf '  本地隧道：%sssh -N -L %s:127.0.0.1:%s root@%s%s\n' "${C_G}" "${PORT}" "${PORT}" "${ip:-<公网IP>}" "${C_0}"
    printf '  本地打开：http://127.0.0.1:%s\n' "${PORT}"
  fi
  printf '\n  %s注意事项：%s\n' "${C_D}" "${C_0}"
  printf '    - 上方 IP 为本机出口 IP；若使用独立 EIP，请以云控制台为准。\n'
  printf '    - 云安全组需放行 %s/tcp，来源建议限制为你自己的 IP/32。\n' "${PORT}"
  printf '    - Manager 插件安装受限于安全策略，listen 模式下可到菜单 7 切换隧道模式或调整 Manager 安全等级。\n'
  ui_sep
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
      if [[ "${major}" =~ ^[0-9]+$ ]] && (( 10#${major} >= 13 )); then
        check_ok "GPU $(gpu_name)；驱动 $(gpu_driver_version)；CUDA ${cv}"
      else
        check_fail "GPU CUDA ${cv:-未知} < 13.0（驱动 <580）"
      fi
    else
      check_fail "nvidia-smi 不可用"
    fi
  fi

  if miniforge_ok; then check_ok "Conda：$("${CONDA_BIN}" --version 2>/dev/null || true)"
  else check_fail "Miniforge/conda 未安装"; fi

  if env_ok; then check_ok "Python 环境：$(env_python_version) (${ENV_PY})"
  else check_fail "Python 环境未就绪 (${ENV_PY})"; fi

  if comfy_present; then check_ok "ComfyUI：$(comfy_summary)"
  else check_fail "ComfyUI 未安装 (${COMFY_DIR})"; fi

  if env_ok; then
    local mgr_ver
    out="$(torch_report || true)"
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
  elif startd_exists && [[ -f "${STARTD_FILE}" ]]; then
    check_fail "${STARTD_FILE} 存在但缺少可执行权限（chmod +x）"
  elif ! systemd_present && ! startd_exists; then
    check_warn "当前容器无 systemd 且无 /start.d，无法配置系统级开机自启"
  else
    check_fail "未配置开机自启"
  fi

  if port_listening; then check_ok "端口 ${PORT} 正在监听"
  else check_fail "端口 ${PORT} 未监听"; fi

  if comfy_http_ok; then
    check_ok "ComfyUI HTTP 127.0.0.1:${PORT}/system_stats 响应正常"
  elif port_listening; then
    check_fail "端口 ${PORT} 虽在监听，但 /system_stats 非 ComfyUI 响应（疑似端口冲突或正在初始化）"
  else
    check_fail "HTTP 127.0.0.1:${PORT} 不可访问"
  fi

  if [[ "$(current_access_mode)" == "listen" ]]; then
    if ! fw_installed; then
      if ! systemd_present; then
        check_warn "容器环境未安装 UFW；放行 ${PORT} 由平台映射/云安全组控制"
      else
        check_warn "UFW 未安装；放行 ${PORT} 只能靠云安全组"
      fi
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
  printf '\n%s部署前安全提醒%s\n' "${C_Y}" "${C_0}"
  printf '  - 默认以 --listen 0.0.0.0:%s 对外监听，ComfyUI 本身无登录鉴权。\n' "${PORT}"
  printf '  - 请确认已在云平台创建 Snapshot，避免操作失误无法回滚。\n'
  printf '  - 如需公网直连，请提前在云安全组放行 %s/tcp（建议限制来源 IP）。\n\n' "${PORT}"
  if ! ask_yesno "已创建 Snapshot 并知晓公网暴露风险，继续部署？" n; then
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

deploy_cleanup_caches() {
  apt_clean_archives
  if env_ok; then
    env_py -m pip cache purge >/dev/null 2>&1 || rm -rf -- "${ROOT_HOME}/.cache/pip"
  else
    rm -rf -- "${ROOT_HOME}/.cache/pip"
  fi
  if conda_ok; then
    HOME="${ROOT_HOME}" "${CONDA_BIN}" clean -t -p -y >/dev/null 2>&1 || true
  fi
  log "已清理流程下载缓存（apt / pip / conda 临时包）"
}

do_standard_deploy() {
  local rc=0
  step_banner 1 "预检：发行版、快照、磁盘、镜像"
  preflight_deploy || { warn "标准部署已中止"; return 1; }

  step_banner 2 "系统换源与基础工具"
  if ask_yesno "安装必要基础组件前，是否先更换系统 apt 软件源（LinuxMirrors，国内服务器推荐）？" n; then
    mirror_change_action || rc=$?
    if (( rc == 1 )); then
      if ! ask_yesno "换源脚本未成功完成，是否仍继续安装基础包？" n; then
        warn "标准部署已中止"
        return 1
      fi
    elif (( rc == 2 )); then
      if ! ask_yesno "未自动执行换源，是否继续安装基础包？" y; then
        warn "标准部署已中止"
        return 1
      fi
    fi
    rc=0
  fi
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
  torch_install 0 || { warn "标准部署已中止"; return 1; }
  requirements_install || { warn "标准部署已中止"; return 1; }

  step_banner 8 "冒烟测试"
  smoke_test || { warn "标准部署已中止"; return 1; }

  step_banner 9 "访问方式：默认 listen 0.0.0.0:${PORT}"
  if [[ -n "$(config_file)" && "$(current_access_mode)" == "tunnel" ]]; then
    if ask_yesno "检测到现有自启配置为隧道模式（仅监听回环），是否保留隧道模式？（选 n 则改为公网 listen）" y; then
      ACCESS_MODE="tunnel"
    else
      ACCESS_MODE="listen"
    fi
  else
    ACCESS_MODE="listen"
  fi
  if [[ "${ACCESS_MODE}" == "listen" ]]; then
    ensure_fw_8188 || warn "UFW 放行失败；公网访问可能不可用"
  else
    log "保留当前隧道模式（仅监听回环 ${PORT}）"
  fi

  step_banner 10 "开机自启"
  autostart_write || { warn "自启配置失败"; return 1; }
  if unit_exists && systemd_present; then
    if wait_http_up; then
      log "服务已在 127.0.0.1:${PORT} 响应"
    else
      warn "服务 60 秒内未响应；查看 journalctl -u ${SERVICE_NAME} -n 100"
    fi
  elif startd_configured; then
    if startd_launch_bg; then
      if wait_http_up; then
        log "服务已在 127.0.0.1:${PORT} 响应（重启容器后由 ${STARTD_FILE} 自动拉起）"
      else
        warn "服务 60 秒内未响应；查看 ${STARTD_LOG_FILE}"
      fi
    else
      warn "当前会话后台启动未成功；请检查日志或重启实例后由 ${STARTD_FILE} 自动拉起"
    fi
  fi

  step_banner 11 "终检"
  if ! verify_all; then
    warn "终检存在红项；按上方提示修复后可重跑终检"
  fi
  if ask_yesno "清理部署下载缓存（apt / pip / conda 安装包缓存，可释放约 3-5GB）？" n; then
    deploy_cleanup_caches
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
    printf '驱动包：%s\n' "$(driver_flavor_label)"
    nvidia-smi 2>&1 || true
  else
    printf 'nvidia-smi 未安装\n'
  fi
  printf '\n[CUDA Toolkit]\n'
  if command -v nvcc >/dev/null 2>&1; then nvcc --version 2>&1 || true; else printf 'nvcc 未安装\n'; fi
  printf '\n[磁盘 / 内存]\n'
  df -h "$(disk_target_dir)" 2>&1 || true
  free -h 2>&1 || true
  printf '\n[Miniforge / Python]\n'
  if miniforge_ok; then "${CONDA_BIN}" --version 2>&1 || true; else printf 'Miniforge/conda 未安装\n'; fi
  printf '当前 Python：%s (%s)\n' "${ENV_PY}" "$(env_python_version)"
  if miniforge_ok; then HOME="${ROOT_HOME}" "${CONDA_BIN}" env list 2>&1 || true; fi
  printf '\n[ComfyUI]\n'
  printf '目标目录：%s\n' "${COMFY_DIR}"
  if comfy_git_ok; then
    git -C "${COMFY_DIR}" log -1 --oneline 2>&1 || true
    printf '分支：%s\n' "$(git -C "${COMFY_DIR}" branch --show-current 2>/dev/null || true)"
  elif comfy_present; then
    printf '已存在（非 Git 目录，包含 main.py）\n'
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
  if command -v ss >/dev/null 2>&1; then
    ss -tlnp 2>&1 | grep -E ":${PORT}\b|State" || true
  elif port_listening; then
    printf '端口 %s 正在监听（/proc/net/tcp）\n' "${PORT}"
  else
    printf 'ss 未安装且未检测到端口 %s 监听\n' "${PORT}"
  fi
  if fw_installed; then ufw status 2>&1 || true; else printf 'UFW 未安装\n'; fi
  printf '\n[镜像连通性]\n'
  mirror_check "清华 Miniforge" "${MINIFORGE_URL}" || true
  mirror_check "清华 conda-forge" "${CONDA_MIRROR}/conda-forge/linux-64/repodata.json" || true
  mirror_check "阿里 PyPI" "${PIP_MIRROR}" || true
  ui_sep
  page_wait "按回车返回主菜单…"
}

# ============ 菜单：基础包与镜像 ============
mirror_instructions() {
  printf '\n'
  ui_sep
  printf '%s第三方系统换源说明（LinuxMirrors）%s\n' "${C_B}" "${C_0}"
  printf '  脚本来源：%s\n' "${LINUXMIRRORS_URL}"

  printf '\n  %s免责声明：%s\n' "${C_Y}" "${C_0}"
  printf '    - 本项目不提供或维护该脚本，也未对当前在线版本完成全量安全审计。\n'
  printf '    - 仅在你已审阅脚本内容，并接受以 root 权限执行第三方代码的风险时运行。\n'
  printf '    - 执行前请确认已在云平台创建 Snapshot。\n'

  printf '\n  %s手动执行命令：%s\n' "${C_D}" "${C_0}"
  printf '    %sbash <(curl -fsSL %s)%s\n' "${C_G}" "${LINUXMIRRORS_URL}" "${C_0}"

  printf '\n  %s操作提示：%s\n' "${C_D}" "${C_0}"
  printf '    - 若随后继续本部署流程，请在换源脚本中选择「跳过软件包升级」，\n'
  printf '      本脚本稍后会按需安装必要组件。\n'
  ui_sep
}

mirror_execute_linuxmirrors() {
  local tmp="${TMPD}/linuxmirrors.sh" rc=0
  ensure_cmd curl curl || return 1
  log "拉取 ${LINUXMIRRORS_URL}"
  if ! curl -fsSL --connect-timeout 15 --max-time 60 -o "${tmp}" "${LINUXMIRRORS_URL}" || [[ ! -s "${tmp}" ]]; then
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

# 返回：0 已执行成功；1 执行失败；2 用户未执行（仅展示说明）
mirror_change_action() {
  mirror_instructions
  printf '\n'
  if ask_yesno "已阅读以上免责声明并自愿承担风险，是否立即执行换源命令？" n; then
    mirror_execute_linuxmirrors || return 1
    return 0
  fi
  log "未自动执行；如需手动运行可复制上方命令"
  return 2
}

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
    ui_item 5 "系统软件源换源（LinuxMirrors 第三方脚本）"
    ui_quit
    ui_sep
    ask_menu "选择" 5
    reply="${UI_REPLY}"
    case "${reply}" in
      0) return 0 ;;
      1) act install_base_packages || true; scr_pause ;;
      2) act condarc_write || true; scr_pause ;;
      3) act pip_config_write || true; scr_pause ;;
      4) act mirror_check_all || true; scr_pause ;;
      5) act mirror_change_action || true; scr_pause ;;
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
      ui_kv "驱动包" "$(driver_flavor_label)"
      ui_kv "CUDA" "$(gpu_cuda_version)"
    else
      ui_kv "GPU" "$(ui_no '未检测到')"
    fi
    ui_sep
    ui_item 1 "查看 nvidia-smi / nvcc"
    ui_item 2 "安装 / 升级驱动（可选稳定分支或最新稳定版）"
    ui_item 3 "安装 / 升级 cuda-toolkit（可选）"
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
    ui_kv "Conda" "$(miniforge_ok && printf '已安装 (%s)' "${CONDA_BIN}" || printf '未安装')"
    ui_kv "Python" "$(env_python_version)"
    ui_kv "解释器" "${ENV_PY}"
    ui_kv "conda 镜像" "$(grep -qF "${CONDA_MIRROR}" "${ROOT_HOME}/.condarc" 2>/dev/null && printf '清华' || printf '未配置')"
    ui_sep
    ui_item 1 "安装 / 修复 Miniforge"
    ui_item 2 "配置 conda 清华镜像"
    ui_item 3 "创建 Python 环境（3.13 默认）"
    ui_item 4 "重建 Python 环境"
    ui_item 5 "查看 conda 环境"
    ui_item 6 "更新 conda / mamba"
    ui_item 7 "切换当前 Python 环境（仅本次会话）"
    ui_quit
    ui_sep
    ask_menu "选择" 7
    reply="${UI_REPLY}"
    case "${reply}" in
      0) return 0 ;;
      1) act miniforge_install || true; scr_pause ;;
      2) act condarc_write || true; scr_pause ;;
      3) if env_ok; then
           warn "Python 环境已存在：$(env_python_version)（${ENV_PY}）"
           if ask_yesno "是否通过重建替换为其他 Python 版本？" n; then
             act env_recreate || true
           fi
         else
           ver="$(ask_input_def "Python 版本" v_pyver "${PY_VER}")" || { warn "输入中断"; return 1; }
           act env_create "${ver}" || true
         fi
         scr_pause ;;
      4) act env_recreate || true; scr_pause ;;
      5) act env_show || true ;;
      6) act conda_update_action || true; scr_pause ;;
      7) act select_python_target || true; scr_pause ;;
    esac
  done
}

env_show() {
  if miniforge_ok; then
    "${CONDA_BIN}" env list 2>&1 || true
  else
    printf 'Miniforge/conda 未安装\n'
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
    ui_kv "目录" "${COMFY_DIR}"
    ui_kv "ComfyUI" "$(comfy_summary)"
    ui_kv "Python" "$(env_python_version)"
    ui_kv "torch" "$(pip_version torch)"
    ui_kv "torchvision" "$(pip_version torchvision)"
    ui_kv "Manager" "$(pip_version comfyui_manager)"
    ui_sep
    ui_item 1 "克隆 / 更新 ComfyUI"
    ui_item 2 "配置 pip 阿里镜像"
    ui_item 3 "安装 / 修复 / 升级 PyTorch"
    ui_item 4 "安装 / 修复 requirements"
    ui_item 5 "完整更新（代码 + 依赖 + 重启）"
    ui_item 6 "查看版本"
    ui_item 7 "切换当前 ComfyUI 目录（仅本次会话）"
    ui_quit
    ui_sep
    ask_menu "选择" 7
    reply="${UI_REPLY}"
    case "${reply}" in
      0) return 0 ;;
      1) act comfy_clone_or_pull || true; scr_pause ;;
      2) act pip_config_write || true; scr_pause ;;
      3) act torch_install 1 || true; scr_pause ;;
      4) act requirements_install || true; scr_pause ;;
      5) act comfy_update || true; scr_pause ;;
      6) act comfy_versions || true ;;
      7) act select_comfy_target || true; scr_pause ;;
    esac
  done
}

comfy_versions() {
  printf '目录：%s\n' "${COMFY_DIR}"
  printf 'ComfyUI：%s\n' "$(comfy_summary)"
  printf 'Python：%s (%s)\n' "$(env_python_version)" "${ENV_PY}"
  printf 'torch：%s\n' "$(pip_version torch)"
  printf 'torchvision：%s\n' "$(pip_version torchvision)"
  printf 'comfyui_manager：%s\n' "$(pip_version comfyui_manager)"
  page_wait "按回车返回…"
}

comfy_update() {
  local before after
  if ! comfy_git_ok || ! env_ok; then
    die_action "ComfyUI（需为 Git 仓库）或 Python 环境未就绪"
    return 1
  fi
  before="$(git -C "${COMFY_DIR}" rev-parse --short HEAD 2>/dev/null || true)"
  if ! git_net -C "${COMFY_DIR}" pull --ff-only; then
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
  if [[ ! -d "${COMFY_DIR}" ]]; then
    die_action "ComfyUI 目录不存在（${COMFY_DIR}），请先克隆或切换目录"
    return 1
  fi
  for d in "${MODEL_DIRS[@]}"; do
    base="${COMFY_DIR}/models/${d}"
    mkdir -p "${base}" || { die_action "创建 ${base} 失败"; return 1; }
    printf '%-20s %s\n' "${d}" "$(du -sh "${base}" 2>/dev/null | awk '{print $1}' || true)"
  done
  return 0
}

resolve_download_py() {
  if env_ok; then
    printf '%s' "${ENV_PY}"
    return 0
  fi
  local syspy
  syspy="$(command -v python3 2>/dev/null || true)"
  if [[ -n "${syspy}" && -x "${syspy}" ]]; then
    printf '%s' "${syspy}"
    return 0
  fi
  return 1
}

download_modelscope() {
  local repo="$1" file="$2" dir="$3" cli="" py=""
  if [[ -x "${ENV_BIN}/modelscope" ]]; then
    cli="${ENV_BIN}/modelscope"
  elif command -v modelscope >/dev/null 2>&1; then
    cli="$(command -v modelscope)"
  else
    py="$(resolve_download_py || true)"
    if [[ -z "${py}" ]]; then
      die_action "未找到可用的 Python/modelscope（请在菜单 4 准备环境或菜单 6 用 aria2c 直链）"
      return 1
    fi
    log "安装 modelscope（使用 ${py}）"
    if ! HOME="${ROOT_HOME}" "${py}" -m pip install -U modelscope; then
      die_action "modelscope 安装失败"
      return 1
    fi
    cli="$(dirname "${py}")/modelscope"
    [[ -x "${cli}" ]] || cli="$(command -v modelscope 2>/dev/null || true)"
  fi
  if [[ -z "${cli}" || ! -x "${cli}" ]]; then
    die_action "modelscope 命令不可用"
    return 1
  fi
  log "ModelScope 下载 ${repo}/${file}"
  mkdir -p "${dir}" || { die_action "创建目录失败：${dir}"; return 1; }
  if ! HOME="${ROOT_HOME}" "${cli}" download --model "${repo}" "${file}" --local_dir "${dir}"; then
    die_action "ModelScope 下载失败"
    return 1
  fi
  ls -lh "${dir}/${file}" 2>/dev/null || true
  return 0
}

download_hf() {
  local repo="$1" file="$2" dir="$3" cli="" py=""
  if [[ -x "${ENV_BIN}/hf" ]]; then
    cli="${ENV_BIN}/hf"
  elif [[ -x "${ENV_BIN}/huggingface-cli" ]]; then
    cli="${ENV_BIN}/huggingface-cli"
  elif command -v hf >/dev/null 2>&1; then
    cli="$(command -v hf)"
  elif command -v huggingface-cli >/dev/null 2>&1; then
    cli="$(command -v huggingface-cli)"
  else
    py="$(resolve_download_py || true)"
    if [[ -z "${py}" ]]; then
      die_action "未找到可用的 Python/huggingface_hub（请在菜单 4 准备环境或菜单 6 用 aria2c 直链）"
      return 1
    fi
    log "安装 huggingface_hub[cli] 与 hf_transfer（使用 ${py}）"
    if ! HOME="${ROOT_HOME}" "${py}" -m pip install -U "huggingface_hub[cli]" hf_transfer; then
      die_action "huggingface_hub 安装失败"
      return 1
    fi
    cli="$(dirname "${py}")/hf"
    [[ -x "${cli}" ]] || cli="$(dirname "${py}")/huggingface-cli"
    [[ -x "${cli}" ]] || cli="$(command -v hf 2>/dev/null || command -v huggingface-cli 2>/dev/null || true)"
  fi
  if [[ -z "${cli}" || ! -x "${cli}" ]]; then
    die_action "hf / huggingface-cli 命令不可用"
    return 1
  fi
  log "hf-mirror 下载 ${repo}/${file}"
  mkdir -p "${dir}" || { die_action "创建目录失败：${dir}"; return 1; }
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
  ensure_cmd aria2c aria2 || return 1
  mkdir -p "${dir}" || { die_action "创建目录失败：${dir}"; return 1; }
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

model_default_dir() {
  if [[ -d "${COMFY_DIR}/models/checkpoints" ]]; then
    printf '%s' "${COMFY_DIR}/models/checkpoints"
  elif [[ -d "${COMFY_DIR}" ]]; then
    printf '%s' "${COMFY_DIR}"
  else
    printf '%s' "${ROOT_HOME}"
  fi
}

model_menu() {
  local reply repo file dir url def_dir
  while :; do
    def_dir="$(model_default_dir)"
    scr_clear
    ui_rule
    printf '%s 模型目录与下载%s\n' "${C_B}" "${C_0}"
    ui_sep
    ui_kv "ComfyUI" "${COMFY_DIR}"
    ui_kv "默认保存" "${def_dir}"
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
      2) if ask_yesno "下载 SDXL Base（约 6.9GB）到 ${def_dir}？" n; then
           act download_modelscope "AI-ModelScope/stable-diffusion-xl-base-1.0" "sd_xl_base_1.0.safetensors" "${def_dir}" || true
         fi
         scr_pause ;;
      3) if ask_yesno "下载 SDXL Base（约 6.9GB）到 ${def_dir}？" n; then
           act download_hf "stabilityai/stable-diffusion-xl-base-1.0" "sd_xl_base_1.0.safetensors" "${def_dir}" || true
         fi
         scr_pause ;;
      4) url="$(ask_input "下载直链" v_nonempty)" || { warn "输入中断"; return 1; }
         file="$(ask_input "文件名" v_nonempty)" || { warn "输入中断"; return 1; }
         dir="$(ask_input_def "目标目录" v_dir "${def_dir}")" || { warn "输入中断"; return 1; }
         act download_aria2 "${url}" "${dir}" "${file}" || true; scr_pause ;;
      5) repo="$(ask_input "ModelScope 仓库（owner/name）" v_nonempty)" || { warn "输入中断"; return 1; }
         file="$(ask_input "文件名" v_nonempty)" || { warn "输入中断"; return 1; }
         dir="$(ask_input_def "目标目录" v_dir "${def_dir}")" || { warn "输入中断"; return 1; }
         act download_modelscope "${repo}" "${file}" "${dir}" || true; scr_pause ;;
      6) act copy_extra_model_paths || true; scr_pause ;;
    esac
  done
}

# ============ ComfyUI-Manager 安全等级 ============
manager_config_file() {
  local p
  for p in \
    "${COMFY_DIR}/user/__manager/config.ini" \
    "${COMFY_DIR}/user/default/ComfyUI-Manager/config.ini" \
    "${COMFY_DIR}/custom_nodes/ComfyUI-Manager/config.ini"; do
    if [[ -f "${p}" ]]; then
      printf '%s' "${p}"
      return 0
    fi
  done
  return 0
}

manager_security_raw() {
  local cfg val
  cfg="$(manager_config_file)"
  [[ -n "${cfg}" && -f "${cfg}" ]] || return 0
  val="$(awk -F= '/^[[:space:]]*security_level[[:space:]]*=/{sub(/^[[:space:]]+/, "", $2); sub(/[[:space:]]*([#;].*)?$/, "", $2); gsub(/\r/, "", $2); print $2; exit}' "${cfg}" 2>/dev/null || true)"
  printf '%s' "${val}"
}

manager_security_summary() {
  local cfg val
  if ! comfy_present; then
    printf 'ComfyUI 未安装'
    return 0
  fi
  cfg="$(manager_config_file)"
  if [[ -z "${cfg}" ]]; then
    printf 'normal（默认，未生成 config.ini）'
    return 0
  fi
  val="$(manager_security_raw)"
  if [[ -n "${val}" ]]; then
    printf '%s (%s)' "${val}" "${cfg}"
  else
    printf 'normal（默认，%s）' "${cfg}"
  fi
}

write_manager_security_level() {
  local level="$1" cfg tmp
  case "${level}" in
    normal|weak|strong) ;;
    *) die_action "不支持的 Manager 安全等级：${level}"; return 1 ;;
  esac
  if ! comfy_present; then
    die_action "未在 ${COMFY_DIR} 检测到 ComfyUI（缺少 main.py）"
    return 1
  fi
  cfg="$(manager_config_file)"
  if [[ -z "${cfg}" ]]; then
    cfg="${COMFY_DIR}/user/__manager/config.ini"
  fi
  if ! mkdir -p "$(dirname "${cfg}")"; then
    die_action "创建 Manager 配置目录失败：$(dirname "${cfg}")"
    return 1
  fi
  if [[ -f "${cfg}" ]]; then
    backup_file "${cfg}" >/dev/null || true
  fi
  tmp="$(mktemp)" || { die_action "创建临时文件失败"; return 1; }
  if [[ -f "${cfg}" ]]; then
    if ! awk -v lvl="${level}" '
      BEGIN { done=0; in_def=0; has_def=0 }
      /^[[:space:]]*\[default\][[:space:]]*\r?$/ {
        has_def=1; in_def=1; print; next
      }
      /^[[:space:]]*\[[^]]+\][[:space:]]*\r?$/ {
        if (in_def && !done) { print "security_level = " lvl; done=1 }
        in_def=0; print; next
      }
      /^[[:space:]]*security_level[[:space:]]*=/ {
        if (!done) { print "security_level = " lvl; done=1; next }
      }
      { print }
      END {
        if (!done) {
          if (!has_def) print "[default]"
          print "security_level = " lvl
        }
      }
    ' "${cfg}" > "${tmp}"; then
      rm -f -- "${tmp}"
      die_action "生成 Manager 配置失败：${cfg}"
      return 1
    fi
  else
    printf '[default]\nsecurity_level = %s\n' "${level}" > "${tmp}" || {
      rm -f -- "${tmp}"
      die_action "写入临时配置失败"
      return 1
    }
  fi
  if ! mv -f -- "${tmp}" "${cfg}"; then
    rm -f -- "${tmp}"
    die_action "写入 Manager 配置失败：${cfg}"
    return 1
  fi
  log "已将 Manager security_level 设为 ${level}（${cfg}）"
  return 0
}

manager_security_action() {
  local cur cfg target reply running=0
  if ! comfy_present; then
    die_action "未在 ${COMFY_DIR} 检测到 ComfyUI（缺少 main.py）"
    return 1
  fi
  cfg="$(manager_config_file)"
  cur="$(manager_security_raw)"
  printf '\n%sComfyUI-Manager 安全等级（security_level）%s\n' "${C_B}" "${C_0}"
  ui_sep
  ui_kv "当前等级" "${cur:-normal（默认）}"
  ui_kv "配置文件" "${cfg:-${COMFY_DIR}/user/__manager/config.ini（将新建）}"
  ui_sep
  printf '  %s说明：%s--listen 0.0.0.0 模式下，normal 会拦截网页端安装/更新插件。\n' "${C_D}" "${C_0}"
  printf '  %s警告：%sweak 会允许任何能访问 %s 端口的人安装/执行插件代码；装完建议切回 normal。\n' "${C_Y}" "${C_0}" "${PORT}"
  ui_sep
  ui_item 1 "normal（默认，推荐：公网模式禁止网页安装插件）"
  ui_item 2 "weak（允许 --listen 0.0.0.0 下网页安装插件）"
  ui_item 3 "strong（最严格限制）"
  ui_item 0 "取消并返回"
  ui_sep
  ask_menu "选择安全等级" 3 "取消"
  reply="${UI_REPLY}"
  case "${reply}" in
    0) return 0 ;;
    1) target="normal" ;;
    2) target="weak" ;;
    3) target="strong" ;;
  esac
  if [[ -n "${cfg}" && "${cur}" == "${target}" ]]; then
    log "Manager security_level 已是 ${target}（${cfg}），无需修改"
    return 0
  fi
  if [[ "${target}" == "weak" ]]; then
    if ! ask_yesno "确认将 security_level 设为 weak？（公网暴露时存在远程代码执行风险）" n; then
      warn "已取消修改 security_level"
      return 0
    fi
  fi
  write_manager_security_level "${target}" || return 1
  if { systemd_present && unit_exists && systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; } || \
     { startd_configured && [[ -n "$(comfy_running_pids)" ]]; }; then
    running=1
  fi
  if (( running )); then
    if ask_yesno "配置已写入，是否立即重启 ComfyUI 服务使其生效？" y; then
      service_restart || return 1
    else
      warn "请稍后手动重启 ComfyUI 服务使 security_level=${target} 生效"
    fi
  else
    log "提示：下次启动 ComfyUI 时将应用 security_level=${target}"
  fi
  return 0
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
    ui_kv "${PORT}" "$(if fw_has_port; then fw_active && printf '已放行' || printf '已预写（UFW 未启用）'; else printf '未放行'; fi)"
    ui_kv "Manager安全" "$(manager_security_summary)"
    ui_sep
    printf '  %s默认监听 0.0.0.0:%s，无鉴权；公网直连风险自负。%s\n' "${C_Y}" "${PORT}" "${C_0}"
    ui_sep
    ui_item 1 "查看访问地址与隧道命令"
    ui_item 2 "设置为监听 0.0.0.0:${PORT}（公网直连）"
    ui_item 3 "设置为仅回环 + SSH 隧道"
    ui_item 4 "仅检查 / 放行 UFW ${PORT} 端口（不改服务）"
    ui_item 5 "重启服务使配置生效"
    ui_item 6 "切换 Manager 安全等级（normal / weak / strong）"
    ui_quit
    ui_sep
    ask_menu "选择" 6
    reply="${UI_REPLY}"
    case "${reply}" in
      0) return 0 ;;
      1) act access_info_page || true; scr_pause ;;
      2) ACCESS_MODE="listen"; act apply_access_mode || true; scr_pause ;;
      3) ACCESS_MODE="tunnel"; act apply_access_mode || true; scr_pause ;;
      4) act ensure_fw_8188 || true; scr_pause ;;
      5) act service_restart || true; scr_pause ;;
      6) act manager_security_action || true; scr_pause ;;
    esac
  done
}

access_info_page() {
  show_access_info
  printf '\n'
  if fw_installed; then ufw status 2>&1 || true; else printf 'UFW 未安装\n'; fi
  page_wait "按回车返回…"
}

apply_access_mode() {
  if [[ "${ACCESS_MODE}" == "listen" ]]; then
    ensure_fw_8188 || warn "UFW 放行失败"
  fi
  sync_runtime_mode
  if { systemd_present && unit_exists; } || { startd_exists && [[ -f "${STARTD_FILE}" ]]; }; then
    autostart_write || return 1
    if ! systemd_present && startd_configured && (( AUTOSTART_CHANGED )) && [[ -n "$(comfy_running_pids)" ]]; then
      service_restart || return 1
    fi
  elif env_ok && comfy_present; then
    if ask_yesno "尚未配置开机自启，现在按 ${ACCESS_MODE} 模式写入自启配置？" y; then
      autostart_write || return 1
      if startd_configured; then
        startd_launch_bg || return 1
        wait_http_up || warn "服务 60 秒内未响应；查看 ${STARTD_LOG_FILE}"
      fi
    else
      warn "未写入自启服务；如手动启动，请按需加减 --listen 0.0.0.0 --port ${PORT}"
    fi
  else
    warn "未检测到可用的 ComfyUI 或 Python 环境，仅处理防火墙策略（未写自启服务）"
  fi
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
    if [[ -n "$(comfy_running_pids)" ]] || comfy_http_ok; then
      printf '/start.d 运行中'
    else
      printf '/start.d 未运行'
    fi
  elif startd_exists && [[ -f "${STARTD_FILE}" ]]; then
    printf '/start.d 缺少执行权限'
  else
    printf '未配置'
  fi
}

autostart_summary() {
  if systemd_present && unit_exists; then
    if service_enabled; then printf 'enabled'; else printf '未启用'; fi
  elif startd_configured; then
    printf '已配置 (/start.d)'
  elif startd_exists && [[ -f "${STARTD_FILE}" ]]; then
    printf '缺少执行权限 (/start.d)'
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
    ui_kv "ComfyUI" "${COMFY_DIR}"
    ui_kv "Python" "${ENV_PY}"
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
  CPU_MODE_DECIDED=1
  ACCESS_MODE="$(current_access_mode)"
  if systemd_present && unit_exists; then
    write_systemd_unit || return 1
  elif startd_exists && [[ -f "${STARTD_FILE}" ]]; then
    write_startd_script || return 1
    if (( AUTOSTART_CHANGED )) && [[ -n "$(comfy_running_pids)" ]]; then
      service_restart || return 1
    fi
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
  local size pip_cmd=""
  size="$(du -sh "${ROOT_HOME}/.cache/pip" 2>/dev/null | awk '{print $1}' || true)"
  printf 'pip 缓存：%s\n' "${size:-未知}"
  if ask_yesno "清理 pip 缓存？" n; then
    if env_ok; then
      env_py -m pip cache purge 2>/dev/null || rm -rf -- "${ROOT_HOME}/.cache/pip"
    else
      pip_cmd="$(command -v pip3 2>/dev/null || command -v pip 2>/dev/null || true)"
      if [[ -n "${pip_cmd}" ]]; then
        HOME="${ROOT_HOME}" "${pip_cmd}" cache purge 2>/dev/null || rm -rf -- "${ROOT_HOME}/.cache/pip"
      else
        rm -rf -- "${ROOT_HOME}/.cache/pip"
      fi
    fi
    log "pip 缓存已清理"
  fi
  if conda_ok && ask_yesno "清理 conda 包缓存？" n; then
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
    if [[ -n "$(comfy_running_pids)" ]] || comfy_http_ok; then
      printf '%s / %s' "$(ui_yes '/start.d active')" "$(current_access_mode)"
    else
      printf '%s / %s' "$(ui_no '/start.d 未运行')" "$(current_access_mode)"
    fi
  elif startd_exists && [[ -f "${STARTD_FILE}" ]]; then
    printf '%s' "$(ui_no '/start.d 缺少执行权限 ⚠')"
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
    if fw_has_port; then printf '%s' "$(ui_yes "active / ${PORT} 已放行")"
    else printf '%s' "$(ui_no "active / ${PORT} 未放行 ⚠")"; fi
  else
    if fw_has_port; then printf '%s' "$(ui_no "inactive（已预写 ${PORT}）")"
    else printf '%s' "$(ui_no 'inactive')"; fi
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
  ui_kv "Conda" "$(miniforge_ok && printf '已安装' || printf '未安装')"
  ui_kv "Python" "$(env_python_version)"
  ui_kv "ComfyUI" "$(comfy_summary)"
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
    discover_native_context
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
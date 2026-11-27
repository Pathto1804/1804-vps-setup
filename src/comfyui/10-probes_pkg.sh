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


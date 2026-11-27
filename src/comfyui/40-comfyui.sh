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


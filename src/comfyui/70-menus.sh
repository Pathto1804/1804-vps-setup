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


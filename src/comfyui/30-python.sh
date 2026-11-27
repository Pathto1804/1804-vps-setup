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


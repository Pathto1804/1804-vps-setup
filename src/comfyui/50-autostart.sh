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


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


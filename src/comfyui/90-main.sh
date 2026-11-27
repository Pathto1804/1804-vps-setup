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
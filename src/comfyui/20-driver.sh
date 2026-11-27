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


# ============ 模块 7：Swap（子 shell 内运行，选项与 trap 不外泄） ============
# 由来：本段原为独立发布版脚本，保留其自有 helper 与 set -uo pipefail（不启用 -e）；
# 私有函数/变量统一 swap_ 前缀，由无参数 run_swap_menu 在子 shell 中调用。
SWAP_FSTAB="/etc/fstab"
SWAP_SYSCTL_CONF="/etc/sysctl.d/99-swappiness.conf"
SWAP_SWAPPINESS_RE='^([0-9]|[1-9][0-9]|100)$'
SWAP_MIN_MB=64
SWAP_WARN_FREE_MB=2048
SWAP_ANSWER=""
SWAP_PARTIAL_FILE=""
SWAP_FSTAB_BAK=""
SWAP_FSTAB_BAK_COUNT=0
SWAP_FSTAB_BASELINE=0

swap_info() { printf '%s\n' "$*"; }
swap_ok()   { printf '%s%s%s\n' "${C_G}" "$*" "${C_0}"; }
swap_warn() { printf '%s%s[警告]%s %s\n' "${C_Y}" "${C_B}" "${C_0}" "$*" >&2; }
swap_err()  { printf '%s%s[错误]%s %s\n' "${C_R}" "${C_B}" "${C_0}" "$*" >&2; }
swap_die()  { swap_err "$*"; exit 1; }

swap_cleanup() {
  local rc=$?
  if [[ -n "${SWAP_PARTIAL_FILE}" ]]; then
    swapoff "${SWAP_PARTIAL_FILE}" 2>/dev/null || true
    rm -f -- "${SWAP_PARTIAL_FILE}"
    swap_err "操作未完成，已清理残留文件: ${SWAP_PARTIAL_FILE}"
    if [[ -n "${SWAP_FSTAB_BAK}" && -f "${SWAP_FSTAB_BAK}" ]]; then
      swap_err "如 fstab 异常，可用备份恢复: cp -a ${SWAP_FSTAB_BAK} ${SWAP_FSTAB}"
    fi
  fi
  exit "${rc}"
}

# 约定: swap_ask_option / swap_ask_value 把结果写入 SWAP_ANSWER；y/n 一律用公共 ask_yesno。
swap_ask_option() {   # "提示" "选项1" "选项2" ... -> SWAP_ANSWER = 选中项；空回车 = 空串（取消）
  local prompt="$1"; shift
  local opts=("$@") i input max
  max=${#opts[@]}
  while true; do
    printf '\n%s%s%s\n' "${C_B}" "${prompt}" "${C_0}"
    for i in "${!opts[@]}"; do
      printf '  %d) %s\n' "$((i + 1))" "${opts[$i]}"
    done
    printf '请输入编号 [1-%d]（回车=取消）: ' "${max}"
    read -r input || swap_die "输入中断，退出"
    input="${input//[[:space:]]/}"
    if [[ -z "${input}" ]]; then
      SWAP_ANSWER=""
      return 0
    fi
    if [[ "${input}" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= max )); then
      SWAP_ANSWER="${opts[input - 1]}"
      return 0
    fi
    swap_warn "无效输入: ${input}（请输入 1-${max} 的编号）"
  done
}

swap_ask_value() {   # "提示" "校验正则" "默认值"（默认值必填：留空即取它）
  local prompt="$1" regex="$2" default="$3" input
  while true; do
    printf '%s（回车=默认 %s）: ' "${prompt}" "${default}"
    read -r input || swap_die "输入中断，退出"
    input="${input:-${default}}"
    if [[ "${input}" =~ ${regex} ]]; then
      SWAP_ANSWER="${input}"
      return 0
    fi
    swap_warn "输入无效，请重新输入"
  done
}


swap_get_mem_mb()     { free -m | awk '/^Mem:/{print $2}'; }
swap_get_mem_h()      { free -h | awk '/^Mem:/{print $2}'; }
swap_get_swappiness() { sysctl -n vm.swappiness 2>/dev/null || echo '?'; }

swap_get_swappiness_default() {
  local v
  v=$(swap_get_swappiness)
  [[ "${v}" =~ ^[0-9]+$ ]] && echo "${v}" || echo 10
}

swap_active_files() { awk 'NR>1 && $2=="file"{print $1}' /proc/swaps; }
swap_is_active() { awk -v p="$1" 'NR>1 && $2=="file" && $1==p{f=1} END{exit (f?0:1)}' /proc/swaps; }
swap_show_free_h() { free -h | sed -n '1,3p' | sed 's/^/  /'; }
swap_get_fstype_of() { findmnt -n -o FSTYPE "$1" 2>/dev/null; }
swap_get_avail_mb() { df -BM --output=avail "$1" | awk 'NR==2{gsub(/M$/,"");print}'; }
swap_fstab_entries() { awk '$3=="swap"{print $1}' "${SWAP_FSTAB}" 2>/dev/null; }
swap_fstab_has() { awk -v p="$1" '$1==p{f=1} END{exit (f?0:1)}' "${SWAP_FSTAB}" 2>/dev/null; }

swap_fstab_backup() {
  SWAP_FSTAB_BAK_COUNT=$((SWAP_FSTAB_BAK_COUNT + 1))
  local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
  mkdir -p -- "${BK_ROOT}/${stamp}" || swap_die "创建备份目录 ${BK_ROOT}/${stamp} 失败"
  if (( SWAP_FSTAB_BAK_COUNT > 1 )); then
    SWAP_FSTAB_BAK="${BK_ROOT}/${stamp}/fstab.${SWAP_FSTAB_BAK_COUNT}"
  else
    SWAP_FSTAB_BAK="${BK_ROOT}/${stamp}/fstab"
  fi
  # 同秒且同目录已有 fstab（上一次运行留下的）时顺延序号，绝不覆盖旧备份
  while [[ -e "${SWAP_FSTAB_BAK}" ]]; do
    SWAP_FSTAB_BAK_COUNT=$((SWAP_FSTAB_BAK_COUNT + 1))
    SWAP_FSTAB_BAK="${BK_ROOT}/${stamp}/fstab.${SWAP_FSTAB_BAK_COUNT}"
  done
  cp -a -- "${SWAP_FSTAB}" "${SWAP_FSTAB_BAK}" || swap_die "备份 ${SWAP_FSTAB} 失败"
  # 只保留最近 BK_KEEP 份时间戳目录（与主程序同一策略，本段不进公共块故本地内联）
  local -a dirs=(); local i
  mapfile -t dirs < <(find "${BK_ROOT}" -mindepth 1 -maxdepth 1 -type d \
    -regextype posix-extended -regex '.*/[0-9]{8}-[0-9]{6}' 2>/dev/null | sort)
  if (( ${#dirs[@]} > BK_KEEP )); then
    for (( i = 0; i < ${#dirs[@]} - BK_KEEP; i++ )); do rm -rf -- "${dirs[$i]}"; done
  fi
  swap_info "已备份 fstab -> ${SWAP_FSTAB_BAK}"
}

swap_fstab_prepare() {
  swap_fstab_backup
  findmnt --verify >/dev/null 2>&1
  SWAP_FSTAB_BASELINE=$?
}

swap_fstab_verify_or_restore() {
  local rc
  findmnt --verify >/dev/null 2>&1
  rc=$?
  if (( rc != 0 )); then
    if (( SWAP_FSTAB_BASELINE == 0 )); then
      swap_err "fstab 校验失败，正在从备份恢复..."
      cat "${SWAP_FSTAB_BAK}" > "${SWAP_FSTAB}" || swap_die "恢复 ${SWAP_FSTAB} 失败，请手动执行: cp -a ${SWAP_FSTAB_BAK} ${SWAP_FSTAB}"
      swap_die "fstab 已恢复原状，操作中止"
    else
      swap_warn "fstab 校验发现问题，但修改前基线同样异常（非本次修改引起），请手动检查: ${SWAP_FSTAB}"
    fi
  fi
}

swap_fstab_append() {
  swap_fstab_prepare
  printf '%s none swap sw 0 0\n' "$1" >> "${SWAP_FSTAB}" || swap_die "写入 ${SWAP_FSTAB} 失败"
  swap_fstab_verify_or_restore
}

swap_fstab_remove() {
  local tmp
  swap_fstab_prepare
  tmp=$(mktemp) || swap_die "创建临时文件失败"
  awk -v p="$1" '$1 != p' "${SWAP_FSTAB}" > "${tmp}" || { rm -f "${tmp}"; swap_die "处理 ${SWAP_FSTAB} 失败"; }
  cat "${tmp}" > "${SWAP_FSTAB}" || { rm -f "${tmp}"; swap_die "写回 ${SWAP_FSTAB} 失败，请手动检查备份: ${SWAP_FSTAB_BAK}"; }
  rm -f "${tmp}"
  swap_fstab_verify_or_restore
}

swap_size_to_mb() {
  local s="$1" n u
  if [[ "${s}" =~ ^([0-9]+)([GgMm]?)$ ]]; then
    n=$((10#${BASH_REMATCH[1]}))
    u="${BASH_REMATCH[2],,}"
    if [[ "${u}" == "g" ]]; then
      echo $((n * 1024))
    else
      echo "${n}"
    fi
    return 0
  fi
  return 1
}

swap_recommend_mb() {
  local mem
  mem=$(swap_get_mem_mb)
  [[ "${mem}" =~ ^[0-9]+$ ]] || mem=2048
  if (( mem <= 2048 )); then echo 2048; else echo 4096; fi
}

swap_write_swappiness() {
  local val="$1"
  mkdir -p /etc/sysctl.d
  if [[ -f "${SWAP_SYSCTL_CONF}" ]] && grep -q '^vm\.swappiness' "${SWAP_SYSCTL_CONF}" 2>/dev/null; then
    sed -i "s/^vm\.swappiness.*/vm.swappiness = ${val}/" "${SWAP_SYSCTL_CONF}"
  else
    printf 'vm.swappiness = %s\n' "${val}" >> "${SWAP_SYSCTL_CONF}"
  fi
  sysctl -p "${SWAP_SYSCTL_CONF}" >/dev/null || swap_die "应用 swappiness 失败"
  swap_ok "swappiness 已设置为 ${val}（写入 ${SWAP_SYSCTL_CONF}）"
}

swap_delete_file() {
  local path="$1"
  if swap_is_active "${path}"; then
    swap_info "正在停用 ${path}（若 swap 正被使用可能需要一些时间）..."
    if ! swapoff "${path}" 2>/dev/null; then
      swap_err "swapoff 失败: ${path}"
      return 1
    fi
  fi
  rm -f -- "${path}" || { swap_err "删除文件失败: ${path}"; return 1; }
  if swap_fstab_has "${path}"; then
    swap_fstab_remove "${path}"
  fi
  swap_ok "已删除 ${path}"
}

swap_status_line() {
  local mem swap
  mem=$(swap_get_mem_h)
  swap=$(free -h | awk '/^Swap:/{print $2}')
  if [[ -z "${swap}" || "${swap}" == "0B" || "${swap}" == "0" ]]; then
    swap="未启用"
  fi
  printf '内存: %s | Swap: %s | swappiness: %s' "${mem}" "${swap}" "$(swap_get_swappiness)"
}

swap_do_status() {
  local -a files entries
  printf '\n%s========== Swap 状态 ==========%s\n' "${C_B}" "${C_0}"
  swap_info "内存使用:"
  swap_show_free_h
  echo
  mapfile -t files < <(swap_active_files)
  if ((${#files[@]} > 0)); then
    swap_info "已启用的 swap:"
    # 注意: 不带 --output，默认列即 NAME TYPE SIZE USED PRIO
    swapon --show | sed 's/^/  /'
  else
    swap_info "已启用的 swap: 无"
  fi
  echo
  if [[ -f "${SWAP_SYSCTL_CONF}" ]]; then
    swap_info "swappiness 当前值: $(swap_get_swappiness)（配置文件: ${SWAP_SYSCTL_CONF}）"
  else
    swap_info "swappiness 当前值: $(swap_get_swappiness)（无独立配置文件，使用系统默认）"
  fi
  echo
  mapfile -t entries < <(swap_fstab_entries)
  if ((${#entries[@]} > 0)); then
    swap_info "fstab 中的 swap 条目:"
    printf '  %s\n' "${entries[@]}"
  else
    swap_info "fstab 中的 swap 条目: 无"
  fi
  echo
  swap_info "根分区空间:"
  df -h / | sed -n '2p' | sed 's/^/  /'
}

swap_do_create() {
  local -a active size_opts
  local f mb mark rec_mb mem_h size_label size_mb path dir fstype avail_mb
  local cur_sw new_sw=""

  mapfile -t active < <(swap_active_files)
  if ((${#active[@]} > 0)); then
    swap_warn "检测到已启用的 swap 文件:"
    printf '  %s\n' "${active[@]}"
    if ask_yesno "替换 = 先删除以上 swap 文件，再创建新的。是否继续替换？" y; then
      for f in "${active[@]}"; do
        swap_delete_file "${f}" || swap_die "替换失败: 无法删除旧 swap 文件 ${f}"
      done
    else
      swap_info "已取消。"
      return 0
    fi
  fi

  rec_mb=$(swap_recommend_mb)
  mem_h=$(swap_get_mem_h)
  for mb in 1024 2048 4096 8192; do
    mark=""
    (( mb == rec_mb )) && mark="（推荐）"
    size_opts+=("$((mb / 1024))G${mark}")
  done
  size_opts+=("自定义大小")

  swap_ask_option "请选择 Swap 大小（物理内存: ${mem_h}）" "${size_opts[@]}"
  size_label=$SWAP_ANSWER
  [[ -z "${size_label}" ]] && { swap_info "已取消。"; return 0; }
  case "${size_label}" in
    "1G"*) size_mb=1024 ;;
    "2G"*) size_mb=2048 ;;
    "4G"*) size_mb=4096 ;;
    "8G"*) size_mb=8192 ;;
    *)
      while true; do
        swap_ask_value "自定义大小 例如 2G、512M，纯数字按 MB 计算" '^[0-9]+[GgMm]?$' "1024"
        size_mb=$(swap_size_to_mb "$SWAP_ANSWER") || { swap_warn "无法解析大小"; continue; }
        if (( size_mb < SWAP_MIN_MB )); then
          swap_warn "Swap 至少需要 ${SWAP_MIN_MB}MB"
          continue
        fi
        break
      done
      ;;
  esac

  while true; do
    swap_ask_value "Swap 文件路径" '^/[A-Za-z0-9._/-]+$' '/swapfile'
    path=$SWAP_ANSWER
    if [[ "${path}" == *".."* || "${path}" == */ ]]; then
      swap_warn "路径不合法（不能包含 .. 或以 / 结尾）"
      continue
    fi
    dir=$(dirname -- "${path}")
    if [[ ! -d "${dir}" ]]; then
      swap_warn "目录不存在: ${dir}"
      continue
    fi
    if [[ -e "${path}" ]]; then
      swap_warn "文件已存在: ${path}（请换一个路径，或先用「删除」功能清理）"
      continue
    fi
    break
  done

  fstype=$(swap_get_fstype_of "${dir}")
  case "${fstype}" in
    btrfs|zfs)
      swap_die "文件系统 ${fstype} 不支持常规方式的 swap 文件（${dir} 所在分区），本程序不处理。"
      ;;
    "")
      swap_warn "无法识别 ${dir} 的文件系统类型，将继续尝试。"
      ;;
  esac

  avail_mb=$(swap_get_avail_mb "${dir}")
  [[ "${avail_mb}" =~ ^[0-9]+$ ]] || swap_die "无法获取磁盘剩余空间"
  if (( size_mb > avail_mb )); then
    swap_err "空间不足: 需要 ${size_mb}M，该分区仅剩 ${avail_mb}M"
    return 1
  fi
  if (( avail_mb - size_mb < SWAP_WARN_FREE_MB )); then
    swap_warn "创建后该分区剩余空间仅 $((avail_mb - size_mb))M（不足 ${SWAP_WARN_FREE_MB}M），系统运行可能紧张"
    ask_yesno "仍要继续？" n || { swap_info "已取消。"; return 0; }
  fi

  cur_sw=$(swap_get_swappiness_default)
  if ask_yesno "是否同时调整 swappiness（当前: ${cur_sw}）？" y; then
    swap_ask_value "swappiness 值 0-100，VPS 常用 10" "${SWAP_SWAPPINESS_RE}" "10"
    new_sw=$SWAP_ANSWER
  fi

  printf '\n%s== 即将执行 ==%s\n' "${C_B}" "${C_0}"
  printf '  Swap 文件:   %s (%sM)\n' "${path}" "${size_mb}"
  printf '  文件系统:    %s\n' "${fstype:-未知}"
  printf '  开机持久化:  写入 %s\n' "${SWAP_FSTAB}"
  if [[ -n "${new_sw}" ]]; then
    printf '  swappiness:  %s -> %s\n' "${cur_sw}" "${new_sw}"
  fi
  printf '%s=============%s\n' "${C_B}" "${C_0}"
  ask_yesno "确认执行？" y || { swap_info "已取消。"; return 0; }

  SWAP_PARTIAL_FILE="${path}"

  swap_info "1/5 创建文件（${size_mb}M）..."
  if ! fallocate -l "${size_mb}M" "${path}" 2>/dev/null; then
    swap_warn "fallocate 不可用（${fstype:-该文件系统}可能不支持），改用 dd 逐块写入，无进度显示，请耐心等待..."
    dd if=/dev/zero of="${path}" bs=1M count="${size_mb}" status=none 2>/dev/null \
      || swap_die "创建文件失败"
  fi

  swap_info "2/5 设置权限（600）..."
  chmod 600 "${path}" || swap_die "chmod 失败"

  swap_info "3/5 格式化为 swap..."
  mkswap "${path}" >/dev/null || swap_die "mkswap 失败"

  swap_info "4/5 启用 swap..."
  if ! swapon "${path}" 2>/dev/null; then
    local virt
    virt=$(systemd-detect-virt 2>/dev/null || true)
    case "${virt}" in
      openvz|lxc|lxc-libvirt|docker|podman|systemd-nspawn)
        swap_err "swapon 失败: 当前运行在 ${virt} 容器中，内核不允许自行启用 swap。"
        swap_err "此类 VPS 无法使用本流程创建 swap（如需 swap 请联系服务商）。"
        ;;
      *)
        swap_err "swapon 失败（未知原因），可运行 dmesg | tail 查看内核日志。"
        ;;
    esac
    swap_die "已清理，未对系统留下改动"
  fi
  swap_ok "  swap 已启用"

  swap_info "5/5 写入 fstab 实现开机持久化..."
  if swap_fstab_has "${path}"; then
    swap_warn "${SWAP_FSTAB} 已存在 ${path} 的条目，跳过写入"
  else
    swap_fstab_append "${path}"
  fi

  SWAP_PARTIAL_FILE=""

  if [[ -n "${new_sw}" ]]; then
    swap_write_swappiness "${new_sw}"
  fi

  printf '\n'
  swap_ok "完成！当前内存状态:"
  swap_show_free_h
  printf '\n'
  return 0
}

swap_do_swappiness() {
  local cur val
  printf '\n%s========== 调整 swappiness ==========%s\n' "${C_B}" "${C_0}"
  cur=$(swap_get_swappiness)
  swap_info "当前值: ${cur}（0 = 尽量不用 swap，100 = 积极使用；VPS 一般推荐 10）"
  if [[ -f "${SWAP_SYSCTL_CONF}" ]]; then
    swap_info "配置文件: ${SWAP_SYSCTL_CONF}"
  else
    swap_info "尚无独立配置文件，将创建: ${SWAP_SYSCTL_CONF}"
  fi
  swap_ask_value "新的 swappiness 值 0-100" "${SWAP_SWAPPINESS_RE}" "$(swap_get_swappiness_default)"
  val=$SWAP_ANSWER
  if [[ "${val}" == "$(swap_get_swappiness)" ]]; then
    swap_info "与当前值相同，未修改。"
    return 0
  fi
  swap_write_swappiness "${val}"
  swap_info "验证: 当前生效值 = $(swap_get_swappiness)"
  return 0
}

swap_do_delete() {
  local -a files
  local f prompt
  printf '\n%s========== 关闭并删除 Swap ==========%s\n' "${C_B}" "${C_0}"

  # 候选 = 已启用的 swap 文件 + fstab 有条目、文件存在但未启用的残留
  mapfile -t files < <(swap_active_files)
  while read -r f; do
    [[ -n "${f}" ]] || continue
    [[ -f "${f}" ]] || continue
    swap_is_active "${f}" || files+=("${f}")
  done < <(swap_fstab_entries)
  if ((${#files[@]} == 0)); then
    swap_info "没有可删除的 swap 文件（无已启用的，也无 fstab 残留条目）。"
    return 0
  fi

  if awk 'NR>1 && $2=="partition"' /proc/swaps | grep -q .; then
    swap_info "注: 检测到 swap 分区，本程序只处理 swap 文件，不会触碰分区。"
  fi

  for f in "${files[@]}"; do
    printf '\n'
    if swap_is_active "${f}"; then
      prompt="确认删除 ${f} ?（停用 + 删除文件 + 移除 fstab 条目）"
    else
      prompt="确认清理 ${f} ?（当前未启用，仅删除文件 + 移除 fstab 条目）"
    fi
    if ask_yesno "${prompt}" n; then
      swap_delete_file "${f}" || swap_err "删除 ${f} 失败，已跳过"
    fi
  done

  mapfile -t files < <(swap_active_files)
  if ((${#files[@]} == 0)) && [[ -f "${SWAP_SYSCTL_CONF}" ]] \
     && ask_yesno "是否同时移除 swappiness 配置（${SWAP_SYSCTL_CONF}）？" n; then
    rm -f -- "${SWAP_SYSCTL_CONF}"
    sysctl -w vm.swappiness=60 >/dev/null
    swap_ok "已移除 ${SWAP_SYSCTL_CONF}；运行时 swappiness 已设为 60（Debian/Ubuntu 默认值），重启后同样生效"
  fi
  return 0
}

swap_menu() {
  trap 'swap_cleanup' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  while true; do
    scr_clear
    ui_rule
    printf '%s Swap 管理%s\n' "${C_B}" "${C_0}"
    ui_sep
    printf '  %s\n' "$(swap_status_line)"
    ui_sep
    ui_item 1 "查看 Swap 状态"
    ui_item 2 "创建 / 替换 Swap"
    ui_item 3 "调整 swappiness"
    ui_item 4 "关闭并删除 Swap"
    ui_quit
    ui_sep
    # 选项列表已在上面画过，这里只读编号（不重复列一遍）
    swap_pick=""
    while :; do
      printf '请选择操作 [0-4]（回车=返回主菜单）: '
      read -r swap_pick || swap_die "输入中断，退出"
      swap_pick="${swap_pick//[[:space:]]/}"
      [[ -z "${swap_pick}" ]] && swap_pick=0
      if [[ "${swap_pick}" =~ ^[0-9]+$ ]] && (( swap_pick <= 4 )); then break; fi
      swap_warn "无效输入: ${swap_pick}（请输入 0-4 的编号）"
    done
    case "${swap_pick}" in
      0) return 0 ;;
      1) swap_do_status ;;
      2) swap_do_create || true ;;
      3) swap_do_swappiness || true ;;
      4) swap_do_delete || true ;;
    esac
    scr_pause "按回车返回 Swap 菜单…"
  done
}

run_swap_menu() {
  # 子 shell 内关闭 -e 与 ERR trap，安装原有 EXIT/INT/TERM 清理语义；选项与 trap 不外泄
  (
    set +e
    set -uo pipefail
    trap - ERR
    swap_menu
  )
}

swap_auto_swappiness() {   # 自动路径固定 vm.swappiness=10
  local cur_sw
  cur_sw="$(swap_get_swappiness)"
  if [[ "${cur_sw}" == "10" ]]; then
    swap_info "swappiness 已是 10（未改动）"
  else
    swap_write_swappiness 10
  fi
  return 0
}

swap_auto_create() {   # swap_auto_create <大小MB>：标准初始化用，全程无交互
  local size_mb="$1" path="/swapfile" fstype avail_mb virt

  fstype="$(swap_get_fstype_of /)"
  case "${fstype}" in
    btrfs|zfs)
      swap_warn "根分区文件系统为 ${fstype}，不支持常规方式的 swap 文件——跳过（菜单 7 也无法处理）"
      return 0 ;;
    "")
      swap_warn "无法识别根分区文件系统类型——跳过自动创建，可用菜单 7 手动尝试"
      return 0 ;;
  esac
  virt="$(systemd-detect-virt 2>/dev/null || true)"
  case "${virt}" in
    openvz|lxc|lxc-libvirt|docker|podman|systemd-nspawn)
      swap_warn "当前运行在 ${virt} 容器中，内核不允许自行启用 swap——跳过"
      return 0 ;;
  esac
  if [[ -e "${path}" ]]; then
    if swap_fstab_has "${path}"; then
      if ! swapon "${path}" 2>/dev/null; then
        swap_err "重新启用 ${path} 失败（dmesg | tail 查看原因）——跳过"
        return 0
      fi
      swap_ok "已重新启用现有 ${path}（fstab 条目已存在，未重建）"
      swap_auto_swappiness
      return 0
    fi
    swap_warn "${path} 已存在但 fstab 无对应条目：为避免覆盖未知文件，跳过自动创建（请用菜单 7 手动处理）"
    return 0
  fi
  avail_mb="$(swap_get_avail_mb /)"
  if ! [[ "${avail_mb}" =~ ^[0-9]+$ ]]; then
    swap_warn "无法获取根分区剩余空间——跳过自动创建"
    return 0
  fi
  if (( size_mb > avail_mb )); then
    swap_warn "根分区剩余 ${avail_mb}M 不足 ${size_mb}M——跳过自动创建"
    return 0
  fi
  if (( avail_mb - size_mb < SWAP_WARN_FREE_MB )); then
    swap_warn "创建后根分区仅剩 $((avail_mb - size_mb))M（不足 ${SWAP_WARN_FREE_MB}M）——跳过自动创建，请用菜单 7 手动确认"
    return 0
  fi

  SWAP_PARTIAL_FILE="${path}"
  swap_info "1/5 创建文件（${size_mb}M）..."
  if ! fallocate -l "${size_mb}M" "${path}" 2>/dev/null; then
    swap_warn "fallocate 不可用（${fstype} 可能不支持），改用 dd 逐块写入，无进度显示，请耐心等待..."
    dd if=/dev/zero of="${path}" bs=1M count="${size_mb}" status=none 2>/dev/null \
      || swap_die "创建文件失败"
  fi
  swap_info "2/5 设置权限（600）..."
  chmod 600 "${path}" || swap_die "chmod 失败"
  swap_info "3/5 格式化为 swap..."
  mkswap "${path}" >/dev/null || swap_die "mkswap 失败"
  swap_info "4/5 启用 swap..."
  swapon "${path}" 2>/dev/null || swap_die "swapon ${path} 失败（dmesg | tail 查看原因）"
  swap_ok "  swap 已启用"
  swap_info "5/5 写入 fstab 实现开机持久化..."
  if swap_fstab_has "${path}"; then
    swap_info "${SWAP_FSTAB} 已存在 ${path} 条目，跳过写入"
  else
    swap_fstab_append "${path}"
  fi
  SWAP_PARTIAL_FILE=""

  swap_auto_swappiness
  printf '\n'
  swap_ok "完成！当前内存状态:"
  swap_show_free_h
  return 0
}

run_swap_auto() {   # run_swap_auto <大小MB>：与 run_swap_menu 同一子 shell 契约
  (
    set +e
    set -uo pipefail
    trap - ERR
    trap 'swap_cleanup' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    swap_auto_create "$1"
  )
}


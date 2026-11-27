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


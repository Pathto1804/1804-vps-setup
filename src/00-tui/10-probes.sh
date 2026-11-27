# ============ 环境前置检查 ============
require_root()   { [[ "${EUID}" -eq 0 ]] || die "需要 root 运行，请用：sudo bash ${SCRIPT_NAME}"; }
require_tty()    { [[ -t 0 ]] || die "需要交互终端运行，不支持无人值守（防锁死设计）"; }
require_distro() {
  local id
  id="$(. /etc/os-release 2>/dev/null && printf '%s' "${ID:-}")"
  [[ "${id}" == "debian" || "${id}" == "ubuntu" ]] || die "仅支持 Debian/Ubuntu，当前发行版：${id:-未知}"
}

# ============ 公共校验器：合法返回 0，非法打印原因返回 1 ============
v_ssh_port() {
  local p="$1"
  [[ "${p}" =~ ^[0-9]+$ ]]           || { printf '端口须为数字\n' >&2; return 1; }
  (( p >= 1024 && p <= 65535 ))      || { printf '端口需在 1024-65535\n' >&2; return 1; }
  [[ "${p}" != "22" && "${p}" != "2222" ]] || { printf '避开常用端口 22/2222\n' >&2; return 1; }
  return 0
}
v_user() {
  [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { printf '用户名不合法（小写字母开头，允许 a-z 0-9 _ -）\n' >&2; return 1; }
  return 0
}
v_ports_list() {
  local s="$1" p
  [[ -z "${s}" ]] && return 0
  for p in ${s//,/ }; do
    [[ "${p}" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 )) || { printf '端口列表含非法项：%s\n' "${p}" >&2; return 1; }
  done
  return 0
}
v_posint() { [[ "$1" =~ ^[0-9]+$ ]] || { printf '须为正整数\n' >&2; return 1; }; }
v_ip() {
  # 仅 IPv4（a.b.c.d）；fail2ban 的 banip/unbanip 也接受 IPv6，本脚本不处理
  local ip="$1" IFS=. parts p
  [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { printf 'IP 格式须为 a.b.c.d\n' >&2; return 1; }
  IFS=. read -r -a parts <<< "${ip}"
  for p in "${parts[@]}"; do
    (( 10#${p} <= 255 )) || { printf 'IP 每段须在 0-255\n' >&2; return 1; }
  done
  return 0
}
v_pubkey() {
  local line
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    [[ "${line}" =~ ^(ssh|ecdsa)- ]] || { printf '公钥应以 ssh- 或 ecdsa- 开头：%s\n' "${line:0:40}" >&2; return 1; }
  done <<< "$1"
  return 0
}

# ============ 状态探测：sshd ============
ssh_eff() {   # sshd -T 全量输出；失败输出空串
  local out
  out="$(sshd -T 2>/dev/null)" || true
  printf '%s' "${out}"
}

eff_val() {   # eff_val <ssh_eff 输出> <键名>：取该键生效值，缺失显示「未知」
  local out="$1" key="$2" v
  v="$(printf '%s\n' "${out}" | awk -v k="${key}" 'tolower($1)==k{v=$2} END{print v}')" || true
  printf '%s' "${v:-未知}"
}

sshd_port() {   # sshd 实际生效端口；读不到输出空串
  # 不用 `awk '/^port /{print $2; exit}'`：awk 提前退出会让 sshd 收到 SIGPIPE（141），
  # 在 set -o pipefail 下整条管道非零 → 赋值失败 → ERR trap 裸奔退出。
  local p
  p="$(sshd -T 2>/dev/null | awk '/^port /{p=$2} END{print p}' | tr -d '\r')" || true
  [[ "${p}" =~ ^[0-9]+$ ]] || { printf ''; return 0; }
  printf '%s' "${p}"
}

rand_port() { shuf -i 10000-65535 -n 1 2>/dev/null || printf '%s' 54321; }

ss_listen_ports() {   # 监听端口的本地地址列（如 0.0.0.0:2222）
  local out
  out="$(ss -tln 2>/dev/null | awk '{print $4}')" || true
  printf '%s' "${out}"
}

# ============ 状态探测：ufw ============
fw_status_numbered() {   # `ufw status numbered` 原始输出（含 Status 与带编号的规则；注意它不含 Default 行）
  # 不写成 `ufw status | grep -q`：grep 匹配即退出会让 ufw 收 SIGPIPE（141），
  # 在 set -o pipefail 下把「有规则」误判成「无规则」
  local out
  out="$(ufw status numbered 2>/dev/null)" || true
  printf '%s' "${out}"
}
fw_status_plain() {   # `ufw status` 原始输出（规则行的第一个字段就是 "端口/协议"，用于精确匹配）
  local out
  out="$(ufw status 2>/dev/null)" || true
  printf '%s' "${out}"
}
fw_status_verbose() {   # `ufw status verbose` 原始输出（唯一带 Default/Logging 行的输出）
  local out
  out="$(ufw status verbose 2>/dev/null)" || true
  printf '%s' "${out}"
}
fw_added() {   # `ufw show added` 原始输出（规则行形如 "ufw allow 22/tcp"）
  # 唯一在 ufw 未启用时也列规则的来源：未启用时 `ufw status` 只回 "Status: inactive"、
  # 一条规则都不列，但规则实际已写入 /etc/ufw/user.rules。首次初始化的自检必须靠它。
  local out
  out="$(ufw show added 2>/dev/null)" || true
  printf '%s' "${out}"
}
FW_RAW=""    # 带编号规则快照（删除要按 ufw 自己的编号；仅 ufw 启用时有意义）
FW_PLAIN=""  # 规则快照（精确匹配用）
FW_VERB=""   # 默认策略/日志快照
FW_ADDED=""  # `ufw show added` 快照（未启用时的规则来源）
fw_refresh() {
  if ! command -v ufw >/dev/null 2>&1; then
    FW_RAW=""; FW_PLAIN=""; FW_VERB=""; FW_ADDED=""
    return 0
  fi
  FW_RAW="$(fw_status_numbered)"; FW_PLAIN="$(fw_status_plain)"; FW_VERB="$(fw_status_verbose)"
  if [[ "$(fw_state)" == "active" ]]; then FW_ADDED=""; else FW_ADDED="$(fw_added)"; fi
  return 0
}
fw_first_line() { printf '%s' "${1%%$'\n'*}"; }   # 取首行：代替 `| head -n 1`（head 早退会 SIGPIPE 上游）
fw_state() {   # active / inactive / 未安装 / 未知
  if ! command -v ufw >/dev/null 2>&1; then printf '未安装'; return 0; fi
  local s
  s="$(sed -n 's/^Status: \(.*\)$/\1/p' <<<"${FW_RAW}")"
  printf '%s' "$(fw_first_line "${s:-未知}")"
}
fw_default_in() {
  local s
  s="$(sed -n 's/^Default: \([a-z]*\) (incoming).*/\1/p' <<<"${FW_VERB}")"
  printf '%s' "$(fw_first_line "${s:-未知}")"
}
fw_default_out() {
  local s
  s="$(sed -n 's/^Default: [a-z]* (incoming), \([a-z]*\) (outgoing).*/\1/p' <<<"${FW_VERB}")"
  printf '%s' "$(fw_first_line "${s:-未知}")"
}
fw_rule_count() {
  local n
  n="$(grep -cE '^\[[[:space:]]*[0-9]+\]' <<<"${FW_RAW}" || true)"
  printf '%s' "${n:-0}"
}
fw_has_rule() {   # fw_has_rule <端口/协议>：ufw 启用时读 status，未启用时读 show added（调用前需 fw_refresh）
  # 用「首字段全等」而非 grep -w：端口范围规则 1000:2000/tcp 会被 -w 误判为含 1000/tcp
  [[ -n "$1" ]] || return 1
  if [[ "$(fw_state)" == "active" ]]; then
    awk -v s="$1" '$1==s{f=1} END{exit !f}' <<<"${FW_PLAIN}"
  else
    # 未启用时 status 不列规则，改查 show added：同时匹配 `ufw allow 22/tcp`
    # 与 `ufw allow from <来源> to any port 22 proto tcp` 两种形态
    local port proto
    port="${1%%/*}"; proto="${1##*/}"
    grep -qE "^ufw (allow|limit) (${1}|from .* to any port ${port} proto ${proto})\$" <<<"${FW_ADDED}"
  fi
}
fw_rule_line() {   # fw_rule_line <编号>：输出该编号规则的文本（去掉 "[ n] " 前缀），无则空
  local n="$1" s
  s="$(sed -n "s/^\[[[:space:]]*${n}\][[:space:]]*//p" <<<"${FW_RAW}")"
  fw_first_line "${s}"
}

# ============ 状态探测：用户 / sudo / 公钥 ============
user_home() { getent passwd "$1" | cut -d: -f6; }
user_gid()  { id -g "$1"; }
user_exists() { id -u "$1" >/dev/null 2>&1; }   # 不打印 id 的报错；账号不存在返回 1
user_is_nonroot() {   # user_is_nonroot <用户>：管理员账号不得是 UID 0
  local uid
  uid="$(id -u "$1" 2>/dev/null)" || return 1
  [[ "${uid}" =~ ^[0-9]+$ ]] && (( uid > 0 ))
}


human_users() {   # 可登录普通用户（UID 1000..59999 且 shell 可用）
  local u uid shell
  while IFS=: read -r u _ uid _ _ _ shell; do
    [[ "${uid}" =~ ^[0-9]+$ ]] || continue
    (( uid >= 1000 && uid < 60000 )) || continue
    [[ "${shell}" == */nologin || "${shell}" == */false ]] && continue
    printf '%s\n' "${u}"
  done < <(getent passwd)
}

admin_from_allowusers() {   # 有效 AllowUsers 中「唯一且存在的非 root 用户」；否则输出空
  local eff raw tok
  local -a users=()
  eff="$(ssh_eff)"
  [[ -n "${eff}" ]] || return 0
  raw="$(awk 'tolower($1)=="allowusers"{for(i=2;i<=NF;i++) print $i}' <<<"${eff}")"
  while IFS= read -r tok; do
    [[ -n "${tok}" ]] || continue
    tok="${tok%%@*}"          # AllowUsers 允许 user@host 形式
    [[ -n "${tok}" ]] || continue
    users+=("${tok}")
  done <<< "${raw}"
  (( ${#users[@]} == 1 )) || return 0
  user_is_nonroot "${users[0]}" || return 0
  printf '%s' "${users[0]}"
}

auto_detect_admin() {   # 仅只读探测：未指定或账号失效时尝试从 AllowUsers 回填 ADMIN_USER
  local auto_u
  if [[ -n "${ADMIN_USER}" ]] && user_exists "${ADMIN_USER}" && user_is_nonroot "${ADMIN_USER}"; then
    return 0
  fi
  auto_u="$(admin_from_allowusers)"
  [[ -n "${auto_u}" ]] && ADMIN_USER="${auto_u}"
  return 0
}

ssh_root_only_allowusers() {   # 当前有效 AllowUsers 只列 root（可带 @host）
  local eff
  eff="$(ssh_eff)"
  [[ -n "${eff}" ]] || return 1
  awk '
    tolower($1)=="allowusers" {
      found=1
      for (i=2; i<=NF; i++) {
        users++
        user=$i
        sub(/@.*/, "", user)
        if (user != "root") other=1
      }
    }
    END { exit !(found && users > 0 && !other) }
  ' <<<"${eff}"
}


select_admin_user() {
  local allow_new=0 u new_u
  [[ "${1-}" == "--allow-new" ]] && allow_new=1
  local -a cands=()
  mapfile -t cands < <(human_users | LC_ALL=C sort)
  printf '系统现有可登录用户：\n'
  printf '  0) 创建新用户\n'
  if (( ${#cands[@]} > 0 )); then
    local i=1 c
    for c in "${cands[@]}"; do
      printf '  %d) %s\n' "${i}" "${c}"
      i=$((i + 1))
    done
  else
    printf '  （无）\n'
  fi
  while :; do
    read -rp "管理员用户（输入编号）（回车=取消）: " u || die "输入中断"
    [[ -n "${u}" ]] || return 1
    if [[ "${u}" =~ ^[0-9]+$ ]]; then
      if (( u == 0 )); then
        if (( ! allow_new )); then
          warn "当前场景不允许创建新用户"
          continue
        fi
        while :; do
          read -rp "新用户名（必填）: " new_u || die "输入中断"
          if ! v_user "${new_u}" >/dev/null 2>&1; then
            warn "用户名不合法，请重新输入"
            continue
          fi
          if user_exists "${new_u}"; then
            warn "用户 ${new_u} 已存在，请从上面的已有用户列表选择"
            break
          fi
          ADMIN_USER="${new_u}"
          log "账号 ${new_u} 尚不存在：稍后按提示创建"
          return 0
        done
        continue
      fi
      if (( ${#cands[@]} > 0 )) && (( u >= 1 && u <= ${#cands[@]} )); then
        ADMIN_USER="${cands[u - 1]}"
        return 0
      fi
      warn "无效编号：请输入 0-${#cands[@]}"
      continue
    fi
    warn "无效输入：请输入用户编号"
  done
}

resolve_admin_user() {
  # 无参数：只解析「已存在」的账号；空回车=暂不指定，返回 1
  # --allow-new：菜单 4 与标准初始化第 4 步允许选择一个尚不存在的合法用户名
  local allow_new=0
  [[ "${1-}" == "--allow-new" ]] && allow_new=1
  local u
  local -a cands=()
  if [[ -n "${ADMIN_USER}" ]] && user_exists "${ADMIN_USER}"; then
    if user_is_nonroot "${ADMIN_USER}"; then return 0; fi
    warn "root（UID 0）不能作为管理员账号；请选择或创建非 root 用户"
    ADMIN_USER=""
  fi
  if (( allow_new )); then
    select_admin_user --allow-new
    return $?
  fi

  u="$(admin_from_allowusers)"
  if [[ -n "${u}" ]]; then
    ADMIN_USER="${u}"
    log "从 sshd 有效 AllowUsers 取到管理员账号：${ADMIN_USER}"
    return 0
  fi
  mapfile -t cands < <(human_users | LC_ALL=C sort)
  printf '系统现有可登录用户：\n'
  if (( ${#cands[@]} > 0 )); then
    local i=1 c
    for c in "${cands[@]}"; do
      printf '  %d) %s\n' "${i}" "${c}"
      i=$((i + 1))
    done
  else
    printf '  （无）\n'
  fi
  while :; do
    read -rp "管理员用户名（输入编号或用户名）（回车=暂不指定）: " u || die "输入中断"
    if [[ -z "${u}" ]]; then
      warn "未指定管理员账号：本页面的写操作都会被拒绝"
      return 1
    fi
    if [[ "${u}" =~ ^[0-9]+$ ]]; then
      if (( ${#cands[@]} > 0 )) && (( u >= 1 && u <= ${#cands[@]} )); then
        ADMIN_USER="${cands[u - 1]}"
        return 0
      fi
      warn "无效编号：请输入 1-${#cands[@]}，或用户名"
      continue
    fi
    if v_user "${u}" >/dev/null 2>&1; then
      if user_exists "${u}"; then
        if ! user_is_nonroot "${u}"; then
          warn "root（UID 0）不能作为管理员账号，请选择或创建非 root 用户"
          continue
        fi
        ADMIN_USER="${u}"
        return 0
      fi
      warn "用户 ${u} 不存在：请在本菜单选 1 创建，或重新输入已有用户名"
      continue
    fi
    warn "无效输入：请输入 1-${#cands[@]} 的编号，或合法用户名（小写字母开头）"
  done
}

need_admin() {   # 写操作前置：管理员账号必须已确定且存在
  if [[ -z "${ADMIN_USER}" ]]; then
    die_action "未确定管理员账号：请先在本菜单选 1 指定用户"
    return 1
  fi
  if ! user_exists "${ADMIN_USER}"; then
    die_action "用户 ${ADMIN_USER} 不存在：请先在本菜单选 1 创建（或改用已有账号）"
    return 1
  fi
  return 0
}

pw_state() {   # P / L / NP / 未知
  local s
  s="$(passwd -S "$1" 2>/dev/null | awk '{print $2}')" || true
  printf '%s' "${s:-未知}"
}

sudo_state() {   # yes / no / unknown —— 用有效权限查询，不用文件存在性推断
  local u="$1" out rc=0
  command -v sudo >/dev/null 2>&1 || { printf 'unknown'; return 0; }
  out="$(LC_ALL=C sudo -l -U "${u}" 2>&1)" || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    if grep -q 'may not run sudo' <<<"${out}"; then printf 'no'; return 0; fi
    printf 'unknown'; return 0
  fi
  if grep -qE '^[[:space:]]+\(.*\)[[:space:]]+.*NOPASSWD:' <<<"${out}"; then
    printf 'yes'
  else
    printf 'no'
  fi
}

ak_path() {   # 管理员用户的 authorized_keys 路径；账号不存在或无主目录时输出空
  local h
  [[ -n "${ADMIN_USER}" ]] || { printf ''; return 0; }
  user_exists "${ADMIN_USER}" || { printf ''; return 0; }
  h="$(user_home "${ADMIN_USER}")" || true
  [[ -n "${h}" && -d "${h}" ]] || { printf ''; return 0; }
  printf '%s/.ssh/authorized_keys' "${h}"
}

ak_count() {   # authorized_keys 中的有效公钥行数
  local ak n
  ak="$(ak_path)"
  [[ -n "${ak}" && -f "${ak}" ]] || { printf '0'; return 0; }
  n="$(grep -cE '^(ssh|ecdsa)-' "${ak}" || true)"
  printf '%s' "${n:-0}"
}

ak_write_lines() {   # 用 AK_LINES 原子替换 authorized_keys（保留属主与 700/600 权限）
  local u="${ADMIN_USER}" h gid ak tmp
  user_exists "${u}" || { die_action "用户 ${u} 不存在，无法写 authorized_keys"; return 1; }
  h="$(user_home "${u}")" || true
  [[ -n "${h}" && -d "${h}" ]] || { die_action "无法解析 ${u} 的主目录"; return 1; }
  gid="$(user_gid "${u}")"
  ak="${h}/.ssh/authorized_keys"
  if ! { mkdir -p "${h}/.ssh" && chmod 700 "${h}/.ssh"; }; then
    die_action "无法准备 ${h}/.ssh（检查目录属主与权限）"
    return 1
  fi
  tmp="${ak}.tmp.$$"
  AK_TMP="${tmp}"
  if ! install -m 600 -o "${u}" -g "${gid}" /dev/null "${tmp}"; then
    die_action "无法在 ${h}/.ssh 创建临时文件（检查属主与权限）"
    return 1
  fi
  if (( ${#AK_LINES[@]} > 0 )); then
    printf '%s\n' "${AK_LINES[@]}" > "${tmp}"
  fi
  if ! { chown "${u}:${gid}" "${tmp}" && chmod 600 "${tmp}" && mv -f "${tmp}" "${ak}"; }; then
    die_action "替换 ${ak} 失败（临时文件已清理）"
    return 1
  fi
  AK_TMP=""        # 已落位，EXIT trap 不再清理
  chown "${u}:${gid}" "${h}/.ssh" "${ak}" 2>/dev/null || true
  chmod 700 "${h}/.ssh"
  chmod 600 "${ak}"
  return 0
}

# ============ 状态探测：fail2ban ============
f2b_installed() { command -v fail2ban-client >/dev/null 2>&1; }

jail_val() {   # 从 jail.local 读键值；文件或键缺失输出空串
  # 不用 `awk ... exit` / `| head -1`：上游收 SIGPIPE（141）在 pipefail 下会让赋值失败
  local v=""
  if [[ -f "${JAIL}" ]]; then
    v="$(awk -F'[[:space:]]*=[[:space:]]*' -v k="${1}" '$1==k{v=$2} END{print v}' "${JAIL}" | tr -d '\r')" || true
  fi
  printf '%s' "${v}"
}

f2b_status_raw() {   # `fail2ban-client status sshd` 原始输出；未就绪输出空串
  local out
  out="$(fail2ban-client status sshd 2>/dev/null)" || true
  printf '%s' "${out}"
}

f2b_param() {   # f2b_param <键> <默认值>：jail.local 有值优先，否则用默认
  local v
  v="$(jail_val "$1")"
  if [[ -n "${v}" ]]; then printf '%s' "${v}"; else printf '%s' "$2"; fi
}

# ============ 状态探测：其他 ============
swap_active() { [[ -n "$(swapon --show 2>/dev/null)" ]]; }
swap_summary() {
  local s
  s="$(free -h 2>/dev/null | awk '/^Swap:/{print $2}')" || true
  if [[ -z "${s}" || "${s}" == "0B" || "${s}" == "0" ]]; then printf '未启用'; else printf '%s' "${s}"; fi
}
swappiness_now() {
  local v
  v="$(sysctl -n vm.swappiness 2>/dev/null | tr -d '\r')" || true
  printf '%s' "${v:-未知}"
}
bbr_cc() {
  local v
  v="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | tr -d '\r')" || true
  printf '%s' "${v:-未知}"
}
bbr_qdisc() {
  local v
  v="$(sysctl -n net.core.default_qdisc 2>/dev/null | tr -d '\r')" || true
  printf '%s' "${v:-未知}"
}
ua_enabled() {
  [[ -f "${UA_FILE}" ]] || return 1
  grep -q 'APT::Periodic::Update-Package-Lists "[1-9]' "${UA_FILE}" || return 1
  grep -q 'APT::Periodic::Unattended-Upgrade "[1-9]' "${UA_FILE}" || return 1
  return 0
}
ua_state() { if ua_enabled; then printf '已启用'; else printf '未启用'; fi; }
ntp_active() {
  local out
  out="$(timedatectl 2>/dev/null)" || true
  grep -q 'NTP service: active' <<<"${out}"
}
cur_tz() {
  local out
  out="$(timedatectl show -p Timezone --value 2>/dev/null)" || true
  printf '%s' "${out:-未知}"
}
timezone_valid() {   # timezone_valid <时区>：只接受 timedatectl 声明的时区
  local zones
  [[ -n "$1" ]] || return 1
  zones="$(timedatectl list-timezones 2>/dev/null)" || return 1
  grep -Fxq -- "$1" <<<"${zones}"
}

pkg_installed() {
  local st
  st="$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" || true
  [[ "${st}" == *"install ok installed"* ]]
}
missing_pkgs() {   # 输出未安装的包名（空格分隔）
  local p
  for p in "$@"; do
    pkg_installed "${p}" || printf '%s ' "${p}"
  done
}
apt_pending_count() {
  local out n
  out="$(DEBIAN_FRONTEND=noninteractive apt-get -s full-upgrade 2>/dev/null)" || true
  n="$(grep -cE '^(Inst|Remv) ' <<<"${out}" || true)"
  printf '%s' "${n:-0}"
}

# ============ 交互原语（显示层） ============
# 显示宽度写入全局 DW：CJK/全角按 2 列，不依赖 wc 或 locale 子进程
_disp_w() {
  local s="$1" i=0 w=0 c n
  while (( i < ${#s} )); do
    c="${s:i:1}"
    printf -v n '%d' "'${c}"
    (( n < 0 )) && n=$(( -n ))
    if (( n < 128 )); then
      w=$((w+1)); i=$((i+1))
    elif (( n <= 255 )); then
      # C locale：按 UTF-8 字节序列长度推进，宽字符仍按 2 列
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
ui_kv() {   # ui_kv <标签> <值>：标签列按显示宽度对齐到 12 列
  local label="$1" val="$2" pad
  _disp_w "${label}"; pad=$(( 12 - DW ))
  (( pad < 1 )) && pad=1
  printf '  %s%*s%s\n' "${label}" "${pad}" '' "${val}"
}
ui_item() { printf '  %s%s%s) %s\n' "${C_G}" "$1" "${C_0}" "$2"; }
ui_quit() { printf '  %s0%s) 返回主菜单\n' "${C_R}" "${C_0}"; }
ui_yes()  { printf '%s%s%s' "${C_G}" "$1" "${C_0}"; }
ui_no()   { printf '%s%s%s' "${C_Y}" "$1" "${C_0}"; }


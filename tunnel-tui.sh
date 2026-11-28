#!/usr/bin/env bash
# 本地 SSH 隧道辅助 TUI · 与 00-tui.sh / comfyui-tui.sh 并列的本地客户端入口
# 运行在用户本地电脑（Linux / macOS / WSL / Windows Git Bash），不要求 root。
# 用法：bash <(curl -fsSL https://raw.githubusercontent.com/Pathto1804/1804-vps-setup/main/tunnel-tui.sh)
#   或：下载后 bash tunnel-tui.sh
# 不保存项目私有状态：所有输入仅存在于本次进程，可选只读读取 ~/.ssh/config 中的 Host 别名。

set -euo pipefail
# 仅 Bash >= 4.4 开启 inherit_errexit；兼容 macOS 默认 Bash 3.2
if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )); then
  shopt -s inherit_errexit
fi

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# 本次进程内的状态；不落盘
SSH_BIN=""
SSH_DEST=""
LOCAL_PORT="8188"
REMOTE_HOST="127.0.0.1"
REMOTE_PORT="8188"
HAS_EXIT_ON_FAIL=0
HAS_ALIVE_INTERVAL=0
HAS_ALIVE_COUNT=0
_TMP_HAS_EXIT=0
_TMP_HAS_INT=0
_TMP_HAS_CNT=0
TUNNEL_INTERRUPTED=0
UI_REPLY=""
MAIN_REPLY=""
DW=0
TOK_OUT=()
SSH_BASE_ARGS=()
EXTRA_FORWARDS=()
TUNNEL_CMD=()

if [[ -t 1 ]]; then
  C_G=$'\e[32m'; C_Y=$'\e[33m'; C_R=$'\e[31m'; C_B=$'\e[1m'; C_D=$'\e[90m'; C_0=$'\e[0m'
else
  C_G=''; C_Y=''; C_R=''; C_B=''; C_D=''; C_0=''
fi

log()  { printf '%s[%s]%s %s\n' "${C_B}" "${SCRIPT_NAME}" "${C_0}" "$*"; }
warn() { printf '%s[%s]%s %s\n' "${C_Y}" "${SCRIPT_NAME}" "${C_0}" "$*" >&2; }
die()  { printf '%s[%s]%s %s\n' "${C_R}" "${SCRIPT_NAME}" "${C_0}" "$*" >&2; exit 1; }

err_trap() { die "行 ${1}: ${2}"; }
die_action() { warn "$*"; return 1; }

act() {
  local rc=0 had_e=0
  case "$-" in *e*) had_e=1 ;; esac
  set +e
  trap - ERR
  "$@" || rc=$?
  trap 'err_trap "${LINENO}" "${BASH_COMMAND}"' ERR
  if (( had_e )); then set -e; fi
  return "${rc}"
}
trap 'err_trap "${LINENO}" "${BASH_COMMAND}"' ERR

ui_abort() {
  printf '\n%s[退出]%s 已中止。\n' "${C_Y}" "${C_0}" >&2
  exit 130
}
trap 'ui_abort' INT

# ============ 屏幕契约 ============
SCR_CLEAR=0
if [[ -t 1 ]]; then
  case "${TERM:-}" in
    ''|dumb|unknown) SCR_CLEAR=0 ;;
    *) SCR_CLEAR=1 ;;
  esac
fi

scr_clear() {
  if (( SCR_CLEAR )); then printf '\e[H\e[2J'; fi
  return 0
}

scr_pause() {
  local msg="${1:-按回车继续…}" _x
  printf '%s%s%s' "${C_D}" "${msg}" "${C_0}"
  read -r _x || true
  return 0
}

page_wait() {
  scr_pause "${1:-按回车返回…}"
  scr_clear
  return 0
}

# ============ 环境探测 ============
require_tty() { [[ -t 0 ]] || die "需要交互终端运行，不支持非交互管道输入"; }

to_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

os_label() {
  local u
  u="$(uname -s 2>/dev/null || printf '未知')"
  case "${u}" in
    Darwin) printf 'macOS' ;;
    Linux)
      if grep -qi microsoft /proc/version 2>/dev/null; then
        printf 'Windows WSL'
      else
        printf 'Linux'
      fi
      ;;
    MINGW*|MSYS*|CYGWIN*) printf 'Windows Git Bash' ;;
    *) printf '%s' "${u}" ;;
  esac
}

detect_ssh_bin() {
  local found u
  u="$(uname -s 2>/dev/null || true)"
  found="$(command -v ssh 2>/dev/null || true)"
  case "${u}" in
    MINGW*|MSYS*|CYGWIN*)
      if [[ -x "/usr/bin/ssh" && "${found}" == *"/System32/OpenSSH/"* ]]; then
        SSH_BIN="/usr/bin/ssh"
        return 0
      fi
      ;;
  esac
  if [[ -n "${found}" && -x "${found}" ]]; then
    SSH_BIN="${found}"
    return 0
  fi
  if [[ -x "/usr/bin/ssh" ]]; then
    SSH_BIN="/usr/bin/ssh"
    return 0
  fi
  return 1
}

# ============ 交互原语 ============
ask_yesno() {
  local prompt="$1" def="${2:-n}" ans hint low
  case "${def}" in
    y|Y) def=y; hint="是" ;;
    *)   def=n; hint="否" ;;
  esac
  while :; do
    read -rp "${prompt} [y/n]（回车=${hint}） " ans || return 1
    ans="${ans:-${def}}"
    low="$(to_lower "${ans}")"
    case "${low}" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *)     printf '%s无效输入：请输入 y 或 n。\n' "${C_Y}" >&2 ;;
    esac
  done
}

ask_input() {
  local prompt="$1" v="$2" val
  while :; do
    read -rp "${prompt}（必填）: " val || die "输入中断"
    if "${v}" "${val}"; then printf '%s' "${val}"; return 0; fi
  done
}

ask_input_def() {
  local prompt="$1" v="$2" def="$3" val
  while :; do
    read -rp "${prompt}（回车=默认 ${def}）: " val || die "输入中断"
    val="${val:-${def}}"
    if "${v}" "${val}"; then printf '%s' "${val}"; return 0; fi
  done
}

ask_menu() {
  local prompt="$1" max="$2" zero="${3:-返回主菜单}" input
  while :; do
    read -rp "${prompt} [0-${max}]（回车=${zero}）: " input || die "输入中断"
    input="${input:-0}"
    if [[ "${input}" =~ ^[0-9]+$ ]] && (( 10#${input} <= max )); then
      UI_REPLY="$((10#${input}))"; return 0
    fi
    warn "无效输入：请输入 0-${max}"
  done
}

# 校验器
v_nonempty() { [[ -n "$1" ]] || { printf '不能为空\n' >&2; return 1; }; }
v_port() {
  if [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); then
    return 0
  fi
  printf '端口必须是 1-65535 的整数\n' >&2
  return 1
}
v_host() {
  if [[ -n "$1" && ! "$1" =~ [[:space:]\;\|\&\`\<\>] ]]; then
    return 0
  fi
  printf '主机地址格式无效\n' >&2
  return 1
}

# 显示宽度：CJK/全角按 2 列（兼容 Bash 3.2）
_disp_w() {
  local s="$1" i=0 w=0 c n
  while (( i < ${#s} )); do
    c="${s:i:1}"
    printf -v n '%d' "'${c}"
    (( n < 0 )) && n=$(( -n ))
    if (( n < 128 )); then
      w=$((w+1)); i=$((i+1))
    elif (( n <= 255 )); then
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
ui_kv() {
  local label="$1" val="$2" pad
  _disp_w "${label}"; pad=$(( 12 - DW ))
  (( pad < 1 )) && pad=1
  printf '  %s%*s%s\n' "${label}" "${pad}" '' "${val}"
}
ui_item() { printf '  %s%s%s) %s\n' "${C_G}" "$1" "${C_0}" "$2"; }
ui_quit() { printf '  %s0%s) 返回主菜单\n' "${C_R}" "${C_0}"; }
ui_yes()  { printf '%s%s%s' "${C_G}" "$1" "${C_0}"; }
ui_no()   { printf '%s%s%s' "${C_Y}" "$1" "${C_0}"; }

# ============ 安全分词与 SSH 命令解析（无 eval） ============
tokenize_ssh_cmd() {
  local raw="$1" i=0 len c next mode="none" tok="" has_tok=0
  TOK_OUT=()
  # 去掉回车与首尾空白
  raw="${raw//$'\r'/}"
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  if [[ -z "${raw}" ]]; then
    die_action "输入为空"
    return 1
  fi
  len=${#raw}
  while (( i < len )); do
    c="${raw:i:1}"
    if (( i + 1 < len )); then next="${raw:i+1:1}"; else next=""; fi
    case "${mode}" in
      none)
        case "${c}" in
          ' '|$'\t')
            if (( has_tok )); then
              TOK_OUT+=("${tok}")
              tok=""
              has_tok=0
            fi
            ;;
          "'")
            mode="single"
            has_tok=1
            ;;
          '"')
            mode="double"
            has_tok=1
            ;;
          ';'|'|'|'&'|'<'|'>'|'`')
            die_action "检测到不安全字符 '${c}'（请只输入单条 ssh 登录命令，不要带管道或分号）"
            return 1
            ;;
          '$')
            if [[ "${next}" == "(" || "${next}" == "{" ]]; then
              die_action "检测到命令/变量替换 '\$${next}'，已拒绝解析"
              return 1
            fi
            tok+="${c}"
            has_tok=1
            ;;
          '\')
            # 保留 Windows 路径的反斜杠（如 C:\Users\...），仅对空白/引号/反斜杠转义
            if [[ "${next}" == " " || "${next}" == '"' || "${next}" == "'" || "${next}" == '\' ]]; then
              tok+="${next}"
              i=$((i + 1))
            else
              tok+="${c}"
            fi
            has_tok=1
            ;;
          *)
            tok+="${c}"
            has_tok=1
            ;;
        esac
        ;;
      single)
        if [[ "${c}" == "'" ]]; then
          mode="none"
        else
          tok+="${c}"
        fi
        ;;
      double)
        if [[ "${c}" == '"' ]]; then
          mode="none"
        elif [[ "${c}" == '`' ]] || [[ "${c}" == '$' && "${next}" == "(" ]]; then
          die_action "双引号内不允许命令替换"
          return 1
        elif [[ "${c}" == '\' ]]; then
          if [[ "${next}" == '"' || "${next}" == '\' || "${next}" == '$' || "${next}" == '`' ]]; then
            tok+="${next}"
            i=$((i + 1))
          else
            tok+="${c}"
          fi
        else
          tok+="${c}"
        fi
        ;;
    esac
    i=$((i + 1))
  done
  if [[ "${mode}" != "none" ]]; then
    die_action "引号未闭合，请检查粘贴的命令"
    return 1
  fi
  if (( has_tok )); then
    TOK_OUT+=("${tok}")
  fi
  return 0
}

expand_tilde_arg() {
  local v="$1" tilde='~'
  if [[ -n "${HOME:-}" && "${v}" == "${tilde}/"* ]]; then
    printf '%s/%s' "${HOME%/}" "${v:2}"
  else
    printf '%s' "${v}"
  fi
}

check_ssh_opt_value() {
  local opt_val low
  opt_val="$1"
  low="$(to_lower "${opt_val}")"
  case "${low}" in
    exitonforwardfailure=*) _TMP_HAS_EXIT=1 ;;
    serveraliveinterval=*)  _TMP_HAS_INT=1 ;;
    serveralivecountmax=*)  _TMP_HAS_CNT=1 ;;
  esac
}

parse_ssh_command() {
  local raw="$1" interactive="${2:-1}"
  local idx=0 count tok first_low expect_arg="" dest="" after_dd=0
  local -a parsed_args=() dropped_cmds=()
  local keep_existing_L=0 asked_L=0
  _TMP_HAS_EXIT=0
  _TMP_HAS_INT=0
  _TMP_HAS_CNT=0

  tokenize_ssh_cmd "${raw}" || return 1
  count=${#TOK_OUT[@]}
  (( count > 0 )) || { die_action "未解析出有效参数"; return 1; }

  first_low="$(to_lower "$(basename -- "${TOK_OUT[0]}")")"
  if [[ "${first_low}" == "ssh" || "${first_low}" == "ssh.exe" ]]; then
    idx=1
  fi
  if (( idx >= count )); then
    die_action "只输入了 ssh，缺少服务器地址（如 root@1.2.3.4）"
    return 1
  fi

  while (( idx < count )); do
    tok="${TOK_OUT[idx]}"
    if [[ -n "${expect_arg}" ]]; then
      tok="$(expand_tilde_arg "${tok}")"
      if [[ "${expect_arg}" == "L" ]]; then
        if (( interactive && asked_L == 0 )); then
          warn "原命令已自带转发规则：-L ${tok}"
          if ask_yesno "忽略原 -L，改由本工具管理端口转发？" y; then
            keep_existing_L=0
          else
            keep_existing_L=1
          fi
          asked_L=1
        fi
        if (( keep_existing_L )); then
          parsed_args+=("-L" "${tok}")
        fi
      else
        if [[ "${expect_arg}" == "o" ]]; then
          check_ssh_opt_value "${tok}"
        fi
        parsed_args+=("-${expect_arg}" "${tok}")
      fi
      expect_arg=""
      idx=$((idx + 1))
      continue
    fi

    if (( after_dd == 0 )) && [[ "${tok}" == "--" ]]; then
      after_dd=1
      parsed_args+=("--")
      idx=$((idx + 1))
      continue
    fi

    if (( after_dd == 0 )) && [[ "${tok}" == -* && "${tok}" != "-" ]]; then
      local rest="${tok#-}" cleaned="" j rlen ch inline_val
      rlen=${#rest}
      for (( j = 0; j < rlen; j++ )); do
        ch="${rest:j:1}"
        case "${ch}" in
          N)
            continue
            ;;
          f)
            warn "原命令包含 -f（后台运行）；本工具会在前台运行以便按 Ctrl+C 关闭，已移除 -f"
            continue
            ;;
          B|b|c|D|E|e|F|I|i|J|L|l|m|O|o|p|Q|R|S|W|w)
            if [[ -n "${cleaned}" ]]; then
              parsed_args+=("-${cleaned}")
              cleaned=""
            fi
            if (( j + 1 < rlen )); then
              inline_val="$(expand_tilde_arg "${rest:j+1}")"
              if [[ "${ch}" == "L" ]]; then
                if (( interactive && asked_L == 0 )); then
                  warn "原命令已自带转发规则：-L ${inline_val}"
                  if ask_yesno "忽略原 -L，改由本工具管理端口转发？" y; then
                    keep_existing_L=0
                  else
                    keep_existing_L=1
                  fi
                  asked_L=1
                fi
                if (( keep_existing_L )); then
                  parsed_args+=("-L" "${inline_val}")
                fi
              else
                if [[ "${ch}" == "o" ]]; then
                  check_ssh_opt_value "${inline_val}"
                fi
                parsed_args+=("-${ch}" "${inline_val}")
              fi
            else
              expect_arg="${ch}"
            fi
            break
            ;;
          *)
            cleaned+="${ch}"
            ;;
        esac
      done
      if [[ -n "${cleaned}" ]]; then
        parsed_args+=("-${cleaned}")
      fi
      idx=$((idx + 1))
      continue
    fi

    # 位置参数：第一个是登录目标（user@host / alias），后续属于远程命令
    if [[ -z "${dest}" ]]; then
      dest="${tok}"
      parsed_args+=("${tok}")
    else
      dropped_cmds+=("${tok}")
    fi
    idx=$((idx + 1))
  done

  if [[ -n "${expect_arg}" ]]; then
    die_action "选项 -${expect_arg} 缺少参数值"
    return 1
  fi
  if [[ -z "${dest}" ]]; then
    die_action "未识别到服务器地址（例如 root@1.2.3.4 或 SSH 配置别名）"
    return 1
  fi
  if (( ${#dropped_cmds[@]} > 0 )); then
    warn "原命令末尾附带远端指令（${dropped_cmds[*]}），与 -N 仅转发端口冲突，已自动剔除"
  fi

  HAS_EXIT_ON_FAIL="${_TMP_HAS_EXIT}"
  HAS_ALIVE_INTERVAL="${_TMP_HAS_INT}"
  HAS_ALIVE_COUNT="${_TMP_HAS_CNT}"
  SSH_DEST="${dest}"
  SSH_BASE_ARGS=("${parsed_args[@]}")
  return 0
}

build_tunnel_cmd() {
  local fwd
  TUNNEL_CMD=("${SSH_BIN}" -N -L "${LOCAL_PORT}:${REMOTE_HOST}:${REMOTE_PORT}")
  if (( ${#EXTRA_FORWARDS[@]} > 0 )); then
    for fwd in "${EXTRA_FORWARDS[@]}"; do
      TUNNEL_CMD+=(-L "${fwd}")
    done
  fi
  if (( HAS_EXIT_ON_FAIL == 0 )); then
    TUNNEL_CMD+=(-o "ExitOnForwardFailure=yes")
  fi
  if (( HAS_ALIVE_INTERVAL == 0 )); then
    TUNNEL_CMD+=(-o "ServerAliveInterval=30")
  fi
  if (( HAS_ALIVE_COUNT == 0 )); then
    TUNNEL_CMD+=(-o "ServerAliveCountMax=3")
  fi
  if (( ${#SSH_BASE_ARGS[@]} > 0 )); then
    TUNNEL_CMD+=("${SSH_BASE_ARGS[@]}")
  fi
}

format_cmd_preview() {
  local out="" a esc
  for a in "$@"; do
    if [[ "${a}" =~ [[:space:]\"\'\\] ]]; then
      esc="${a//\"/\\\"}"
      out+="\"${esc}\" "
    else
      out+="${a} "
    fi
  done
  printf '%s' "${out% }"
}

# ============ 本地端口占用检测 ============
local_port_in_use() {
  local port="$1" out
  if command -v ss >/dev/null 2>&1; then
    out="$(ss -tln 2>/dev/null || true)"
    grep -qE ":${port}[[:space:]]" <<< "${out}" && return 0
    return 1
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1 && return 0
    return 1
  fi
  if command -v netstat >/dev/null 2>&1; then
    out="$(netstat -an 2>/dev/null || true)"
    grep -qiE "[:.]${port}[[:space:]].*LISTEN" <<< "${out}" && return 0
    return 1
  fi
  # 最后兜底：Bash 内置 TCP 探测
  if ( exec 3<>"/dev/tcp/127.0.0.1/${port}" ) 2>/dev/null; then
    exec 3>&- 2>/dev/null || true
    return 0
  fi
  return 1
}

find_next_free_port() {
  local p="$1" tries=0
  while (( tries < 50 )); do
    if ! local_port_in_use "${p}"; then
      printf '%s' "${p}"
      return 0
    fi
    p=$((10#${p} + 1))
    tries=$((tries + 1))
  done
  printf '%s' "$((10#$1 + 1))"
}

# ============ 读取 ~/.ssh/config 别名（只读） ============
list_ssh_config_hosts() {
  local cfg="${HOME:-}/.ssh/config" line rest tok
  [[ -f "${cfg}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    case "${line}" in
      Host\ *|host\ *|Host$'\t'*|host$'\t'*)
        rest="${line#?ost}"
        for tok in ${rest}; do
          case "${tok}" in
            *'*'*|*'?'*|'!'*) continue ;;
            *) printf '%s\n' "${tok}" ;;
          esac
        done
        ;;
    esac
  done < "${cfg}"
}

# ============ 业务动作 ============
configure_ssh_cmd() {
  local -a hosts=()
  local h idx=1 choice input
  while IFS= read -r h; do
    [[ -n "${h}" ]] && hosts+=("${h}")
  done < <(list_ssh_config_hosts || true)

  printf '\n请输入你平时用来连接这台服务器的完整 SSH 命令：\n'
  printf '  示例 1：%sssh root@1.2.3.4%s\n' "${C_D}" "${C_0}"
  printf '  示例 2：%sssh -p 23456 ubuntu@1.2.3.4%s\n' "${C_D}" "${C_0}"
  printf '  示例 3：%sssh -i ~/.ssh/id_ed25519 -p 23456 ubuntu@1.2.3.4%s\n' "${C_D}" "${C_0}"
  if (( ${#hosts[@]} > 0 )); then
    printf '\n检测到本机 ~/.ssh/config 已有别名（也可直接输入编号）：\n'
    for h in "${hosts[@]}"; do
      printf '  %d) ssh %s\n' "${idx}" "${h}"
      idx=$((idx + 1))
    done
  fi
  printf '\n'

  while :; do
    input="$(ask_input "粘贴 SSH 命令（或输入别名编号）" v_nonempty)" || return 1
    if [[ "${input}" =~ ^[0-9]+$ ]] && (( ${#hosts[@]} > 0 )) && (( 10#${input} >= 1 && 10#${input} <= ${#hosts[@]} )); then
      choice="${hosts[$((10#${input} - 1))]}"
      input="ssh ${choice}"
      log "已选择别名：${input}"
    fi
    if parse_ssh_command "${input}" 1; then
      build_tunnel_cmd
      printf '\n%s已解析成功，将使用的隧道命令：%s\n' "${C_G}" "${C_0}"
      printf '  %s\n' "$(format_cmd_preview "${TUNNEL_CMD[@]}")"
      return 0
    fi
    warn "请重新输入有效的 SSH 登录命令"
  done
}

port_menu() {
  local reply p lp rp rh
  while :; do
    scr_clear
    ui_rule
    printf '%s 设置转发端口%s\n' "${C_B}" "${C_0}"
    ui_sep
    ui_kv "主转发" "本地 ${LOCAL_PORT} -> ${REMOTE_HOST}:${REMOTE_PORT}"
    if (( ${#EXTRA_FORWARDS[@]} > 0 )); then
      ui_kv "额外转发" "${EXTRA_FORWARDS[*]}"
    else
      ui_kv "额外转发" "无"
    fi
    ui_sep
    ui_item 1 "修改本地端口（当前 ${LOCAL_PORT}；避免与本机端口冲突）"
    ui_item 2 "修改远端端口（当前 ${REMOTE_PORT}；ComfyUI 默认 8188）"
    ui_item 3 "修改远端主机（当前 ${REMOTE_HOST}；一般保持 127.0.0.1）"
    ui_item 4 "追加一条额外端口转发"
    ui_item 5 "清空额外转发并恢复默认 8188 -> 127.0.0.1:8188"
    ui_quit
    ui_sep
    ask_menu "选择" 5
    reply="${UI_REPLY}"
    case "${reply}" in
      0) return 0 ;;
      1)
        p="$(ask_input_def "本地监听端口" v_port "${LOCAL_PORT}")" || return 1
        LOCAL_PORT="$((10#${p}))"
        log "本地端口已设为 ${LOCAL_PORT}"
        scr_pause
        ;;
      2)
        p="$(ask_input_def "远端目标端口" v_port "${REMOTE_PORT}")" || return 1
        REMOTE_PORT="$((10#${p}))"
        log "远端端口已设为 ${REMOTE_PORT}"
        scr_pause
        ;;
      3)
        rh="$(ask_input_def "远端目标主机" v_host "${REMOTE_HOST}")" || return 1
        REMOTE_HOST="${rh}"
        log "远端主机已设为 ${REMOTE_HOST}"
        scr_pause
        ;;
      4)
        lp="$(ask_input "额外本地端口" v_port)" || return 1
        rh="$(ask_input_def "远端目标主机" v_host "127.0.0.1")" || return 1
        rp="$(ask_input "额外远端端口" v_port)" || return 1
        EXTRA_FORWARDS+=("$((10#${lp})):${rh}:$((10#${rp}))")
        log "已追加转发：$((10#${lp})):${rh}:$((10#${rp}))"
        scr_pause
        ;;
      5)
        LOCAL_PORT="8188"
        REMOTE_HOST="127.0.0.1"
        REMOTE_PORT="8188"
        EXTRA_FORWARDS=()
        log "已恢复默认 8188 -> 127.0.0.1:8188"
        scr_pause
        ;;
    esac
  done
}

preflight_check() {
  local g_out
  if [[ -z "${SSH_BIN}" ]]; then
    die_action "未检测到 ssh 客户端，请先安装 OpenSSH"
    return 1
  fi
  printf 'SSH 客户端：%s\n' "${SSH_BIN}"
  printf 'SSH 版本：%s\n' "$("${SSH_BIN}" -V 2>&1 || true)"
  if local_port_in_use "${LOCAL_PORT}"; then
    warn "本地端口 ${LOCAL_PORT} 已被占用（可能是已有隧道或其他程序）"
  else
    log "本地端口 ${LOCAL_PORT} 空闲可用"
  fi
  if [[ -z "${SSH_DEST}" ]]; then
    warn "尚未设置 SSH 登录命令（可去菜单 2 输入）"
    return 0
  fi
  build_tunnel_cmd
  printf '\n即将使用的隧道命令：\n  %s\n' "$(format_cmd_preview "${TUNNEL_CMD[@]}")"
  printf '\n[ssh -G 配置解析结果（不发起网络连接）]\n'
  if (( ${#SSH_BASE_ARGS[@]} > 0 )); then
    g_out="$("${SSH_BIN}" -G "${SSH_BASE_ARGS[@]}" 2>&1 || true)"
    awk '/^(hostname|port|user|identityfile) / {print "  " $0}' <<< "${g_out}"
  fi
  return 0
}

start_tunnel() {
  local alt rc=0 fwd fwd_lp
  if [[ -z "${SSH_BIN}" ]]; then
    die_action "未检测到 ssh 客户端，请先安装 OpenSSH"
    return 1
  fi
  if [[ -z "${SSH_DEST}" ]]; then
    configure_ssh_cmd || return 1
  fi

  if local_port_in_use "${LOCAL_PORT}"; then
    alt="$(find_next_free_port "$((10#${LOCAL_PORT} + 1))")"
    warn "检测到本机端口 ${LOCAL_PORT} 已被占用！"
    if ask_yesno "改用空闲的本地端口 ${alt} 转发到远端 ${REMOTE_HOST}:${REMOTE_PORT}？" y; then
      LOCAL_PORT="${alt}"
    else
      warn "继续尝试使用 ${LOCAL_PORT}（若确实冲突，ExitOnForwardFailure 会立即报错退出）"
    fi
  fi
  if (( ${#EXTRA_FORWARDS[@]} > 0 )); then
    for fwd in "${EXTRA_FORWARDS[@]}"; do
      fwd_lp="${fwd%%:*}"
      if local_port_in_use "${fwd_lp}"; then
        warn "额外转发的本地端口 ${fwd_lp} 已被占用（若冲突连接会因 ExitOnForwardFailure 退出）"
      fi
    done
  fi

  build_tunnel_cmd
  printf '\n'
  ui_sep
  printf '  登录目标：%s\n' "${SSH_DEST}"
  printf '  隧道映射：http://127.0.0.1:%s  --->  远端 %s:%s\n' "${LOCAL_PORT}" "${REMOTE_HOST}" "${REMOTE_PORT}"
  if (( ${#EXTRA_FORWARDS[@]} > 0 )); then
    printf '  额外映射：%s\n' "${EXTRA_FORWARDS[*]}"
  fi
  printf '  执行命令：%s\n' "$(format_cmd_preview "${TUNNEL_CMD[@]}")"
  ui_sep

  if ! ask_yesno "立即启动隧道？" y; then
    log "已取消启动"
    return 0
  fi

  printf '\n%s隧道正在建立…%s 如需确认指纹请输入 yes，如需密码/私钥口令请按提示输入。\n' "${C_G}" "${C_0}"
  printf '%s连接成功后保持本窗口开启，在浏览器打开：http://127.0.0.1:%s%s\n' "${C_B}" "${LOCAL_PORT}" "${C_0}"
  printf '%s按 Ctrl+C 可随时关闭隧道并返回菜单。%s\n\n' "${C_D}" "${C_0}"

  TUNNEL_INTERRUPTED=0
  trap 'TUNNEL_INTERRUPTED=1' INT
  "${TUNNEL_CMD[@]}" || rc=$?
  trap 'ui_abort' INT

  printf '\n'
  if (( TUNNEL_INTERRUPTED )) || (( rc == 130 )); then
    log "已关闭隧道，返回菜单"
    return 0
  fi
  if (( rc != 0 )); then
    die_action "隧道连接退出（exit ${rc}）。若提示 Permission denied 请到菜单 2 核对用户名/端口/私钥；若提示端口占用请到菜单 3 更换本地端口。"
    return 1
  fi
  log "隧道已正常结束"
  return 0
}

help_page() {
  scr_clear
  ui_rule
  printf '%s 使用说明与常见问题%s\n' "${C_B}" "${C_0}"
  ui_sep
  printf '1. 什么是 SSH 隧道？\n'
  printf '   把服务器本机（127.0.0.1:%s）的网页服务，通过加密 SSH 通道映射到你电脑本机的 %s 端口。\n' "${REMOTE_PORT}" "${LOCAL_PORT}"
  printf '   在服务器上 ComfyUI 只监听回环时，用隧道访问最安全，也能在 ComfyUI-Manager 界面装插件。\n\n'
  printf '2. 该输入什么命令？\n'
  printf '   把你平时能连上服务器的 ssh 命令完整贴进菜单 2 即可，例如：\n'
  printf '     ssh -p 23456 -i ~/.ssh/id_ed25519 ubuntu@1.2.3.4\n'
  printf '   本工具会自动加上 -N（只转发不进远程命令行）、-L、断线保活与失败即退出参数。\n\n'
  printf '3. Windows 用户提示：\n'
  printf '   PowerShell 不支持 bash <(...) 语法，请在 Git Bash 或 WSL 中运行本脚本。\n'
  printf '   若遇到密码输入无响应，建议使用 Git Bash 自带的 /usr/bin/ssh。\n'
  ui_sep
  page_wait "按回车返回主菜单…"
}

# ============ 主菜单 ============
draw_main_menu() {
  local port_state
  if local_port_in_use "${LOCAL_PORT}"; then
    port_state="$(ui_no "已被占用 ⚠")"
  else
    port_state="$(ui_yes "空闲可用")"
  fi
  scr_clear
  ui_rule
  printf '%s 本地 SSH 隧道 TUI%s %s（%s，不落盘配置）%s\n' \
    "${C_B}" "${C_0}" "${C_D}" "$(os_label)" "${C_0}"
  ui_sep
  ui_kv "SSH 客户端" "${SSH_BIN:-$(ui_no '未找到')}"
  ui_kv "登录目标" "${SSH_DEST:-$(ui_no '未设置（选 1 或 2 输入）')}"
  ui_kv "端口映射" "127.0.0.1:${LOCAL_PORT} -> ${REMOTE_HOST}:${REMOTE_PORT}"
  if (( ${#EXTRA_FORWARDS[@]} > 0 )); then
    ui_kv "额外转发" "${EXTRA_FORWARDS[*]}"
  fi
  ui_kv "本地端口" "${LOCAL_PORT} (${port_state})"
  ui_sep
  ui_item 1 "启动 SSH 隧道"
  ui_item 2 "输入 / 更换 SSH 登录命令"
  ui_item 3 "设置转发端口（默认 8188 -> 8188）"
  ui_item 4 "预检本地端口与 SSH 配置解析（ssh -G）"
  ui_item 5 "使用说明与常见问题"
  printf '  %sq%s) 退出\n' "${C_R}" "${C_0}"
  ui_sep
}

ask_main() {
  local input
  while :; do
    read -rp "选择 [1-5]（q=退出）: " input || die "输入中断"
    case "${input}" in
      q|Q) MAIN_REPLY="q"; return 0 ;;
      1|2|3|4|5) MAIN_REPLY="${input}"; return 0 ;;
      *) warn "无效输入：请输入 1-5，或 q 退出" ;;
    esac
  done
}

main() {
  require_tty
  detect_ssh_bin || warn "未检测到 ssh 客户端，请先安装 OpenSSH 后再启动隧道"
  while :; do
    draw_main_menu
    ask_main
    case "${MAIN_REPLY}" in
      q) break ;;
      1) act start_tunnel || true; scr_pause ;;
      2) act configure_ssh_cmd || true; scr_pause ;;
      3) act port_menu || true ;;
      4) act preflight_check || true; scr_pause ;;
      5) act help_page || true ;;
    esac
  done
  printf '\n%s再见。%s\n' "${C_D}" "${C_0}"
  return 0
}

main "$@"

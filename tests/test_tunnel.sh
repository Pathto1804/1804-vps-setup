#!/usr/bin/env bash
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/mock_env.sh
source "${REPO_ROOT}/tests/lib/mock_env.sh"

setup_test_env
load_script_functions "${REPO_ROOT}/tunnel-tui.sh"

SSH_BIN="/usr/bin/ssh"

# 1. 空 SSH_BASE_ARGS 在 set -u 下安全展开
SSH_BASE_ARGS=()
build_tunnel_cmd
assert_eq "${TUNNEL_CMD[0]}" "${SSH_BIN}" "空 SSH_BASE_ARGS 安全组装"

# 2. 标准 user@ip 与默认参数注入
parse_ssh_command "ssh root@117.50.215.39" 0
build_tunnel_cmd
assert_eq "${SSH_DEST}" "root@117.50.215.39" "标准目标解析"
assert_eq "${TUNNEL_CMD[*]}" "/usr/bin/ssh -N -L 8188:127.0.0.1:8188 -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 root@117.50.215.39" "默认隧道命令组装"

# 3. 无前缀 ssh、连写参数与组合短选项末尾带参（-4p 2222 / -vvNfp2222）
parse_ssh_command "-p 23456 -l ubuntu 117.50.215.39" 0
assert_eq "${SSH_DEST}" "117.50.215.39" "无前缀 ssh 目标解析"
assert_eq "${SSH_BASE_ARGS[*]}" "-p 23456 -l ubuntu 117.50.215.39" "无前缀参数解析"

parse_ssh_command "ssh -4p 2222 root@1.2.3.4" 0
assert_eq "${SSH_DEST}" "root@1.2.3.4" "-4p 2222 目标解析"
assert_eq "${SSH_BASE_ARGS[*]}" "-4 -p 2222 root@1.2.3.4" "-4p 2222 组合旗标拆分"

parse_ssh_command "ssh -vvNfp2222 ubuntu@1.2.3.4" 0
assert_eq "${SSH_DEST}" "ubuntu@1.2.3.4" "-vvNfp2222 目标解析"
assert_eq "${SSH_BASE_ARGS[*]}" "-vv -p 2222 ubuntu@1.2.3.4" "-vvNfp2222 剥离 Nf 并保留 vv 与 p"

# 4. 含空格与反斜杠的 Windows 私钥路径及尾部远程指令剥离
parse_ssh_command 'ssh -f -i "C:\Users\my name\.ssh\id_ed25519" -p2222 root@1.2.3.4 echo hi' 0
assert_eq "${SSH_BASE_ARGS[1]}" 'C:\Users\my name\.ssh\id_ed25519' "保留带空格引号 Windows 私钥路径"
assert_eq "${SSH_DEST}" "root@1.2.3.4" "剔除尾部远程命令后目标正确"
assert_eq "${#SSH_BASE_ARGS[@]}" "5" "剥离 -f 与尾部远程指令"

# 5. 错误重输不污染上一次合法状态
parse_ssh_command "ssh -o ServerAliveInterval=60 valid@1.2.3.4" 0
assert_eq "${HAS_ALIVE_INTERVAL}" "1" "识别已有 ServerAliveInterval"
assert_rc 1 parse_ssh_command "ssh -p" 0
assert_eq "${HAS_ALIVE_INTERVAL}" "1" "失败重解析保留原有 HAS_ALIVE_INTERVAL"
assert_eq "${SSH_DEST}" "valid@1.2.3.4" "失败重解析保留原有 SSH_DEST"

# 6. 拒绝多命令注入与未闭合引号
assert_rc 1 parse_ssh_command 'ssh root@1.2.3.4; whoami' 0
assert_rc 1 parse_ssh_command 'ssh root@1.2.3.4 && id' 0
assert_rc 1 parse_ssh_command 'ssh $(whoami)@1.2.3.4' 0
assert_rc 1 parse_ssh_command 'ssh -i "unclosed root@1.2.3.4' 0

finish_test_file "test_tunnel"

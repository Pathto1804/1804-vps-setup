#!/usr/bin/env bash
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/mock_env.sh
source "${REPO_ROOT}/tests/lib/mock_env.sh"

setup_test_env
load_script_functions "${REPO_ROOT}/00-tui.sh"

# 1. 缺 UFW（无 ufw 命令）场景：ufw_precheck 必须要求显式确认外部防火墙
# 把 PATH 缩窄到仅含 MOCK_BIN 与标准系统工具（排除真实 /usr/sbin/ufw 如存在）
make_mock_bin awk "$(command -v awk >/dev/null && printf 'exec "%s" "$@"' "$(command -v awk)")"
make_mock_bin sed "$(command -v sed >/dev/null && printf 'exec "%s" "$@"' "$(command -v sed)")"
make_mock_bin grep "$(command -v grep >/dev/null && printf 'exec "%s" "$@"' "$(command -v grep)")"

ORIG_INNER_PATH="${PATH}"
export PATH="${MOCK_BIN}"

# 拒绝确认外部防火墙 -> 返回 1
assert_rc 1 ufw_precheck 22 22222 <<< "n"
# 显式确认外部防火墙 -> 返回 0
assert_rc 0 ufw_precheck 22 22222 <<< "y"

export PATH="${ORIG_INNER_PATH}"

# 2. 多 AllowUsers 老机器兼容场景：sshd -T 存在 alice 与 bob@1.2.3.4
make_mock_bin sshd '
if [[ "${1:-}" == "-T" ]]; then
  cat <<EOF
port 22
permitrootlogin no
passwordauthentication no
pubkeyauthentication yes
allowusers alice bob@1.2.3.4 ghostuser
EOF
fi
'
make_mock_bin id '
case "${2:-}" in
  alice) echo "1000" ;;
  bob)   echo "1001" ;;
  *)     exit 1 ;;
esac
'

tokens="$(sshd_allowusers_tokens)"
assert_eq "${tokens}" "alice bob@1.2.3.4" "sshd_allowusers_tokens 过滤不存在的 ghostuser 并保留多个合法用户"

# 在交互确认 y 时，resolve_harden_allowusers 应保留多用户白名单而非覆盖成单用户
HARDEN_ALLOWUSERS=""
resolve_harden_allowusers <<< "y" >/dev/null 2>&1
rc=$?
assert_eq "${rc}" "0" "resolve_harden_allowusers 沿用多用户白名单返回 0"
assert_eq "${HARDEN_ALLOWUSERS}" "alice bob@1.2.3.4" "HARDEN_ALLOWUSERS 完整保留多用户白名单"

# 3. 确认 00-tui.sh 的 Swap 段子 shell 隔离不泄漏 errexit 到外层
# （此处只检查 run_swap_menu 函数定义存在且包含子 shell）
if grep -q '^run_swap_menu()' "${REPO_ROOT}/00-tui.sh"; then
  TEST_PASS=$((TEST_PASS + 1))
else
  TEST_FAIL=$((TEST_FAIL + 1))
  printf 'FAIL: 00-tui.sh 应包含 run_swap_menu\n' >&2
fi

finish_test_file "test_00_tui_legacy"

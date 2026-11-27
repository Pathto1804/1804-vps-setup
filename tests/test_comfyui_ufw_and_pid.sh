#!/usr/bin/env bash
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/mock_env.sh
source "${REPO_ROOT}/tests/lib/mock_env.sh"

setup_test_env
load_script_functions "${REPO_ROOT}/comfyui-tui.sh"

# 1. fw_has_port 精确匹配测试：区分 DENY / 18188 / ALLOW / inactive
# shellcheck disable=SC2034
PORT=8188

make_mock_bin ufw '
if [[ "${1:-}" == "status" ]]; then
  cat <<EOF
Status: active

To                         Action      From
--                         ------      ----
18188/tcp                  ALLOW       Anywhere
8188/tcp                   DENY        Anywhere
EOF
fi
'
# 18188/tcp ALLOW 与 8188/tcp DENY 不应被误判为 8188 已放行
assert_rc 1 fw_has_port

make_mock_bin ufw '
if [[ "${1:-}" == "status" ]]; then
  cat <<EOF
Status: active

To                         Action      From
--                         ------      ----
8188/tcp                   ALLOW       Anywhere
EOF
fi
'
# 8188/tcp ALLOW 应精确判定为已放行
assert_rc 0 fw_has_port

make_mock_bin ufw '
case "${1:-}" in
  status) echo "Status: inactive" ;;
  show)   echo "ufw allow 8188/tcp" ;;
esac
'
# UFW inactive 时应回退 ufw show added 识别预写规则
assert_rc 0 fw_has_port

# 2. driver_apt_install_pkg 拒绝低于 580 的旧候选驱动
make_mock_bin apt-cache '
cat <<EOF
nvidia-open:
  Installed: (none)
  Candidate: 535.183.01-0ubuntu0.20.04.1
EOF
'
# 候选驱动 535 (<580) 应被拒绝
assert_rc 1 driver_apt_install_pkg nvidia-open

# 3. install_base_packages 在缺包时先执行 apt-get update 再 install
APT_LOG="${TEST_TMP}/apt.log"
: > "${APT_LOG}"
export APT_LOG
make_mock_bin dpkg-query 'echo "dpkg-query: no packages found" >&2; exit 1'
make_mock_bin apt-get 'echo "apt-get $*" >> "${APT_LOG}"; exit 0'
assert_rc 0 install_base_packages <<< "y"
first_apt="$(head -n 1 "${APT_LOG}")"
second_apt="$(sed -n '2p' "${APT_LOG}")"
assert_eq "${first_apt}" "apt-get -o DPkg::Lock::Timeout=60 update" "装包前必须先刷新 apt 索引"
[[ "${second_apt}" == "apt-get -o DPkg::Lock::Timeout=60 install -y "* ]] && TEST_PASS=$((TEST_PASS + 1)) || {
  TEST_FAIL=$((TEST_FAIL + 1)); printf 'FAIL: 第二步应执行 apt-get install -y\n' >&2;
}

# 4. CUDA_TOOLKIT .bashrc 写入：LD_LIBRARY_PATH 未定义时不应产生末尾冒号
ROOT_HOME="${TEST_TMP}/root"
mkdir -p "${ROOT_HOME}"
: > "${ROOT_HOME}/.bashrc"
make_mock_bin nvidia-smi 'exit 0'
make_mock_bin nvcc 'echo "release 13.0, V13.0.0"'
make_mock_bin apt-cache '
cat <<EOF
cuda-toolkit:
  Installed: (none)
  Candidate: 13.0.0-1
EOF
'
grep -rnq "developer.download.nvidia.com" /dev/null 2>/dev/null || true
# 绕过 nvidia_repo_setup 联网：直接打桩该函数
nvidia_repo_setup() { return 0; }
assert_rc 0 cuda_toolkit_install <<< "y"
if grep -q 'LD_LIBRARY_PATH="/usr/local/cuda/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"' "${ROOT_HOME}/.bashrc"; then
  TEST_PASS=$((TEST_PASS + 1))
else
  TEST_FAIL=$((TEST_FAIL + 1))
  printf 'FAIL: .bashrc 中 LD_LIBRARY_PATH 应使用安全条件展开\n' >&2
fi

finish_test_file "test_comfyui_ufw_and_pid"

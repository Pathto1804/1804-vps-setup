#!/usr/bin/env bash
# 隔离打桩测试公共夹具：仅用于本地/CI 测试，不进入交付产物。

TEST_PASS=0
TEST_FAIL=0
TEST_TMP=""

setup_test_env() {
  TEST_TMP="$(mktemp -d)"
  MOCK_BIN="${TEST_TMP}/bin"
  mkdir -p "${MOCK_BIN}"
  export ORIG_PATH="${PATH}"
  export PATH="${MOCK_BIN}:${PATH}"
}

teardown_test_env() {
  if [[ -n "${ORIG_PATH:-}" ]]; then
    export PATH="${ORIG_PATH}"
  fi
  if [[ -n "${TEST_TMP:-}" && -d "${TEST_TMP}" ]]; then
    rm -rf -- "${TEST_TMP}"
  fi
  TEST_TMP=""
}

# 将入口脚本去掉末尾 main "$@" 后加载进当前 bash 进程，供单元测试调用内部函数
load_script_functions() {
  local script_path="$1"
  local patched
  patched="${TEST_TMP}/$(basename "${script_path}").lib.sh"
  sed '/^main "\$@"$/d' "${script_path}" > "${patched}"
  # shellcheck disable=SC1090
  source "${patched}"
  # 覆盖临时目录与日志函数，避免测试污染宿主机或提前 exit
  TMPD="${TEST_TMP}/tmpd"
  mkdir -p "${TMPD}"
  # shellcheck disable=SC2034
  BK_ROOT="${TEST_TMP}/backups"
}

make_mock_bin() {
  local name="$1"
  local body="$2"
  local target="${MOCK_BIN}/${name}"
  printf '#!/usr/bin/env bash\n%s\n' "${body}" > "${target}"
  chmod +x "${target}"
}

assert_eq() {
  local got="$1" want="$2" msg="$3"
  if [[ "${got}" == "${want}" ]]; then
    TEST_PASS=$((TEST_PASS + 1))
  else
    TEST_FAIL=$((TEST_FAIL + 1))
    printf 'FAIL: %s\n  got : [%s]\n  want: [%s]\n' "${msg}" "${got}" "${want}" >&2
  fi
}

assert_rc() {
  local expected_rc="$1"
  shift
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  if (( rc == expected_rc )); then
    TEST_PASS=$((TEST_PASS + 1))
  else
    TEST_FAIL=$((TEST_FAIL + 1))
    printf 'FAIL: %s\n  got rc : %d\n  want rc: %d\n' "$*" "${rc}" "${expected_rc}" >&2
  fi
}

finish_test_file() {
  local name="$1"
  teardown_test_env
  printf '[%s] pass=%d fail=%d\n' "${name}" "${TEST_PASS}" "${TEST_FAIL}"
  (( TEST_FAIL == 0 ))
}

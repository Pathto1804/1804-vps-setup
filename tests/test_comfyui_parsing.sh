#!/usr/bin/env bash
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/mock_env.sh
source "${REPO_ROOT}/tests/lib/mock_env.sh"

setup_test_env
load_script_functions "${REPO_ROOT}/comfyui-tui.sh"

# 1. 模拟非 systemd 容器环境 + 残留无效 unit + 手动编写的无引号 /start.d/comfyui.sh
ROOT_HOME="${TEST_TMP}/root"
COMFY_DIR="${ROOT_HOME}/ComfyUI"
UNIT_FILE="${TEST_TMP}/etc/systemd/system/comfyui.service"
STARTD_DIR="${TEST_TMP}/start.d"
STARTD_FILE="${STARTD_DIR}/comfyui.sh"
ENV_PY="${ROOT_HOME}/miniforge3/envs/comfyui/bin/python"

mkdir -p "${COMFY_DIR}" "$(dirname "${UNIT_FILE}")" "${STARTD_DIR}" "$(dirname "${ENV_PY}")"
touch "${COMFY_DIR}/main.py"
printf '#!/usr/bin/env bash\nexit 0\n' > "${ENV_PY}"
chmod +x "${ENV_PY}"

# 模拟非 systemd 容器环境（覆盖 /run/systemd/system 探测与 ps -p 1）
systemd_present() { return 1; }
make_mock_bin ps 'echo bash'

cat > "${UNIT_FILE}" <<EOF
[Service]
WorkingDirectory=/stale/ComfyUI
ExecStart=${ENV_PY} main.py --listen 0.0.0.0 --port 9999
EOF

cat > "${STARTD_FILE}" <<EOF
#!/bin/bash
# 注释里的 --listen 127.0.0.1 不应影响解析
cd ${COMFY_DIR}
${ENV_PY} main.py --enable-manager --listen --port 6006 --use-sage-attention
EOF
chmod +x "${STARTD_FILE}"

# 容器下应优先读取 /start.d/comfyui.sh 而非残留 unit
assert_eq "$(config_file)" "${STARTD_FILE}" "容器环境优先选择 /start.d/comfyui.sh"
assert_eq "$(parse_startd_workdir)" "${COMFY_DIR}" "兼容无引号 cd 路径解析"
assert_eq "$(parse_config_python)" "${ENV_PY}" "兼容无 exec 的 python 启动行解析"
assert_eq "$(current_access_mode)" "listen" "裸 --listen 解析为 listen 模式"
assert_eq "$(parse_config_port)" "6006" "解析自定义端口 6006"

extract_existing_extra_args
assert_eq "${COMFY_EXTRA_ARGS[*]}" "--use-sage-attention" "裸 --listen 不吞掉 --port 6006，完整保留自定义参数"

# 2. 验证回环 --listen 127.0.0.1 与 --cpu-vae 误判防护
cat > "${STARTD_FILE}" <<EOF
#!/bin/bash
cd "${COMFY_DIR}" || exit 1
exec "${ENV_PY}" main.py --listen 127.0.0.1 --port 8188 --cpu-vae --preview-method auto
EOF

assert_eq "$(current_access_mode)" "tunnel" "--listen 127.0.0.1 识别为 tunnel 模式"
# --cpu-vae 不应被误判为 --cpu
assert_rc 1 config_has_cpu
extract_existing_extra_args
assert_eq "${COMFY_EXTRA_ARGS[*]}" "--cpu-vae --preview-method auto" "正确剥离 --listen 127.0.0.1 与 --port 8188 并保留其余参数"

# 3. 验证注释中的 --listen 不干扰无 --listen 的隧道配置
cat > "${STARTD_FILE}" <<EOF
#!/bin/bash
# --listen 0.0.0.0
cd "${COMFY_DIR}" || exit 1
exec "${ENV_PY}" main.py --enable-manager --cpu
EOF

assert_eq "$(current_access_mode)" "tunnel" "注释里的 --listen 不干扰 tunnel 判定"
# 精确匹配 --cpu 参数
assert_rc 0 config_has_cpu

# 4. 验证 tokenize_cmdline 引号与空格处理
tokenize_cmdline "\"${ENV_PY}\" main.py --extra \"foo bar\" '--flag=a b'"
assert_eq "${#CMD_WORDS[@]}" "5" "tokenize_cmdline 正确切分含空格引号参数"
assert_eq "${CMD_WORDS[3]}" "foo bar" "tokenize_cmdline 还原双引号内容"
assert_eq "${CMD_WORDS[4]}" "--flag=a b" "tokenize_cmdline 还原单引号内容"

# 5. 验证 ComfyUI-Manager security_level 探测、新建、保留更新与备份
BK_ROOT="${TEST_TMP}/vps-init-backups"
assert_eq "$(manager_config_file)" "" "未生成 config.ini 时探测返回空"
assert_eq "$(manager_security_raw)" "" "未生成 config.ini 时读取等级为空"

write_manager_security_level "weak"
mgr_cfg="${COMFY_DIR}/user/__manager/config.ini"
assert_eq "$(manager_config_file)" "${mgr_cfg}" "新建默认写入 user/__manager/config.ini"
assert_eq "$(manager_security_raw)" "weak" "新建后读取到 weak"

cat > "${mgr_cfg}" <<EOF
[default]
preview_method = auto
# 保留注释
security_level = normal
bypass_ssl = False
EOF
write_manager_security_level "strong"
assert_eq "$(manager_security_raw)" "strong" "更新已有 config.ini 为 strong"
assert_rc 0 grep -qF "preview_method = auto" "${mgr_cfg}"
assert_rc 0 grep -qF "# 保留注释" "${mgr_cfg}"
assert_eq "$(find "${BK_ROOT}" -type f -name 'config.ini' | wc -l | tr -d ' ')" "1" "修改前已备份 config.ini"

finish_test_file "test_comfyui_parsing"

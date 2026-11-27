#!/usr/bin/env bash
# 双入口一致性自检
# 检查项：
#   1. 两个入口存在；已退役步骤脚本与根目录其他 NN-*.sh 不得复活
#   2. 关键行存在性：两个脚本都有 shopt -s inherit_errexit
#   3. 包清单：00-tui.sh 的 BASE/TOOLS_EXTRA_DEFAULT vs README/教程；
#      comfyui-tui.sh 的 COMFY_BASE vs README 及 comfyui-docs/README 的 ComfyUI 包清单
#   4. 项目私有状态文件不得复活：/root/.vps-init.conf、/root/.comfyui-tui.conf
#   5. 两套文档树存在（docs/、comfyui-docs/）
set -euo pipefail
ENTRY="00-tui.sh"
COMFY_ENTRY="comfyui-tui.sh"
RETIRED="01-base.sh 04-user.sh 05-ufw-ssh.sh 07-fail2ban.sh 08-swap.sh 09-bbr.sh 12-verify.sh"
declare -i BAD=0

# ---- 1. 入口存在；旧步骤脚本不得复活 ----
[[ -f "${ENTRY}" ]] || { echo "❌ 缺少入口脚本：${ENTRY}"; BAD+=1; }
[[ -f "${COMFY_ENTRY}" ]] || { echo "❌ 缺少入口脚本：${COMFY_ENTRY}"; BAD+=1; }
for f in ${RETIRED}; do
  [[ -f "${f}" ]] && { echo "❌ 已退役的步骤脚本仍在：${f}（功能应已并入 ${ENTRY}）"; BAD+=1; }
done
while IFS= read -r f; do
  [[ "$(basename "${f}")" == "${ENTRY}" ]] && continue
  echo "❌ 根目录出现编号步骤脚本：${f}（两个入口之外不要再拆步骤脚本）"
  BAD+=1
done < <(find . -maxdepth 1 -type f -name '[0-9][0-9]-*.sh' -print 2>/dev/null)

# ---- 2. 关键行存在性 ----
for f in "${ENTRY}" "${COMFY_ENTRY}"; do
  [[ -f "${f}" ]] || continue
  grep -qxF 'shopt -s inherit_errexit' "${f}" 2>/dev/null || {
    echo "❌ ${f} 缺少关键行：shopt -s inherit_errexit"; BAD+=1; }
done

# ---- 3. 包清单一致性 ----
norm_list() { tr ' ' '\n' | grep -v '^$' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ *$//'; }
BASE_LIST="$(sed -n 's/^BASE="\(.*\)"$/\1/p' "${ENTRY}" | norm_list)"
EXTRA_LIST="$(sed -n 's/^TOOLS_EXTRA_DEFAULT="\(.*\)"$/\1/p' "${ENTRY}" | norm_list)"
README_BASE="$(grep -o '`sudo ca-certificates[^`]*`' README.md | head -1 | tr -d '`' | norm_list)"
README_EXTRA="$(grep -o '默认 `jq [^`]*`' README.md | head -1 | sed 's/默认 //' | tr -d '`' | norm_list)"
TUT_LIST="$(sed -n '/^apt install -y sudo ca-certificates/,/[^\\]$/p' docs/tutorial.md \
            | tr -d '\\' | sed 's/^apt install -y //' | norm_list)"
EXPECT_ALL="$(printf '%s %s' "${BASE_LIST}" "${EXTRA_LIST}" | norm_list)"
COMFY_LIST="$(sed -n 's/^COMFY_BASE="\(.*\)"$/\1/p' "${COMFY_ENTRY}" | norm_list)"
README_COMFY_RAW="$(grep -o '`git curl[^`]*`' README.md || true)"
README_COMFY="$(sed -n '1p' <<< "${README_COMFY_RAW}" | tr -d '`' | norm_list)"
COMFY_DOC_RAW="$(grep -o '`git curl[^`]*`' comfyui-docs/README.md 2>/dev/null || true)"
COMFY_DOC_LIST="$(sed -n '1p' <<< "${COMFY_DOC_RAW}" | tr -d '`' | norm_list)"

check_list() {   # check_list <名称> <脚本侧> <文档侧>
  [[ "$2" == "$3" ]] && return 0
  echo "❌ $1 与脚本不一致"
  echo "    脚本: $2"
  echo "    文档: $3"
  BAD+=1
}

if [[ -z "${BASE_LIST}" ]]; then
  echo "❌ 未能从 ${ENTRY} 提取 BASE 包清单"
  BAD+=1
else
  check_list "README 包清单" "${BASE_LIST}" "${README_BASE}"
  check_list "README TOOLS_EXTRA 默认值" "${EXTRA_LIST}" "${README_EXTRA}"
  check_list "tutorial 包清单" "${EXPECT_ALL}" "${TUT_LIST}"
fi

if [[ -z "${COMFY_LIST}" ]]; then
  echo "❌ 未能从 ${COMFY_ENTRY} 提取 COMFY_BASE 包清单"
  BAD+=1
else
  check_list "README ComfyUI 包清单" "${COMFY_LIST}" "${README_COMFY}"
  check_list "comfyui-docs/README ComfyUI 包清单" "${COMFY_LIST}" "${COMFY_DOC_LIST}"
fi

# ---- 4. 项目私有状态文件不得复活 ----
for f in "${ENTRY}" "${COMFY_ENTRY}"; do
  [[ -f "${f}" ]] || continue
  if grep -nE '/root/\.(vps-init|comfyui-tui)\.conf' "${f}" >/dev/null 2>&1; then
    echo "❌ ${f} 引用了项目私有状态文件"
    BAD+=1
  fi
done

# ---- 5. 两套文档树 ----
for d in docs/codewiki comfyui-docs/codewiki; do
  [[ -d "${d}" ]] || { echo "❌ 缺少文档目录：${d}"; BAD+=1; }
done

[[ $BAD -eq 0 ]] && echo "=== 一致性 OK ===" || echo "=== ${BAD} 处仍有差异 ==="
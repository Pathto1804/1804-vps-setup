#!/usr/bin/env bash
# 单入口一致性自检（00-tui.sh 之后不再有跨脚本公共块）
# 检查项：
#   1. 入口脚本存在且唯一（00-tui.sh），旧步骤脚本不得复活
#   2. 关键行存在性：shopt -s inherit_errexit（命令替换不继承 errexit，漏加即空值写盘）
#   3. 包清单一致：00-tui.sh 的 BASE / TOOLS_EXTRA_DEFAULT vs README 与手动教程
#   4. 项目私有状态文件不得复活：脚本里不得出现 /root/.vps-init.conf
set -euo pipefail
ENTRY="00-tui.sh"
RETIRED="01-base.sh 04-user.sh 05-ufw-ssh.sh 07-fail2ban.sh 08-swap.sh 09-bbr.sh 12-verify.sh"
declare -i BAD=0

# ---- 1. 入口存在且唯一，旧脚本不得复活 ----
[[ -f "${ENTRY}" ]] || { echo "❌ 缺少入口脚本：${ENTRY}"; BAD+=1; }
for f in ${RETIRED}; do
  [[ -f "${f}" ]] && { echo "❌ 已退役的步骤脚本仍在：${f}（功能应已并入 ${ENTRY}）"; BAD+=1; }
done

# ---- 2. 关键行存在性 ----
# 命令替换默认不继承 errexit：漏加这一行，$(ask_input ...) 里的 die 只终止子 shell，
# 空值会被照常写进系统配置（2026-09-29 修 F3 缺陷时实测复现）
grep -qxF 'shopt -s inherit_errexit' "${ENTRY}" 2>/dev/null || {
  echo "❌ ${ENTRY} 缺少关键行：shopt -s inherit_errexit"; BAD+=1; }

# ---- 3. 包清单一致性：00-tui.sh 的 BASE / TOOLS_EXTRA_DEFAULT vs README 与手动教程 ----
norm_list() { tr ' ' '\n' | grep -v '^$' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ *$//'; }
BASE_LIST="$(sed -n 's/^BASE="\(.*\)"$/\1/p' "${ENTRY}" | norm_list)"
EXTRA_LIST="$(sed -n 's/^TOOLS_EXTRA_DEFAULT="\(.*\)"$/\1/p' "${ENTRY}" | norm_list)"
README_BASE="$(grep -o '`sudo ca-certificates[^`]*`' README.md | head -1 | tr -d '`' | norm_list)"
README_EXTRA="$(grep -o '默认 `jq [^`]*`' README.md | head -1 | sed 's/默认 //' | tr -d '`' | norm_list)"
TUT_LIST="$(sed -n '/^apt install -y sudo ca-certificates/,/[^\\]$/p' docs/tutorial.md \
            | tr -d '\\' | sed 's/^apt install -y //' | norm_list)"
EXPECT_ALL="$(printf '%s %s' "${BASE_LIST}" "${EXTRA_LIST}" | norm_list)"

check_list() {   # check_list <名称> <00-tui.sh 侧> <文档侧>
  [[ "$2" == "$3" ]] && return 0
  echo "❌ $1 与 ${ENTRY} 不一致"
  echo "    ${ENTRY}: $2"
  echo "    $1: $3"
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

# ---- 4. 项目私有状态文件不得复活 ----
# 状态一律读系统原生来源；任何脚本引用该路径都说明私有运行态被重新引入
if grep -n '/root/\.vps-init\.conf' "${ENTRY}" >/dev/null 2>&1; then
  echo "❌ ${ENTRY} 引用了已废弃的项目私有状态文件 /root/.vps-init.conf"
  BAD+=1
fi

[[ $BAD -eq 0 ]] && echo "=== 一致性 OK ===" || echo "=== ${BAD} 处仍有差异 ==="

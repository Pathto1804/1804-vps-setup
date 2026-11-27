# CodeWiki

本仓库的长期知识库。`README.md` 回答“怎么快速使用”，`docs/guide.md` 回答“完整使用说明”，`docs/tutorial.md` 回答“手动怎么做”；这里为基础脚本 `00-tui.sh` 回答“为什么这样做、怎么改”。ComfyUI 入口 `comfyui-tui.sh` 的知识在 [`comfyui-docs/codewiki/`](../../comfyui-docs/codewiki/README.md)。

| 文档 | 负责的问题 | 什么时候必须改 |
|---|---|---|
| [business.md](business.md) | 给谁用、解决什么、边界在哪、什么不做 | 目标用户、支持矩阵、交付形态、非目标变化 |
| [architecture.md](architecture.md) | 代码怎么组织、状态从哪来、失败语义 | 状态来源、菜单结构、备份/报告路径、动作隔离变化 |
| [features.md](features.md) | 主菜单每项做什么、写哪些文件、验证口径 | 任何菜单行为、前置自检、闸门、步骤顺序变化 |
| [development.md](development.md) | 改代码的流程、命令、检查项、已知教训 | 工具链、检查项、工作区规范、踩坑记录 |
| [terms.md](terms.md) | 术语的唯一定义 | 出现新概念或既有概念改义 |

## 维护规则

1. **行为改变必须同批更新 `features.md` 与 `README.md`。** 二者口径不一致时，以脚本实际行为为准，并立即修正文档。
2. **术语只写在 `terms.md`。** 其他文档直接使用术语，需要澄清时链接过去，不重复定义。
3. **架构约束写在 `architecture.md`，决策理由写在 ADR。** 新决策先补 `docs/adr/`，再回填架构文档的结论段，不把长篇论证塞进本目录。
4. **本目录不记录会话过程、临时调试结论、待办清单。** 未落地的想法写进 ADR 的"被否的替代方案"或直接丢掉。
5. **不复制易漂移的清单。** 包清单的权威位置是 `00-tui.sh` 的 `BASE` / `TOOLS_EXTRA_DEFAULT` 与 `README.md`，这里只链接并说明规则；`tools/sync_check.sh` 会核对。
6. **修改本目录不需要跑 `sync_check`**，但改了脚本后跑它是硬性要求（见 [development.md](development.md)）。
7. **两套 CodeWiki 分工**：共享概念只在 `docs/codewiki/terms.md` 定义；ComfyUI 专属概念写在 `comfyui-docs/codewiki/terms.md`，不重复定义共享术语。

以上规则在 `AGENTS.md`「CodeWiki 维护原则」中作为对 AI 代理的硬约束重复声明；两处不一致时以 `AGENTS.md` 为准，并立即修正本页。

## 快照

| 项 | 值 |
|---|---|
| 脚本数 | 2（`00-tui.sh` 基础；`comfyui-tui.sh` ComfyUI） |
| 代码量 | 基础约 3260 行 bash；ComfyUI 约 2000 行 |
| 平台 | 基础：Debian 12/13 一等；ComfyUI：Ubuntu 22.04/24.04 一等，Debian 12/13 兼容未逐版本验证 |
| 决策记录 | [ADR-0003](../adr/0003-single-tui-native-state.md)（基础）；[ADR-0004](../adr/0004-comfyui-entry.md)（第二入口）；ADR-0001/0002 已被 0003 取代 |
| 自动检查 | `tools/sync_check.sh`；无 CI、无测试框架 |

# ComfyUI CodeWiki

本目录是 `comfyui-tui.sh` 的长期维护知识。基础脚本 `00-tui.sh` 的知识仍在 `docs/codewiki/`；**共享概念（原生状态、动作隔离、TUI、闸门）只在 `docs/codewiki/terms.md` 定义**，这里只写 ComfyUI 专属内容并链接回去。

| 文档 | 负责的问题 | 什么时候必须改 |
|---|---|---|
| [business.md](business.md) | 给谁用、成功标准、明确不做什么 | 目标用户、边界、平台矩阵变化 |
| [architecture.md](architecture.md) | 代码怎么组织、状态从哪来、失败语义 | 状态来源、访问方式、自启方式、备份路径变化 |
| [features.md](features.md) | 菜单 0–9 每项做什么、写哪些文件、停点 | 任何菜单行为、流程顺序、默认参数变化 |
| [development.md](development.md) | 改代码的流程、检查命令、已知教训、验收 | 工具链、镜像链路、踩坑记录变化 |
| [terms.md](terms.md) | ComfyUI 专属术语 | 新概念或改义 |

## 快照

| 项 | 值 |
|---|---|
| 入口 | `comfyui-tui.sh`（单文件、raw 执行） |
| 平台 | Ubuntu 22.04/24.04 一等；Debian 12/13 兼容未逐版本验证 |
| 用户 | root-only，安装到 `/root` |
| 默认访问 | `--listen 0.0.0.0:8188`；菜单 7 可切 SSH 隧道 |
| 镜像 | 阿里 PyPI；清华 conda/Miniforge；PyTorch 官方 CPU 索引；NVIDIA 官方源 |
| 决策记录 | [`docs/adr/0004-comfyui-entry.md`](../../docs/adr/0004-comfyui-entry.md) |
| 自动检查 | `tools/sync_check.sh`；无 CI、无测试框架 |

## 维护规则

1. 脚本行为、菜单、默认参数、前置自检任一变化，同批更新 `features.md` 与本目录 `README.md`、根 `README.md`。
2. 共享术语只改 `docs/codewiki/terms.md`；这里不重复定义。
3. 架构取舍先写 ADR（`docs/adr/`），再回填 `architecture.md` 结论。
4. 不记录会话过程、临时调试输出、待办清单和单机环境细节。
5. 改脚本后必须 `bash -n` + `shellcheck -S warning` + `tools/sync_check.sh`。
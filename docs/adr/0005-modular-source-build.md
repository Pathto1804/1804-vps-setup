# 0005 — 源码模块化、单文件构建与打桩回归测试

- 状态：已接受（2026-11-28）
- 关联：[ADR-0003](0003-single-tui-native-state.md)（单入口与原生状态）、[ADR-0004](0004-comfyui-entry.md)（ComfyUI 第二入口）、[`tools/build.sh`](../../tools/build.sh)、[`tools/sync_check.sh`](../../tools/sync_check.sh)、[`tests/run.sh`](../../tests/run.sh)

## 背景

`00-tui.sh` 已达 3,431 行，`comfyui-tui.sh` 已达 3,396 行，均已超过 [ADR-0004](0004-comfyui-entry.md) 设定的“约 2,500 行”重评门槛。两套脚本长期并行维护暴露出三类工程问题：

1. 颜色、屏幕契约、交互提示（`ask_yesno` / `ask_input` / `ask_menu`）、`act` 动作隔离与 `backup_file` 等约 200 余行基础原语在两个文件手工双写，曾出现只修一端漏掉另一端的问题。
2. 三千行级单文件使函数边界与模块职责不够直观，局部改动需要全文件定位。
3. 缺少本地自动化行为回归测试，参数解析、UFW 精确匹配、老机器多 `AllowUsers` 等关键防锁死逻辑仅靠人工肉眼与真机验收兜底。

同时，用户侧 **raw 单文件自包含执行契约**（`bash <(curl -fsSL .../00-tui.sh)` 与 `.../comfyui-tui.sh`，不 `source` 仓库内其他文件、不保存项目私有状态）保持不变。

## 决策

1. **源码层与交付层分离**：
   - 根目录 [`00-tui.sh`](../../00-tui.sh) 与 [`comfyui-tui.sh`](../../comfyui-tui.sh) 继续作为**唯二用户交付入口**并保留在 Git 跟踪中（由构建脚本生成，保持单文件自包含、LF 换行、无外部 `source`）。
   - 源码按职责拆分为三棵目录：
     - `src/lib/`：双入口共享原语库（`ui_screen.sh`、`prompts.sh`、`backup.sh`）。
     - `src/00-tui/`：基础运维脚本各独立模块（`00-header.sh`、`10-probes.sh`、`20-base.sh`、`30-users.sh`、`40-ssh_ufw.sh`、`50-fail2ban.sh`、`60-swap.sh`、`70-bbr.sh`、`80-verify_flow.sh`、`90-main.sh`）。其中 `60-swap.sh` 保留子 shell + `set -uo pipefail`（不开 `-e`）隔离风格不变。
     - `src/comfyui/`：ComfyUI 脚本各独立模块（`00-header.sh`、`10-probes_pkg.sh`、`20-driver.sh`、`30-python.sh`、`40-comfyui.sh`、`50-autostart.sh`、`60-verify_deploy.sh`、`70-menus.sh`、`90-main.sh`）。
2. **零依赖构建与一致性门禁**：
   - 新增 [`tools/build.sh`](../../tools/build.sh)（纯 Bash，无 Make/Node 等外部构建依赖），按固定清单顺序拼装生成根目录 `00-tui.sh` 与 `comfyui-tui.sh`。
   - `tools/build.sh --check` 校验根目录交付文件与 `src/` 拼装结果**字节完全一致**；该校验接入 [`tools/sync_check.sh`](../../tools/sync_check.sh)，杜绝“手改根目录产物却忘记同步 `src/`”或反向漂移。
3. **隔离打桩回归测试与 CI**：
   - 新增 [`tests/run.sh`](../../tests/run.sh) 与 `tests/lib/mock_env.sh`、`tests/test_*.sh`，通过 `PATH` 前置 mock 命令与临时目录隔离验证核心逻辑（不依赖真实 root 或云主机）。
   - 新增 [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml)，在 Ubuntu runner 上自动执行 `bash -n`、`shellcheck -S warning`、`bash tools/sync_check.sh` 与 `bash tests/run.sh`。

## 被否的替代方案

1. **在根目录脚本中运行时 `curl` 拉取 `src/lib/*.sh`**：违反单文件自包含与离线/代理环境稳定性，网络抖动会导致半途加载失败。否决。
2. **Git 中不跟踪生成的 `00-tui.sh` / `comfyui-tui.sh`（仅 Release 产物）**：会破坏用户直接 `raw.githubusercontent.com/.../main/00-tui.sh` 一行拉取的使用习惯。否决。
3. **引入 Makefile / Python Jinja / Node 构建器**：为个人 Bash 运维仓库增加构建工具链依赖与学习成本，不符合最小依赖原则。否决。

## 后果

- **正面**：共享原语单一事实源；每个业务模块控制在几百行内；任何提交均受 `build.sh --check` 与打桩测试保护。
- **约束**：修改脚本逻辑时须修改 `src/` 下对应模块并运行 `bash tools/build.sh` 重新生成根目录入口（不可仅手改根目录产物）。
- **延续性**：[ADR-0003](0003-single-tui-native-state.md) 与 [ADR-0004](0004-comfyui-entry.md) 的业务边界、原生状态探测、三条铁律与动作隔离约定全部保留不变。

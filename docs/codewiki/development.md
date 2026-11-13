# 开发与演进

## 环境与命令

无构建、无测试框架、无 CI。本地验证手段只有三条：

```bash
bash -n 00-tui.sh && shellcheck -S warning 00-tui.sh   # 改完必须双绿
bash tools/sync_check.sh                               # 必须输出「一致性 OK」
# 真机验收：Snapshot 保护的 VPS 上走全流程（改菜单 0/3 时必须）
```

`sync_check` 输出 `=== 一致性 OK ===` 才算过。它检查不到语法与行为，所以 `bash -n` + `shellcheck` 是它前面的闸。

## 改动类型与必须动作

| 改动 | 必须做的 |
|---|---|
| 任何代码改动 | `bash -n` + `shellcheck -S warning` + `sync_check` |
| 增加/删除 `BASE` 或 `TOOLS_EXTRA_DEFAULT` 项 | 同步 `README.md` 与 `docs/tutorial.md` 的清单 → `sync_check` 会比对 |
| 改主菜单编号、子菜单项 | 同步 `README.md`、`docs/codewiki/features.md`、`docs/tutorial.md` 的对应引用 |
| 改 `ssh_harden` / `ufw_precheck` / 闸门 | 必须真机全链路：两次闸门 + 新终端密钥登录 + 终检全绿 |
| 改标准初始化的步骤顺序或停点 | 同步 `features.md` 的顺序表与 README「标准初始化」表 |
| 改状态来源（新增/替换探测命令） | 同步 `architecture.md` 的状态来源表 |
| 重新引入任何项目私有状态文件 | 不允许。`sync_check` 会拦截 `/root/.vps-init.conf` 引用；要改这条约束先写 ADR |
| 新架构决策 | 新建 `docs/adr/000N-*.md`，把被取代的旧 ADR 状态改为「已被 ADR-000N 取代」，再回填 `architecture.md` 结论段 |

## 编码约定

- `set -euo pipefail` + `shopt -s inherit_errexit`（bash ≥ 4.4）+ `trap 'err_trap ...' ERR` 在进程级保持生效。
- **菜单动作必须经 `act` 调用**：它临时关闭 `-e` 与 ERR trap，让 TUI 在动作失败后存活。动作内每个危险步骤必须显式判错（`|| die_action "..."` 或 `if ! ...; then`），不能依赖 `set -e`。
- **`die` 只用于启动前置检查与输入中断**（进程已无法继续）；动作内失败用 `die_action`（打印原因 + 返回 1）。
- **命令替换不继承 errexit**：`$(ask_input ...)` 里的失败不传出来。这是已经修过的真实缺陷，别删 `inherit_errexit`。
- **`pipefail` 下的管道**：`sed ... | head -n 1` 在文件缺失或 head 早退（SIGPIPE，141）时返回非零。写法统一为 `|| true`，或先取全量输出再匹配（如 `ss -tln` 先取全量再 `grep`，避免 `grep -q` 早退）。
- **`return "$(...)"` 是陷阱**：命令替换输出为空时 `return` 报 `numeric argument required`（rc=2）。要返回状态码就分两步写：先 `flow_abort "..."`，再 `return 1`。
- **禁止把命令替换的输出当作唯一判据**：状态一律取原始输出再匹配，不在管道里提前 `exit`/`grep -q`。
- 面向终端输出用 `log`/`warn`/`die`/`die_action`；状态行读取系统实时值，不读缓存。
- 交互强制 TTY；不提供 `--yes` / 非交互开关。

## 工作区规范

- 根目录只放入口脚本 `00-tui.sh`、`README.md`、仓库配置（`.gitignore`/`.gitattributes`）；其余进 `docs/`、`tools/`、`.omp/`。
- 脚手架（测试脚本、打桩环境、调试输出、提交草稿、中间产物）放 `.scratch/`（已 gitignore），交付前清空。
- 不往工作区外写文件；不删用户已有文件；不擅自提交、推送（推送前必须征得用户确认）。
- 交付时 `git status -sb` 应与 `origin/main` 同步，无未跟踪文件。

## 已知教训（踩过的坑）

| 坑 | 规则 |
|---|---|
| 命令替换不继承 errexit，`Ctrl-D` 写出空值行 | 保留 `shopt -s inherit_errexit`；`sync_check` 拦截漏加 |
| `set -o pipefail` 下 `sed \| head -n 1` 返回 141，报告都没生成 | 同类 helper 一律 `\|\| true`，或先取全量再匹配 |
| `sshd -T` 读端口的 SIGPIPE 竞态误判 | 先取全量输出再 `grep`，不用 `grep -q` 直连上游 |
| `return "$(f)"` 在 f 无输出时崩成 rc=2 | 分两步：先打印，再 `return 1` |
| 公共块曾独立演化出 9 个函数分歧（2026-09-23） | 单入口后不再存在；若将来重新拆文件必须重建一致性检查 |
| `BK_ROOT` 曾被漏定义，首跑被 `backup_file` 提前返回掩盖 | 常量在文件头统一定义，勿在函数内重新赋值 |
| 用 python/perl 程序化改多行 bash 块，产出字面 `\n`、控制字节、函数体截断 | 改脚本用逐块编辑；程序化操作后立刻 `bash -n` + `shellcheck` |
| Windows 环境：CRLF 会让 raw 脚本在 Linux 炸；python 读 git 输出默认 GBK | `.gitattributes` 强制 LF；subprocess 显式 `encoding='utf-8'` |
| 曾把脚手架写到工作区外（`E:/tmp`），并在根目录产生空目录 `E/` | 只写工作区内；发现杂项目录立即删 |
| 打桩测试里 `systemctl restart` 不改变 `sshd -T` 输出，会把"已达标短路"误判成失败 | 桩必须模拟真实语义：`sshd -T` 解析配置，不反映运行中的监听端口 |

## 演进记录

| 日期 | 变化 | 影响 |
|---|---|---|
| 2026-09-22 | 初版：自包含 + 幂等 + 交互闸门 | — |
| 2026-09-23 | 公共块统一 + `sync_check`；随机端口/密码；兼容厂商随机 SSH 端口 | 一致性从人肉同步变为工具校验 |
| 2026-09-25 | `04` 改菜单式；新增日常维护章节 | 用户不再需要记 `ufw`/`sshd` 子命令 |
| 2026-09-26 | `08-swap` 纳入仓库；`sync_check` 增加变量与包清单检查 | 比对范围扩到 `08` |
| 2026-09-29 | `05`/`06`/`07` 改菜单式；fail2ban 端口 fail-closed；修 `inherit_errexit` 缺陷 | 菜单成为标准形态；静默失效被前移成硬失败 |
| 2026-10-06 | `01+02` → `01-base.sh`，`05+06` → `05-ufw-ssh.sh` | 公共块拷贝 8 → 6（ADR-0002） |
| 2026-10-07 | 支持矩阵改为 Debian 优先 | 验收基线固定为 Debian 12 |
| 2026-11-12 | README 增加 Git 本地执行可选方案 | 交付形态增加，架构不变 |
| 2026-11-12 | 交互层统一（`ask_menu`/`ui_*`）；`05`/`07` 首次运行不再自动写 | 交互契约写入 `terms.md` |
| 2026-11-12 | 备份目录保留策略（`BK_KEEP`=20、内容相同复用、`bk_prune`） | 目标机不再产生散落文件 |
| 2026-11-12 | `CONTEXT.md` 退役，知识迁入 `docs/codewiki/` | 单一知识入口 |
| 2026-11-16 | 七个步骤脚本合并为单入口 `00-tui.sh`；删除私有 conf，状态改读原生来源；新增主菜单 `0` 标准初始化；`sync_check` 收缩为入口/关键行/包清单/私有状态四项 | ADR-0001、ADR-0002 被 ADR-0003 取代；失去历史旧端口自动推断 |

## 文档职责

| 文件 | 读者 | 内容 |
|---|---|---|
| `README.md` | 使用者 | 入口命令、主菜单、各功能菜单、检查点 |
| `docs/tutorial.md` | 想理解每条命令的人 | 手动等价做法 |
| `docs/codewiki/*` | 维护者 | 业务边界、架构、功能、开发流程、术语 |
| `docs/adr/*` | 维护者 | 决策与已否方案 |
| `.omp/AGENTS.md` | AI 代理 | 操作约束与硬规则（不含知识正文） |

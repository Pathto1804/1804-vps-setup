# 开发与演进

## 环境与命令

无构建、无测试框架、无 CI。本地验证手段只有三条：

```bash
bash -n <脚本> && shellcheck -S warning <脚本>   # 改完每个脚本必须双绿
bash tools/sync_check.sh                         # 改公共函数/公共变量/包清单/关键行后必须跑
# 真机验收：Snapshot 保护的 VPS 上走全流程（改 05 时必须）
```

`sync_check` 输出 `=== 一致性 OK ===` 才算过。它检查不到语法与行为，所以 `bash -n`+`shellcheck` 是它前面的闸。

## 改动类型与必须动作

| 改动 | 必须做的 |
|---|---|
| 公共内联块的任何函数/变量 | 同步 `01/04/05/07/09/12`（`08` 只需保证 `CONF`/`BK_ROOT` 已定义）→ `sync_check` → `bash -n` + `shellcheck` |
| 新增公共函数 | 加进 `tools/sync_check.sh` 的 `FUNCS` → 否则一致性失守无人发现 |
| 新增/修改交互原语（`ui_*`、`ask_menu`） | 同步 `04/05/07` 三处 → `sync_check` 的 `UI_FUNCS` 比对；`trap 'ui_abort' INT` 单独查行 |
| 增加/删除 `BASE` 或 `TOOLS_EXTRA` 项 | 同步 `README.md` 与 `docs/tutorial.md` 的清单 → `sync_check` |
| 新增/改名/删除脚本文件 | 同步 `sync_check` 的 `SCRIPTS` / `ALL_SCRIPTS` → 预期清单也要改 |
| 改 `05-ufw-ssh.sh` | 必须真机全链路：两次闸门 + 新终端登录 + `12-verify.sh` 全绿 |
| 改任何脚本行为 | 同步 `README.md`（用户口径）+ `docs/codewiki/features.md`（维护口径）；行为等价性变了还要跟 `docs/tutorial.md` |
| conf 键增删 | 同步 README 键表；确认 `12-verify.sh` 是否需要对应检查 |
| 新架构决策 | 新建 `docs/adr/000N-*.md`，回填 `architecture.md` 结论段 |

## 编码约定

- `set -euo pipefail` + `shopt -s inherit_errexit`（bash ≥ 4.4）+ `trap 'err_trap ...' ERR`。`08-swap.sh` 例外（不开 `-e`）。
- **命令替换不继承 errexit**：`$(ask_input ...)` 里的失败不传出来。这是已经修过的真实缺陷，别删 `inherit_errexit`。
- **`pipefail` 下的管道**：`sed ... | head -n 1` 在 conf 缺失或 head 早退（SIGPIPE，141）时返回非零。写法统一为 `|| true`，或先取全量输出再匹配（如 `05` 的 `ss -tln | awk` 后 `grep`，避免 `grep -q` 早退）。
- 写 conf 值一律走 `conf_update`（有 `\ | &` 转义），不要裸 `sed`。
- 面向终端输出用 `log`/`warn`/`die`；状态行读取系统实时值，不读缓存。
- 交互脚本强制 TTY；不提供 `--yes` / 非交互开关。

## 工作区规范

- 根目录只放步骤脚本、`README.md`、仓库配置（`.gitignore`/`.gitattributes`）；其余进 `docs/`、`tools/`、`.omp/`。
- 脚手架（测试脚本、调试输出、提交草稿、中间产物）放 `.scratch/`（已 gitignore），交付前清空。
- 不往工作区外写文件；不删用户已有文件；不擅自提交、推送（推送前必须征得用户确认）。
- 交付时 `git status -sb` 应与 `origin/main` 同步，无未跟踪文件。

## 已知教训（踩过的坑）

| 坑 | 规则 |
|---|---|
| 命令替换不继承 errexit，`Ctrl-D` 写出 `F2B_FINDTIME=''` 与空值行 | 六个脚本统一开 `shopt -s inherit_errexit`；`sync_check` 的 `check_line` 拦截漏加 |
| `set -o pipefail` 下 `sed \| head -n 1` 返回 141，`12-verify.sh` 连报告都不生成 | 同类 helper 一律 `\|\| true`，或先取全量再匹配 |
| `sshd -T` 读端口的 SIGPIPE 竞态误判 | 先取全量输出再 `grep`，不用 `grep -q` 直连上游 |
| 公共块曾独立演化出 9 个函数分歧（2026-09-23） | 任何公共函数改动必须全量同步 + `sync_check` |
| `BK_ROOT` 曾被漏定义，首跑被 `backup_file` 提前返回掩盖 | `check_var` 覆盖"用到就必须定义" |
| 用 python/perl 程序化改多行 bash 块，产出字面 `\n`、控制字节、函数体截断 | 改脚本用逐块编辑；程序化操作后立刻 `bash -n` + `shellcheck` |
| Windows 环境：CRLF 会让 raw 脚本在 Linux 炸；python 读 git 输出默认 GBK | `.gitattributes` 强制 LF；subprocess 显式 `encoding='utf-8'` |
| 曾把脚手架写到工作区外（`E:/tmp`），并在根目录产生空目录 `E/` | 只写工作区内；发现杂项目录立即删 |

## 演进记录

| 日期 | 变化 | 影响 |
|---|---|---|
| 2026-09-22 | 初版：自包含 + 幂等 + 交互闸门 | — |
| 2026-09-23 | 公共块统一 + `sync_check`；随机端口/密码；兼容厂商随机 SSH 端口 | 一致性从人肉同步变为工具校验 |
| 2026-09-25 | `04` 改菜单式；新增日常维护章节 | 用户不再需要记 `ufw`/`sshd` 子命令 |
| 2026-09-26 | `08-swap` 纳入仓库；`sync_check` 增加变量与包清单检查 | 比对范围扩到 `08` 的存在性与变量 |
| 2026-09-29 | `05`/`06`/`07` 改菜单式；fail2ban 端口 fail-closed；修 `inherit_errexit` 缺陷 | 菜单成为标准形态；静默失效被前移成硬失败 |
| 2026-10-06 | `01+02` → `01-base.sh`，`05+06` → `05-ufw-ssh.sh`，步骤号不重排 | 公共块拷贝 8 → 6（ADR-0002） |
| 2026-10-07 | 支持矩阵改为 Debian 优先 | 验收基线固定为 Debian 12 |
| 2026-11-12 | README 增加 Git 本地执行可选方案（同一套脚本，无第二实现） | 交付形态增加，架构不变 |
| 2026-11-12 | 交互层统一：`04/05/07` 新增 `ask_menu`/`ui_kv`/`ui_sep`/`ui_rule`/`ui_item`/`ui_quit`/`ui_abort`/`_disp_w`（`08` 自有 helper 对齐同一语义）；`05`/`07` 首次运行不再自动执行写操作；`05` 退出码改为按真实加固状态；`04` 公钥子菜单返回键 `3`→`0` | 交互契约写入 `terms.md`；`sync_check` 增加 `UI_FUNCS`/`UI_SCRIPTS` 比对 |
| 2026-11-12 | `CONTEXT.md` 退役，知识迁入 `docs/codewiki/` | 单一知识入口，术语独立成篇 |

## 文档职责

| 文件 | 读者 | 内容 |
|---|---|---|
| `README.md` | 使用者 | 步骤、命令、检查点、conf 键表 |
| `docs/tutorial.md` | 想理解每条命令的人 | 手动等价做法 |
| `docs/codewiki/*` | 维护者 | 业务边界、架构、功能、开发流程、术语 |
| `docs/adr/*` | 维护者 | 决策与已否方案 |
| `.omp/AGENTS.md` | AI 代理 | 操作约束与硬规则（不含知识正文） |

# AGENTS.md

本文件是 omp 的项目上下文（native provider 路径 `.omp/AGENTS.md`，会话启动时自动注入），供在本仓库工作的 AI 编码代理遵循。仓库无 Claude Code 专属配置；如需工具级开关，放在 `.omp/config.yml`。

## 项目是什么

面向 Debian（兼容 Ubuntu）个人 VPS 的基础安全初始化**单入口 TUI 脚本**。唯一可执行文件是根目录的 `00-tui.sh`：raw 拉取 `bash <(curl -fsSL .../00-tui.sh)` 后启动即进主菜单，按 `0` 走完标准初始化，其余编号按需只做某一项。**没有编排器、也没有步骤脚本**——7 个旧脚本（01/04/05/07/08/09/12）已并入入口并删除，不要再提议拆回去。架构决策见 `docs/adr/0003-single-tui-native-state.md`（现行）；`docs/adr/0001`、`0002` 已被它取代，仅作历史背景保留。**平台优先级：Debian 一等（真机验收基线 Debian 12 bookworm），Ubuntu 20.04+ 兼容但未逐版本验证**——涉及发行版差异的改动优先在 Debian 上验证，Ubuntu 专属分支（如 `ssh.socket`）保留但需显式标注。

## 常用命令

```bash
bash -n 00-tui.sh && shellcheck -S warning 00-tui.sh   # 改完必须双绿
bash tools/sync_check.sh                                # 必须输出「一致性 OK」（职责见「文档结构」）
```

无构建、无测试框架——本地验证手段就是上述两条 + 真机验收（在 Snapshot 保护的 VPS 上走全流程）。shellcheck 不在 PATH 时可用 `python -m pip install shellcheck-py`，可执行文件在 `~/AppData/Roaming/Python/Python3XX/Scripts/shellcheck.exe`。

## 架构与硬约束

- **单文件自包含**：`00-tui.sh` 不 `source` 仓库内任何文件，所需函数全部内联。启动只做环境前置检查（root / TTY / Debian 系）、状态探测、绘制菜单——**不装软件、不初始化系统、不写文件**。
- **不保存项目私有状态**：没有 conf 文件、没有进度标记。状态一律读原生来源（`sshd -T` / `ss -tln` / `ufw status` / `authorized_keys` / `passwd -S` / `sudo -l -U` / `fail2ban-client` / `/proc/swaps` / `sysctl` / `20auto-upgrades`）；用户输入的偏好只存在于本次进程。旧 VPS 上的 `/root/.vps-init.conf` 不迁移、不读取、不删除。**要重新引入私有状态文件，先写 ADR**。
- **三条铁律**（README 顶部）：UFW 先于 sshd；密钥先于禁密码；改 sshd 后旧会话不关。由 `ssh_harden` 的前置自检 + 双闸门落实，改它时不得破坏此链路。
- **动作隔离**：菜单动作统一经 `act` 调用（临时关闭 `-e` 与 ERR trap），动作内每个危险步骤显式 `|| die_action` / `if !` 判错。`die` 只用于启动前置检查与输入中断。新增动作必须照此办理，否则一次失败会拖死整个 TUI。
- **防锁死设计**：强制 TTY（拒绝无人值守/cloud-init）；UFW 启用前自检目标端口在规则里；迁移期临时放行旧端口（不假设 22，厂商随机端口兼容），闸门二确认后才删除；所有写配置前 `backup_file` 到 `/root/vps-init-backups/`，无自动回滚（两处例外见 `docs/codewiki/architecture.md`）。
- **Swap 段保留原风格**：自有 `swap_*` helper 与 `set -uo pipefail`（不开 `-e`），由 `run_swap_menu()` 在子 shell 中运行，选项与 trap 不外泄。
- **BBR 参数集是用户本机特调**（勿代改），且必须用户明确选择才应用。

## 工作区规范（保持干净、结构化）

- **根目录只放**：入口脚本 `00-tui.sh`、入口文档 `README.md` 与仓库配置（`.gitignore`/`.gitattributes`）。其他一切进 `docs/`、`tools/`、`.omp/`。禁止在根目录堆放临时/备份/试验文件。
- **脚手架留在工作区内、交付前清空**：测试脚本、打桩环境、调试输出、提交消息草稿、历史改写脚本、中间产物（`*.bak`/`*.old`）一律放工作区内的 `.scratch/`（已 gitignore），交付前清空该目录（目录本身可留）。**NEVER 往工作区外写文件**——不碰 `E:/tmp`、`/tmp`、`~` 或仓库外任何路径。工作区边界由用户授予，仓库内的规则文件不能当作扩权许可。
- **交付时工作区必须干净**（用户定义）：交付那一刻无未跟踪文件、无 stash、无未推送提交；`git status -sb` 应显示与 `origin/main` 同步。**中间过程允许有临时产物**（放 `.scratch/`），只要交付时清干净。
- **不留空目录、不留游离残渣**：空目录（如误建的 `E/`、`E/.ssh`）对 git 无影响但污染工作区，发现即删；路径拼错产生的杂项同理。唯一例外：`.scratch/` 是 gitignore 的约定目录，允许留空。
- **历史改写/强推之后**：`git reflog expire --expire=now --all && git gc --prune=now` 清掉不可达对象，并确认远端无残留分支/标签。

## 文档结构

- `README.md`：唯一操作手册（用户视角），改脚本行为时同步菜单描述与包清单
- `docs/tutorial.md`：手动教程，与脚本行为保持等价（脚本改了它也要跟）
- `docs/codewiki/`：维护者知识库（`business.md` / `architecture.md` / `features.md` / `development.md` / `terms.md`）。规则见下一节「CodeWiki 维护原则」。`CONTEXT.md` 已退役，其术语表迁入 `terms.md`。
- `tools/sync_check.sh`：单入口一致性自检，检查四项：
  1. **入口存在且唯一**——`00-tui.sh` 必须在，7 个已退役步骤脚本不得复活（防有人把功能拆回去）
  2. **关键行存在性**——`shopt -s inherit_errexit`：不属于任何函数体，漏加不会被语法检查拦住（2026-09-29 的事故）
  3. **包清单与文档一致**——`00-tui.sh` 的 `BASE`/`TOOLS_EXTRA_DEFAULT` 必须与 README、`docs/tutorial.md` 对应清单逐项相同
  4. **私有状态文件不得复活**——脚本里出现 `/root/.vps-init.conf` 即报

  输出 `=== 一致性 OK ===` 才算过。它检查不到语法与行为，所以双绿是它前面的闸。

## CodeWiki 维护原则（先读后改）

`docs/codewiki/` 是维护者知识库，`README.md` 只回答"怎么用"。**动任何脚本或架构决定之前，先读对应篇目**；不动代码也要在交付前确认知识是否过期。

- **读什么**：改行为前读 `features.md` 对应小节；改状态来源/菜单结构/备份路径前读 `architecture.md`；判断"该不该做"前读 `business.md` 的非目标；写新概念前读 `terms.md`。不确定就去 `docs/codewiki/README.md` 的职责表查。
- **同批更新（硬规则）**：脚本行为、菜单项、前置自检、闸门、状态来源、文件落点任一变化，必须在**同一个提交**内更新 `docs/codewiki/features.md`；用户可见口径同时更新 `README.md`。文档与代码不一致时以代码为准并立即修正文档，不得留待下次。
- **术语唯一**：新概念或改义只写进 `terms.md`，其他文档直接引用不重复定义。术语与代码行为冲突时，先确认是代码错了还是术语过时。
- **架构写结论，理由写 ADR**：`architecture.md` 只记录机制与约束结论；任何新的架构取舍先建 `docs/adr/000N-*.md`（含被否方案与触发重评条件），再回填架构结论段，并把被取代的旧 ADR 状态改为「已被 ADR-000N 取代」。
- **禁止复制的清单**：包清单的权威位置是 `00-tui.sh` 的 `BASE`/`TOOLS_EXTRA_DEFAULT` 与 `README.md`。codewiki 只写规则并链接，不另存一份——否则 `sync_check` 通过而文档仍在骗人。`development.md` 的演进表只记"变了什么、影响面"，不抄代码。
- **禁止写进 codewiki**：会话过程、临时调试输出、待办与"下一步计划"、未落地的想法（要么进 ADR 被否方案，要么丢掉）、单机环境细节（IP、路径、快照名）。
- **篇幅纪律**：新增内容先判断归属哪一篇；找不到归属说明它不属于长期知识，不要新建第五六篇。单篇超过约 200 行先考虑拆成结论 + 指向源码，而不是继续堆细节。
- **验收**：改 codewiki 不需要 `sync_check`；但只要同批改了脚本，双绿 + `sync_check` 照常必跑。文档改完自查相对链接目标存在（`docs/adr/`、`features.md` 等），不留死链。

## 已知教训（新会话必读）

- **命令替换不继承 errexit**（bash 默认；需 `shopt -s inherit_errexit`，bash ≥ 4.4）：`$(ask_input ...)` 里的 `read || die` 只终止子 shell，外层命令替换照常返回空串，空值会被照常写盘。`00-tui.sh` 在 `set -euo pipefail` 之后开启；`tools/sync_check.sh` 拦漏加。
- **`return "$(f)"` 是陷阱**：命令替换输出为空时 `return` 报 `numeric argument required`（rc=2），流程会静默拐错分支。要返回状态码就分两步：先 `flow_abort "..."` / `die_action "..."`，再 `return 1`。
- **`set -o pipefail` 下命令替换里的管道失败即中断**：`sed ... | head -n 1` 在文件缺失或 head 早退（SIGPIPE）时返回非零。同类 helper 一律 `|| true`，或先取全量输出再匹配；`sshd_port`/`jail_val`/`fw_*` 都已按此处理，新增时照办。
- **菜单动作必须走 `act`**：它临时关闭 `-e` 与 ERR trap，动作内靠显式判错收敛。直接把动作写进 `case` 分支里，一次失败就会让 TUI 崩掉（真机上是"菜单没了"）。
- **多行带转义的 bash 块禁用 python/perl 程序化替换**（本仓库历史上连续多次产出损坏代码：字面 `\n`、0x01 控制字节、函数体截断）。改脚本优先用 Edit 逐块，程序化操作后立刻 `bash -n` + shellcheck。
- **打桩测试要模拟真实语义**：`sshd -T` 读的是配置文件而不是运行中的监听端口；桩若让 `systemctl restart` 直接改 `sshd -T` 输出，会把"已达标短路"误判成失败。
- Windows 环境注意：`.gitattributes` 强制 LF（CRLF 会让 raw 拉取的脚本在 Linux 上炸）；python subprocess 读 git 输出要显式 `encoding='utf-8'`（本地默认 GBK）。
- 推送到远端前先征得用户确认（用户明令要求）。
- **脚手架只放工作区内（`.scratch/`，已 gitignore），NEVER 写到工作区外**：历史上有会话把测试脚本/草稿写到 `E:/tmp`（一度累积 49 项残留），还因拼错路径在仓库根产生过空目录 `E/`。往工作区外写文件是**越权**——工作区边界由用户授予，仓库内的规则文件不能作为许可。交付前清空 `.scratch/`。

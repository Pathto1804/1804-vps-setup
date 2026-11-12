# 功能清单

按步骤号排列。每个脚本：做什么 / 写哪些文件 / 失败语义 / 验证口径。菜单项编号与脚本实际输出一致，改菜单必须同步本节与 README。

步骤号是**起始**步骤号：`01` 覆盖步骤 1–2，`05` 覆盖 5–6，其余一一对应。3/10/11 无脚本（手动），跳号是有意的。

---

## 01-base.sh — 系统更新 + 基础工具（步骤 1–2）

**做什么**
1. `apt-get update` + `apt-get full-upgrade -y`。
2. 读/问 `TOOLS_EXTRA`（默认 `jq tmux lsof rsync zip`），装 `BASE` + `TOOLS_EXTRA`。
3. 写 `20auto-upgrades` 两行 `"1"`，并 `systemctl enable --now apt-daily.timer apt-daily-upgrade.timer`。
4. 最后才检查 `/var/run/reboot-required`，需要则询问是否立即重启。

**写**：`/etc/apt/apt.conf.d/20auto-upgrades`、conf 的 `TOOLS_EXTRA`。
**不写**：不装 git、tcpdump/strace/sysstat。
**失败**：`set -e` + ERR trap，apt 失败直接退出。
**验证**：`apt list --installed` 抽查；12 会复核自动更新与 needrestart。

---

## 04-user.sh — 管理员用户 + 公钥（步骤 4）

**做什么**：选目标用户（conf 记住上次的，可确认或换人；不存在则 `adduser` 并加入 `sudo` 组），进三项目录。

| 菜单 | 行为 | 写什么 |
|---|---|---|
| `1` 设置/修改登录密码 | 自己输入（转发 `passwd`）或随机生成（22 位，只显示一次，不进 conf） | 系统密码；`SUDO_NOPASSWD` 不动 |
| `2` sudo 免密 开↔关 | 切换 `/etc/sudoers.d/<user>`，`visudo -c` 校验，失败即删文件 | `SUDO_NOPASSWD`、sudoers 文件 |
| `3` 管理公钥 | 追加（逐行粘贴，空行结束）/ 删除（编号选择） | conf 的 `SSH_PUBKEY_N`、`~/.ssh/authorized_keys`（700/600、正确属主） |

**设计要点**：conf 是公钥的唯一事实源，每次改动后整份重写 `authorized_keys`；随机密码不落盘（`unset pw`）。
**失败**：`visudo -c` 失败立即删除刚写的 sudoers 文件并退出。
**退出后**：未设密码会警告；打印闸门一提示（新终端密钥登录 + `sudo -v`，通过前禁止 05/06）。

---

## 05-ufw-ssh.sh — 防火墙 + SSH 加固（步骤 5–6）

仓库里**唯一能锁死登录**的文件。改动必须真机全链路验收：两次闸门 + 新终端登录 + `12-verify.sh` 全绿。

**首次运行**：无 `SSH_PORT` → `do_init` 仍需用户从菜单 `1` 触发（脚本只做前置的端口询问与 conf 写入）；不再自动接 `do_apply`。加固同样只由菜单 `2` 触发，ufw 未启用时只提示。

### 防火墙初始化 `do_init`（菜单 `1`）
- 读当前 sshd 端口（读不到即退出）。
- 端口：conf 有则确认沿用；否则给 `rand_port` 建议，回车采纳。
- 迁移期 `ufw allow <旧端口>/tcp` 并写 `OLD_SSH_PORT`；已在目标端口则跳过。
- `ALLOWED_PORTS`（conf_get）→ `ufw default deny incoming` / `allow outgoing` → 放行 SSH 与业务端口。
- **自检**：`ufw show added` 中必须能看到新端口，否则拒绝 `enable`（顺序不能反，否则当场切断会话）。

### SSH 加固 `do_apply`（菜单 `2`）
1. 断言 `Include` drop-in 已启用；读迁移前端口，写 `OLD_SSH_PORT`（无迁移则不打这条规则）。
2. 断言 `ADMIN_USER` 真实存在（AllowUsers 写错即全体锁死）。
3. `ufw_precheck`：ufw active + 新端口已放行 + 迁移期旧端口仍放行。
4. `backup_file` 后写 `01-hardening.conf`：`Port` / `PermitRootLogin no` / `PasswordAuthentication no` / `PubkeyAuthentication yes` / `AllowUsers` / `MaxAuthTries 3`。
5. `sshd -t` → `sshd -T` 实际端口比对（防 drop-in 被压）→ **闸门一**（确认 04 后密钥登录可用）→ 若有 `ssh.socket` 则切回 `ssh.service` → `systemctl restart ssh`。
6. 轮询 `ss` 确认端口监听（3 秒内未监听只警告）。
7. **闸门二**：新终端新端口登录成功才继续；答 n 保留旧端口规则并打印恢复指引，退出码 1。
8. 确认后删除旧端口临时规则。

### 维护菜单（`0` 或回车退出；子菜单 `0` 或回车返回）
| 项 | 行为 |
|---|---|
| `1` | 防火墙初始化 / 重新应用 |
| `2` | SSH 加固 / 重新应用（同样过双闸门） |
| `3` | 状态总览（ufw 规则 + sshd 生效值 + 加固文件 + drop-in 覆盖检查） |
| `4` | 放行端口（tcp/udp/两者，逗号多端口，可限来源 IP） |
| `5` | 按编号删规则；删到 SSH 端口时先警告断连；ufw 未启用时拒绝（拿不到编号） |
| `6` | 启用 / 禁用（禁用二次确认；启用前自动补放行 SSH 端口） |
| `7` | 改默认策略（入站/出站） |
| `8` | 改 `ALLOWED_PORTS` 并按清单增删规则（跳过当前 SSH 端口） |
| `9` | 改 `SSH_PORT` / `ADMIN_USER`，写 conf |
| `10` | 从备份恢复 `01-hardening.conf`：按时间倒序列表、恢复前再备份、`sshd -t` 失败自动回滚、端口变化时先确认放行再问是否重启 |

**写**：`01-hardening.conf`、conf、ufw 规则。
**退出语义**：加固文件已写且 sshd 实际端口 == conf `SSH_PORT` 才算"第 5–6 步完成"；否则打印未完成原因并以退出码 1 结束（`12-verify.sh` 同口径）。
**已知细节**：`01-` 前缀抢在 `50-cloud-init.conf` 之前（sshd 先出现者优先）；`do_scan_dropins` 会指出哪些文件会压过或已被压住。

---

## 07-fail2ban.sh — fail2ban（步骤 7）

**首次运行**：conf 无 `F2B_BANTIME` → 只提示"尚未按本脚本策略配置"，安装与写配置全部由菜单 `1` 触发（不再自动 `do_apply`）。

### `do_apply`（菜单 `1`）
- `apt-get install -y fail2ban`。
- **端口闸门（fail closed）**：`sshd -T` 读不到端口 → 拒绝；端口不是认可的新端口（1024–65535 且非 22/2222）→ 拒绝；conf 端口与 sshd 实际不一致 → 拒绝。conf 无可用端口时以 sshd 实际值为默认问一次。
- 写 `jail.local`：`[sshd] enabled=true` / `port` / `backend = systemd` / `bantime` / `findtime` / `maxretry`（后三者来自 `conf_get_def`，默认 86400 / 600 / 3）。
- `systemctl enable fail2ban` → `restart` → 轮询 `fail2ban-client status sshd`（最多 10 秒）。
- 10 秒未就绪：警告并 `exit 1`。

### 维护菜单（`0` 或回车退出；子菜单 `0` 或回车返回）
| 项 | 行为 |
|---|---|
| `2` | 只读详情：`jail.local` + 封禁列表 + 服务日志末 20 行 |
| `3` | 改 bantime/findtime/maxretry → 写 conf，末尾问是否立即应用 |
| `4` | 封禁 / 解封 IP（仅 IPv4） |

**表头四行**：服务状态、jail 状态与封禁数、`jail.local` 生效参数（与 conf 不一致标注"按 1 应用"）、jail 端口 vs sshd 实际端口（读不到显示"未知"）。

**退出语义**：jail 未就绪 或 jail 端口 ≠ sshd 实际端口 → 打印"第 7 步未完成"并 `exit 1`；`12-verify.sh` 在同状态下同样判红。

**为什么 fail closed**：让 fail2ban 盯一个 sshd 没在监听的端口是静默失效，比拒绝写入更危险。

---

## 08-swap.sh — Swap 管理（步骤 8）

独立风格：`set -uo pipefail`（无 `-e`）、自有 helper、`trap cleanup EXIT`。只管理 swap **文件**，不碰分区；不支持 btrfs/ZFS 上的 swap；容器内无法启用 swap。
**交互契约**：沿用自有 `ask_option`/`ask_value`/`confirm`，语义与 `04`/`05`/`07` 一致——`ask_option` 空回车返回空 `ANSWER`（调用方视为取消，主菜单即退出）；`ask_value` 空回车取默认值（所有调用点都有默认值，不存在空转）。

| 菜单 | 行为 |
|---|---|
| 查看状态 | 内存 / swap / swappiness / `/proc/swaps` / fstab 条目 |
| 创建 / 替换 | 已有 swap 则先确认替换并删除；大小选项（1/2/4/8G + 自定义，按内存推荐）；路径校验 + btrfs/ZFS 拒绝 + 空间检查；可选同时调 swappiness；确认后 `fallocate`（退化 `dd`）→ `chmod 600` → `mkswap` → `swapon` → 写 fstab |
| 调整 swappiness | 0–100，写 `/etc/sysctl.d/99-swappiness.conf` 并 `sysctl -p` |
| 关闭并删除 | 候选 = 已启用 + fstab 残留条目；逐个确认；全部删完后可选移除 swappiness 配置（运行时回 60） |

**fstab 安全链**：备份到 `/etc/fstab.bak.<时间戳>.<序号>` → 记录 `findmnt --verify` 基线 → 修改 → 再校验 → 失败且基线正常则自动恢复。
**清理**：创建中途失败或 Ctrl+C，删除半成品文件并提示 fstab 备份位置。

---

## 09-bbr.sh — BBR + TCP 调优（步骤 9）

- 写 `/etc/sysctl.d/99-bbr.conf`（内容内联，逐行可审；含 `vm.swappiness = 10`、`tcp_congestion_control = bbr`、`default_qdisc = fq` 等）。
- 内容一致则跳过写入（幂等）；不一致先 `backup_file`。
- `sysctl -p` 部分键失败只警告（新内核可能移除 `tcp_fack`）。
- **验证**：`tcp_congestion_control` 必须为 `bbr`，否则 `die`；`default_qdisc` 非 `fq` 只警告。

**注意**：参数是为作者自己的线路/内存特调的，README 已声明不通用。

---

## 12-verify.sh — 终检 + 归档（步骤 12–13）

只读。conf 缺失则降级为纯系统检查并提示。

**红灯（退出码 1）**
- sshd 端口不可读，或与 conf 不一致。
- `passwordauthentication` / `permitrootlogin` 不为 `no`。
- ufw 未启用 / 未放行当前 SSH 端口 / 仍放行旧端口（`OLD_SSH_PORT` 与当前相同则转为黄灯提示）。
- fail2ban 未运行或 sshd jail 未启用；`jail.local` 未写 `port`（默认盯 22）或端口与 sshd 实际不一致。
- `20auto-upgrades` 未启用；needrestart 未安装。

**黄灯**
- swap 未启用、BBR 未启用、NTP 未激活、根分区 ≥90%、存在 `reboot-required`、conf 缺失导致无法比对旧端口。

**输出**：屏幕绿/红/黄逐项 + `/root/vps-init-report.md`（含主机、时间、发行版、配置摘要、检查结果）。无红灯才打印第 12 步完成。

---

## 手动步骤（无脚本）

| 步骤 | 内容 |
|---|---|
| 0 | 查系统、记 SSH 端口、建 Snapshot、生成密钥、国内换源、可选 bench.sh |
| 3 | `hostnamectl`（可选）、`timedatectl set-timezone`、确认 NTP |
| 10 | 复核 `20auto-upgrades` 两行 `"1"` |
| 11 | Docker 仅提示：linuxmirrors 脚本，**必须选不关闭防火墙** |
| 13 | 核对报告 + 创建最终 Snapshot |

# 功能清单

唯一入口 `00-tui.sh`。本节按**主菜单编号**排列：每项写清状态来源、动作、写哪些文件、失败语义与验证口径。菜单编号与脚本实际输出一致，改菜单必须同批更新本节与 README。

启动本身不写任何文件；所有写操作都必须由用户在子菜单里显式选择。

---

## 主菜单（`q` 退出，空输入重问）

顶部状态行全部实时读取：SSH 端口（`sshd -T`）、UFW（`ufw status`）、管理员（有效 `AllowUsers` 唯一用户）、公钥数（`authorized_keys`）、fail2ban（服务 + jail）、Swap（`free`/`swapon`）、BBR（`sysctl`）、自动更新（`20auto-upgrades`）。

| 编号 | 功能 |
|---|---|
| `0` | 标准初始化 |
| `1` | 换源说明（第三方脚本；只显示命令，不自动执行） |
| `2` | 系统更新与基础工具 |
| `3` | 时区 |
| `4` | 用户、密码、sudo 和密钥 |
| `5` | UFW 与 SSH |
| `6` | fail2ban |
| `7` | Swap |
| `8` | BBR |
| `9` | 终检与报告 |
| `q` | 退出 |

---

## `0` 标准初始化

无参数、只由主菜单 `0` 调用。按固定顺序执行，逐项读原生状态，**只修改未达标项**；已有状态满足要求时打印"已满足"并跳过写入。没有任何进度标记或私有状态文件，失败后重跑由当前系统状态续接。

| 步 | 动作 | 停点 |
|---|---|---|
| 1 | 一开始询问是否换源；显示环境与当前 SSH 端口 | 必须确认初始 Snapshot、安全组端口、密钥；换源选择只在 Snapshot 确认后转为人工步骤，拒绝 Snapshot 即中止且不改系统 |
| 2 | `apt-get update`；`apt-get -s full-upgrade` 有事务才 `full-upgrade -y`；补齐 `BASE`；选装可选工具；`ua_enable`；`maybe_reboot` | 需要重启时询问，选重启即结束本次流程 |
| 3 | 检查当前时区与 NTP | 时区须是 `timedatectl list-timezones` 返回的有效值，接受任一有效时区；NTP 未 active 时暂停复检，仍未 active 即中止；不自动改 NTP |
| 4 | 解析非 root 管理员（`--allow-new`）→ `adduser` + 复查存在性 + 加入 sudo 组 → 密码 / sudo 免密 → 公钥 | 必须在新终端强制公钥登录并通过 `sudo -v`；有效 `AllowUsers` 仅允许 root 时停止，不写 SSH 加固配置 |
| 5 | 读 sshd 实际端口；22/2222 时给随机建议并要求确认/输入目标端口，已是自定义端口则沿用 → `fw_prepare_for_ssh` → `ssh_harden` | 双闸门；闸门一/二任一拒绝即中止且不进入第 6 步；闸门二拒绝时旧端口规则保留 |
| 6 | jail 未就绪或端口不一致才 `f2b_apply` | 读不到 sshd 端口或 jail 未就绪即中止 |
| 7 | swap 未启用时询问是否进 Swap 流程（默认跳过） | 跳过则继续 |
| 8 | 显示拥塞控制与 qdisc，说明参数为作者特调 | 明确选择才写 `99-bbr.conf`；拒绝则继续，不改 sysctl |
| 9 | 复核自动更新 → Docker 仅提示（必须选"不关闭防火墙"）→ 终检 → 提示创建最终 Snapshot | — |

`fw_prepare_for_ssh` 的细节：ufw 未启用时写默认策略（deny incoming / allow outgoing）；迁移期临时放行当前端口；放行目标端口；**仅首次初始化（ufw 未启用）时**询问额外业务端口；启用前自检目标端口在规则里，否则拒绝 `enable`。

---

## `1` 换源说明

只显示 [LinuxMirrors](https://linuxmirrors.cn/main.sh) 来源、风险提示和人工命令。脚本不是本项目提供或维护的工具；本项目不下载、不执行，也未完成其当前在线版本的全量安全审计。标准初始化开始时询问是否换源，Snapshot 确认后由操作者在另一个 root 终端执行；若继续标准流程，应在第三方脚本里跳过软件包升级。

## `2` 系统更新与基础工具

| 项 | 行为 |
|---|---|
| `1` 刷新索引并升级系统 | `apt-get update`（失败即中止动作）→ `apt_pending_count` 为 0 则只提示"已是最新"→ 否则 `full-upgrade -y` → `maybe_reboot` |
| `2` 补齐必要包 | `missing_pkgs ${BASE}`，为空则"已满足"，否则只装缺的 |
| `3` 选择并安装可选工具 | 回车取 `TOOLS_EXTRA_DEFAULT`（`jq tmux lsof rsync zip`），`none` 不装；只装缺的 |
| `4` 启用自动安全更新 | `20auto-upgrades` 两行已为 `"1"` 则跳过写入；否则先备份再写；`systemctl enable --now apt-daily.timer apt-daily-upgrade.timer` |

**写**：`/etc/apt/apt.conf.d/20auto-upgrades`、apt 包集合。
**不写**：不装 git、tcpdump/strace/sysstat。

---

## `3` 时区

显示当前时区与 NTP 状态。修改时只接受 `timedatectl list-timezones` 中的名称；先用 `backup_file` 备份 `/etc/localtime`，再 `timedatectl set-timezone` 并复查。失败时不自动回滚。该菜单不修改 NTP；标准初始化接受任一有效当前时区并要求 NTP active。

## `4` 用户、密码、sudo 和密钥

管理员解析顺序：本进程已确定且 UID 非 0 的现存账号 → sshd 有效 `AllowUsers` 中唯一且存在的非 root 用户 → 列出系统现有可登录普通用户（UID 1000–59999 且 shell 非 nologin/false）。root（UID 0）永远不能作为管理员。

**解析结果必须是已存在的非 root 账号**（`user_exists` 且 `id -u` 非 0）。默认模式下输入不存在的用户名会被拒绝；只有 `do_standard_init` 第 4 步用 `--allow-new` 放行新用户名，随后立即创建并复查。若有效 `AllowUsers` 只列 root，新账号在当前策略下不能登录：流程会停止且不会改 SSH 配置，操作者须手动允许新用户并验证后重跑。用户名只存在于本次进程。

> 历史缺陷：早期版本用 `v_user` 格式校验就接受用户名，导致"幽灵账号"——此后 `chpasswd`、`sudo -l`、`authorized_keys` 全部对着不存在的账号执行，`chpasswd` 报 PAM `Authentication token manipulation error`。

| 项 | 行为 | 写什么 |
|---|---|---|
| `1` 切换 / 新建管理员 | 列候选 → 选择；不存在则 `adduser` + 复查 `user_exists` + `usermod -aG sudo`，任一步失败则 `die_action` 且不切换管理目标 | 系统账户 |
| `2` 设置或修改密码 | 转发 `passwd`，或生成 22 位随机密码（只显示一次，`unset` 后不留存）；两条路径写完后都复查 `passwd -S` 为 `P`，失败时原文回显 `chpasswd`/`passwd` 的 stderr | 系统密码 |
| `3` sudo 免密 开/关 | 用 `sudo -l -U` 的有效权限判断当前状态；`unknown` 直接拒绝切换。开启写 `/etc/sudoers.d/<用户>` 并 `visudo -c`，失败即删文件。关闭**只删本项目管理的那个文件**，删后重查；若仍 NOPASSWD 则明确报告"其他规则仍放行" | `/etc/sudoers.d/<用户>` |
| `4` 追加公钥 | 逐行粘贴，空行结束；逐行过 `v_pubkey`，非法行跳过；读现有文件后追加 | `authorized_keys` |
| `5` 删除公钥 | 按行号删除用户选中的**原始行**，其余行原样保留 | `authorized_keys` |
| `6` 查看 authorized_keys | 只读 | — |

**authorized_keys 写法**：先 `backup_file`，再 `install -m 600` 建 `<file>.tmp.$$` → 写入 → `mv -f` 原子替换 → 恢复属主与 700/600。异常退出由 EXIT trap 清理临时文件。**不重建为"缓存里的密钥列表"**。

---

## `5` UFW 与 SSH

仓库里**唯一能锁死登录**的菜单。改动必须真机全链路验收：两次闸门 + 新终端登录 + 终检全绿。

| 项 | 行为 |
|---|---|
| `1` 查看 UFW 状态与规则 | `ufw status verbose` + 带编号规则；未启用时改列 `ufw show added` |
| `2` 添加放行规则 | tcp/udp/两者，逗号多端口，可限来源 IP |
| `3` 删除规则（按编号） | 未启用时拒绝（拿不到编号）；删到当前 SSH 端口时先警告断连 |
| `4` 启用 / 禁用 | 禁用二次确认；启用前若 SSH 端口未放行先补上 |
| `5` 修改默认策略 | 入站/出站 × allow/deny；入站 allow 需二次确认 |
| `6` 应用 SSH 加固 | 沿用当前生效端口；已达标则提示"已满足"，不重写、不重启 |
| `7` 修改 SSH 端口并加固 | 新端口先确认 ufw 已放行（未放行可先放行），再走同一加固流程 |
| `8` 查看生效值与加固文件 | `sshd -T` 关键项 + 加固文件 + drop-in 覆盖检查 |
| `9` 从备份恢复 | 按时间倒序列备份；恢复前再备份；`sshd -t` 失败自动回滚；端口变化时先确认放行再问是否重启 |

**`ssh_harden` 顺序**（不可调整）：
1. 断言 `Include` drop-in 已启用；断言 `ADMIN_USER` 真实存在。
2. 读迁移前实际端口，只保存在本次流程变量里。
3. `ufw_precheck`：active + 目标端口已放行 + 迁移期旧端口仍放行。
4. **已达标短路**：加固文件内容与 `sshd -T` 生效值全部匹配则直接返回，不重写不过闸门。
5. 备份后写 `01-hardening.conf`（`Port` / `PermitRootLogin no` / `PasswordAuthentication no` / `PubkeyAuthentication yes` / `AllowUsers` / `MaxAuthTries 3`）。
6. `sshd -t` → `sshd -T` 实际端口比对 → **闸门一** → 若有 `ssh.socket` 则切回 `ssh.service` → `systemctl restart ssh`。
7. 轮询 `ss -tln` 确认监听（3 秒未监听只警告）。
8. **闸门二**：答 n 保留旧端口规则并给恢复指引，返回 1；答 y 才删旧端口临时规则。

---

## `6` fail2ban

| 项 | 行为 |
|---|---|
| `1` 应用 / 重新应用 | 未装则 `apt-get install -y fail2ban` → **端口闸门**（`sshd -T` 读不到端口即拒绝写 jail）→ 逐项询问参数（默认取 `jail.local` 现值，缺失用 86400/600/3）→ 写 jail → enable + restart → 轮询 `fail2ban-client status sshd`（最多 10 秒） |
| `2` 查看状态详情 | `jail.local` + 封禁列表 + 服务日志末 20 行 |
| `3` 修改参数 | 当前值来自 `jail.local`；未变化则不改；确认后写 jail 并重启，端口同样先校验 |
| `4` 封禁 / 解封 IP | `fail2ban-client set sshd banip\|unbanip`，仅 IPv4 |

**表头四行**：服务状态、jail 状态与封禁数、`jail.local` 生效参数、jail 端口 vs sshd 实际端口（读不到显示"未知"）。

**为什么 fail closed**：让 fail2ban 盯一个 sshd 没在监听的端口是静默失效，比拒绝写入更危险。

---

## `7` Swap

独立风格模块：`set -uo pipefail`（无 `-e`）、自有 helper（`swap_ask_option` / `swap_ask_value` / `swap_confirm`，结果写入 `SWAP_ANSWER`）、`trap swap_cleanup EXIT`；在子 shell 中运行，选项与 trap 不外泄。只管理 swap **文件**，不碰分区；不支持 btrfs/ZFS 上的 swap 文件；容器内无法启用 swap。

| 项 | 行为 |
|---|---|
| `1` 查看状态 | 内存 / swap / swappiness / `/proc/swaps` / fstab 条目 |
| `2` 创建 / 替换 | 已有 swap 则先确认替换并删除；大小选项（1/2/4/8G + 自定义，按内存推荐）；路径校验 + btrfs/ZFS 拒绝 + 空间检查；可选同时调 swappiness；确认后 `fallocate`（退化 `dd`）→ `chmod 600` → `mkswap` → `swapon` → 写 fstab |
| `3` 调整 swappiness | 0–100，写 `/etc/sysctl.d/99-swappiness.conf` 并 `sysctl -p` |
| `4` 关闭并删除 | 候选 = 已启用 + fstab 残留条目；逐个确认；全部删完后可选移除 swappiness 配置（运行时回 60） |

**fstab 安全链**：备份到 `${BK_ROOT}/<时间戳>/fstab[.N]` → 记录 `findmnt --verify` 基线 → 修改 → 再校验 → 失败且基线正常则自动恢复。同秒同目录已有同名备份时顺延序号，绝不覆盖旧备份。

---

## `8` BBR

显示当前 `tcp_congestion_control` / `default_qdisc` / 配置文件状态；`1` 写入并应用 `/etc/sysctl.d/99-bbr.conf`（内容一致则跳过写入；`sysctl -p` 部分键失败只警告）；`2` 只读查看。**参数是作者本机特调，必须用户明确选择才应用**；`tcp_congestion_control` 不是 `bbr` 时报错返回 1。

---

## `9` 终检与报告

只读。全部结论来自当前系统状态，**不从任何缓存推断历史端口或历史选择**。

**红灯**：`passwordauthentication` / `permitrootlogin` 不为 `no`；sshd 端口不可读；ufw 未安装/未启用/未放行当前 SSH 端口；fail2ban 未安装/未运行/jail 端口未写或与 sshd 不一致；`20auto-upgrades` 未启用；needrestart 未安装。

**黄灯**：swap 未启用、BBR 未启用、NTP 未激活、根分区 ≥90%、存在 `reboot-required`、**历史端口无法自动判定**（提示人工核对规则列表）。

**输出**：屏幕绿/红/黄逐项 + `/root/vps-init-report.md`（主机、时间、发行版、当前系统状态、完整 ufw 规则、检查结果）。写入失败时明确报告路径不可写。有红灯返回 1。

---


## 手动步骤（无脚本）

| 步骤 | 内容 |
|---|---|
| 上机前 | 查系统、记 SSH 端口、建 Snapshot、生成密钥、国内换源、可选 bench.sh |
| 时区/NTP | `timedatectl list-timezones` 中任一有效时区 + 确认 NTP active（标准初始化只检查，不自动修改 NTP） |
| Docker | 仅提示：linuxmirrors 脚本，**必须选不关闭防火墙** |
| 收尾 | 核对报告 + 创建最终 Snapshot |

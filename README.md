# myVPS：给一台 Debian VPS 做安全初始化

假设你刚刚买了一台 VPS，用 SSH 连上去，面对着 root 提示符，不知道从哪儿下手。这本小册子就是为这个时刻写的。

我们要做的事可以一句话概括：**把一台出厂状态、随时可能被扫描器敲门的机器，改造成一台只认你的密钥、该关的门都关着、补丁会自己打上的机器。** 入口只有一个脚本：拉下来跑，它会进入交互式菜单；按 `0` 就按正确顺序把整套流程走一遍。

本页是唯一操作手册：怎么跑、菜单每一项做什么、检查点在哪。想弄清楚每条命令在干什么，可以对照[手动教程](docs/tutorial.md)逐条敲一遍。

## 从这里开始（三步）

1. **云平台先拍 Snapshot**。控制台里创建一份初始快照——锁死时这是唯一退路。
2. **登录 VPS 并提权**：

   ```bash
   sudo -i
   ```

3. **拉脚本跑起来，在主菜单按 `0`**：

   ```bash
   bash <(curl -fsSL https://raw.githubusercontent.com/Pathto1804/myVPS/main/00-tui.sh)
   ```

   国内拉不动就把 URL 前面加 `https://ghproxy.net/`（详见[国内拉不动 GitHub 怎么办](#国内拉不动-github-怎么办)）。

跑起来之后只剩两件事要你决定：**要不要继续**（每个闸门用 `y` / `n` 回答，大小写都认，直接回车走提示里写明的默认值），和**去云平台改安全组**。其余都是按回车。

第一次用？照 `0` 的提示一路走下去，它会在正式初始化前询问是否手动换源，然后依次做：系统更新 → 时区/NTP 检查 → 建管理员 → 防火墙 → SSH 加固 → fail2ban → Swap → BBR → 终检。任何安全检查失败或闸门拒绝，都会停止后续步骤；只有 Swap 创建失败只告警并继续。

> **免责声明**：本项目是**个人自用**的 VPS 基础配置脚本集，**不具有通用性**。脚本里的参数和取舍都基于作者本人的需求，由 AI 协助生成，没有经过广泛验证。作者不对任何内容作担保。动手之前，请**自己把脚本读一遍**，尤其是涉及防火墙和 SSH 的那部分。据此操作的风险由使用者自负。

## 先把三条铁律刻在脑子里

后面所有步骤都是围着这三条规矩转的。它们不是建议，是防锁死的底线：

1. **UFW 先于 sshd**：改 SSH 端口之前，新端口必须已经在 ufw 里放行，并且 `ufw status` 能看见它。
2. **密钥先于禁密码**：写下 `PasswordAuthentication no` 之前，你必须已经用密钥成功登录过新用户。
3. **旧会话不关**：改完 sshd 配置，当前这个窗口别关。新开一个终端，确认新端口加密钥能登录，才允许关掉旧的。

脚本会用"前置自检"和"闸门"挡住大多数顺序错误——比方说 ufw 还没放行就去做 SSH 加固，脚本会直接拒绝执行。但整体顺序终究是你自己掌握的。

## 上机之前，先在云平台上做几件事

这一步没有脚本，全靠你手动看和记。但它决定了后面出问题时你有没有退路，所以别跳。

先确认你手里这台机器是什么：

```bash
cat /etc/os-release        # 发行版和版本号
nproc                      # 几个核
free -h                    # 内存多大
df -h                      # 磁盘多大
```

系统要求：**Debian 12 / 13 是一等支持**，真机验收基线是 Debian 12 bookworm；Debian 11 和 Ubuntu 20.04+ 理论上可用，但没有逐版本验证过。两者都依赖 `sshd_config.d` 目录，而且基础工具里的 `bind9-dnsutils` 从 Debian 11 / Ubuntu 20.04 起才有——更老的系统会卡在装包上。

接着记下当前的 SSH 端口：

```bash
sshd -T | grep ^port
```

有些云厂商很调皮，把 sshd 预置在一个随机端口上，而不是 22。脚本能自动识别，但你自己得知道它是什么，并且确认云平台的**安全组**放行的正是这个端口。

然后到云平台控制台上做三件事：

- 记下安全组当前放行的规则。
- **创建一个初始 Snapshot**。整个流程里唯一不可替代的一步，就是它。万一你把 SSH 锁死了，这是最后一道闸门。
- 如果 SSH 密钥还没生成，在本地机器上生成一对：`ssh-keygen -t ed25519`。

云镜像一般自带 `curl`；万一没有，`apt install -y curl`。

### 国内服务器：先换源再上路

官方源在国内访问可能较慢，国内服务器可选用 SuperManito 的 [LinuxMirrors](https://linuxmirrors.cn) 第三方脚本：

```bash
bash <(curl -fsSL https://linuxmirrors.cn/main.sh)
```

该脚本不是本项目提供或维护的工具；上游脚本标注 MIT，但本项目**未对当前在线版本完成全量安全审计**。以 root 执行前先自行检查并接受风险。脚本会改软件源，也可能询问是否升级软件包；若接下来运行本项目标准初始化，请在第三方脚本里选择不升级，避免重复处理。

主菜单 `1` 只显示来源、风险和命令，不下载或执行脚本。标准流程一开始会询问是否换源；选择是时，必须先通过 Snapshot 确认，再由你在另一个 root 终端手动运行并返回确认。海外服务器或不愿使用第三方脚本时跳过。

参数说明见[手动教程](docs/tutorial.md#0-云平台基础检查)。

### 顺便测一下机器真实性能（可选）

趁系统还干净，跑一下 [bench.sh](https://bench.sh)，看看商家标称的带宽和磁盘读写有没有虚标：

```bash
bash <(curl -Lso- bench.sh)
```

输出包括系统信息、网络测速、磁盘读写。跑完心里有数，后面步骤也不会影响它。

## 怎么跑

**先提权，在 root 会话里跑。**

```bash
sudo -i
bash <(curl -fsSL https://raw.githubusercontent.com/Pathto1804/myVPS/main/00-tui.sh)
# 国内拉不动 → 加速版：
bash <(curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/Pathto1804/myVPS/main/00-tui.sh)
```

启动后**只做三件事**：检查运行环境（root / 交互终端 / Debian 系）、读系统当前状态、画主菜单。**不装软件、不初始化系统、不写任何文件。** 按 `q` 直接退出，机器上不会留下任何痕迹。

- **不要**用普通用户身份 `sudo bash <(curl …)`。sudo 会关掉额外文件描述符，你会得到一个莫名其妙的 `/dev/fd/63: No such file or directory`。
- 已经在 root 会话里了，就**别**再套一层 `sudo`。
- curl 统一带 `-S`，这样下载失败会明确报错，而不是无声无息地断掉。

**想固定版本？** 把命令里的 `main` 换成发布 tag。**跑到一半 SSH 断了？** 重连后再跑一次，选 `0` 会按当前系统状态续接——已经达标的项会显示"已满足"并跳过，不会重写。

### 国内拉不动 GitHub 怎么办

如果你看到命令卡住、`Connection reset`，或者速度只有几十 KB/s，那是网络问题，不是脚本问题。在原始 URL 前面加一层第三方加速前缀，默认用 `ghproxy.net`。可用的前缀不止一个，哪个挂了就换下一个：

```text
https://ghproxy.net/
https://ghfast.top/
https://gh-proxy.com/
https://gh.llkk.cc/
https://gh.ddlc.top/
```

也可以整段换成 jsDelivr CDN：把 `https://raw.githubusercontent.com/Pathto1804/myVPS/main/` 换成 `https://cdn.jsdelivr.net/gh/Pathto1804/myVPS@main/`。按分支取有大约 12 小时缓存，要准就用 tag。

两点提醒：

- **加速站是第三方。** 脚本内容要经过它中转，在意的话就本机 `curl` 下载 → `scp` 上传 → `sudo bash 00-tui.sh`。
- **缓存滞后哪家都有。** 刚推送的改动可能要几分钟才在代理上生效。

按开头免责声明的要求：不管走哪条路，执行前先读一遍。

## 主菜单

菜单顶部是**实时状态**，每次绘制前重新读取，全部来自系统原生来源，没有任何缓存文件：

| 状态行 | 来源 |
|---|---|
| SSH 端口 | `sshd -T` 的有效值 |
| UFW | `ufw status` |
| 管理员 | sshd 有效 `AllowUsers` 中唯一存在的用户；没有则显示"未确定" |
| 公钥 | `~/.ssh/authorized_keys` 里的公钥行数 |
| fail2ban | `systemctl is-active fail2ban` + `fail2ban-client status sshd` |
| Swap | `free -h` / `swapon --show` |
| BBR | `sysctl net.ipv4.tcp_congestion_control` |
| 自动更新 | `/etc/apt/apt.conf.d/20auto-upgrades` |

菜单编号固定：

| 编号 | 功能 |
|---|---|
| `0` | 标准初始化（按顺序引导全流程） |
| `1` | 换源（显示第三方脚本说明；不自动执行） |
| `2` | 系统更新与基础工具 |
| `3` | 时区 |
| `4` | 用户、密码、sudo 和密钥 |
| `5` | UFW 与 SSH |
| `6` | fail2ban |
| `7` | Swap |
| `8` | BBR |
| `9` | 终检与报告 |
| `q` | 退出 |

**进入任何编号都只是打开状态页/子菜单，不会自动执行写操作**，必须再显式选动作。主菜单空回车原地重问（不会当成 `0`）；子菜单里 `0` 或空回车返回主菜单。

## 标准初始化（菜单 `0`）

这是把整套流程按顺序走一遍的引导。顺序固定，每一步先读系统状态，**只修改未达标项**；任何安全检查失败或你回答 `n`，都会立刻中止剩余步骤，不会跳过闸门（例外：第 7 步 Swap 创建失败只告警并继续）。

| 步骤 | 做什么 | 停点 |
|---|---|---|
| 1 | 显示环境信息；一开始询问是否换源 | 确认 Snapshot、安全组端口与密钥；若选择换源，Snapshot 确认后自行运行第三方脚本并确认未升级软件包 |
| 2 | `apt update` → 有事务才 `full-upgrade` → 补齐必要包 → 选装可选工具 → 启用自动安全更新 | 需要重启时询问，选重启即结束本次流程 |
| 3 | 检查当前时区与 NTP | 任一 `timedatectl` 有效时区均可；时区无效或 NTP 未 active 时停止，时区可从菜单 `3` 设置，NTP 仍由用户处理 |
| 4 | 创建/选择非 root 管理员、密码、sudo 免密、authorized_keys | 新终端必须用公钥认证登录并通过 `sudo -v`；root-only `AllowUsers` 时先手动放行新用户并验证 |
| 5 | 先配 UFW（放行目标端口 + 迁移期保留旧端口），再 SSH 加固 | 首次启用防火墙时先问要不要放行 80/443，再问还要放行哪些端口（可留空）；双闸门，闸门二拒绝时旧端口规则保留 |
| 6 | fail2ban（jail 端口必须等于 sshd 实际端口） | 服务未就绪即停止 |
| 7 | 未启用 swap 时按内存定档（≤2G 内存 → 2G，否则 4G）自动创建 `/swapfile` 并设 `vm.swappiness=10` | 一次确认；btrfs/ZFS、容器等无法创建的情况只说明原因并继续 |
| 8 | BBR 当前状态 + 外部来源说明 | 只读，不写任何 sysctl；自行按外部说明应用后可回车复查 |
| 9 | 复核自动更新、Docker 提示、终检并生成报告 | 最后提示去云平台创建最终 Snapshot |

第 2 步的包清单：必要项 `sudo ca-certificates curl wget gnupg ufw fail2ban unattended-upgrades vim nano unzip htop needrestart ncdu mtr-tiny bind9-dnsutils`；可选工具默认 `jq tmux lsof rsync zip`，回车取默认，输入 `none` 不装，也可以自己列。

关于第 2 步里几个不显眼的包：

- **needrestart**：补上"自动更新之后重启受影响服务"这一环。缺了它，libc 或 openssl 的补丁装了也不生效。脚本内部是非交互的，所以它只列清单。
- **ncdu / mtr-tiny / bind9-dnsutils**：磁盘、链路、DNS 三件套。
- tcpdump、strace、sysstat 这类有提权面或需要额外启用的诊断工具仍不预装，用到再说。

关于第 3 步：菜单 `3` 可把时区改为 `timedatectl list-timezones` 提供的任一时区，并备份 `/etc/localtime` 后复查。标准初始化接受任一有效当前时区，但仍要求 NTP active；它不会自动修改 NTP。

关于第 7 步：swap 没启用时不再让你进退子菜单，直接按上面的档位创建并设 `swappiness=10`，只确认一次。btrfs/ZFS 上的 swap 文件、容器（OpenVZ/LXC）里创建、`/swapfile` 已有同名文件但 fstab 没条目、空间不足——这些情况脚本说明原因后跳过并继续后面的步骤。要自己挑大小、换路径或删除 swap，仍走菜单 `7`。

关于第 8 步：脚本**不再内置也不再写入任何 TCP 调优参数集**，只显示当前拥塞控制与队列规则，并指向 <https://omnitt.com> 让你自己取参数。本项目不提供、不维护该站点的脚本，也未完成安全审计；从外部站点执行 root 代码前请自己检查脚本内容。需要匹配自己机器的参数就去那边拿，应用完回到这一步回车即可复查。

## 各功能菜单

### `1` 换源（第三方脚本说明）

只显示 LinuxMirrors 来源、风险提示和手动命令；**本项目不下载或执行第三方脚本，也未完成当前在线版本的全量安全审计**。以 root 运行前先自行检查；标准初始化中选择换源时，必须先确认 Snapshot，再在另一个 root 终端运行，并在第三方脚本里跳过软件包升级。

### `2` 系统更新与基础工具

- 刷新索引并升级系统：先 `apt-get -s full-upgrade` 判断有没有待处理事务，没有就只提示"已是最新"。
- 补齐必要包：按 dpkg 当前状态只装缺的那些。
- 选择并安装可选工具：同样只装缺的。
- 启用自动安全更新：写 `/etc/apt/apt.conf.d/20auto-upgrades` 两行 `"1"` 并拉起 `apt-daily` 定时器；已经是这个内容就跳过。

### `3` 时区

显示当前时区与 NTP 状态。修改时使用 `timedatectl list-timezones` 中的完整名称；确认后备份 `/etc/localtime`，执行 `timedatectl set-timezone` 并复查。设置失败时不会自动回滚；原时区备份保存在 `/root/vps-init-backups/`。NTP 不在此菜单修改。

### `4` 用户、密码、sudo 和密钥

管理员账号优先取 sshd 有效 `AllowUsers` 中唯一且存在的**非 root** 用户；root（UID 0）不能作为管理员。没有唯一的非 root 结果时，列出系统现有可登录用户让你选。

这里只接受**已存在**的账号：输入一个不存在的用户名会被拒绝，不会把它当成管理员——否则后面的每一动作都会对着幽灵账号执行（`chpasswd` 直接报 PAM `Authentication token manipulation error`）。要新建账号，用本菜单 `1`，它会先 `adduser` 再确认账号真的建出来了。没指定账号时页面显示"未指定"，除了 `1` 以外的动作都会被拒绝。这个选择**只保存在本次运行的内存里**，不落盘。

- **设置/修改登录密码**：可以转发 `passwd` 自己输，也可以生成 22 位随机密码（只在屏幕上显示一次，不存任何文件）。两条路径都会在写完后再查一次 `passwd -S`，确认状态变成 `P`；`chpasswd`/`passwd` 失败时会把工具自己的报错（PAM 拒收原因）原样打出来。
- **sudo 免密 开/关**：状态用 `sudo -l -U <用户>` 的有效权限判断。关闭时**只删除本项目管理的 `/etc/sudoers.d/<用户>`**，删完再查一次；如果别的 sudoers 规则仍然放行 NOPASSWD，会明确告诉你"仍然有效"，不会假称已关闭。查询失败显示"未知"并拒绝切换。
- **追加公钥**：逐行粘贴，空行结束；每行都过校验，非法行跳过。只追加你贴的行。
- **删除公钥**：按行号删除你选中的那一行，其余行原样保留。
- 两种公钥操作都走原子替换：先备份 `authorized_keys`，写临时文件 → 校验 → `mv` 落位，保留属主与 700/600 权限。

> **闸门**：保持当前 root 会话不关闭；新开终端，用 `ssh -o PreferredAuthentications=publickey -o PasswordAuthentication=no -p <当前端口> <用户名>@<host>` 强制验证密钥登录（端口为 22 时可省略 `-p`）。登录后运行 `sudo -v`，退出码为 0 才通过。密码提示属于 sudo，不是 SSH 密码回退。任一项不通过，标准初始化不会继续。

> 如果当前有效 `AllowUsers` 只允许 `root`，新用户无法先登录验证。流程会停止且不会改 SSH 配置；先用菜单 `4` 准备非 root 用户，再手动让现有规则允许该用户、验证密钥登录后重跑。

root 当前是仅密码、仅密钥（例如 `PermitRootLogin prohibit-password`）还是混合认证，都不作为流程前提；流程只依赖新非 root 管理员通过上述密钥与 sudo 验证，之后才关闭 root 登录与密码认证。

### `5` UFW 与 SSH

这是**唯一能把你锁在门外**的菜单，请认真读。

- **查看 UFW 状态与规则**：`ufw status verbose` + 带编号的规则列表（未启用时改为 `ufw show added`）。
- **添加放行规则**：选 tcp / udp / 两者，端口可逗号分隔写多个，还可以限制来源 IP。
- **删除规则（按编号）**：删到当前 SSH 端口那条时会先警告断连风险。ufw 未启用时拿不到编号，脚本会拒绝并提示你先启用。
- **启用 / 禁用防火墙**：禁用需要二次确认；启用前若 SSH 端口没放行会先补上（铁律一）。
- **修改默认策略**（入站 / 出站）。
- **应用 SSH 加固**：沿用当前生效端口，写 `/etc/ssh/sshd_config.d/01-hardening.conf` 并过双闸门。已经达标时直接提示"已满足"，不重写、不重启。
- **修改 SSH 端口并加固**：先确认 ufw 已放行新端口，再走同一套加固流程。
- **查看 sshd 生效值与加固文件**：`sshd -T` 的关键项 + 加固文件内容 + drop-in 覆盖检查。
- **从备份恢复 `01-hardening.conf`**：列表按时间从新到旧排，恢复前先把当前文件备份一遍；`sshd -t` 校验失败会自动回滚。如果备份里的端口变了，会先确认 ufw 已放行再问你要不要重启 sshd。

加固文件写的是：`Port` / `PermitRootLogin no` / `PasswordAuthentication no` / `PubkeyAuthentication yes` / `AllowUsers <管理员>` / `MaxAuthTries 3`。`01-` 前缀是为了抢在云镜像的 `50-cloud-init.conf` 之前拿到优先权——sshd 配置是**先出现者优先**。

写完之后依次做：`sshd -t` 语法校验 → `sshd -T` 验证实际生效值（防止 drop-in 被覆盖）→ 应用配置 → 确认新端口在监听。

> **仅 Ubuntu**：22.10+ 默认的 `ssh.socket` 套接字激活会让 `Port` 不生效——`sshd -T` 显示已经改了，实际还在听 22。脚本检测到这种情况会自动切回标准的 `ssh.service` 模式再重启。（Debian 默认就是 `ssh.service`，不涉及这个问题。）

> **两道闸门**：
> 1. 写配置之前先问你"验证过密钥登录吗"。答 n 就直接返回，什么都不改。
> 2. reload 之后：**保持本会话别断**，新开终端执行 `ssh -p <新端口> <用户名>@<host>`，验证密钥登录成功、root 被拒；同时去云平台改安全组。回来答 y，脚本才移除旧端口的临时放行；答 n 则保留旧端口规则并打印恢复指引。

### `6` fail2ban

- **应用 / 重新应用配置**：装 fail2ban（没装的话）→ 写 `/etc/fail2ban/jail.local` → 启用并重启 → 轮询等待 jail 就绪。
- **查看状态详情**：`jail.local` 内容 + `fail2ban-client status sshd` 的封禁列表 + 服务日志最后 20 行。
- **修改参数**：封禁时长 / 统计窗口 / 重试次数。默认值优先取 `jail.local` 里的现值，键缺失时用 86400 / 600 / 3；新值只在本次交互里传递，确认后才写入。
- **封禁 / 解封 IP**：走 `fail2ban-client set sshd banip|unbanip`，只接受 IPv4。

**jail 端口必须与 sshd 实际端口一致。** 读不到 sshd 实际端口时脚本**拒绝写入**并打印原因——它不会拿一个编造的默认端口凑数。让 fail2ban 盯一个 sshd 根本没在监听的端口是静默失效，比拒绝写入更危险。

`jail.local` 里固定写 `backend = systemd`，兼容 Debian 12 没有 auth.log、以及 Ubuntu 24.04+ 的情况。

### `7` Swap

交互式管理 swap **文件**：查看现状 / 创建（写进 fstab 做持久化）/ 调整 swappiness / 删除。标准初始化里的自动创建只覆盖"按内存定档 + `swappiness=10`"这一条路径；要换大小、换路径、替换已有 swap 就进这个菜单。不碰 swap 分区，不支持 btrfs/ZFS 上的 swap 文件，容器里无法启用 swap（脚本会检测并解释）。

fstab 是这里唯一的高危写操作，所以每次修改前备份到 `/root/vps-init-backups/<时间戳>/fstab[.N]`，修改后用 `findmnt --verify` 校验；校验失败且修改前基线正常时自动从备份恢复。创建中途失败或 Ctrl+C 会删掉半成品文件。

### `8` BBR

**只读**：显示当前 `tcp_congestion_control` / `default_qdisc`，以及 `/etc/sysctl.d/99-bbr.conf` 是否存在（存在即说明是你自己按外部说明写的）。菜单里可以查看外部来源与风险说明，或查看当前 sysctl 值与那个文件的内容。

脚本不提供参数集、不写 sysctl，所以这里没有"应用"动作；`tcp_congestion_control` 不是 `bbr` 时终检会标黄，按外部说明自行处理后再回来复查。

### `9` 终检与报告

只读检查，逐项做绿 / 红 / 黄：

- **红灯**：`passwordauthentication` / `permitrootlogin` 不为 `no`；ufw 未启用或未放行当前 SSH 端口；fail2ban 未运行或 jail 端口与 sshd 实际端口不一致；`20auto-upgrades` 未启用；needrestart 未安装。
- **黄灯**：swap 未启用、BBR 未启用、NTP 未激活、根分区 ≥90%、存在 `reboot-required`。

报告写到 `/root/vps-init-report.md`，包含当前系统状态、**完整 ufw 规则列表**和检查结果。有红灯时菜单里会明确标出，修完再跑一次。

> 一个刻意的边界：脚本**不保存也不推断历史旧端口**。所以终检不会声称"旧端口已关闭"，而是把规则全列出来让你核对。这是"状态只读系统原生来源"的代价，换来的是结论永远和机器一致。

## 状态存在哪里

**不存。** 本项目没有自己的配置文件。SSH 端口、管理员、公钥、ufw 规则、fail2ban 参数、swap、BBR 全部直接读系统原生来源；你输入的偏好（比如可选工具清单、jail 参数）只在本次运行里用一次。

服务所需的原生配置当然会照旧被创建或修改，它们是服务的持久状态，不是本项目的缓存：

| 路径 | 谁写 |
|---|---|
| `/etc/ssh/sshd_config.d/01-hardening.conf` | 菜单 5（SSH 加固） |
| `/etc/fail2ban/jail.local` | 菜单 6 |
| `/etc/apt/apt.conf.d/20auto-upgrades` | 菜单 2 |
| `/etc/sysctl.d/99-swappiness.conf`、`/etc/fstab` | 菜单 7 与标准初始化第 7 步 |
| `/etc/sudoers.d/<用户>` | 菜单 4 |
| `~/.ssh/authorized_keys` | 菜单 4 |
| `/root/vps-init-backups/<时间戳>/` | 所有写配置的动作（备份） |
| `/root/vps-init-report.md` | 菜单 9 |

> 老版本用过 `/root/.vps-init.conf`。新入口**不读、不写、不迁移、也不自动删除**它——留着不影响任何判断，想清掉自己 `rm` 即可。

## 出问题怎么办

先记住一条总规律：**所有写系统配置的动作都会先把原文件备份到 `/root/vps-init-backups/<时间戳>/`。** 脚本执行失败时会把这个路径打印出来。

这个目录不会无限增长：只保留最近 **20** 份时间戳目录，超出时自动删最旧的；内容与最新一份完全相同的备份不新建目录，只把它刷新为当前时间戳。清理逻辑只匹配 `YYYYmmdd-HHMMSS` 形式的目录名，你在里面手工放的其他文件和目录不会被碰到。

除这个目录外，脚本在目标机器上不产生任何中间文件：不写 `/tmp`，swap 半成品由退出钩子清理，`authorized_keys` 重写的临时文件在异常退出时也会被清掉。

- **SSH 疑似锁死**：用云平台控制台或 VNC 登录，从备份目录还原 `sshd_config.d` 下的相关文件，再 `systemctl reload ssh`。
- **以上都不行**：上机前那个 Snapshot 就是最终防线。这就是为什么它不可替代。
- **拉取 / 执行方式的坑**：
  - `sudo bash <(curl …)`：sudo 关闭了继承的文件描述符，报 `/dev/fd/63: No such file or directory`。
  - `curl … | bash`：脚本因为 stdin 不是终端，会拒绝执行。
  - 两种解法：**按本页的标准做法先 `sudo -i` 提权**；必须留在 sudo 环境里的话，用 `sudo bash -c 'bash <(curl -fsSL <URL>)'`。
  - 下载失败却无声无息？确认命令里是 `-sSL` 而不是 `-sL`——`-S` 才会打印错误。
- **网络原因拉不到脚本**：先在本地下载好，`scp` 传上去，再 `sudo bash 00-tui.sh` 执行，效果一样。

## 初始化之后：日常维护

防火墙已经跟着系统启动自动生效，重启不用管。要改规则，重跑 `00-tui.sh` 进菜单 `5`：`2` 放行、`3` 删规则、`4` 启用/禁用、`5` 默认策略、`1` 看状态。

习惯命令行也行：

```bash
ufw status numbered          # 查看规则（带编号）
ufw allow 8080/tcp           # 放行新业务端口
ufw delete allow 8080/tcp    # 删除；或按编号：ufw delete <编号>
ufw status                   # 改完确认
```

几条日常规律：

- **云平台安全组要和 ufw 同步改。** 两边不一致，是"服务到底通不通"排查里最常见的坑。
- **SSH 端口、sudo 策略、公钥**想改：菜单 `5` 改端口，菜单 `4` 管用户与公钥。
- **fail2ban** 改参数 / 看封禁 / 解封误封的 IP：菜单 `6`。
- **系统补丁**由 `unattended-upgrades` 自动打（security 源）；需要手动全量升级时，菜单 `2`。
- **定期创建 Snapshot**，大改动前后各一份。菜单 `9` 随时可以重跑，当体检用。
- **Docker 本轮不装。** 需要的时候自己装，推荐用 [linuxmirrors](https://linuxmirrors.cn) 维护的一键脚本：

  ```bash
  bash <(curl -fsSL https://linuxmirrors.cn/docker.sh)
  ```

  > ⚠️ 这个脚本会问"是否关闭防火墙"——**选否**（或者直接加 `--close-firewall false`）。否则前面辛苦配好的 ufw 就被它关掉了。`docker` 组权限等价于 root，这和"禁 root 登录"的目标是冲突的，知情即可。完整交互和参数见[手动教程](docs/tutorial.md#11-docker提示)。

## 附：Git 拉取到本地执行（可选）

正文的命令都是 raw 拉取单文件执行。如果你希望**整套脚本固定在一个版本**、执行前先读一遍、或者日常反复进维护菜单时不必每次重新下载，也可以把仓库拉到 VPS 上本地执行。行为与 raw 完全一致，这里只讲操作差异。

```bash
apt update && apt install -y git
git clone https://github.com/Pathto1804/myVPS.git /root/myVPS
sudo -i
cd /root/myVPS
bash 00-tui.sh
```

固定版本与更新：

```bash
cd /root/myVPS
git log --oneline -5            # 挑一个提交
git checkout <commit>           # 固定到该版本
git checkout main && git pull --ff-only   # 回到 main 并更新到最新
```

三点提醒：

- **本地副本不会自己更新。** 修复和新功能只在仓库里，用 `git pull --ff-only` 同步；拉之前先 `git status` 确认没有本地改动。
- **执行目录不影响行为。** 脚本自包含，不读取仓库里的其他文件；备份与报告仍写在 `/root` 下，与 raw 方式共用同一份。
- **国内拉不动仓库**：在本地机器 clone 后 `scp -r` 上传到 `/root/myVPS`，效果相同。

## 附录：给改脚本的人看

- 仓库只有**一个可执行脚本** `00-tui.sh`，它自包含：不 `source` 仓库里的任何文件，单独拉下来就能跑。
- 所有菜单动作都**幂等**、中文交互，危险操作前停下来等你确认；已经达标的原生配置不会被重写。
- 改完之后必须双绿 + 一致性自检：

  ```bash
  bash -n 00-tui.sh && shellcheck -S warning 00-tui.sh
  bash tools/sync_check.sh     # 必须输出「一致性 OK」
  ```

- `tools/sync_check.sh` 现在检查四件事：入口存在且旧步骤脚本不得复活、`shopt -s inherit_errexit` 关键行存在、包清单与 README/手动教程逐项一致、脚本里不得再引用 `/root/.vps-init.conf`。
- 改菜单编号、前置自检、闸门或状态来源时，必须同批更新 `README.md`、`docs/codewiki/features.md` 与 `docs/tutorial.md`。
- 维护者知识库见 [docs/codewiki/](docs/codewiki/README.md)：业务边界、架构机制、功能清单、开发流程、术语（术语措辞以此为准）。为什么收敛成单入口 TUI、状态为什么不再落盘，见 [ADR-0003](docs/adr/0003-single-tui-native-state.md)；[ADR-0001](docs/adr/0001-no-orchestrator.md) 与 [ADR-0002](docs/adr/0002-script-consolidation.md) 已被它取代。

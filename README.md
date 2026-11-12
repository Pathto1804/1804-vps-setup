# myVPS：给一台 Debian VPS 做安全初始化

假设你刚刚买了一台 VPS，用 SSH 连上去，面对着 root 提示符，不知道从哪儿下手。这本小册子就是为这个时刻写的。

我们要做的事可以一句话概括：**把一台出厂状态、随时可能被扫描器敲门的机器，改造成一台只认你的密钥、该关的门都关着、补丁会自己打上的机器。** 整个过程分成十几个小步骤，每一步配一个脚本。脚本从 GitHub 直接拉下来就能跑，不装任何东西，也不用先 `git clone`（想整套固定版本，见文末[可选方案](#附git-拉取到本地执行可选)）。

本页是唯一操作手册：步骤顺序、命令、检查点全在这里。如果你更想弄清楚每条命令在干什么，可以对照[手动教程](docs/tutorial.md)逐条敲一遍——那份教程的步骤编号与本页一一对应。

> **免责声明**：本项目是**个人自用**的 VPS 基础配置脚本集，**不具有通用性**。脚本里的参数和取舍都基于作者本人的需求，由 AI 协助生成，没有经过广泛验证。作者不对任何内容作担保。动手之前，请**自己把脚本读一遍**，尤其是涉及防火墙和 SSH 的那部分。据此操作的风险由使用者自负。

## 先把三条铁律刻在脑子里

后面所有步骤都是围着这三条规矩转的。它们不是建议，是防锁死的底线：

1. **UFW 先于 sshd**：改 SSH 端口之前，新端口必须已经在 ufw 里放行，并且 `ufw status` 能看见它。
2. **密钥先于禁密码**：写下 `PasswordAuthentication no` 之前，你必须已经用密钥成功登录过新用户。
3. **旧会话不关**：改完 sshd 配置，当前这个窗口别关。新开一个终端，确认新端口加密钥能登录，才允许关掉旧的。

脚本会用"前置自检"和"闸门"挡住大多数顺序错误——比方说 ufw 还没放行就去做 SSH 加固，脚本会直接拒绝执行。但整体顺序终究是你自己掌握的。人，才是这套东西的调度者。

## 步骤 0：上机之前，先在云平台上做几件事

这一步没有脚本，全靠你手动看和记。但它决定了后面出问题时你有没有退路，所以别跳。

先确认你手里这台机器是什么：

```bash
cat /etc/os-release        # 发行版和版本号
nproc                      # 几个核
free -h                    # 内存多大
df -h                      # 磁盘多大
```

系统要求是这样的：**Debian 12 / 13 是一等支持**，真机验收基线是 Debian 12 bookworm；Debian 11 和 Ubuntu 20.04+ 理论上可用，但没有逐版本验证过。两者都依赖 `sshd_config.d` 目录，而且 01-base 要装的 `bind9-dnsutils` 从 Debian 11 / Ubuntu 20.04 起才有——更老的系统会在第 1–2 步卡在装包上。

接着记下当前的 SSH 端口：

```bash
sshd -T | grep ^port
```

有些云厂商很调皮，把 sshd 预置在一个随机端口上，而不是 22。脚本后面能自动识别，但你自己得知道它是什么，并且确认云平台的**安全组**放行的正是这个端口——等第 5–6 步改了端口，安全组也要跟着改。

然后到云平台控制台上做三件事：

- 记下安全组当前放行的规则。
- **创建一个初始 Snapshot**。整个流程里唯一不可替代的一步，就是它。万一你把 SSH 锁死了，这是最后一道闸门。
- 如果 SSH 密钥还没生成，在本地机器上生成一对：`ssh-keygen -t ed25519`。

云镜像一般自带 `curl`；万一没有，`apt install -y curl`。

### 国内服务器：先换源再上路

官方源在国内访问很慢。如果你的机器在国内，在步骤 1 之前先换国内镜像源；海外服务器跳过这一节。

```bash
bash <(curl -fsSL https://linuxmirrors.cn/main.sh)
```

按提示选镜像站和协议就行，脚本改源文件之前会自动备份。不想一条条点，可以直接指定：

```bash
bash <(curl -fsSL https://linuxmirrors.cn/main.sh) --source mirrors.aliyun.com --protocol https
```

详细交互和参数见[手动教程](docs/tutorial.md#0-云平台基础检查)。

### 顺便测一下机器真实性能（可选）

趁系统还干净，跑一下 [bench.sh](https://bench.sh)，看看商家标称的带宽和磁盘读写有没有虚标：

```bash
bash <(curl -Lso- bench.sh)
```

输出包括系统信息、网络测速、磁盘读写。跑完心里有数，后面步骤也不会影响它。

## 这些脚本是怎么跑的

先说清楚执行方式，这里踩坑的人最多。

**先提权，在 root 会话里跑。** 所有脚本自带 root 检查和 TTY 检查：

```bash
sudo -i
```

然后下面的命令直接在 root 会话里执行。

- **不要**用普通用户身份 `sudo bash <(curl …)`。sudo 会关掉额外文件描述符，你会得到一个莫名其妙的 `/dev/fd/63: No such file or directory`。
- 已经在 root 会话里了，就**别**再套一层 `sudo`。
- curl 统一带 `-S`，这样下载失败会明确报错，而不是无声无息地断掉。

**想固定版本？** 把命令里的 `main` 换成发布 tag。**跑到一半 SSH 断了？** 重连后从对应步骤接着跑就行，脚本是幂等的，已完成的部分会自动跳过。

**想整套固定版本、保留本地副本审阅？** 见文末[附：Git 拉取到本地执行](#附git-拉取到本地执行可选)。

### 国内拉不动 GitHub 怎么办

如果你看到命令卡住、`Connection reset`，或者速度只有几十 KB/s，那是网络问题，不是脚本问题。下面每条命令都附了一行**加速版**，就是在原始 URL 前面加一层第三方加速前缀，默认用 `ghproxy.net`。

可用的前缀不止一个。哪个挂了、或者返回的是旧版，就换下一个（2026-09-26 逐个实测，返回的都是脚本原文）：

```text
https://ghproxy.net/
https://ghfast.top/
https://gh-proxy.com/
https://gh.llkk.cc/
https://gh.ddlc.top/
```

也可以整段换成 jsDelivr CDN：把 `https://raw.githubusercontent.com/Pathto1804/myVPS/main/` 换成 `https://cdn.jsdelivr.net/gh/Pathto1804/myVPS@main/`。按分支取有大约 12 小时缓存，要准就用 tag。

两点提醒：

- **加速站是第三方。** 脚本内容要经过它中转，在意的话就本机 `curl` 下载 → `scp` 上传 → `sudo bash 文件名`。
- **缓存滞后哪家都有。** 刚推送的改动可能要几分钟才在代理上生效，重要的脚本拉下来先 `bash -n` 看一眼，或者直接读一遍。

按开头免责声明的要求：不管走哪条路，执行前先读一遍。

## 步骤 1–2：系统准备（更新 + 基础工具）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Pathto1804/myVPS/main/01-base.sh)
# 国内拉不动 → 加速版：
bash <(curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/Pathto1804/myVPS/main/01-base.sh)
```

这个脚本一次把两件事做完：先把系统补到最新，再装上日常要用的工具。顺序是"升级 → 装工具 → 最后才问重启"，这样只需重启一次。

它具体做了什么：

- `apt update` + `apt full-upgrade`，把系统补到最新。
- 装必要项和常用工具：`sudo ca-certificates curl wget gnupg ufw fail2ban unattended-upgrades vim nano unzip htop needrestart ncdu mtr-tiny bind9-dnsutils`
- 随后再问一句"还要装什么"，默认 `jq tmux lsof rsync zip`，不需要就留空。
- 写入并启用安全补丁自动安装（`20auto-upgrades` 两行都写成 `"1"`；第 10 步只是复核）。
- **needrestart**：补上"自动更新之后重启受影响服务"这一环。缺了它，libc 或 openssl 的补丁装了也不生效。装上之后，在有终端的 apt 里（包括第 10 步的 docker 一键脚本）会多问一句要重启哪些服务：答 `i` 立即重启，答 `l` 只看清单。脚本内部是非交互的，所以它只列清单。
- **ncdu / mtr-tiny / bind9-dnsutils**：磁盘、链路、DNS 三件套。
- tcpdump、strace、sysstat 这类有提权面或需要额外启用的诊断工具仍不预装，用到再说。
- **最后才问重启**：需要重启（通常是内核更新）时选 y 自动重启，重连后从第 3 步继续。

## 步骤 3：系统基础配置（手动）

这一步没有脚本，就三条命令：

```bash
hostnamectl set-hostname <主机名>      # 可选，保持厂商默认可跳过
timedatectl set-timezone Asia/Shanghai
timedatectl                            # 确认 NTP service 是 active
```

设主机名、设时区，然后确认系统时间同步在跑。时间不准会带来两个麻烦：fail2ban 的封禁窗口算错，证书校验出问题。都是那种"看起来一切正常，其实默默坏了"的故障。

## 步骤 4：创建管理员用户 + 公钥

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Pathto1804/myVPS/main/04-user.sh)
# 国内拉不动 → 加速版：
bash <(curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/Pathto1804/myVPS/main/04-user.sh)
```

这是个**菜单式**脚本。你先选目标用户——新建一个，或者管理已有的；conf 会记住你上次操作的用户——然后进入主菜单。菜单一次只做一件事，按 `0` 或直接回车退出；子菜单里按 `0` 返回上一层。

三个菜单项：

- **1 设置/修改登录密码**：可以选**随机生成**（只在屏幕上显示一次，请立刻保存；脚本不把它存进 conf），也可以直接转发 `passwd` 的原生交互，自己输入。
- **2 sudo 免密切换**：确认一次之后，脚本自动处理 sudoers 文件的写入或删除，最后用 `visudo -c` 校验兜底。
- **3 管理公钥**（追加/删除）：每改一笔就立刻重写 `~/.ssh/authorized_keys`，权限 700/600、属主正确，同时存进 conf 供后续复用。

用户没有密码时，状态行会标一个 `⚠`；退出前脚本还会再提醒你一次——没密码的话，sudo 的密码模式根本没法验证。

> **闸门一**：新开一个终端，用 `ssh <用户名>@<host>` 验证密钥登录成功，再 `sudo -v` 通过。**这一步不通过，就不许往下做第 5–6 步及之后的步骤。** 这不是脚本在刁难你，是铁律二在生效。

## 步骤 5–6：防火墙 + SSH 加固

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Pathto1804/myVPS/main/05-ufw-ssh.sh)
# 国内拉不动 → 加速版：
bash <(curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/Pathto1804/myVPS/main/05-ufw-ssh.sh)
```

这是整个流程里**唯一能把你锁在门外**的脚本，请认真读这一节。

它同样是**菜单式**的：首次运行只做一屏状态检测、给出建议，**不会自动执行任何写操作**——防火墙初始化和 SSH 加固都由你从菜单选。一次只做一件事，按 `0` 或直接回车退出。如果 ufw 还没启用，脚本不会硬闯 sshd 加固——那是铁律一（UFW 先于 sshd）在拦着，它只会提示你先用菜单 `1`。

### 防火墙初始化（菜单 `1`）

- ufw 默认拒绝入站、允许出站。
- 放行新 SSH 端口。首次询问时**直接回车就用随机端口**，也可以自己输入。
- **迁移期临时放行当前 SSH 端口**：脚本自动从 sshd 读出当前端口，22 或厂商随机端口都行。因为第 5–6 步没走完之前，旧端口还得用。如果 sshd 已经在新端口上了，就不建这条规则。
- 按需放行业务端口。
- **启用前自检**：新端口必须已在放行列表里；没放行就拒绝启用。这是防锁死的关键一环。注意 ufw 未启用时 `ufw status` 不列规则，所以这个自检读的是 `ufw show added`。

### SSH 加固（菜单 `2`，两步闸门）

- 写 `/etc/ssh/sshd_config.d/01-hardening.conf`：改端口（conf 里已有就沿用，菜单 `1` 已经存过了，不用再输）、禁 root 登录、禁密码认证（只留密钥）、用 `AllowUsers` 限定管理员、`MaxAuthTries 3`。
- `01-` 前缀是为了抢在云镜像的 `50-cloud-init.conf` 之前拿到优先权——sshd 配置是**先出现者优先**。
- 前置自检会核对 ufw：新端口没放行就拒绝执行；迁移期间还要求**旧端口也保持放行**，在闸门二确认之前不能自断退路。
- 写完之后依次做：`sshd -t` 语法校验 → `sshd -T` 验证实际生效值（防止 drop-in 被覆盖）→ 应用配置 → 确认新端口在监听。
- **仅 Ubuntu**：22.10+ 默认的 `ssh.socket` 套接字激活会让 `Port` 不生效——`sshd -T` 显示已经改了，实际还在听 22。脚本检测到这种情况会自动切回标准的 `ssh.service` 模式再重启。（Debian 默认就是 `ssh.service`，不涉及这个问题。）
- 如果已经跑在目标端口上，脚本按"无迁移"处理，不再去动旧端口规则。

> **闸门二**（脚本会两次停下来确认）：
> 1. 写配置之前先问你"04 之后验证过密钥登录吗"。答 n 就直接退出，什么都不改。
> 2. reload 之后：**保持本会话别断**，新开终端执行 `ssh -p <新端口> <用户名>@<host>`，验证密钥登录成功、root 被拒；同时去云平台改安全组（关旧端口、开新端口）。回来答 y，脚本才移除旧端口的临时放行；答 n 则保留旧端口规则并打印恢复指引。

### 维护菜单

`0` 退出，其他九项各管一件事：

- `1` 防火墙初始化 / 重新应用：默认拒绝入站 + 放行 SSH 与业务端口。
- `2` SSH 加固 / 重新应用：写 `01-hardening.conf`，同样要过双闸门。
- `3` 状态总览：ufw 规则 + sshd 生效值 + 加固文件 + drop-in 覆盖检查。
- `4` 放行端口：选 tcp/udp/两者，端口可以用逗号分隔写多个，还可以限制来源 IP。
- `5` 按编号删规则：删到 SSH 端口那条时，会先警告断连风险。ufw 未启用时拿不到编号，脚本会提示你先启用，或者用 `ufw delete allow <规则>`。
- `6` 启用 / 禁用防火墙：禁用需要二次确认。
- `7` 改默认策略（入站 / 出站）。
- `8` 改 `ALLOWED_PORTS` 清单：**按清单增删规则**，清单里没有的端口规则自动删掉，新增的自动放行。
- `9` 改参数（SSH 端口 / 管理员用户）：写进 conf。改端口时会提示你先在菜单 `1` 放行新端口。
- `10` 从 `/root/vps-init-backups/` 挑一份 `01-hardening.conf` 恢复：列表按时间从新到旧排，恢复前先把当前文件备份一遍；语法校验失败会自动回滚。如果备份里的端口变了，脚本会先确认 ufw 已放行，再问你要不要重启 sshd。

日常维护时重跑这个脚本进菜单就行，不必再去记 ufw 和 sshd 的子命令。但请记住 ADR-0002 的结论：这个文件是仓库里唯一能锁死登录的东西，改它必须走真机全链路验收。

## 步骤 7：fail2ban

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Pathto1804/myVPS/main/07-fail2ban.sh)
# 国内拉不动 → 加速版：
bash <(curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/Pathto1804/myVPS/main/07-fail2ban.sh)
```

**菜单式**脚本：首次运行只提示"尚未按本脚本策略配置"，**不会自动安装**——安装与写配置由你从菜单 `1` 发起。之后进入维护菜单，一次只做一件事，按 `0` 或直接回车退出。

### 应用配置（菜单 `1`）

- 写 `/etc/fail2ban/jail.local`：sshd jail 监听**新端口**（不写这一条的话，fail2ban 默认盯着 22，形同虚设），`backend = systemd`（兼容 Debian 12 没有 auth.log、以及 Ubuntu 24.04+ 的情况）。
- 默认是激进档：封 24 小时 / 统计窗口 10 分钟 / 3 次触发。首次运行会逐项询问，回车取默认值。
- 写文件前自动备份到 `/root/vps-init-backups/`。
- **jail 端口必须与 sshd 实际端口一致。** 不一致，或者读不到 sshd 实际端口（`sshd -T` 失败）时，脚本**拒绝写入**并打印原因。它不会拿一个编造的默认端口凑数——宁可 fail closed，也不让 fail2ban 去盯一个 sshd 根本没在监听的端口，那是静默失效。
- 重启之后轮询等待 jail 就绪。fail2ban 读配置、起 backend 需要 1～2 秒，立刻去查会误报 `Jail 'sshd' does not exist`；10 秒还没就绪就报错退出。
- 退出前核对两件事：jail 在跑，且 jail 端口等于 sshd 实际端口。都满足才打印"第 7 步完成"；否则打印"第 7 步未完成"并以非零状态退出（`12-verify.sh` 在同样状态下也会报红）。

### 菜单项

- `2` 只读详情：`jail.local` 的内容 + `fail2ban-client status sshd` 的封禁列表 + 服务日志最后 20 行。
- `3` 改封禁时长 / 统计窗口 / 重试次数：写进 conf，末尾问一句要不要立即应用到 `jail.local`。
- `4` 手动封禁 / 解封 IP：走 `fail2ban-client set sshd banip|unbanip`，只接受 IPv4。

表头四行是实时状态：服务是否 active、jail 是否运行中以及当前封禁数、`jail.local` 里的生效参数（与 conf 不一致时会标注"按 1 应用"）、jail 端口与 sshd 实际端口是否一致（读不到时明确显示"未知"，而不是武断地说不一致）。

## 步骤 8：Swap

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Pathto1804/myVPS/main/08-swap.sh)
# 国内拉不动 → 加速版：
bash <(curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/Pathto1804/myVPS/main/08-swap.sh)
```

交互式管理 swap 文件：查看现状 / 创建（写进 fstab 做持久化）/ 调整 swappiness / 删除。自带 fstab 备份和回滚。做完用 `free -h` 和 `swapon --show` 确认一下。

这个脚本保留了它自己的一套 helper 和 `set -uo pipefail`（不开 `-e`），不并入公共块，风格上与本仓库其余脚本略有不同——那是历史原因，功能上没有区别。

## 步骤 9：BBR + TCP 调优

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Pathto1804/myVPS/main/09-bbr.sh)
# 国内拉不动 → 加速版：
bash <(curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/Pathto1804/myVPS/main/09-bbr.sh)
```

写 `/etc/sysctl.d/99-bbr.conf`：打开 BBR 拥塞控制、配 fq 队列，附一组 TCP 缓冲和连接参数。`sysctl -p` 应用之后验证 `tcp_congestion_control = bbr`。个别键如果已经被新内核移除（比如 `tcp_fack`），脚本只警告，不中断。

> 注意：仓库里的 `09-bbr.sh` 参数是根据作者自己的 VPS（线路、内存、用途）特调的，**不一定适合你的机器**。想要匹配自己 VPS 的脚本，可以去 <https://omnitt.com> 拿。但从外部站点拉脚本执行之前，请**自己检查脚本内容的安全性**。

## 步骤 10：自动安全更新（只复核，不用装）

VPS 不常登录，所以自动打安全补丁是一份很廉价的保险。检查一下：

```bash
cat /etc/apt/apt.conf.d/20auto-upgrades   # 两行都应该是 "1"
```

要点在于**装包不等于启用**：`unattended-upgrades` 装完之后，那个文件默认是两行 `"0"`，等于关闭。`01-base.sh` 已经自动写入并启用了它，所以这里只是复核。如果看到 `"0"`，说明 `01-base.sh` 没跑到，或者被你覆盖过，重跑一次就行。

## 步骤 11：Docker（仅提示，不自动安装）

本轮初始化不装 Docker。需要的时候自己装——推荐用 [linuxmirrors](https://linuxmirrors.cn) 维护的一键脚本，它会把 Docker Engine 装上并配好镜像加速，国内服务器尤其合适：

```bash
bash <(curl -fsSL https://linuxmirrors.cn/docker.sh)
```

> ⚠️ 这个脚本会问"是否关闭防火墙"——**选否**（或者直接加 `--close-firewall false`）。否则我们前面辛苦配好的 ufw 就被它关掉了。

- 不想交互的话，用 `--source mirrors.aliyun.com --source-registry docker.1ms.run --install-latest true --close-firewall false` 全自动跳过选择；或者按官方仓库的安装指引来（docs.docker.com，注意核对最新写法）。
- `docker` 组权限等价于 root，这和"禁 root 登录"的目标是冲突的，知情即可。
- 装完用 `docker run --rm hello-world` 验证一下。
- 完整交互和参数见[手动教程](docs/tutorial.md#11-docker提示)。

## 步骤 12–13：终检 + 归档

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Pathto1804/myVPS/main/12-verify.sh)
# 国内拉不动 → 加速版：
bash <(curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/Pathto1804/myVPS/main/12-verify.sh)
```

这个脚本只读不写，逐项做绿/红检查：

- **红灯项**：sshd 实际生效值（端口 / 禁密码 / 禁 root）、ufw 规则（包括旧端口已关闭）、fail2ban jail（jail 没在跑，或者 `jail.local` 的 `port` 与 sshd 实际端口不一致，都判红；口径与 07 的 fail-closed 一致）、自动更新与 needrestart（升级后要重启受影响服务，缺它则库补丁不生效）。
- **黄灯提示**：swap / BBR / NTP / 磁盘 / 重启标记。

报告和配置摘要（端口 / 用户 / 放行端口 / fail2ban 参数）会写入 `/root/vps-init-report.md`，可以当归档记录用。有红灯时退出码为 1，修完重跑。

全绿之后的收尾：核对报告 → 到云平台创建最终 Snapshot。

## 参数只输一次：conf 文件

SSH 端口、用户名、公钥这些参数，脚本问过一遍就不用你反复输入了。它们会被存进 `/root/.vps-init.conf`：600 权限，只在 VPS 本地，永远不进仓库；后面的脚本自动读取。

这个文件删了也没关系，重跑脚本会重新问你。

> **输入中断**：在提示处按 `Ctrl-D`（输入流结束），脚本会立刻以退出码 1 退出，**不会**把空值写进 conf。这不是多余的小心——空值会污染后续所有脚本的读取，所以这里刻意 fail fast，而不是拿一个空串继续。

conf 的全部键，供维护时对照：

| 键 | 写入脚本 | 含义 / 默认 |
|---|---|---|
| `SSH_PORT` | 05 | 新 SSH 端口（1024–65535，避开 22/2222） |
| `OLD_SSH_PORT` | 05 | 迁移前的旧端口（自动从 sshd 读取，兼容厂商随机端口；不假设是 22；写新配置前会再确认一次） |
| `ADMIN_USER` | 04 | 管理员用户名 |
| `SSH_PUBKEY_N` | 04 | 公钥，N=1,2,…，逐行存 |
| `ALLOWED_PORTS` | 05 | 额外放行端口，逗号分隔，默认问询后留空 |
| `TOOLS_EXTRA` | 01 | 额外工具包，默认 `jq tmux lsof rsync zip` |
| `SUDO_NOPASSWD` | 04 | sudo 免密开关，默认 no |
| `F2B_BANTIME` | 07 | 封禁时长（秒），默认 86400 |
| `F2B_FINDTIME` | 07 | 统计窗口（秒），默认 600 |
| `F2B_MAXRETRY` | 07 | 最大重试次数，默认 3 |

## 出问题怎么办

先记住一条总规律：**所有脚本在改系统配置之前，都会先把原文件备份到 `/root/vps-init-backups/<时间戳>/`。** 脚本执行失败时会把这个路径打印出来。

这个目录不会无限增长：只保留最近 **20** 份时间戳目录，超出时自动删最旧的；内容与最新一份完全相同的备份不新建目录，只把它刷新为当前时间戳。清理逻辑只匹配 `YYYYmmdd-HHMMSS` 形式的目录名，你在里面手工放的其他文件和目录不会被碰到。

除这个目录外，脚本在目标机器上不产生任何中间文件：不写 `/tmp`，swap 半成品由退出钩子清理，`authorized_keys` 重写的临时文件在异常退出时也会被清掉。

- **SSH 疑似锁死**：用云平台控制台或 VNC 登录，从备份目录还原 `sshd_config.d` 下的相关文件，再 `systemctl reload ssh`。
- **以上都不行**：步骤 0 那个 Snapshot 就是最终防线。这就是为什么它不可替代。
- **拉取 / 执行方式的坑**：
  - `sudo bash <(curl …)`：sudo 关闭了继承的文件描述符，报 `/dev/fd/63: No such file or directory`。
  - `curl … | bash`：脚本因为 `BASH_SOURCE` 未定义、加上 stdin 不是终端，会拒绝执行。
  - 两种解法：**按本页的标准做法先 `sudo -i` 提权**；必须留在 sudo 环境里的话，用 `sudo bash -c 'bash <(curl -fsSL <URL>)'`（FD 在 sudo 之后的那个 bash 内部创建，不会丢）。
  - 下载失败却无声无息？确认命令里是 `-sSL` 而不是 `-sL`——`-S` 才会打印错误。
- **网络原因拉不到脚本**：先在本地下载好，`scp` 传上去，再 `sudo bash 脚本名` 执行，效果一样。

## 初始化之后：日常维护

防火墙已经跟着系统启动自动生效，重启不用管。要改规则，重跑 `05-ufw-ssh.sh` 进菜单：`4` 放行、`5` 删规则、`6` 启用/禁用、`7` 默认策略、`8` 业务端口清单，`3` 看状态总览。

习惯命令行也行：

```bash
ufw status numbered          # 查看规则（带编号）
ufw allow 8080/tcp           # 放行新业务端口
ufw delete allow 8080/tcp    # 删除；或按编号：ufw delete <编号>
ufw status                   # 改完确认
```

几条日常规律：

- **云平台安全组要和 ufw 同步改。** 两边不一致，是"服务到底通不通"排查里最常见的坑。
- **SSH 端口、sudo 策略、公钥**想改：重跑对应脚本（04 / 05），它会沿用 conf 里的现有参数，只改你选择要改的那项。
- **fail2ban** 改参数 / 看封禁 / 解封误封的 IP：重跑 `07-fail2ban.sh` 进菜单（`3` 改参数、`2` 看详情与封禁列表、`4` 封禁或解封）。
- **系统补丁**由 `01-base.sh` 装上的 `unattended-upgrades` 自动打（security 源）；需要手动全量升级时，重跑 `01-base.sh`。
- **定期创建 Snapshot**，大改动前后各一份。`12-verify.sh` 随时可以重跑，当体检用。

## 附：Git 拉取到本地执行（可选）

正文所有命令都是 raw 拉取单文件执行。如果你希望**整套脚本固定在一个版本**、执行前先把它们读一遍、或者日常反复进维护菜单时不必每次重新下载，也可以把仓库拉到 VPS 上本地执行。步骤、顺序、闸门与正文完全一致，这里只讲操作差异。

先装 git（`01-base.sh` 默认不预装），拉到 `/root/myVPS`，然后照正文的顺序执行同样编号的脚本：

```bash
apt update && apt install -y git
git clone https://github.com/Pathto1804/myVPS.git /root/myVPS
sudo -i
cd /root/myVPS

bash 01-base.sh      # 步骤 1–2
bash 04-user.sh      # 步骤 4
bash 05-ufw-ssh.sh   # 步骤 5–6
bash 07-fail2ban.sh  # 步骤 7
bash 08-swap.sh      # 步骤 8
bash 09-bbr.sh       # 步骤 9
bash 12-verify.sh    # 步骤 12–13
```

步骤 0、3、10、11 仍是手动操作，照正文做。

固定版本与更新：

```bash
cd /root/myVPS
git log --oneline -5            # 挑一个提交
git checkout <commit>           # 固定到该版本
git checkout main && git pull --ff-only   # 回到 main 并更新到最新
```

三点提醒：

- **本地副本不会自己更新。** 修复和新功能只在仓库里，用 `git pull --ff-only` 同步；拉之前先 `git status` 确认没有本地改动。
- **执行目录不影响行为。** 脚本自包含，不读取仓库里的其他文件；conf（`/root/.vps-init.conf`）和备份（`/root/vps-init-backups/`）仍写在 `/root` 下，与 raw 方式共用同一份。
- **国内拉不动仓库**：在本地机器 clone 后 `scp -r` 上传到 `/root/myVPS`，效果相同。

## 附录：给改脚本的人看

- 每个脚本都是**自包含**的：公共函数内联在每个脚本里，不 `source` 仓库里的其他文件；单独拉下来就能跑。这也意味着改公共函数时，必须把所有用到它的脚本一起改。
- 每个脚本都**幂等**、中文交互，危险操作前停下来等你确认。
- 修改系统配置前先备份到 `/root/vps-init-backups/<时间戳>/`，失败不回滚。唯一的例外是 `05-ufw-ssh.sh` 菜单 `10`：它从备份恢复时会先校验 `sshd -t`，失败就退回恢复前的版本。
- 备份目录只保留最近 `BK_KEEP`（默认 20）份，超出删最旧；内容与最新一份相同的备份复用该目录并刷新时间戳。裁剪由 `bk_prune` 执行，只匹配 `YYYYmmdd-HHMMSS` 目录名。`08-swap.sh` 的 fstab 备份同样落在 `${BK_ROOT}/<时间戳>/fstab[.N]`，不再写 `/etc`。
- 公共函数在脚本之间必须保持一致。改完之后跑 `bash tools/sync_check.sh` 自查，输出「一致性 OK」才算过。公共块里的关键行（比如 `shopt -s inherit_errexit`）也在这个工具的检查范围内——它不属于任何函数体，漏加不会被函数比对拦住。
- 维护者知识库见 [docs/codewiki/](docs/codewiki/README.md)：业务边界、架构机制、逐脚本功能、开发流程、术语（术语措辞以此为准）。为什么没有总控脚本，见 [ADR-0001](docs/adr/0001-no-orchestrator.md)；哪些步骤被合并、步骤号前缀怎么算，见 [ADR-0002](docs/adr/0002-script-consolidation.md)。

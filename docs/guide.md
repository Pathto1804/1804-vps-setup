# 1804 VPS Setup: 详细使用说明

本页是完整的操作参考。只想把脚本跑起来，请先看 [README](../README.md)。想逐条手动执行命令，请看[手动教程](tutorial.md)。

## 1. 使用前准备

### 支持范围

- Debian 12、13：一等支持，真机验收基线是 Debian 12 bookworm。
- Debian 11、Ubuntu 20.04 及以上：理论兼容，未逐版本验证。
- 更老的系统可能没有 `bind9-dnsutils`，会在基础包安装阶段失败。
- 脚本必须在 root 交互终端中运行，不支持 cloud-init、user-data 或其他无人值守执行。

先在 VPS 上确认环境：

```bash
cat /etc/os-release
nproc
free -h
df -h
sshd -T | grep '^port'
```

`sshd -T` 显示的端口可能不是 22，云厂商经常会预置随机 SSH 端口。云平台安全组必须放行这个实际端口。

### Snapshot、安全组和密钥

运行脚本前完成三件事：

1. 在云平台创建初始 Snapshot。
2. 记录安全组当前放行的 SSH 端口。
3. 在本地准备好 SSH 密钥，例如 `ssh-keygen -t ed25519`。

SSH 加固期间不要关闭当前 root 会话。新端口和新用户验证完成后，再关闭旧会话。

### 国内服务器换源

主菜单 `1` 只展示 LinuxMirrors 的来源、风险和命令，不会下载或执行第三方脚本。标准初始化开始时可以选择换源，确认 Snapshot 后，在另一个 root 终端手动运行：

```bash
bash <(curl -fsSL https://linuxmirrors.cn/main.sh)
```

如果随后继续标准初始化，在第三方脚本中跳过软件包升级，避免重复处理。执行任何第三方 root 脚本前，先自行审阅内容并接受风险。

### 可选性能检查

可以在系统初始化前运行 [bench.sh](https://bench.sh)，查看带宽、磁盘读写和系统信息：

```bash
bash <(curl -Lso- bench.sh)
```

## 2. 运行脚本

推荐使用 raw 入口：

```bash
sudo -i
bash <(curl -fsSL https://raw.githubusercontent.com/Pathto1804/1804-vps-setup/main/00-tui.sh)
```

国内拉取失败时，可以使用代理：

```bash
bash <(curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/Pathto1804/1804-vps-setup/main/00-tui.sh)
```

可替换的代理前缀包括：

```text
https://ghproxy.net/
https://ghfast.top/
https://gh-proxy.com/
https://gh.llkk.cc/
https://gh.ddlc.top/
```

也可以使用 jsDelivr：

```text
https://cdn.jsdelivr.net/gh/Pathto1804/1804-vps-setup@main/00-tui.sh
```

raw 入口启动时只检查运行环境、读取系统状态并绘制菜单，不安装软件、不初始化系统、不写项目私有配置。按 `q` 退出即可。

不要使用普通用户执行 `sudo bash <(curl ...)`。sudo 可能关闭进程替换所需的文件描述符，出现 `/dev/fd/63: No such file or directory`。已经在 root 会话中时，也不要再套一层 sudo。

### 拉取失败时

- 下载失败却没有错误信息时，确认 curl 使用 `-fsSL`，其中 `-S` 会显示错误。
- 如果 VPS 无法访问 GitHub，可以先在本地下载 `00-tui.sh`，再用 `scp` 上传后执行 `sudo bash 00-tui.sh`。
- 代理站和 CDN 都可能缓存旧版本。需要固定版本时，使用 Git tag 或本地副本。

### 本地副本执行

需要固定版本、反复维护或执行前审阅代码时，可以在 VPS 上拉取仓库：

```bash
apt update && apt install -y git
git clone https://github.com/Pathto1804/1804-vps-setup.git /root/1804-vps-setup
sudo -i
cd /root/1804-vps-setup
bash 00-tui.sh
```

固定版本或更新：

```bash
cd /root/1804-vps-setup
git log --oneline -5
git checkout <commit>
git checkout main && git pull --ff-only
```

本地副本不会自动更新。执行目录不影响脚本行为，备份和报告仍写入目标系统的 `/root` 及 `/etc` 路径。

## 3. 三条安全规则

1. **UFW 先于 sshd**：目标 SSH 端口必须先出现在 UFW 规则中，再启用防火墙或修改 sshd。
2. **密钥先于禁密码**：新用户必须先完成公钥登录和 `sudo -v` 验证，再关闭密码认证。
3. **旧会话不关闭**：新端口验证成功、云平台安全组修改完成后，才删除旧端口规则并关闭旧会话。

脚本会用前置检查和两道闸门拦截高风险顺序。最终仍要以云平台 Snapshot 和当前 root 会话作为恢复手段。

## 4. 主菜单

进入编号只打开状态页或子菜单，不会自动执行写操作。主菜单空回车会重新询问，子菜单 `0` 或空回车返回主菜单。

| 编号 | 功能 |
|---|---|
| `0` | 标准初始化，按顺序执行完整流程 |
| `1` | 换源说明，不执行第三方脚本 |
| `2` | 系统更新与基础工具 |
| `3` | 时区 |
| `4` | 用户、密码、sudo 和密钥 |
| `5` | UFW 与 SSH |
| `6` | fail2ban |
| `7` | Swap |
| `8` | BBR，只读检查 |
| `9` | 终检与报告 |
| `q` | 退出 |

菜单顶部的状态来自系统原生来源，每次重绘都会重新读取：

| 状态 | 来源 |
|---|---|
| SSH 端口 | `sshd -T` |
| UFW | `ufw status` |
| 管理员 | 有效 `AllowUsers` 与账号状态 |
| 公钥 | `authorized_keys` |
| fail2ban | 服务状态和 `fail2ban-client` |
| Swap | `free`、`swapon`、`/proc/swaps` |
| BBR | `sysctl` |
| 自动更新 | `20auto-upgrades` 和 apt 定时器 |

## 5. 标准初始化

主菜单 `0` 固定按以下顺序运行：

| 步骤 | 内容 | 停止条件 |
|---|---|---|
| 1 | 环境检查、Snapshot 和安全组确认，可选换源 | 未确认 Snapshot 或换源未完成 |
| 2 | apt 更新、系统升级、必要包、可选工具、自动更新 | apt 失败，或拒绝安装缺失必要包 |
| 3 | 时区和 NTP 检查 | 当前时区无效，或 NTP 仍未 active |
| 4 | 选择管理员、密码、sudo、公钥 | 未通过新终端密钥登录和 `sudo -v` |
| 5 | 配置 UFW，再加固 SSH | 任一 SSH 闸门拒绝 |
| 6 | 配置 fail2ban | jail 未就绪或端口不一致 |
| 7 | 按内存创建 Swap | Swap 创建失败只告警并继续 |
| 8 | 查看 BBR 和外部说明 | 只读，不写 TCP 参数 |
| 9 | 复核自动更新、终检并提示创建最终 Snapshot | 终检红灯时按报告修复 |

### 必要包

必要包为：

```text
sudo ca-certificates curl wget gnupg ufw fail2ban unattended-upgrades
vim nano unzip htop needrestart ncdu mtr-tiny bind9-dnsutils
```

发现缺失包时，脚本会先列出缺失清单并确认。回答否不会安装，标准初始化会停止后续步骤。可选工具默认是 `jq tmux lsof rsync zip`，回车采用默认值，输入 `none` 可跳过。

### 时区

菜单 `3` 提供固定选项：

1. `Asia/Shanghai（推荐）`
2. `UTC`
3. `Asia/Tokyo`
4. `Asia/Singapore`
5. `Europe/London`
6. `America/New_York`

选择后会备份 `/etc/localtime`，执行 `timedatectl set-timezone` 并重新读取校验。标准初始化只检查当前时区是否为系统有效值，不自动修改 NTP。

### 管理员用户

进入菜单 `4` 或标准初始化第 4 步时，脚本列出 UID 1000 至 59999、登录 shell 可用的普通用户，并按字典序排列：

```text
0) 创建新用户
1) alice
2) bob
3) charlie
```

选择 `0` 后再输入新用户名并确认创建。已有用户从 `1` 开始选择。root、系统账号以及 `nologin`、`false` shell 账号不会进入列表。

选择用户后，脚本可以设置密码、sudo 免密和 `authorized_keys`。禁用密码认证前，必须在新终端执行：

```bash
ssh -o PreferredAuthentications=publickey \
    -o PasswordAuthentication=no \
    -p <当前端口> <用户名>@<host>
sudo -v
```

如果有效 `AllowUsers` 只允许 root，新用户暂时无法登录验证。先手动放行新用户，验证密钥登录，再重跑标准初始化。

## 6. 各功能菜单

### 菜单 `1`：换源说明

只显示 LinuxMirrors 的来源、风险和手动命令，不下载、不执行。标准初始化中选择换源后，必须先确认 Snapshot，再在另一个 root 终端完成换源。

### 菜单 `2`：系统更新与基础工具

- `1`：刷新 apt 索引，有待处理事务时执行 `full-upgrade`。
- `2`：检查并确认安装缺失必要包。
- `3`：选择并安装可选工具，只安装缺少的包。
- `4`：写入 `20auto-upgrades` 并启用 apt 定时器。

`needrestart` 用于提示更新后需要重启的服务。`ncdu`、`mtr-tiny`、`bind9-dnsutils` 分别用于磁盘、链路和 DNS 检查。tcpdump、strace、sysstat 等诊断工具不预装。

### 菜单 `3`：时区

显示当前时区和 NTP 状态。修改只使用固定的常用时区选项，NTP 仍由用户自行处理。

### 菜单 `4`：用户、密码、sudo 和密钥

- `1`：重新选择或创建管理员用户。
- `2`：手动设置密码，或生成 22 位随机密码。
- `3`：开启或关闭 sudo 免密。
- `4`：追加公钥。
- `5`：按行删除公钥。
- `6`：查看 `authorized_keys`。

公钥修改会先备份，再使用临时文件校验并原子替换，保留目录和文件权限。

### 菜单 `5`：UFW 与 SSH

这是最容易导致 SSH 断连的菜单。可查看规则、添加或删除放行规则、启用或禁用 UFW、修改默认策略、加固 SSH、修改 SSH 端口，以及从备份恢复加固文件。

加固前必须确认：

1. 目标端口已经在 UFW 中放行。
2. 新用户已经用密钥登录并通过 `sudo -v`。
3. 当前 root 会话保持打开。

修改端口时，脚本会在迁移期保留旧端口。reload 或 restart 后，新终端必须验证新端口登录、root 被拒绝，并在云平台修改安全组。第二道闸门确认后才删除旧端口规则，拒绝时保留旧规则。

Ubuntu 22.10 及以上可能使用 `ssh.socket`。脚本会检测并切回标准 `ssh.service` 模式。Debian 默认使用 `ssh.service`。

### 菜单 `6`：fail2ban

- `1`：安装、写入或重新应用 jail 配置。
- `2`：查看 jail、封禁列表和日志。
- `3`：修改封禁时长、统计窗口和重试次数。
- `4`：封禁或解封 IPv4 地址。

jail 端口必须等于 `sshd -T` 的实际 SSH 端口。读不到端口或端口不一致时，脚本拒绝写入配置。

### 菜单 `7`：Swap

只管理 Swap 文件：查看、创建或替换、调整 `swappiness`、删除。标准初始化会在 Swap 未启用时按内存选择 2G 或 4G，并设置 `vm.swappiness=10`。

不支持 btrfs、ZFS 和无法启用 Swap 的容器环境。修改 fstab 前会备份，修改后用 `findmnt --verify` 校验，校验失败且原状态正常时自动恢复。

### 菜单 `8`：BBR

只读显示 `tcp_congestion_control`、`default_qdisc` 和外部配置文件状态。本项目不提供、不写入 TCP 调优参数集。需要应用外部参数时，先审阅来源，再自行执行。

### 菜单 `9`：终检与报告

终检检查 SSH 认证策略、UFW、fail2ban、自动更新、needrestart、Swap、BBR、NTP、磁盘空间和重启标记。报告写入：

```text
/root/vps-init-report.md
```

报告包含完整 UFW 规则，便于人工核对旧端口。脚本不保存也不推断历史旧端口。

## 7. 备份、恢复和故障处理

所有写配置动作都会在修改前备份到：

```text
/root/vps-init-backups/<时间戳>/
```

备份目录最多保留 20 份，内容相同的备份会复用时间戳目录。脚本不保存项目私有状态，不读写旧版本的 `/root/.vps-init.conf`。

如果 SSH 疑似锁死：

1. 通过云平台控制台或 VNC 登录。
2. 从备份目录恢复对应的 `sshd_config.d` 文件。
3. 执行 `systemctl reload ssh`。
4. 重新确认 UFW 和云平台安全组。

如果无法恢复，使用初始化前创建的 Snapshot。

## 8. 初始化后的日常维护

重跑 `00-tui.sh` 可以进入任意菜单，脚本会根据当前系统状态跳过已满足项。

常用维护入口：

- UFW 规则：菜单 `5`。
- 用户和公钥：菜单 `4`。
- fail2ban：菜单 `6`。
- 手动系统升级：菜单 `2`。
- 状态复核：菜单 `9`。

也可以直接使用：

```bash
ufw status numbered
ufw allow 8080/tcp
ufw delete allow 8080/tcp
ufw status
```

云平台安全组和 VPS 内的 UFW 必须保持一致。大改动前后都建议创建 Snapshot。

本项目不安装 Docker。需要 Docker 时，请自行审阅 [LinuxMirrors Docker 脚本](https://linuxmirrors.cn/docker.sh)，并选择不关闭防火墙，也可以显式使用 `--close-firewall false`。加入 `docker` 组等价于获得 root 权限。

## 9. 其他文档

- [README](../README.md)：快速开始和菜单入口。
- [手动教程](tutorial.md)：不使用脚本，逐条执行命令。
- [CodeWiki](codewiki/README.md)：维护者文档，包括架构、功能、开发流程和术语。
- [ADR-0003](adr/0003-single-tui-native-state.md)：单入口和原生状态的现行架构决策。

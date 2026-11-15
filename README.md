# 1804 VPS Setup

给 Debian VPS 做基础安全初始化。入口只有根目录的 `00-tui.sh`，启动后进入交互菜单。

## 快速开始

运行前先在云平台创建 Snapshot，确认安全组放行当前 SSH 端口，并准备好本地 SSH 密钥。

```bash
sudo -i
bash <(curl -fsSL https://raw.githubusercontent.com/Pathto1804/1804-vps-setup/main/00-tui.sh)
```

国内拉取失败时，可使用代理：

```bash
bash <(curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/Pathto1804/1804-vps-setup/main/00-tui.sh)
```

脚本要求 root 和交互终端，支持 Debian 12、13，Debian 11 与 Ubuntu 20.04 及以上版本理论兼容但未逐版本验证。启动只检查环境、读取当前状态和显示菜单，不会自动安装软件或修改系统。

第一次使用建议在主菜单选择 `0`，按顺序完成系统更新、时区、管理员、公钥、UFW、SSH、fail2ban、Swap、终检。任何 SSH 操作期间都保留当前 root 会话，确认新用户和新端口可以登录后再关闭旧会话。

## 主菜单

| 编号 | 功能 |
|---|---|
| `0` | 标准初始化 |
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

进入编号只打开状态页或子菜单，不会自动执行写操作。主菜单空回车会重新询问，子菜单 `0` 或空回车返回主菜单。

## 菜单 `2` 的包清单

必要项：`sudo ca-certificates curl wget gnupg ufw fail2ban unattended-upgrades vim nano unzip htop needrestart ncdu mtr-tiny bind9-dnsutils`；可选工具默认 `jq tmux lsof rsync zip`。缺少必要包时，脚本会先列出清单并确认，拒绝后不会安装。

## 使用时记住三点

1. UFW 先于 sshd，目标 SSH 端口必须先放行。
2. 密钥登录和 `sudo -v` 先于关闭密码认证。
3. 新端口验证成功、云平台安全组修改完成后，才删除旧端口规则。

## 详细文档

- [详细使用说明](docs/guide.md)：准备工作、完整菜单说明、备份恢复、故障处理和日常维护。
- [手动教程](docs/tutorial.md)：不使用脚本，逐条执行初始化命令。
- [维护者文档](docs/codewiki/README.md)：架构、功能、开发流程和术语。
- [架构决策 ADR-0003](docs/adr/0003-single-tui-native-state.md)：为什么采用单入口和系统原生状态。

## 安全提醒

这是个人 VPS 基础配置脚本，不保证适用于所有环境。涉及防火墙、SSH、用户和密码的操作前，请先阅读脚本和[详细使用说明](docs/guide.md)，并保留云平台 Snapshot 作为最终恢复手段。

## 本地副本执行

需要固定版本或反复维护时，可以拉取仓库后运行：

```bash
apt update && apt install -y git
git clone https://github.com/Pathto1804/1804-vps-setup.git /root/1804-vps-setup
sudo -i
cd /root/1804-vps-setup
bash 00-tui.sh
```

本地副本的完整说明见[详细使用说明](docs/guide.md#拉取失败时)。

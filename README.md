# 1804 VPS Setup

Debian/Ubuntu 个人 VPS 的交互式 TUI 工具集，包含两个独立、单文件自包含的入口：[`00-tui.sh`](00-tui.sh)（基础安全初始化与运维）和 [`comfyui-tui.sh`](comfyui-tui.sh)（ComfyUI 部署）。启动只探测系统原生状态，不写私有配置，也不会自动修改系统。

## 快速开始

两个脚本均要求 `root`（`sudo -i`）和交互终端，运行前先在云平台创建 Snapshot：

```bash
sudo -i

# 1. 基础安全初始化与运维
bash <(curl -fsSL https://raw.githubusercontent.com/Pathto1804/1804-vps-setup/main/00-tui.sh)

# 2. ComfyUI 部署
bash <(curl -fsSL https://raw.githubusercontent.com/Pathto1804/1804-vps-setup/main/comfyui-tui.sh)
```

国内拉取失败时，可使用加速链接：

```bash
# 1. 基础安全初始化与运维（国内加速）
bash <(curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/Pathto1804/1804-vps-setup/main/00-tui.sh)

# 2. ComfyUI 部署（国内加速）
bash <(curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/Pathto1804/1804-vps-setup/main/comfyui-tui.sh)
```

---

## 一、基础运维脚本（`00-tui.sh`）

- **适用平台**：Debian 12/13 一等支持；Debian 11 与 Ubuntu 20.04+ 兼容（未逐版本验证）。
- **建议流程**：首次使用选 `0` 按顺序完成更新、时区、管理员、公钥、UFW、SSH、fail2ban、Swap、终检；SSH 变更期间保留当前 root 会话，验证新用户和新端口可登录后再关旧会话。

### 主菜单

| 编号 | 功能 |
|---|---|
| `0` | 标准初始化 |
| `1` | 系统换源（LinuxMirrors 第三方脚本） |
| `2` | 系统更新与基础工具 |
| `3` | 时区 |
| `4` | 用户、密码、sudo 和密钥 |
| `5` | UFW 与 SSH |
| `6` | fail2ban |
| `7` | Swap |
| `8` | BBR，只读检查 |
| `9` | 终检与报告 |
| `q` | 退出 |

进入编号只打开状态页或子菜单，不自动写入；主菜单空回车重问，子菜单 `0` 或空回车返回主菜单。

### 菜单 `2` 包清单

必要项：`sudo ca-certificates curl wget gnupg ufw fail2ban unattended-upgrades vim nano unzip htop needrestart ncdu mtr-tiny bind9-dnsutils`；可选工具默认 `jq tmux lsof rsync zip`。缺包时先列出清单并确认后再安装。

### 三条铁律

1. UFW 先于 sshd，目标 SSH 端口必须先放行。
2. 密钥登录和 `sudo -v` 先于关闭密码认证。
3. 新端口验证成功、云平台安全组修改完成后，才删除旧端口规则。

详细操作见[详细使用说明](docs/guide.md)与[手动教程](docs/tutorial.md)。

---

## 二、ComfyUI 部署脚本（`comfyui-tui.sh`）

- **适用平台**：Ubuntu 22.04/24.04 一等支持（Debian 12/13 仅 NVIDIA 官方源路径，兼容未逐版本验证）。
- **前置条件**：`x86_64`、`root`、交互终端、家目录可用空间建议 >=30GB（<10GB 中止）；GPU 模式要求 `nvidia-smi` CUDA Version >=13.0（驱动 >=580，不提供 `cu126` 回退），无 GPU 可选 CPU 测试模式。已配置过部分环境的机器会自动探测已有 ComfyUI 目录与 Python 环境（conda/venv），各子菜单可单独执行并按需升级驱动/PyTorch。
- **访问与安全**：**默认 `--listen 0.0.0.0:8188`**，ComfyUI 无鉴权。需在云安全组放行 `8188/tcp`（建议限制来源为本人 IP/32）；UFW active 时标准部署会询问放行；菜单 `7` 可切换为仅回环 + SSH 隧道。

### 主菜单

| 编号 | 功能 |
|---|---|
| `0` | ComfyUI 标准部署 |
| `1` | 环境与依赖检查 |
| `2` | 基础工具与镜像 |
| `3` | GPU 驱动与 CUDA |
| `4` | Miniforge 与 Python 环境 |
| `5` | ComfyUI 与 PyTorch |
| `6` | 模型目录与下载 |
| `7` | 远程访问与防火墙 |
| `8` | 开机自启 |
| `9` | 终检与维护 |
| `q` | 退出 |

<!-- 与 comfyui-tui.sh 的 COMFY_BASE 保持一致；tools/sync_check.sh 会比对 -->
ComfyUI 基础包：`git curl wget vim build-essential tmux htop ca-certificates ffmpeg libgl1 libglib2.0-0 aria2 nvtop ncdu pciutils`

详细说明见 [ComfyUI 文档](comfyui-docs/README.md)、[部署指南](comfyui-docs/deployment-guide.md) 与 [CPU 测试指南](comfyui-docs/cpu-test-guide.md)。

---

## 本地克隆与更多文档

需要固定版本或代理拉取失败时，可克隆到本地运行：

```bash
apt update && apt install -y git
git clone https://github.com/Pathto1804/1804-vps-setup.git /root/1804-vps-setup
sudo -i && cd /root/1804-vps-setup
bash 00-tui.sh      # 或 bash comfyui-tui.sh
```

- 维护者知识库：[基础脚本 CodeWiki](docs/codewiki/README.md) · [ComfyUI CodeWiki](comfyui-docs/codewiki/README.md)
- 架构决策：[ADR-0003 单入口与原生状态](docs/adr/0003-single-tui-native-state.md) · [ADR-0004 ComfyUI 第二入口](docs/adr/0004-comfyui-entry.md)

> 个人 VPS 工具集，不保证适用于所有环境。涉及防火墙、SSH、用户权限或公网暴露 `8188` 端口前，请务必阅读对应指南并保留云平台 Snapshot。

# ComfyUI 部署脚本

入口是根目录的 [`comfyui-tui.sh`](../comfyui-tui.sh)，与基础初始化脚本 [`00-tui.sh`](../00-tui.sh) 并列。它只负责从裸 Ubuntu/GPU 云镜像到可用的 ComfyUI 服务；SSH、UFW、fail2ban、Swap、BBR 等安全基线与日常运维仍由 `00-tui.sh` 负责。

## 快速开始

```bash
sudo -i
bash <(curl -fsSL https://raw.githubusercontent.com/Pathto1804/1804-vps-setup/main/comfyui-tui.sh)
```

国内拉取失败时：

```bash
bash <(curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/Pathto1804/1804-vps-setup/main/comfyui-tui.sh)
```

## 前提

- Ubuntu 22.04 / 24.04（一等），Debian 12 / 13 仅 NVIDIA 官方源路径、兼容但未逐版本验证。
- x86_64，root（`sudo -i`），交互终端。
- GPU 模式要求 `nvidia-smi` 的 CUDA Version >= 13.0（驱动 >=580）；没有 GPU 时可进入 CPU 测试模式。
- 家目录至少 30GB 可用；默认不下载模型。
- 默认访问方式是 `--listen 0.0.0.0:8188`，ComfyUI 无鉴权。必须在云安全组放行 8188/tcp，并建议把来源限制为你自己的 IP/32。

## 主菜单

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

主菜单空回车原地重问；子菜单 `0` 或空回车返回。进入编号只打开状态页/子菜单，不自动执行写操作。

## 默认访问与后备

- 默认写入 `--listen 0.0.0.0 --port 8188`，终检打印 `http://<公网IP>:8188`。
- 菜单 `7` 可切换为“仅回环 + SSH 隧道”，移除 `--listen` 并重启；同时打印 `ssh -N -L 8188:127.0.0.1:8188 root@<IP>`。
- UFW active 时，默认流程问一次并放行 8188/tcp；UFW inactive 时不启用，只提示云安全组。
- ComfyUI-Manager 在 listen 模式下会拦截界面装插件；需要装插件时切菜单 `7` 的隧道模式，或终端进 `~/ComfyUI/custom_nodes` 手动 clone。

## 基础包

<!-- 与 comfyui-tui.sh 的 COMFY_BASE 保持一致；tools/sync_check.sh 会比对 -->
ComfyUI 基础包：`git curl wget vim build-essential tmux htop ca-certificates ffmpeg libgl1 libglib2.0-0 aria2 nvtop ncdu pciutils`

## 详细文档

- [部署指南（手动等价流程）](deployment-guide.md)
- [CPU 无卡测试指南](cpu-test-guide.md)
- [维护者知识库](codewiki/README.md)
- [架构决策 ADR-0004：ComfyUI 第二入口](../docs/adr/0004-comfyui-entry.md)

## 仓库规则

- 不保存项目私有状态：GPU/驱动读 `nvidia-smi`，环境读 Miniforge/env，服务读 systemd 或 `/start.d`，端口读 `ss`，防火墙读 `ufw`，ComfyUI 读 git。
- 菜单动作统一经 `act` 调用；动作内显式判错，失败只中止当前动作。
- 改配置前备份到 `/root/vps-init-backups/`；默认不自动回滚。
- 共享术语只在 [`docs/codewiki/terms.md`](../docs/codewiki/terms.md) 定义；本目录的 `codewiki/terms.md` 只写 ComfyUI 专属术语。
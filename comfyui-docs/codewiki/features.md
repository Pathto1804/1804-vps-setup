# 功能清单

入口 `comfyui-tui.sh`。本节按主菜单编号排列；编号与脚本实际输出一致，改菜单必须同批更新本页与 `README.md`。

启动不写文件；所有写操作由用户在子菜单显式选择。

## 主菜单

顶部状态行实时读取：GPU/驱动/CUDA、磁盘可用 GB、Miniforge、Python 环境、ComfyUI commit、torch 版本、服务、访问方式、UFW。

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

## `0` ComfyUI 标准部署

按固定顺序执行，逐项读原生状态，已满足则跳过。失败只中止当前流程，TUI 继续可用。

| 步 | 动作 | 停点 |
|---|---|---|
| 1 | 预检：root/TTY/x86_64/Ubuntu-Debian、Snapshot 确认、磁盘 >=10GB（<30GB 警告）、清华/阿里镜像连通 | 拒绝 Snapshot、磁盘 <10GB、镜像确认拒绝即中止 |
| 2 | `apt-get update` + 安装 `COMFY_BASE` | 用户拒绝安装或 apt 失败即中止 |
| 3 | 检测 NVIDIA 硬件与驱动 | 驱动 CUDA <13.0 或不可用：安装驱动后**停止流程等重启**；拒绝升级/安装则中止（无 cu126 回退）；无 GPU 可进 CPU 测试模式 |
| 4 | 安装 Miniforge（清华，GitHub 兜底）、写 `.condarc` 清华源、`conda init` | 下载/安装失败即中止 |
| 5 | 创建 `comfyui` 环境（Python 3.13） | 创建失败即中止 |
| 6 | clone/pull ComfyUI（GitHub；失败可问 ghproxy） | clone 失败即中止；pull 冲突只警告并继续 |
| 7 | pip 阿里源；装 `torch torchvision`（GPU 用阿里 PyPI；CPU 用官方 CPU 索引）；装两份 requirements | 安装失败或 CUDA 主版本 !=13 即中止 |
| 8 | `main.py --quick-test-for-ci --enable-manager [--cpu]` | 非零即中止 |
| 9 | 访问方式固定 `listen`；UFW active 时问一次并放行 8188 | 拒绝放行只警告，流程继续 |
| 10 | 写 systemd unit 或 `/start.d`，启用并等待 HTTP 60 秒 | 写 unit/启用失败即中止；无 systemd 且无 `/start.d` 只警告 |
| 11 | 终检（红/黄/绿），打印公网 URL 与隧道命令 | 红项只警告，不自动回滚 |

## `1` 环境与依赖检查

只读页：`nvidia-smi`、`nvcc --version`、`df -h`、`free -h`、conda/env、ComfyUI commit/分支、torch/torchvision/manager 版本、systemd 状态、`ss -tln` 的 8188、`ufw status`、三个镜像连通性。

## `2` 基础工具与镜像

| 项 | 行为 |
|---|---|
| `1` 安装缺失基础包 | `missing_pkgs COMFY_BASE`，先列清单并确认；只装缺的 |
| `2` 配 conda 清华镜像 | 已指向清华则跳过；否则备份 `.condarc` 后写入 |
| `3` 配 pip 阿里镜像 | 已是阿里则跳过；否则备份 pip 配置后写入 |
| `4` 测试镜像 | 清华 Miniforge/conda、阿里 PyPI、清华 PyPI、PyTorch 官方 CPU 索引 |

## `3` GPU 驱动与 CUDA

| 项 | 行为 |
|---|---|
| `1` 查看状态 | `nvidia-smi` + `nvcc --version` |
| `2` 安装/升级驱动 | Ubuntu 优先 `ubuntu-drivers`，最高版本 <580 时自动改 NVIDIA 官方源；Debian 直接官方源；装完提示必须重启 |
| `3` 安装 cuda-toolkit | 仅编译插件需要；装后把 `/usr/local/cuda` 写入 `.bashrc`（先备份，已存在则跳过） |
| `4` 重启 | 二次确认后 `systemctl reboot` / `reboot` |

## `4` Miniforge 与 Python 环境

安装/修复 Miniforge（清华 → GitHub）、写 `.condarc`（清华）、创建 3.13/3.12 环境、重建环境（二次确认，只删 conda 环境，不碰 ComfyUI/models）、查看 `conda env list`。

## `5` ComfyUI 与 PyTorch

clone/pull、配 pip 阿里源、安装/修复 PyTorch（GPU 走阿里 PyPI；CPU 走官方索引，失败问南京镜像）、安装两份 requirements、完整更新（pull + 依赖 + 重启，失败给旧 commit 回滚命令）、查看版本。

## `6` 模型目录与下载

创建/查看 `checkpoints diffusion_models text_encoders vae loras controlnet upscale_models`；ModelScope / hf-mirror 下载 SDXL Base（约 6.9GB，默认否）；aria2c 直链；自定义 ModelScope 仓库/文件；复制 `extra_model_paths.yaml.example`（目标已存在则不动）。

## `7` 远程访问与防火墙

查看当前访问方式、公网 URL、SSH 隧道命令、UFW；设置为 listen（默认，UFW active 时问一次放行 8188）或 tunnel（移除 `--listen`，重启）；重启服务。

## `8` 开机自启

查看 systemd/`/start.d` 状态；写/更新自启（当前访问方式）；单独写 systemd 服务或 `/start.d` 脚本；启动/停止/重启/状态；切换 CPU/GPU 启动参数；删除自启（先备份，再 disable + rm）。

## `9` 终检与维护

完整终检（GPU、Miniforge、env、ComfyUI、torch、manager、服务、端口、HTTP、UFW）；更新 ComfyUI + 依赖 + 重启；清理 pip/conda/journal 缓存（逐项确认）；查看 journald 或 `/start.d/log`。
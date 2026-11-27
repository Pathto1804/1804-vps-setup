# 功能清单

入口 `comfyui-tui.sh`。本节按主菜单编号排列；编号与脚本实际输出一致，改菜单必须同批更新本页与 `README.md`。

启动只做前置检查与原生上下文发现（优先从已有 `comfyui.service` / `/start.d/comfyui.sh`、常见目录含 `main.py`、conda/venv 探测 `COMFY_DIR` 与 `ENV_PY`），不装软件、不写文件；所有写操作由用户在子菜单显式选择。

## 主菜单

顶部状态行实时读取：GPU/驱动/CUDA、磁盘可用 GB、Conda、Python 环境、ComfyUI（commit 或非 Git 目录）、torch 版本、服务、访问方式、UFW。

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
| 2 | 安装必要基础包前询问是否先更换系统 apt 源（LinuxMirrors：展示免责声明与命令，确认风险后可执行或跳过），然后 `apt-get update` + 安装 `COMFY_BASE` | 换源失败且拒绝继续、未执行换源且拒绝继续、用户拒绝安装或 apt 失败即中止 |
| 3 | 检测 NVIDIA 硬件与驱动 | 驱动 CUDA <13.0 或不可用：安装/升级驱动后**停止流程等重启**；已满足 >=580 时明确说明仅满足最低要求（容器环境提示由宿主机提供；systemd 主机可选联网对比软件源并升级到最新稳定版）；拒绝安装不足驱动则中止；无 GPU 可进 CPU 测试模式 |
| 4 | 安装 Miniforge（清华，GitHub 兜底；支持 `wget`/`curl` 自动回退；若检测到非 Miniforge 的其他 conda 如 Miniconda 则询问直接复用或另装 Miniforge）、写 `.condarc` 清华源、`conda init` | 下载/安装失败即中止 |
| 5 | 创建 `comfyui` 环境（Python 3.13） | 创建失败即中止 |
| 6 | clone/pull ComfyUI（GitHub；失败可问 ghproxy；非 Git 且含 `main.py` 目录跳过 pull 并保留） | clone 失败即中止；pull 冲突只警告并继续 |
| 7 | pip 阿里源；装 `torch torchvision`（GPU 用阿里 PyPI；CPU 用官方 CPU 索引）；装 requirements（`manager_requirements.txt` 存在才装） | 安装失败或 CUDA 主版本 !=13 即中止 |
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
| `3` 配 pip 阿里镜像 | 直接备份并写 `~/.config/pip/pip.conf`（不强依赖先创建 conda 环境）；已是阿里则跳过 |
| `4` 测试镜像 | 清华 Miniforge/conda、阿里 PyPI、清华 PyPI、PyTorch 官方 CPU 索引 |
| `5` 系统软件源换源 | 展示 [LinuxMirrors](https://linuxmirrors.cn/main.sh) 来源、免责声明与命令，确认风险后询问是否立即拉取执行（默认否） |

## `3` GPU 驱动与 CUDA

| 项 | 行为 |
|---|---|
| `1` 查看状态 | `nvidia-smi` + `nvcc --version` |
| `2` 安装 / 升级驱动 | 检查容器透传及非 dpkg（`.run`）风险；展示当前版本/包风味 vs 仓库候选稳定版；Ubuntu 可选系统源（>=580 分支）或 NVIDIA 官方源（`nvidia-open` / `cuda-drivers` / 指定 `>=580` 分支），Debian 直接官方源；已达标也可按意愿升级到最新稳定版；装完且有变更时提示必须重启 |
| `3` 安装 / 升级 cuda-toolkit | 显示当前 `nvcc` 与 `apt-cache policy` 候选版本；装后把 `/usr/local/cuda` 写入 `.bashrc`（先备份，已存在则跳过） |
| `4` 重启 | 二次确认后 `systemctl reboot` / `reboot` |

## `4` Miniforge 与 Python 环境

安装/修复 Miniforge（`wget`/`curl` 自动回退，清华 → GitHub）、写 `.condarc`（清华）、创建 3.13/3.12 环境（环境已存在时提示当前版本并问是否重建）、重建环境（二次确认，只删目标 conda 环境，不碰 ComfyUI/models）、查看 `conda env list`、更新 `conda`/`mamba`、**切换当前 Python 环境（仅本次会话，支持已探测 conda/venv 或任意路径）**。

## `5` ComfyUI 与 PyTorch

clone/pull（非 Git 但含 `main.py` 目录保留代码）、配 pip 阿里源、安装/修复/升级 PyTorch（已满足时可选 `pip install -U` 升到最新稳定版；有 GPU 但驱动未就绪时可选预装 CUDA 13 或装 CPU 版）、安装 requirements（`manager_requirements.txt` 存在才装）、完整更新（仅 Git 仓库，pull + 依赖 + 重启，失败给旧 commit 回滚命令）、查看版本、**切换当前 ComfyUI 目录（仅本次会话）**。

## `6` 模型目录与下载

显示当前 `COMFY_DIR`；创建/查看 `checkpoints diffusion_models text_encoders vae loras controlnet upscale_models`（需 `COMFY_DIR` 存在）；ModelScope / hf-mirror 下载 SDXL Base（约 6.9GB，默认否；CLI 优先使用当前环境并可回退系统 `PATH`/`python3`）；aria2c 直链（缺命令可按需单装 `aria2`）；自定义 ModelScope 仓库/文件；复制 `extra_model_paths.yaml.example`（目标已存在则不动）。

## `7` 远程访问与防火墙

查看当前访问方式、公网 URL、SSH 隧道命令、UFW；设置为 listen（默认，UFW active 时问一次放行 8188）或 tunnel（移除 `--listen`，重启）；**仅检查/放行 UFW 8188 端口（不改自启服务）**；重启服务。未配自启服务时设置访问方式不报错中断，只按需更新防火墙并提示手动参数。

## `8` 开机自启

查看 systemd/`/start.d` 状态与当前目标路径；写/更新自启（包含 `main.py` 与当前访问方式，并保留已有 unit/start.d 中的自定义启动参数）；单独写 systemd 服务或 `/start.d` 脚本；启动/停止/重启/状态；切换 CPU/GPU 启动参数；删除自启（先备份，再 disable + rm）。

## `9` 终检与维护

完整终检（GPU、Conda、env、ComfyUI、torch、manager、服务、端口、HTTP、UFW）；更新 ComfyUI + 依赖 + 重启；清理 pip/conda/journal 缓存（逐项确认，不强依赖脚本安装 Miniforge）；查看 journald 或 `/start.d/log`。
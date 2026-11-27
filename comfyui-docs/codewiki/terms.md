# ComfyUI 术语

本页只定义 ComfyUI 部署脚本的专属术语。共享概念（单入口脚本、原生状态、动作隔离、TUI、闸门、备份目录、终检）以 [`docs/codewiki/terms.md`](../../docs/codewiki/terms.md) 为准，这里不重复定义。

**ComfyUI 部署脚本**（`comfyui-tui.sh`）
与基础初始化脚本 `00-tui.sh` 并列的第二入口，单文件自包含，负责 GPU/CPU 环境、Miniforge、ComfyUI、PyTorch、模型目录、访问方式与自启；不负责 SSH/UFW 安全基线。
_Avoid_: 原脚本、新脚本、增强版

**ComfyUI 标准部署**（菜单 `0`）
按固定顺序执行预检 → 基础包 → GPU/驱动 → Miniforge → Python 环境 → ComfyUI → PyTorch/依赖 → 冒烟 → 访问方式 → 自启 → 终检的动作。每步先读原生状态，已满足则跳过。与基础脚本的「标准初始化」区分。
_Avoid_: 一键安装、全自动部署

**CPU 测试模式**
没有可用 GPU 或用户显式选择时，安装 PyTorch 官方 CPU 索引的 `torch`/`torchvision`，启动参数加 `--cpu`。只用于验证流程和网页 UI，不用于出图。
_Avoid_: 无卡模式（口语可用，文档用 CPU 测试模式）

**访问方式**
unit/start.d 的 `ExecStart` 是否包含 `--listen`：
- **监听**：`--listen 0.0.0.0 --port 8188`，公网直连；无鉴权。
- **隧道**：仅监听回环，本地 `ssh -N -L 8188:127.0.0.1:8188`。
默认监听；菜单 7 切换。
_Avoid_: 方案 A/B、内网/外网模式

**自启方式**
- **systemd**：PID 1 是 systemd 时写 `/etc/systemd/system/comfyui.service`。
- **/start.d**：容器平台（PID 1 非 systemd）写 `/start.d/comfyui.sh`，由平台在实例启动时执行。
两者只能选其一；脚本优先 systemd。
_Avoid_: 守护进程、开机脚本（泛称）

**镜像源**
本脚本的默认下载链路：清华 Miniforge/conda；阿里 PyPI（清华兜底）；PyTorch 官方 CPU 索引（南京仅可选兜底）；NVIDIA 官方 apt 源；ModelScope / hf-mirror 下载模型。NJU PyTorch 索引不是默认路径。
_Avoid_: 镜像站（泛称）、加速器

**驱动门槛**
GPU 模式要求 `nvidia-smi` 的 CUDA Version >= 13.0（驱动 >=580）。低于该门槛只提供升级路径，不提供 `cu126` 软件回退。
_Avoid_: 兼容旧驱动、降级 torch
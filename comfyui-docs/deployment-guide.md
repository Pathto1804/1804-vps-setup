# Ubuntu 22.04 Server 从零部署 ComfyUI 完整指南（家目录极简 + PyPI/conda 双镜像加速版）

本指南面向**纯净或云厂商定制的 Ubuntu 22.04 Server 镜像**（无图形界面），全部软件直接安装在当前用户家目录（`~/miniforge3` 和 `~/ComfyUI`），**无需折腾 `/opt` 权限**，并默认配置阿里云 PyPI + 清华 conda/Miniforge 高速镜像、先查版本再按需升级、不写死版本号。

> 本仓库的 `comfyui-tui.sh` 把本指南自动化。脚本只支持**驱动 CUDA >= 13.0（驱动 >=580）**；不提供 `cu126` 回退。脚本默认 `--listen 0.0.0.0:8188`，菜单 7 可切回 SSH 隧道。

## 核心技术栈与云端容量规划

| 组件 / 目录 | 路径 / 方案 | 说明 | 
| ----- | ----- | ----- | 
| 操作系统 | Ubuntu 22.04 LTS Server (x86_64) | 纯净或云厂商定制镜像（同样适用于 24.04） | 
| 显卡驱动 | 先查版本，过旧则升级，未装则按路径补齐 | 需满足目标 PyTorch 的 CUDA 最低驱动要求（如 CUDA 13.x 需 `>= 580`） | 
| CUDA Toolkit | 先查 `nvcc`，按需安装/升级（非必需） | `pip` 版 PyTorch 自带 CUDA 运行时，仅编译加速插件时需对齐系统 `nvcc` | 
| Python 环境 | `~/miniforge3` ([Miniforge](https://mirrors.tuna.tsinghua.edu.cn/github-release/conda-forge/miniforge/LatestRelease/)) | 即使镜像预装了 Miniconda 也可独立安装并接管；首选 **Python 3.13**（3.12 作回退） | 
| ComfyUI 主程序 | `~/ComfyUI` ([ComfyUI](https://github.com/Comfy-Org/ComfyUI)) | 已内置 [ComfyUI-Manager](https://docs.comfy.org/manager/install)（通过 `--enable-manager` 启用） | 
| PyTorch | 官方最新稳定版 | 通过阿里云 PyPI 安装；当前 `torch 2.15.0` 默认依赖 `nvidia-*-cu13`，即 CUDA 13 运行时 | 

### 云端磁盘总空间参考（固定底座约 15–25 GB + 模型按需浮动）

| 使用场景 | 推荐总容量 | 说明 | 
| ----- | ----- | ----- | 
| **轻量体验**（1\~2 个 SDXL 底模 + 少量 LoRA） | **60 – 80 GB** | 最低安全线，留出约 20 GB 缓冲避免爆盘 | 
| **主力日常出图**（SDXL + Flux + 多套插件/LoRA） | **100 – 150 GB** | 最稳妥的甜点容量，不至于频繁删模型 | 
| **重度全能 / 视频生成**（Flux + 视频模型 + 长期存图） | **200 – 500 GB** | 建议拆成“50 GB 系统盘 + 200 GB+ 独立数据盘” | 

## 1. 硬件检查与基础工具 / 底层库安装

先确认显卡硬件已识别以及家目录剩余空间充足，然后直接补齐基础工具与底层库（已装过的包 `apt` 会自动跳过）。其中 **`ffmpeg`**（视频节点必装）和 **`libgl1`、`libglib2.0-0`**（解决无桌面服务器下 OpenCV 节点报 `libGL.so.1` 缺失）强烈建议一并安装；`nvtop` 和 `ncdu` 分别用于监控显存与排查大文件：

```
lspci | grep -i nvidia
df -h ~

sudo apt update
sudo apt install -y git curl wget vim build-essential tmux htop ca-certificates \
  ffmpeg libgl1 libglib2.0-0 aria2 nvtop ncdu pciutils iproute2



```

## 2. 显卡驱动与 CUDA 检查、安装及老版本处理

很多云平台特制镜像会预装驱动甚至老版本 CUDA，**不能只看“有没有装”，必须核对版本号是否满足新工作流与新版 PyTorch 要求**：

```
nvidia-smi
nvcc --version





```

按以下 3 种情况处理：

* **情况一：已预装驱动，且 `nvidia-smi` 右上角 `CUDA Version >= 13.0`（满足新版本要求）**

  * 直接**跳过本节进入第 3 步**。

  * *(注：就算镜像里预装了老版本系统级 `nvcc` 例如 11.8/12.1，只要你不本地编译插件，`pip` 装的 PyTorch 会优先使用自带的 CUDA 13 运行时，不受老 `nvcc` 影响；若需要编译 `sageattention` 等插件，再按路径 B 装新版 `cuda-toolkit` 即可。)*

* **情况二：已预装驱动，但 `nvidia-smi` 显示驱动过旧（例如 `CUDA Version` 只有 12.2 / 12.4，驱动 `< 580`）**

  * 老驱动带不动新版 PyTorch（`cu130`+）及现代新工作流所需的算子优化。**建议先走路径 A**：运行 `ubuntu-drivers devices` 查看系统或云厂商源是否已提供 580+ 新版驱动，如果有，直接 `sudo ubuntu-drivers install` 并重启即可平滑升级；只有当系统源没有更新版本（或原驱动系 `.run` 离线包安装导致 `apt` 冲突）时，再改走**路径 B** 接入 NVIDIA 官方源升级。

* **情况三：纯净镜像，尚未安装任何驱动**

  * 先尝试下方**路径 A**；若系统源里的驱动版本依然过旧，再改走**路径 B**。

### 路径 A：优先使用系统源 / 云厂商定制源推荐驱动

```
sudo apt install -y ubuntu-drivers-common
ubuntu-drivers devices
sudo ubuntu-drivers install
sudo reboot





```

重启后重新 SSH 登录，运行 `nvidia-smi` 检查右上角 `CUDA Version`。如果已经达到目标版本（例如 `>= 13.0`），直接进入第 3 步。

### 路径 B：接入 NVIDIA 官方源（升级老旧驱动 / 安装新版 CUDA Toolkit）

当需要把老驱动升级到 580+，或者需要新版系统级 `nvcc` 编译 `sageattention`、`flash-attn` 等加速插件时执行。临时安装包放入 `/tmp` 并在安装后立即清理：

```
wget -O /tmp/cuda-keyring.deb https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb \
  && sudo dpkg -i /tmp/cuda-keyring.deb \
  && rm -f /tmp/cuda-keyring.deb

sudo apt update
# 只需升级驱动可执行：sudo apt install -y nvidia-open
# 若同时需要系统级 nvcc 编译插件，连同 cuda-toolkit 一起安装：
sudo apt install -y nvidia-open cuda-toolkit
sudo reboot





```

如果安装了 `cuda-toolkit`（或覆盖了旧版 CUDA），重启登录后将通用软链 `/usr/local/cuda` 写入环境变量最前面，确保 `nvcc` 指向新版：

```
echo 'export PATH="/usr/local/cuda/bin${PATH:+:${PATH}}"' >> ~/.bashrc
echo 'export LD_LIBRARY_PATH="/usr/local/cuda/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"' >> ~/.bashrc
source ~/.bashrc

nvidia-smi      # 确认驱动已升级且 CUDA Version >= 13.0
nvcc --version  # 确认已指向新版 CUDA Toolkit





```

## 3. 安装 Miniforge 到家目录（即使预装了 Miniconda 也适用）

### 第一步：检查预装情况 & 独立安装 Miniforge

先检查是否已有 Miniforge 或 Miniconda：

```
which conda mamba
ls -d ~/miniforge3 ~/miniconda3 /opt/miniforge3 /opt/miniconda3 2>/dev/null





```

* **如果镜像已经预装了 `Miniconda`**：**你依然可以下载安装 `Miniforge`**，两者互不冲突！只需将 Miniforge 安装到 `~/miniforge3` 并执行 `conda init bash`，初始化脚本会自动把 `~/.bashrc` 里的 `conda` 指向接管为 `~/miniforge3`（原有系统的 `miniconda3` 目录可保留不动）。

* 若已预装的正是 Miniforge 且可用，可直接跳到第二步；否则从[清华大学开源软件镜像站](https://mirrors.tuna.tsinghua.edu.cn/github-release/conda-forge/miniforge/LatestRelease/)高速下载安装到 `~/miniforge3`（**不要加 `sudo`**，装完即删 `/tmp/miniforge.sh`）：

```
wget -c -O /tmp/miniforge.sh https://mirrors.tuna.tsinghua.edu.cn/github-release/conda-forge/miniforge/LatestRelease/Miniforge3-Linux-x86_64.sh \
  && bash /tmp/miniforge.sh -b -u -p "$HOME/miniforge3" \
  && rm -f /tmp/miniforge.sh

# 若镜像原本就自动激活了旧 Miniconda 的 (base)，先退出一次以免当前终端残留旧路径
conda deactivate 2>/dev/null || true
"$HOME/miniforge3/bin/conda" init bash
source ~/.bashrc

# 安装后验收：确认当前接管的是 ~/miniforge3（非 miniconda3）且 conda/mamba 均可用
which conda
conda --version && mamba --version





```

> **提示**：执行 `source ~/.bashrc` 后命令行最前面出现 `(base)` 属于正常现象，说明 Miniforge 已成功初始化并接管终端。如果不想每次登录 SSH 都自动显示 `(base)`，运行 `conda config --set auto_activate_base false` 即可关闭。
> *(若服务器在海外网络环境，可将下载地址替换为 `https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh`。)*

### 第二步：配置 `~/.condarc` 清华源并创建 Python 3.13 环境

将 `conda-forge` 指向清华镜像（当前阿里云的 `conda-forge` repodata 返回 404，不要用阿里云 conda 源）：

```
cp ~/.condarc ~/.condarc.bak 2>/dev/null || true
cat > ~/.condarc << 'EOF'
channels:
  - conda-forge
show_channel_urls: true
custom_channels:
  conda-forge: https://mirrors.tuna.tsinghua.edu.cn/anaconda/cloud
EOF





```

使用 Miniforge 内置的 `mamba` 创建并激活独立的 `comfyui` 环境（**不要把 ComfyUI 装在 `(base)` 里**；参照 [ComfyUI 系统要求](https://docs.comfy.org/installation/system_requirements) 首选推荐 `3.13`，若个别老插件报错可改为 `3.12`）：

```
PY_VER=3.13
mamba create -n comfyui python=${PY_VER} -y
conda activate comfyui

# 安装后验收：确认已切换到 (comfyui) 且 Python 版本符合预期
python --version
conda env list





```

> **重要提示（掉回 `(base)` 怎么办）**：`conda activate comfyui` 只对当前这一次 SSH 会话有效。**一旦重启服务器或重连 SSH，终端会默认回到 `(base)`**——这不是环境丢了，只需重新执行 `conda activate comfyui` 切回来再继续操作即可。

## 4. 部署 ComfyUI、PyTorch 与 Manager（全阿里云高速源）

确认终端提示符前缀已切换为 `(comfyui)` 后，先检查家目录是否已有 `ComfyUI` 文件夹：

```
ls -d ~/ComfyUI





```

* 如果提示 `No such file or directory`（未安装），直接克隆 [ComfyUI 官方仓库](https://github.com/Comfy-Org/ComfyUI)（新版已内置 ComfyUI-Manager，无需再单独 `git clone`）：

  ```
  git clone https://github.com/Comfy-Org/ComfyUI.git ~/ComfyUI
  cd ~/ComfyUI
  
  
  
  
  
  ```

* 如果已经存在，进入目录拉取最新代码即可：

  ```
  cd ~/ComfyUI && git pull
  
  
  
  
  
  ```

### 配置 `pip` 全局阿里云源并安装 PyTorch 与依赖

先将 `pip` 全局默认源设为阿里云，再检查是否已预装 PyTorch：

```
pip config set global.index-url https://mirrors.aliyun.com/pypi/simple/
python -c "import torch; print('已安装:', torch.__version__, 'CUDA:', torch.version.cuda)"
```

若提示 `ModuleNotFoundError: No module named 'torch'`，直接通过标准 PyPI 安装即可。当前 PyPI 的 `torch 2.15.0` 元数据依赖 `nvidia-cudnn-cu13` / `nvidia-nccl-cu13`，默认就是 CUDA 13 运行时，**不需要 `+cu130` 本地版本后缀**：

```
python -m pip install torch torchvision

python -m pip install -r ~/ComfyUI/requirements.txt
python -m pip install -r ~/ComfyUI/manager_requirements.txt

```

> **说明与排错**：
>
> * **不要安装 `torchaudio`**：cu130 索引没有它，ComfyUI 的 `requirements.txt` 也不需要；强行从 PyPI 装旧版可能与 torch 2.15 ABI 不匹配。
>
> * **为什么不用阿里云 `pytorch-wheels/cu130`**：该地址是文件浏览页，不是 PEP503 索引，`pip --extra-index-url` 会报 `No matching distribution found`。只有确实需要 `+cu130` 本地版本时，才用官方索引：`python -m pip install torch torchvision --index-url https://download.pytorch.org/whl/cu130`（国内慢时可换南京大学 `https://mirror.nju.edu.cn/pytorch/whl/cu130`）。
>
> * **为什么推荐用 `python -m pip`**：确保安装包精准写入当前激活的 `(comfyui)` Python 环境。如果后续启动报 `ModuleNotFoundError: No module named 'yaml'` 等缺包错误，先确认终端前缀为 `(comfyui)`（若掉回 `(base)` 请先 `conda activate comfyui`），再重跑上面两条 `python -m pip install -r ...` 补齐即可。
>
> * **`root` 用户黄色警告**：如果服务器默认以 `root` 登录，只要终端前缀是 `(comfyui)` 且 `which python` 指向 `miniforge3/envs/comfyui`，出现的 `Running pip as the 'root' user` 警告可以安全忽略。

验证 PyTorch 与核心依赖是否就绪（`torch.version.cuda` 应为 `13.0`，`Available: True` 表示 GPU 可用；确认后可执行 `pip cache purge` 清理约 3–5 GB 的下载缓存）：

```
python -c "import yaml, torch, torchvision; print('PyTorch:', torch.__version__, 'CUDA:', torch.version.cuda, 'Available:', torch.cuda.is_available())"
pip cache purge





```

## 5. 模型目录规划、高速下载与前台测试

### 常见模型存放路径

| 模型类型 | 默认存放路径 | 
| ----- | ----- | 
| 主模型 (Checkpoint) | `~/ComfyUI/models/checkpoints/` | 
| 独立扩散模型 (Flux / UNet) | `~/ComfyUI/models/diffusion_models/` | 
| 文本编码器 (`t5xxl` / `clip_l`) | `~/ComfyUI/models/text_encoders/` | 
| VAE 模型 | `~/ComfyUI/models/vae/` | 
| LoRA 模型 | `~/ComfyUI/models/loras/` | 
| ControlNet 模型 | `~/ComfyUI/models/controlnet/` | 
| 放大模型 (`4x-UltraSharp` 等) | `~/ComfyUI/models/upscale_models/` | 

*(如果模型存放在单独挂载的大容量数据盘，复制模板文件修改路径即可：`cp ~/ComfyUI/extra_model_paths.yaml.example ~/ComfyUI/extra_model_paths.yaml`。)*

### 远端命令行高速下载公开大底模（建议在 `tmux` 会话中执行防断线）

**方式 A：ModelScope 魔搭社区（国内云主机最快、免配镜像）**

```
pip install -U modelscope
# 只下载指定单文件到对应目录（以 SDXL 1.0 Base 为例）
modelscope download --model AI-ModelScope/stable-diffusion-xl-base-1.0 \
  sd_xl_base_1.0.safetensors \
  --local_dir ~/ComfyUI/models/checkpoints





```

**方式 B：`hf-mirror` 镜像站（资源最全，支持最新 HuggingFace 仓库）**

```
pip install -U "huggingface_hub[cli]" hf_transfer
export HF_ENDPOINT=https://hf-mirror.com
export HF_HUB_ENABLE_HF_TRANSFER=1

huggingface-cli download stabilityai/stable-diffusion-xl-base-1.0 \
  sd_xl_base_1.0.safetensors \
  --local-dir ~/ComfyUI/models/checkpoints





```

**方式 C：已知直链时使用 `aria2c` 16 线程断点续传**

```
aria2c -x 16 -s 16 -c \
  "https://hf-mirror.com/stabilityai/stable-diffusion-xl-base-1.0/resolve/main/sd_xl_base_1.0.safetensors" \
  -d ~/ComfyUI/models/checkpoints \
  -o sd_xl_base_1.0.safetensors



```

下载完成后检查文件大小是否正常（避免下到 0 字节或网页报错文件）：

```
ls -lh ~/ComfyUI/models/checkpoints/



```

### 常用插件与推理加速组件（按需）

* **常用基础节点**：可通过网页端内置的 **Manager** 按需安装，常见组合包括 `rgthree-comfy`、`ComfyUI-KJNodes`、`ComfyUI-Easy-Use`、`ComfyUI-Impact-Pack`、`comfyui_controlnet_aux`、`ComfyUI-VideoHelperSuite` 等。

* **推理加速**：抠图/换脸/姿态类节点建议安装 `onnxruntime-gpu` 避免退回 CPU 慢速推理；跑 Flux 或视频大模型可按需安装 `sageattention` 并配合启动参数 `--use-sage-attention`（本地编译需第 2 步路径 B 的系统级 `cuda-toolkit`）。

### 首次前台测试

```
cd ~/ComfyUI
python main.py --enable-manager





```

终端输出 `To see the GUI go to: http://127.0.0.1:8188` 且无报错后，按 `Ctrl + C` 停止，继续配置远程访问与后台守护。

## 6. 远程访问与防火墙配置

> `comfyui-tui.sh` 默认采用**方案 B（`--listen 0.0.0.0:8188`）**；方案 A（SSH 隧道）是菜单 7 的后备。以下两种都保留，按需选择。
> 脚本的默认流程不做 `apt full-upgrade`，只做 `apt-get update` + 安装缺失基础包，避免升级内核/驱动导致额外重启。

> **客户端浏览器要求**：参照 [ComfyUI 官方系统要求](https://docs.comfy.org/installation/system_requirements)，访问前端界面请使用 **Google Chrome 143 及以上版本**；142 及更早版本存在已知的画布渲染异常与性能问题。

云服务器上通常有**云厂商控制台安全组**与 **Ubuntu 系统 `ufw`** 两层防火墙，按需二选一配置：

| 访问方案 | 需要放行的端口 | 云厂商安全组建议 | 说明 | 
| ----- | ----- | ----- | ----- | 
| **方案 A：SSH 端口转发（推荐）** | 仅 **`22/tcp`** (SSH) | 默认已开，**无需新增** | **不要放行 `8188`**。最安全且不影响 Manager 在线装插件 | 
| **方案 B：IP 直连 (`--listen 0.0.0.0`)** | **`22/tcp`** + **`8188/tcp`** | 入站来源 IP 限制为**你自己的公网 IP/32** 或内网网段 | 需同时在系统内执行 `sudo ufw allow 8188/tcp` | 

### 方案 A：SSH 端口转发（强烈推荐）

服务端保持默认监听 `127.0.0.1:8188`，在**本地电脑**终端执行：

```
ssh -N -L 8188:127.0.0.1:8188 你的用户名@服务器IP





```

保持该终端窗口开启，在本地浏览器访问 `http://127.0.0.1:8188` 即可。由于服务端仍绑定在本地回环地址，**ComfyUI-Manager 的界面安装插件功能可以正常使用**。

### 方案 B：局域网 / 指定 IP 直接访问

若需外部设备直连，在后续 `systemd` 启动命令末尾追加 `--listen 0.0.0.0 --port 8188`，并放行 `ufw` 端口：

```
sudo ufw status
sudo ufw allow 8188/tcp





```

> **重要安全与功能限制提示**：
>
> 1. **Manager 安装拦截**：根据 [ComfyUI 管理文档](https://docs.comfy.org/installation/desktop/usage/manage)，使用 `--listen` 对外监听时，ComfyUI-Manager 在默认网络模式下会**拦截通过界面安装自定义节点包**；此时需改用终端进入 `~/ComfyUI/custom_nodes` 手动 `git clone` 安装，或改用方案 A。
>
> 2. **无鉴权风险**：ComfyUI 默认无登录密码校验，切勿对 `0.0.0.0/0` 全网裸露 8188 端口；若需公网直连，建议前置 Nginx + HTTPS 与基础认证（仅放行 `443/tcp`）。

## 7. 配置开机自启与后台守护（按实例类型二选一）

先执行以下两条命令，确认当前是**完整云主机（支持 `systemd`）**还是**算力平台容器实例（使用 `/start.d/`）**：

```
ps -p 1 -o comm=
ls -d /start.d 2>/dev/null

```

### 方式 A：算力平台容器实例（如优云智算，存在 `/start.d` 目录且 `ps -p 1` 非 `systemd`）

参照平台规范在 `/start.d/` 创建可执行脚本。**注意**：在非交互式自启脚本里直接写 `conda activate` 容易触发 `CondaError`，推荐直接把 `comfyui` 环境的 `bin` 目录加入 `PATH` 并调用该环境的 `python` 绝对路径：

```
cat > /start.d/comfyui.sh << EOF
#!/bin/bash
export PATH="${HOME}/miniforge3/envs/comfyui/bin:/usr/local/cuda/bin:\$PATH"
cd "${HOME}/ComfyUI" || exit 1
exec "${HOME}/miniforge3/envs/comfyui/bin/python" main.py --enable-manager --listen 0.0.0.0 --port 8188
EOF

chmod +x /start.d/comfyui.sh

```

*(注：若不走平台自带端口映射而是用本地 SSH 隧道访问，删掉上面命令末尾的 `--listen` 即可。)*

先手动执行 `/start.d/comfyui.sh` 验证无报错后，重启实例并通过 `/start.d/log/` 日志或 `ps aux | grep main.py` 验收自启是否生效。

### 方式 B：完整 GPU 云主机（`ps -p 1 -o comm=` 输出 `systemd`）

在支持 `systemd` 的云主机上，直接生成服务配置（自动读取当前的 `$USER` 和 `$HOME`）：

```
sudo tee /etc/systemd/system/comfyui.service > /dev/null << EOF
[Unit]
Description=ComfyUI Service
After=network.target

[Service]
Type=simple
User=${USER}
WorkingDirectory=${HOME}/ComfyUI
ExecStart=${HOME}/miniforge3/envs/comfyui/bin/python main.py --enable-manager
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF





```

*(若采用方案 B 直连，请将 `ExecStart` 行末尾改为 `main.py --enable-manager --listen 0.0.0.0 --port 8188`。)*

重载配置并设置开机自启：

```
sudo systemctl daemon-reload
sudo systemctl enable --now comfyui





```

### 日常运维常用命令

```
# 安装后验收：确认状态为 active (running) 且 8188 端口已监听
sudo systemctl status comfyui
ss -tlnp | grep 8188
journalctl -u comfyui -f

# 重启 / 停止服务
sudo systemctl restart comfyui
sudo systemctl stop comfyui

# 实时监控显卡显存与排查磁盘大文件
nvtop
ncdu ~





```

## 8. 长期升级与日常维护指南

### 8.1 日常更新 ComfyUI 本体与插件

```
conda activate comfyui
cd ~/ComfyUI
git pull
pip install -r requirements.txt
pip install -r manager_requirements.txt
sudo systemctl restart comfyui





```

### 8.2 升级 Python / PyTorch / CUDA（按需分层处理）

升级前先弄清：**PyTorch 跑图用的是虚拟环境里自带的 CUDA 运行时，而系统驱动决定这台机器最高能跑到哪一代 CUDA。**

1. **情况 A：驱动已支持新版 CUDA（只需升级 Python / PyTorch / `cuXXX`）**

   * 先用 `nvidia-smi` 看右上角 `CUDA Version`（比如已支持 13.2+）。

   * **不要**在原环境里强行覆盖，用 `mamba` 新建并行环境做“双环境热切换”：

     ```
     NEW_PY_VER=3.13
     mamba create -n comfyui_new python=${NEW_PY_VER} -y
     conda activate comfyui_new
     
     pip config set global.index-url https://mirrors.aliyun.com/pypi/simple/
     pip install torch torchvision
     cd ~/ComfyUI
     pip install -r requirements.txt
     pip install -r manager_requirements.txt
     ```

   * 测试通过后，修改 `/etc/systemd/system/comfyui.service` 里的 `ExecStart` 指向 `/home/<你的用户名>/miniforge3/envs/comfyui_new/bin/python`，执行 `sudo systemctl daemon-reload && sudo systemctl restart comfyui`。若个别插件不兼容，改回原路径即可秒级回滚。

2. **情况 B：驱动过旧，带不动新版 CUDA / PyTorch（升级显卡驱动）**

   * 如果想升到更新的 `cuXXX` 但 `nvidia-smi` 显示上限不够，需先升级主机驱动：

     ```
     sudo apt update
     sudo apt install -y nvidia-open   # 若此前未接 NVIDIA 官方源，先按第 2 步路径 B 装 cuda-keyring
     sudo reboot
     
     
     
     
     
     ```

   * 重启确认 `nvidia-smi` 版本提升后，再按上面情况 A 建新环境装新版 PyTorch。

3. **情况 C：需要升级系统级 CUDA Toolkit（`nvcc`，供本地编译加速插件用）**

   * 仅在编译新版 `sageattention`、`flash-attn` 等报错提示 `nvcc` 版本过老时需要：

     ```
     apt-cache search ^cuda-toolkit-[0-9]   # 查看仓库中最新的大版本包名
     sudo apt update && sudo apt install -y cuda-toolkit
     
     
     
     
     
     ```

   * 安装新版本后，`/usr/local/cuda` 软链通常会自动指向最新版本，运行 `nvcc --version` 核对；若仍显示旧版本，检查 `/usr/local/` 下的目录并通过 `sudo ln -sfn /usr/local/cuda-XX.X /usr/local/cuda` 切换软链即可。

### 8.3 磁盘与日志日常清理

长期运行后，安装包缓存和 `systemd` 日志会逐渐占空间，可定期执行以下无损清理：

```
pip cache purge                      # 清理 pip 下载缓存
mamba clean -a -y                    # 清理 conda/mamba 安装包缓存
sudo journalctl --vacuum-time=7d     # 只保留最近 7 天的系统服务日志
ncdu ~                               # 交互式排查家目录剩余大文件





```
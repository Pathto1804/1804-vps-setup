# Ubuntu ComfyUI 无卡（CPU）快速测试指南

本指南用于在**没有 GPU 显卡的普通云服务器或本地虚拟机**上，用最省空间、最快的方式验证 ComfyUI 的环境搭建、网页 UI、Manager 插件加载以及开机自启脚本是否能正常跑通（**跳过所有显卡驱动与 CUDA 步骤**）。

---

## 1. 安装基础工具与底层库

```bash
sudo apt update && sudo apt install -y git wget curl vim ffmpeg libgl1 libglib2.0-0
```

---

## 2. 安装 Miniforge 并创建 Python 3.13 环境

使用清华镜像下载安装脚本（装完即删 `/tmp/miniforge.sh`），再用清华 conda 源建环境：

```bash
wget -c -O /tmp/miniforge.sh https://mirrors.tuna.tsinghua.edu.cn/github-release/conda-forge/miniforge/LatestRelease/Miniforge3-Linux-x86_64.sh \
  && bash /tmp/miniforge.sh -b -u -p "$HOME/miniforge3" \
  && rm -f /tmp/miniforge.sh

conda deactivate 2>/dev/null || true
"$HOME/miniforge3/bin/conda" init bash
source ~/.bashrc

cat > ~/.condarc << 'EOF'
channels:
  - conda-forge
show_channel_urls: true
custom_channels:
  conda-forge: https://mirrors.tuna.tsinghua.edu.cn/anaconda/cloud
EOF

mamba create -n comfyui python=3.13 -y
conda activate comfyui
```

> **提示**：重启或重连 SSH 后终端会默认回到 `(base)`，重新执行 `conda activate comfyui` 即可切回。

---

## 3. 拉取 ComfyUI 并安装纯 CPU 版 PyTorch

不带 `cuXXX` 后缀、使用 PyTorch 官方 CPU 索引安装，可省去 3–4 GB 的 CUDA 依赖下载：

```bash
git clone https://github.com/Comfy-Org/ComfyUI.git ~/ComfyUI
cd ~/ComfyUI

pip config set global.index-url https://mirrors.aliyun.com/pypi/simple/
python -m pip install torch torchvision --index-url https://download.pytorch.org/whl/cpu
python -m pip install -r ~/ComfyUI/requirements.txt
python -m pip install -r ~/ComfyUI/manager_requirements.txt
```

> 官方 CPU 索引慢时，可改用南京大学镜像：`--index-url https://mirror.nju.edu.cn/pytorch/whl/cpu`。CPU 索引里的 torchvision 可能比 PyPI 旧，pip 会自动选择兼容组合；它只用于流程/UI 测试，不用于出图。不要装 `torchaudio`。

验收依赖是否就绪（无卡环境下 `CUDA` 输出 `False` 属于正常现象）：

```bash
python -c "import yaml, torch, torchvision; print('PyTorch:', torch.__version__, 'CUDA:', torch.cuda.is_available())"
```

---

## 4. 使用 `--cpu` 启动并测试网页访问

> `comfyui-tui.sh` 的 CPU 测试模式默认同样写 `--listen 0.0.0.0:8188`；下面的前台测试示例只用 `--cpu`，SSH 隧道访问不受影响。

无卡环境**必须加上 `--cpu` 参数**，否则会因找不到显卡驱动报错退出：

```bash
cd ~/ComfyUI
python main.py --cpu --enable-manager
```

在**本地电脑**终端建立 SSH 端口转发：

```bash
ssh -N -L 8188:127.0.0.1:8188 你的用户名@服务器IP
```

用浏览器打开 `http://127.0.0.1:8188`，能正常加载画布且右上角出现 **Manager** 按钮即表示核心流程测试通过。

---

## 5. 测试开机自启（可选，按实例类型二选一）

确认测试命令：

```bash
ps -p 1 -o comm=
ls -d /start.d 2>/dev/null
```

* **容器平台（存在 `/start.d`）**：
  ```bash
  cat > /start.d/comfyui.sh << EOF
  #!/bin/bash
  export PATH="${HOME}/miniforge3/envs/comfyui/bin:\$PATH"
  cd "${HOME}/ComfyUI" || exit 1
  exec "${HOME}/miniforge3/envs/comfyui/bin/python" main.py --cpu --enable-manager --listen 0.0.0.0 --port 8188
  EOF
  chmod +x /start.d/comfyui.sh
  ```

* **完整云主机（输出 `systemd`）**：
  ```bash
  sudo tee /etc/systemd/system/comfyui.service > /dev/null << EOF
  [Unit]
  Description=ComfyUI CPU Test Service
  After=network.target

  [Service]
  Type=simple
  User=${USER}
  WorkingDirectory=${HOME}/ComfyUI
  ExecStart=${HOME}/miniforge3/envs/comfyui/bin/python main.py --cpu --enable-manager
  Restart=always
  RestartSec=10

  [Install]
  WantedBy=multi-user.target
  EOF

  sudo systemctl daemon-reload
  sudo systemctl enable --now comfyui
  sudo systemctl status comfyui
  ```

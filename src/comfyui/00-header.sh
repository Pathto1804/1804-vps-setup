#!/usr/bin/env bash
# ComfyUI 部署 TUI · 与 00-tui.sh 并列的第二入口
# 自包含 + 原生状态 + 动作隔离。用法：sudo -i 后 bash <(curl -fsSL .../comfyui-tui.sh)
# 默认访问方式：--listen 0.0.0.0 --port 8188；菜单 7 可切换为仅回环 + SSH 隧道。
# 不保存项目私有状态：GPU/驱动读 nvidia-smi，环境读 miniforge/env，服务读 systemd 或 /start.d，
# 端口读 ss，防火墙读 ufw，ComfyUI 读 git；用户输入的偏好只存在于本次进程。

set -euo pipefail
# 命令替换默认不继承 errexit：开启后顶层命令替换继承 -e；
# act 动作内临时关闭 -e，所有 $(ask_input*) 调用点均须显式接 || return 1 拦截输入中断。（bash >= 4.4）
shopt -s inherit_errexit

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
ROOT_HOME="$(getent passwd root 2>/dev/null | cut -d: -f6)" || ROOT_HOME="/root"
[[ -n "${ROOT_HOME}" ]] || ROOT_HOME="/root"
BK_ROOT="/root/vps-init-backups"
BK_KEEP=20

COMFY_BASE="git curl wget vim build-essential tmux htop ca-certificates ffmpeg libgl1 libglib2.0-0 aria2 nvtop ncdu pciutils iproute2"
MINIFORGE_URL="https://mirrors.tuna.tsinghua.edu.cn/github-release/conda-forge/miniforge/LatestRelease/Miniforge3-Linux-x86_64.sh"
MINIFORGE_FALLBACK="https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh"
CONDA_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/anaconda/cloud"
PIP_MIRROR="https://mirrors.aliyun.com/pypi/simple/"
PIP_MIRROR_FALLBACK="https://pypi.tuna.tsinghua.edu.cn/simple"
CPU_INDEX="https://download.pytorch.org/whl/cpu"
CPU_INDEX_FALLBACK="https://mirror.nju.edu.cn/pytorch/whl/cpu"
LINUXMIRRORS_URL="https://linuxmirrors.cn/main.sh"

MINIFORGE_DIR="${ROOT_HOME}/miniforge3"
CONDA_BIN="${MINIFORGE_DIR}/bin/conda"
MAMBA_BIN="${MINIFORGE_DIR}/bin/mamba"
ENV_DIR="${MINIFORGE_DIR}/envs/comfyui"
ENV_PY="${ENV_DIR}/bin/python"
ENV_BIN="${ENV_DIR}/bin"
COMFY_DIR="${ROOT_HOME}/ComfyUI"
COMFY_REPO="https://github.com/Comfy-Org/ComfyUI.git"
COMFY_REPO_PROXY="https://ghproxy.net/https://github.com/Comfy-Org/ComfyUI.git"

SERVICE_NAME="comfyui"
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
STARTD_DIR="/start.d"
STARTD_FILE="${STARTD_DIR}/comfyui.sh"
STARTD_LOG_DIR="${STARTD_DIR}/log"
STARTD_LOG_FILE="${STARTD_LOG_DIR}/comfyui.log"
PORT=8188

# 本次进程内的选择；不落盘
CPU_MODE=0
CPU_MODE_DECIDED=0
ACCESS_MODE=""
PY_VER="3.13"
CONDA_ENV_NAME="comfyui"
CUSTOM_TARGET_SET=0
DRIVER_CHANGED=0
AUTOSTART_CHANGED=0
TMPD=""
UI_REPLY=""
MAIN_REPLY=""
DW=0
declare -a COMFY_ARGS=()
declare -a COMFY_EXTRA_ARGS=()
declare -a CMD_WORDS=()

cleanup() {
  if [[ -n "${TMPD}" && -d "${TMPD}" ]]; then
    rm -rf -- "${TMPD}"
  fi
}
trap cleanup EXIT


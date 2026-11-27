#!/usr/bin/env bash
# 1804 VPS Setup · 00 单入口 TUI
# 自包含 + 原生状态 + 交互闸门。用法：sudo -i 后 bash <(curl -fsSL .../00-tui.sh)
# 启动即进入主菜单：只做环境前置检查与状态探测，不安装软件、不初始化系统、不写文件。
# 状态一律读系统原生来源（sshd -T / ss -tlnp / ufw / authorized_keys / fail2ban-client /
# /proc/swaps / sysctl / 20auto-upgrades），不保存项目私有运行态。
# 项目：https://raw.githubusercontent.com/Pathto1804/1804-vps-setup/main/00-tui.sh

set -euo pipefail
# 命令替换默认不继承 errexit：不开这个，$(ask_input ...) 里的 die 只终止子 shell，
# 空值会被照常写进系统配置。开启后交互读取遇 EOF/Ctrl-D 即中止脚本。（bash >= 4.4）
shopt -s inherit_errexit

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
BK_ROOT="/root/vps-init-backups"
# 备份目录保留份数（超出删最旧；bk_prune 只匹配 YYYYmmdd-HHMMSS 目录）
BK_KEEP=20
REPORT="/root/vps-init-report.md"
UA_FILE="/etc/apt/apt.conf.d/20auto-upgrades"
SSHD_CFG="/etc/ssh/sshd_config"
SSHD_D="/etc/ssh/sshd_config.d"
HARD="${SSHD_D}/01-hardening.conf"
JAIL="/etc/fail2ban/jail.local"
BBR_CONF="/etc/sysctl.d/99-bbr.conf"

BASE="sudo ca-certificates curl wget gnupg ufw fail2ban unattended-upgrades vim nano unzip htop needrestart ncdu mtr-tiny bind9-dnsutils"
TOOLS_EXTRA_DEFAULT="jq tmux lsof rsync zip"
LINUXMIRRORS_URL="https://linuxmirrors.cn/main.sh"

# 本次进程内的管理员用户（不落盘；来源见 resolve_admin_user）
ADMIN_USER=""
# authorized_keys 原子替换的临时文件；异常退出时清掉半成品
AK_TMP=""
declare -a AK_LINES=()

trap 'if [[ -n "${AK_TMP}" ]]; then rm -f -- "${AK_TMP}"; fi' EXIT

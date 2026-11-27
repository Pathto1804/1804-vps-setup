#!/usr/bin/env bash
# 单文件构建器：从 src/ 拼装生成根目录 00-tui.sh 与 comfyui-tui.sh。
# 用法：
#   bash tools/build.sh          # 重新生成根目录两个交付脚本
#   bash tools/build.sh --check  # 校验根目录脚本与 src/ 构建结果字节一致
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="build"
if [[ "${1:-}" == "--check" ]]; then
  MODE="check"
elif [[ -n "${1:-}" ]]; then
  printf '用法：%s [--check]\n' "$0" >&2
  exit 2
fi

assemble_target() {
  local out_file="$1"
  shift
  local tmp
  tmp="$(mktemp)"
  for part in "$@"; do
    cat "${ROOT}/${part}" >> "${tmp}"
  done
  if [[ "${MODE}" == "check" ]]; then
    if [[ ! -f "${ROOT}/${out_file}" ]] || ! cmp -s "${tmp}" "${ROOT}/${out_file}"; then
      rm -f -- "${tmp}"
      printf '❌ %s 与 src/ 构建产物不一致；请运行 bash tools/build.sh 重新生成\n' "${out_file}" >&2
      return 1
    fi
    rm -f -- "${tmp}"
    return 0
  fi
  mv -f -- "${tmp}" "${ROOT}/${out_file}"
  chmod +x "${ROOT}/${out_file}"
  printf '已生成 %s\n' "${out_file}"
}

declare -a BASE_PARTS=(
  "src/00-tui/00-header.sh"
  "src/lib/ui_screen.sh"
  "src/00-tui/10-probes.sh"
  "src/lib/prompts.sh"
  "src/lib/backup.sh"
  "src/00-tui/20-base.sh"
  "src/00-tui/30-users.sh"
  "src/00-tui/40-ssh_ufw.sh"
  "src/00-tui/50-fail2ban.sh"
  "src/00-tui/60-swap.sh"
  "src/00-tui/70-bbr.sh"
  "src/00-tui/80-verify_flow.sh"
  "src/00-tui/90-main.sh"
)

declare -a COMFY_PARTS=(
  "src/comfyui/00-header.sh"
  "src/lib/ui_screen.sh"
  "src/comfyui/10-probes_pkg.sh"
  "src/lib/prompts.sh"
  "src/lib/backup.sh"
  "src/comfyui/20-driver.sh"
  "src/comfyui/30-python.sh"
  "src/comfyui/40-comfyui.sh"
  "src/comfyui/50-autostart.sh"
  "src/comfyui/60-verify_deploy.sh"
  "src/comfyui/70-menus.sh"
  "src/comfyui/90-main.sh"
)

BAD=0
assemble_target "00-tui.sh" "${BASE_PARTS[@]}" || BAD=1
assemble_target "comfyui-tui.sh" "${COMFY_PARTS[@]}" || BAD=1

if (( BAD )); then
  exit 1
fi
if [[ "${MODE}" == "check" ]]; then
  printf '=== 构建产物一致性 OK ===\n'
fi

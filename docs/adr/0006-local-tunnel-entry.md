# 0006 — 本地 SSH 隧道客户端入口 `tunnel-tui.sh`

- 状态：已接受（2026-11-28）
- 关联：[ADR-0003](0003-single-tui-native-state.md)（基础入口）、[ADR-0004](0004-comfyui-entry.md)（ComfyUI 入口）、[ADR-0005](0005-modular-source-build.md)（源码模块化构建）

## 背景

`00-tui.sh` 与 `comfyui-tui.sh` 均运行在远端云主机（`root` + Debian/Ubuntu，Bash >= 4.4）。用户在启用 SSH 密钥/非 22 端口或 ComfyUI 仅回环模式后，需要在**本地电脑**建立 SSH 端口转发隧道（如 `8188:127.0.0.1:8188`）。新手常直接复制 `ssh -N -L 8188:127.0.0.1:8188 root@<IP>`，在改过端口、禁用 root、使用非默认私钥或容器平台高位端口时直接 `Permission denied`。

用户要求新增一个交互式简易 TUI 脚本：
1. 在**本地 shell** 执行（非 root，兼容 Linux / macOS / WSL / Windows Git Bash）；
2. 允许用户直接粘贴平时 SSH 连上服务器的命令，自动注入隧道与保活/失败退出参数；
3. 支持默认 `8188 -> 127.0.0.1:8188` 与自定义端口修改，且支持下载到本地或一行 raw 命令拉取执行。

## 决策

1. **第三个根目录入口 `tunnel-tui.sh`**：放在仓库根目录，与 `00-tui.sh`、`comfyui-tui.sh` 并列，保持一致的 raw 单文件形态（`.../main/tunnel-tui.sh`）与本地执行形态。
2. **定位边界与维护方式**：只运行在用户本地机器，**不要求 root、不检查 Linux 发行版/x86_64**；不负责服务端配置。由于需兼容 macOS 默认 `/bin/bash`（3.2），不共用依赖 Bash 4.4+（`inherit_errexit`、`${ans,,}`）的 `src/lib/` 构建链路，而是作为约 850 行的独立单文件直接维护。
3. **Bash 3.2+ 兼容**：条件开启 `inherit_errexit`（仅 Bash >= 4.4），不使用 `mapfile`、`${var,,}`、`declare -A` 等 Bash 4+ 特性，并对 `set -u` 空数组展开做显式非空保护。
4. **无 `eval` 安全分词**：使用纯 Bash 引号感知分词器解析用户输入的 `ssh` 命令，拒绝 `;`、`&&`、`||`、`|`、`` ` ``、`$(...)` 等多命令注入；自动识别 OpenSSH 带参选项（含组合短选项如 `-4p 2222`）并注入 `-N`、`-L`、`-o ExitOnForwardFailure=yes`、`-o ServerAliveInterval=30`、`-o ServerAliveCountMax=3`。
5. **无项目私有状态文件**：不写入 `~/.tunnel-tui.conf` 等私有配置；如需快捷选择，只读原生 `~/.ssh/config` 中的 `Host` 别名。
6. **`sync_check.sh` 与 CI 扩展**：检查 `tunnel-tui.sh` 存在性与禁私有状态文件约束，并纳入 CI 的 `bash -n` 与 `shellcheck` 检查。

## 被否的替代方案

1. **放在 `tools/tunnel-tui.sh`**：不调整根目录白名单，但用户拉取链接多一层 `tools/`，与前两个入口体验不一致。否决。
2. **用 `eval` 解析用户输入**：无法防止误粘贴含特殊字符或命令替换的输入导致本机执行意外命令。否决。

## 后果

- 根目录入口增至三个：`00-tui.sh`、`comfyui-tui.sh`（远端服务端，由 `src/` 构建生成）、`tunnel-tui.sh`（本地客户端，直接维护）。
- Windows 用户需在 **Git Bash** 或 **WSL** 中运行 `bash <(curl ...)`（PowerShell 原生不支持 `<(...)` 进程替换），文档需明确提示。

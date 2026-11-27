# 开发与验收

## 命令

```bash
bash -n 00-tui.sh && shellcheck -S warning 00-tui.sh
bash -n comfyui-tui.sh && shellcheck -S warning comfyui-tui.sh
bash tools/sync_check.sh          # 必须输出「一致性 OK」
```

无构建、无测试框架、无 CI。本地只能做语法与 ShellCheck；行为必须在真机验收。

## 改动类型与必须动作

| 改动 | 必须做的 |
|---|---|
| 任何脚本改动 | 双脚本 `bash -n` + `shellcheck -S warning` + `sync_check` |
| 改菜单编号/子菜单/默认参数 | 同批改 `features.md`、根 `README.md`、`comfyui-docs/README.md` |
| 改状态来源或写入落点 | 同批改 `architecture.md` |
| 改 `COMFY_BASE` | 同批改根 `README.md` 的 ComfyUI 包清单；`sync_check` 会比对 |
| 改默认访问/UFW/自启 | 同批改 `features.md` 与本页验收步骤；必须真机验证 |
| 新架构取舍 | 新建 `docs/adr/000N-*.md`，再回填 `architecture.md` |

## 编码约定

- `set -euo pipefail` + `shopt -s inherit_errexit` + `trap ... ERR` 在进程级生效。
- 菜单动作必须经 `act` 调用；动作内每个危险步骤显式 `|| die_action` / `if !`，不能依赖 `set -e`。
- `die` 只用于启动前置检查与输入中断；动作内失败用 `die_action`。
- 命令替换不继承 errexit：`$(ask_input ...)` 必须接 `|| { ...; return 1; }`。
- `pipefail` 下不要用 `sed | head`；先取全量输出再匹配。`ss -tln`、`ufw status`、`pip show` 都按此处理。
- 面向终端用 `log`/`warn`/`die`/`die_action`；状态行只读实时值。
- 强制 TTY；不提供 `--yes`。

## 工作区

- 根目录允许：`00-tui.sh`、`comfyui-tui.sh`、`README.md`、仓库配置。
- 文档分两套：`docs/`（基础脚本）与 `comfyui-docs/`（ComfyUI）。
- 脚手架只放 `.scratch/`（gitignore），交付前清空；不往工作区外写文件。

## 已知教训（2026-11-27 实测）

| 坑 | 规则 |
|---|---|
| 阿里云 `pytorch-wheels/cu130` 是文件浏览页，不是 PEP503 索引；`pip --extra-index-url` 报 `No matching distribution` | 默认走标准 PyPI；需要 `+cu130` 时才用官方/NJU 的 `whl` 索引 |
| 阿里云 conda 的 `conda-forge/linux-64/repodata.json` 返回 404 | conda 用清华；NJU/USTC 兜底 |
| 清华不镜像 PyTorch pip wheel（两条常见路径均 404） | 不要假设清华能替代 PyTorch 索引 |
| cu130 索引没有 `torchaudio`；ComfyUI `requirements.txt` 只要 torch/torchvision | 默认不装 torchaudio |
| PyPI `torch 2.15.0` 元数据依赖 `nvidia-*-cu13`，即 CUDA 13 | GPU 模式要求驱动 >=580；运行时用 `torch.version.cuda` 复核 |
| CPU 索引的 torchvision 可能停留在旧版本（0.21.0+cpu），与最新 CPU torch 不一定同版 | CPU 模式让 pip 从 CPU 索引自行解析兼容组合；只用于流程/UI 测试 |
| 容器实例 PID 1 不是 systemd | 自启写 `/start.d/comfyui.sh`；不要用 systemctl |
| 驱动装完不重启，torch 装了也跑不起来 | 驱动安装后停流程，提示 reboot；不自动重启 |
| 默认 listen 无鉴权 | 标准部署开头打印一次风险；菜单 7 保留隧道后备 |

## 真机验收

### CPU 实例（Ubuntu 22.04，无 GPU）

1. `sudo -i` → 一行命令 → 菜单 `0` → 确认 Snapshot → 基础包 → Miniforge → 3.13 → ComfyUI → CPU torch（官方 CPU 索引）→ requirements → systemd。
2. 检查 `systemctl is-active comfyui`、`ss -tln | grep 8188`、`curl -fsS http://127.0.0.1:8188/`。
3. 本地 `ssh -N -L 8188:127.0.0.1:8188 root@IP`，浏览器打开画布 + Manager。
4. 重跑 `0`：所有步骤应显示已满足；不重复下载、不重写 unit。

### GPU 实例

1. 驱动 >=580：菜单 `0` 跳过驱动，装 CUDA 13 torch，`torch.cuda.is_available()` 为 True。
2. 驱动 <580：菜单 `3` 安装驱动后停流程；重启重跑，终检通过。
3. 默认 listen：终检打印 `http://<公网IP>:8188`；云安全组放行 8188；UFW active 时已放行。
4. 菜单 `7` 切 tunnel：unit 移除 `--listen`，本地隧道可访问，Manager 界面装插件恢复。

### 失败路径

- UFW inactive + listen：警告但继续，终检黄灯。
- Git 工作区有改动：更新动作拒绝并提示 `git status`。
- 服务停掉：终检查红，不自动重启。
- 驱动安装失败：默认流程中止，TUI 继续可用。
# 0004 — ComfyUI 第二入口与双文档树

- 状态：已接受（2026-11-27）；源码组织与构建链路已按 [ADR-0005](0005-modular-source-build.md) 演进（业务边界与运行时约束不变）
- 关联：[ADR-0003](0003-single-tui-native-state.md)（基础脚本的单入口与原生状态）、[ADR-0005](0005-modular-source-build.md)（源码模块化与单文件构建）、[comfyui-docs/codewiki](../../comfyui-docs/codewiki/README.md)、[docs/codewiki/terms.md](../codewiki/terms.md)

## 背景

仓库原本只有 `00-tui.sh`，负责 Debian/Ubuntu 的安全基线与日常运维。作者另有一份国内云算力平台部署 ComfyUI 的手动指南（清华 Miniforge、conda、PyPI、PyTorch、ComfyUI、模型、自启），希望把它变成与基础脚本同形态的第二入口：一行的 raw 执行、默认流程 + 逐项菜单、原生状态、不保存项目私有配置。

用户明确要求：

1. 新脚本与 `00-tui.sh` **同级**，是两个不同的脚本，不合并、不做转发壳。
2. `docs/` 与 `codewiki` 也维护**两套**，与两个脚本对应。
3. 默认访问方式为 **`--listen 0.0.0.0:8188`**，SSH 隧道作为后备。

本决策同时修正了旧指南里会直接失败的命令（见“迁移时的事实修正”）。

## 决策

1. **第二入口** `comfyui-tui.sh` 放在仓库根目录，与 `00-tui.sh` 并列，单文件自包含；不 `source` 仓库文件，UI 原语与备份函数允许重复。
2. **双文档树**：`docs/` 继续服务基础脚本；`comfyui-docs/` 服务 ComfyUI 脚本，包含 README、两份指南与 `codewiki/`。共享术语只在 `docs/codewiki/terms.md` 定义，`comfyui-docs/codewiki/terms.md` 只写专属术语并链接回去。ADR 共用 `docs/adr/`，本页为仓库级决策。
3. **平台优先级**：`00-tui.sh` 保持 Debian 12/13 一等；`comfyui-tui.sh` 以 Ubuntu 22.04/24.04 为一等，Debian 12/13 仅走 NVIDIA 官方源、兼容但未逐版本验证。
4. **root-only**：`sudo -i` 后运行，安装到 `/root`；systemd `User=root`。非 root/多用户不在 v1 范围。
5. **驱动门槛**：GPU 模式要求 `nvidia-smi` CUDA Version >= 13.0（驱动 >=580）。不足只提供升级路径，装完停流程等重启；**不提供 `cu126` 回退**。
6. **默认 listen**：unit/start.d 写 `--listen 0.0.0.0 --port 8188`；UFW active 时默认流程问一次并放行 8188，UFW inactive 时不启用；菜单 7 可切换为仅回环 + SSH 隧道。标准部署开头打印一次无鉴权风险。
7. **镜像链路**：Miniforge/conda 清华；PyPI/torch/torchvision 阿里（清华兜底）；CPU 模式 PyTorch 官方 CPU 索引（南京仅可选）；驱动 NVIDIA 官方源；模型 ModelScope/hf-mirror。NJU PyTorch 索引不是默认路径。
8. **默认组件**：不装 `torchaudio`，不下载模型；两者放菜单 5/6 手动触发。
9. **自启**：PID 1 是 systemd 时写 `comfyui.service`；否则 `/start.d` 存在时写 `comfyui.sh`；两者都没有则跳过并警告。
10. **无项目私有状态**：GPU/驱动读 `nvidia-smi`，环境读 Miniforge/env，服务读 systemd 或 `/start.d`，访问方式读 unit/start.d 的 `ExecStart`，端口读 `ss`，防火墙读 `ufw`。不写 `comfyui.conf` 或进度标记。

## 迁移时的事实修正（2026-11-27 实测）

原指南中的三条命令不能照抄：

1. `pip install ... --extra-index-url https://mirrors.aliyun.com/pytorch-wheels/cu130`：阿里该地址是文件浏览页，不是 PEP503 索引；`/cu130/torch/` 404，pip 报 `No matching distribution found`。标准 PyPI 的 `torch 2.15.0` 元数据依赖 `nvidia-*-cu13`，默认已是 CUDA 13，直接 `pip install torch torchvision` 即可。
2. `pip install ... torchaudio`：cu130 索引没有 torchaudio，ComfyUI `requirements.txt` 也不需要；PyPI 最新 torchaudio 2.11 与 torch 2.15 存在 ABI 风险。默认不装。
3. `.condarc` 指向阿里云 `anaconda/cloud`：`conda-forge/linux-64/repodata.json` 返回 404；改用清华（NJU/USTC 兜底）。

NJU PyTorch 索引只在需要 `+cu130` 本地版本或 CPU 索引官方源不可达时作为可选路径，不进入默认流程。

## 被否的替代方案

1. **合并进 `00-tui.sh`**：基础脚本已约 3260 行且是唯一能锁死登录的脚本；混入 ML 栈会扩大审查面、混合不同平台与受众。否决。
2. **另开仓库**：一行命令、文档、ADR、sync_check 会分裂成两套入口；用户明确要求同级并存。否决。
3. **抽共享 `lib.sh` 供两个 raw 脚本 source**：raw 单文件形态无法定位同级文件，且与 ADR-0003 的自包含约束冲突。否决。
4. **默认 NJU PyTorch 索引**：把指南里坏掉的阿里索引直接换成南大，属于过度设计；标准 PyPI 已够用。否决为默认。
5. **保留 `cu126` 回退**：多一个 torch 版本矩阵与旧驱动验收面；v1 只支持 580+。否决。
6. **非 root/多用户安装**：要处理 `SUDO_USER`、`HOME`、systemd `User=`、文件属主，收益低。否决。
7. **默认 SSH 隧道**：用户明确选择默认 listen。记录风险，不反复劝阻；隧道保留为菜单后备。

## 后果

- **有意失去**：旧驱动（<580）机器不能直接用本脚本；需要 `+cu130` 精确本地版本或 cu126 时只能按文档手动处理。
- **默认暴露**：`0.0.0.0:8188` 无鉴权；云安全组与 UFW 是唯一边界。风险由用户承担，脚本只打印提示。
- **重复代码**：两个单文件脚本各有一份 UI 原语与备份函数（约 200 行），一致性靠 `sync_check` 与人工审查。
- **双文档树**：`docs/` 与 `comfyui-docs/` 需要同批维护；共享术语只在一处定义，避免两套定义打架。
- **`sync_check` 扩展**：检查两个入口、旧步骤脚本不复活、`inherit_errexit`、私有状态文件禁令、`COMFY_BASE` 与根 README 一致。

## 重评条件

- 脚本超过约 2500 行，或出现必须按发行版分叉的大段逻辑。
- 出现真实的非 root/多用户需求。
- 云平台要求旧驱动（<580）或必须使用 `cu126`。
- 双文档树出现无法通过“共享术语单源”控制的漂移。
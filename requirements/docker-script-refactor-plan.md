# Docker 安装脚本重构需求与实施计划

## 背景
当前 `install-docker.sh` 仅支持非交互在线安装，依赖外网下载。  
为适配更多场景，需要扩展为多模式脚本，支持在线安装、离线安装、离线包准备、卸载。

## 目标
将脚本统一为参数化入口，支持以下模式：

1. `online`：在线安装（保留现有能力）
2. `offline`：离线安装（无外网）
3. `prepare-offline`：下载并准备离线安装包
4. # `uninstall`：卸载 Docker 相关组件

## 已确认需求

### 1) online 在线安装
- 继续保留当前功能：从外网下载 Docker/Compose 并安装。
- 需要重构为函数化、参数化实现。

### 2) offline 离线安装
- 在无法联网环境下安装。
- 离线目录规范（已确认）：
  - `docker-<docker-version>.tgz`
  - `docker-compose-linux-x86_64`
  - 可选：`SHA256SUMS`

### 3) uninstall 卸载
- 反向操作：停止服务、禁用服务、删除安装文件和相关配置。
- 默认不删除 Docker 数据目录。
- 仅在 `--purge-data` 时删除 `data-root`。

### 4) prepare-offline 离线包准备（新增）
- 下载离线安装所需文件（Docker tgz、Docker Compose）。
- 按 offline 要求的文件名与目录保存。
- 提供下载进度可视化。
- 防止下载中断导致后续安装失败：
  - 使用 `.part` 临时文件
  - 支持断点续传与重试
  - 下载后完整性校验
  - 输出下载结果报告

## 参数设计（规划）

统一入口：
`install-docker.sh --mode <online|offline|prepare-offline|uninstall> [options]`

通用参数：
- `--docker-version`（默认：`28.4.0`）
- `--compose-version`（默认：`v2.27.0`）
- `--data-root`（默认：`/data/docker`）
- `--install-dir`（默认：`/usr/local/bin`）
- `--force`
- `--help`

模式参数：
- `online`：`--mirror-url`（可选）
- `offline`：`--offline-dir`（必填）
- `prepare-offline`：`--offline-dir`（必填），`--mirror-url`（可选）
- `uninstall`：`--purge-data`（可选）

## 关键实现原则

### 安全与可靠性
- 启用：`set -Eeuo pipefail`、`IFS=$'\n\t'`
- 变量引用统一加引号。
- 使用 `mktemp -d` + `trap`，避免固定临时目录和危险删除。
- 禁止 `chmod +x /usr/local/bin/*` 这类全目录操作。
- 删除操作采用白名单，避免误删。

### 下载与校验
- 下载使用 `curl --fail --location --retry ... --progress-bar`
- 下载到 `.part`，成功后原子重命名。
- `prepare-offline` 下载后生成 `SHA256SUMS` 与下载报告。
- `offline` 校验策略（已确认）：
  - 存在 `SHA256SUMS` 则校验
  - 不存在仅 warning，不中断

### systemd 与配置
- 写入 Docker 配置与服务时保留可回滚思路。
- 服务变更后执行 `daemon-reload` 并验证运行状态。

## 脚本结构规划

- `main`
- `parse_args`
- `require_root`
- `check_dependencies`
- `prepare_tmpdir` / `cleanup`
- `install_online`
- `prepare_offline_packages`
- `install_offline`
- `install_binaries`
- `write_daemon_config`
- `install_systemd_unit`
- `start_and_verify`
- `uninstall_docker`
- `print_summary`

## 验证计划

静态检查：
1. `bash -n install-docker.sh`
2. `shellcheck install-docker.sh`（若可用）
3. `shfmt -d -i 2 -ci install-docker.sh`（若可用）

场景验证：
1. `online` 首次安装与重复执行
2. `prepare-offline` 下载与校验报告
3. `offline` 无网安装
4. `uninstall` 卸载
5. `uninstall --purge-data` 全量清理

## 验收标准

- 四种模式均可按参数正确执行。
- 离线安装不访问外网。
- 下载过程可视化，且能识别中断/不完整文件。
- 失败有清晰错误输出，成功有摘要结果。
- 重复执行具备幂等性或可恢复性。

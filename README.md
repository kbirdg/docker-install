# Docker Offline Installer

用于在 Linux systemd 主机上安装、准备离线包和卸载 Docker Engine 与 Docker Compose 的 Bash 脚本。

当前默认版本：

- Docker Engine: `28.4.0`
- Docker Compose: `v2.27.0`
- 默认数据目录: `/data/docker`
- 默认安装目录: `/usr/local/bin`
- 支持架构: `x86_64`、`aarch64`

> 注意：`online`、`offline`、`uninstall` 模式会修改系统路径、Docker 配置和 systemd 服务。不要在非目标机器上随意执行安装或卸载命令。

## 文件清单

当前目录包含双架构离线包：

```text
docker-install.sh
docker-28.4.0-x86_64.tgz
docker-compose-linux-x86_64
docker-28.4.0-aarch64.tgz
docker-compose-linux-aarch64
SHA256SUMS
download-report.txt
```

离线包命名规则：

- Docker: `docker-<docker-version>-<arch>.tgz`
- Compose: `docker-compose-linux-<arch>`
- 校验文件: `SHA256SUMS`

其中 `<arch>` 取值为：

- `x86_64`
- `aarch64`

## 环境要求

目标安装主机需要：

- Linux
- systemd
- root 权限
- `tar`
- `install`
- `sha256sum`
- `systemctl`

准备离线包时额外需要：

- `curl`

## 参数说明

```bash
bash docker-install.sh --mode <online|offline|prepare-offline|uninstall> [options]
```

通用参数：

```text
--docker-version <version>   Docker version，默认 28.4.0
--compose-version <version>  Docker Compose version，默认 v2.27.0
--arch <auto|x86_64|aarch64>
                             目标架构，默认 auto
--data-root <path>           Docker data-root，默认 /data/docker
--install-dir <path>         二进制安装目录，默认 /usr/local/bin
--force                      覆盖已存在文件
--help                       显示帮助
```

架构参数说明：

- `auto` 会使用 `uname -m` 自动识别当前机器架构。
- `amd64` 会归一化为 `x86_64`。
- `arm64` 会归一化为 `aarch64`。
- 不支持 32 位 ARM。

## 离线安装

将整个目录复制到目标 Linux 主机后执行。

x86_64 主机：

```bash
sudo bash docker-install.sh --mode offline --arch x86_64 --offline-dir .
```

ARM64/aarch64 主机：

```bash
sudo bash docker-install.sh --mode offline --arch aarch64 --offline-dir .
```

如果目标机器的 `uname -m` 能正确返回 `x86_64` 或 `aarch64`，也可以使用自动识别：

```bash
sudo bash docker-install.sh --mode offline --offline-dir .
```

安装过程会：

- 校验 `SHA256SUMS` 中当前架构需要的 Docker 和 Compose 包。
- 解压 Docker 静态二进制。
- 将 Docker 二进制安装到 `--install-dir`。
- 将 Compose 安装为 `docker-compose`。
- 写入 `/etc/docker/daemon.json`。
- 写入 `/etc/systemd/system/docker.service`。
- 启动或重启 Docker 服务，并检查服务状态。

## 准备离线包

在有网络的机器上准备指定架构离线包。

准备 x86_64：

```bash
bash docker-install.sh \
  --mode prepare-offline \
  --arch x86_64 \
  --offline-dir . \
  --mirror-url https://download.docker.com
```

准备 ARM64/aarch64：

```bash
bash docker-install.sh \
  --mode prepare-offline \
  --arch aarch64 \
  --offline-dir . \
  --mirror-url https://download.docker.com
```

脚本会下载：

- `docker-<version>-<arch>.tgz`
- `docker-compose-linux-<arch>`

并生成或更新：

- `SHA256SUMS`
- `download-report.txt`

同一目录中可以同时保存 x86_64 和 aarch64 的离线包。`SHA256SUMS` 会包含目录中已存在的两种架构包。

## 在线安装

在目标 Linux 主机上直接联网安装。

```bash
sudo bash docker-install.sh --mode online --arch auto
```

指定架构：

```bash
sudo bash docker-install.sh --mode online --arch aarch64
```

指定 Docker 数据目录：

```bash
sudo bash docker-install.sh \
  --mode online \
  --arch auto \
  --data-root /data/docker
```

## 卸载

默认卸载 Docker 相关二进制、systemd unit 和 Docker 配置，但保留数据目录。

```bash
sudo bash docker-install.sh --mode uninstall
```

同时删除 `--data-root`：

```bash
sudo bash docker-install.sh --mode uninstall --purge-data
```

`--purge-data` 会删除 Docker 数据目录，可能导致镜像、容器、卷等数据丢失。脚本会拒绝直接删除 `/` 和 `/data`。

## 校验离线包

在当前目录校验所有离线包：

```bash
sha256sum -c SHA256SUMS
```

预期输出类似：

```text
docker-28.4.0-x86_64.tgz: OK
docker-compose-linux-x86_64: OK
docker-28.4.0-aarch64.tgz: OK
docker-compose-linux-aarch64: OK
```

查看 Docker tgz 结构：

```bash
tar -tzf docker-28.4.0-x86_64.tgz | head
tar -tzf docker-28.4.0-aarch64.tgz | head
```

## 本地静态检查

语法检查：

```bash
bash -n docker-install.sh
```

回归测试：

```bash
bash tests/arch-options.sh
```

可选检查工具：

```bash
shellcheck docker-install.sh
shfmt -d -i 2 -ci docker-install.sh
```

如果本机没有安装 `shellcheck` 或 `shfmt`，可以跳过这两项。

## 常见问题

### 离线安装提示找不到包

确认 `--arch` 与离线包架构一致。例如 ARM64 安装需要：

```text
docker-28.4.0-aarch64.tgz
docker-compose-linux-aarch64
```

### SHA256SUMS 缺少当前架构条目

重新准备一次对应架构离线包：

```bash
bash docker-install.sh --mode prepare-offline --arch aarch64 --offline-dir .
```

脚本会重新生成包含当前目录双架构包的 `SHA256SUMS`。

### 当前机器不是 Linux

可以在 macOS 上准备离线包和运行静态检查，但不能执行安装或卸载。安装和卸载需要 Linux systemd 环境。

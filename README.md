# Mundo X Node

`proxy-node` 的 Linux 安装与管理入口，支持 **AMD64 / ARM64 自动识别**。首次安装和后续更新使用同一条命令；安装后通过 `mnode` 管理节点。

## 快速开始

在服务器的 SSH 交互终端中，用 **root** 执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/basumobai/moudu-X-used/main/install.sh)
```

如果当前不是 root，先执行 `sudo -i`，再运行上面的命令。

首次安装按提示填写以下信息：

| 信息 | 填写要求 |
| --- | --- |
| 面板后端地址 | 以 `http://` 或 `https://` 开头，填写节点实际连接的后端地址 |
| API KEY | 面板提供的节点通信密钥 |
| Node ID | 面板里的节点编号，必须是大于 0 的整数，默认 `1` |
| 协议 | 与面板节点配置对应，默认 `mx` |

配置菜单提供 `mx`、`vless`、`vmess`、`trojan`、`anytls`、`jatp`、`socks`、`shadowsocks`、`v2node` 选项，具体使用哪一项取决于面板接口和节点配置。

脚本会注册服务及 `mnode` 命令，首次安装默认启动节点，完成后自动进入管理菜单。一行入口默认不安装 WARP 或 Brutal。

安装后检查：

```bash
mnode status
mnode log
```

systemd 环境下，`mnode log` 会持续跟踪日志，按 `Ctrl+C` 退出日志查看。

## 系统与架构

当前提供 Linux 64 位二进制：

| `uname -m` 输出 | 自动选择 | 二进制所在仓库 |
| --- | --- | --- |
| `x86_64` / `amd64` | Linux AMD64 | [basumobai/MXnode-amd64](https://github.com/basumobai/MXnode-amd64) |
| `aarch64` / `arm64` | Linux ARM64 | [basumobai/moudu-X-used](https://github.com/basumobai/moudu-X-used) |

两个仓库的 `install.sh` 内容相同。无论从哪个仓库看到本说明，都可以使用上面的统一命令。

执行一行命令前需要有 Bash、curl 和可用的 HTTPS 连接。入口会按需通过 `apt-get`、`dnf`、`yum` 或 `apk` 安装 curl、CA 证书和 coreutils 等必要工具。服务注册优先使用 systemd，其次是 OpenRC、supervisord；未检测到支持的服务管理器时会直接启动进程，此时需自行安排开机启动和异常退出后的重启。

一行入口会拒绝其他 CPU 架构及非 Linux 系统；当前没有提供 32 位或 BSD 二进制。

## 更新现有节点

**重新执行同一条安装命令即可。** 更新不会重新询问面板地址、密钥或节点编号。

更新流程为：

1. 根据 CPU 架构下载对应程序和共用管理脚本，分别校验 SHA-256。
2. 检查二进制架构，准备完整的新文件，并备份当前二进制。
3. 停止旧服务；确认旧进程已退出后，替换程序并同步 `mnode`。
4. 按要求恢复节点的启停状态。

现有 `config.json`、`node_config.defaults.json`、证书及其他安装目录中的自定义文件会保留。运行中的节点更新时会短暂停止并重新启动。

### 更新后的状态

更新默认采用 `keep`：原本运行则重新启动，原本停止则保持停止。可通过环境变量指定：

| `PROXY_NODE_POST_INSTALL_STATE` | 更新完成后的行为 |
| --- | --- |
| `keep` | 保持更新前的运行或停止状态，默认值 |
| `start` | 启动服务 |
| `stop` | 保持服务停止 |

例如，更新后明确启动：

```bash
PROXY_NODE_POST_INSTALL_STATE=start bash <(curl -fsSL https://raw.githubusercontent.com/basumobai/moudu-X-used/main/install.sh)
```

已有 `/opt/proxy-node/config.json` 的节点可以在没有交互终端的环境中更新；完成后不会打开管理菜单。首次安装需要交互终端填写配置。

### 备份与回退

替换前，当前二进制保存为 `/opt/proxy-node/proxy-node.bak`。**每次更新都会覆盖这份备份**；它只保存上一次替换前的程序，不包含配置和证书。

下载、SHA-256 校验、架构检查、新文件准备或旧二进制备份失败时，更新会在停止旧服务前退出。旧服务无法停止时会取消替换。新程序启动后的运行问题需要通过日志排查，脚本没有自动健康检查回滚。

需要回退已有的二进制备份时，用 root 执行以下命令。该操作会停止节点、恢复备份并重新启动：

```bash
(
  set -e
  test -s /opt/proxy-node/proxy-node.bak || {
    echo "未找到有效的旧二进制备份" >&2
    exit 1
  }
  mnode stop
  install -m755 /opt/proxy-node/proxy-node.bak /opt/proxy-node/proxy-node
  mnode start
)
```

## 管理命令

输入 `mnode` 打开菜单，也可直接执行下列命令：

| 命令 | 作用 |
| --- | --- |
| `mnode status` | 查看运行状态和配置位置 |
| `mnode start` | 启动服务，需要 root |
| `mnode stop` | 停止服务，需要 root |
| `mnode restart` | 停止后重新启动，需要 root |
| `mnode log` | 查看日志；systemd 环境下持续跟踪，其他环境显示最近 100 行 |
| `mnode config` | 确认后交互重建配置并重启，需要 root |
| `mnode uninstall` | 确认后停止并删除服务、整个安装目录及管理命令，需要 root |

`mnode config` 会重新生成 **`config.json` 和 `node_config.defaults.json`**。运行前请自行备份这两个文件，尤其是已有多节点或 Reality 自定义配置时。脚本会尝试将旧主配置复制为 `config.json.bak`，这份固定文件会被后续操作覆盖。

仅修改已有配置中的个别字段时，可直接编辑对应文件，然后执行 `mnode restart`。卸载会删除安装目录中的配置与证书，如需保留，先自行备份安装目录。

## 文件与路径

### 仓库文件

| 文件 | 用途 |
| --- | --- |
| `install.sh` | 统一联网安装入口，自动识别架构并校验下载文件 |
| `onekey.sh` | 同目录交互安装、更新及 `mnode` 管理脚本 |
| `install-local.sh` | 原上传的标准本地安装脚本，生成占位配置 |
| `proxy-node` | 本仓库对应架构的二进制；两个仓库中的程序不能互换 |
| `SHA256SUMS` | 本仓库二进制与脚本的 SHA-256 清单 |

一行入口直接下载文件，不再使用旧版 `proxy.zip` 安装包。

### 安装后的路径

| 路径 | 用途 |
| --- | --- |
| `/opt/proxy-node/proxy-node` | 节点程序 |
| `/opt/proxy-node/config.json` | 主配置，包括面板地址、密钥和节点信息 |
| `/opt/proxy-node/node_config.defaults.json` | 本地节点补全配置，例如 Reality 参数 |
| `/opt/proxy-node/cert.pem`、`key.pem` | 默认配置中指定的证书与私钥路径 |
| `/opt/proxy-node/mnode` | 安装后的管理脚本 |
| `/usr/local/bin/mnode` | 管理命令链接；注册时也可能回退到 `/usr/bin/mnode` |
| `/opt/proxy-node/proxy-node.bak` | 更新前的二进制备份 |
| `/var/log/proxy-node.log` | OpenRC、supervisord 或直接启动进程使用的日志文件 |

systemd 服务名为 `proxy-node`，使用 journal 保存日志，可直接运行：

```bash
journalctl -u proxy-node -f --no-pager -n 100
```

## 本地安装

下载或克隆与服务器架构对应的仓库，将 `proxy-node` 和安装脚本放在同一目录。在仓库目录检查文件：

```bash
sha256sum -c SHA256SUMS
```

用 root 交互安装并注册 `mnode`：

```bash
bash onekey.sh
```

需要先生成占位配置、之后手动填写时：

```bash
bash install-local.sh
```

标准本地安装脚本默认保留更新前的启停状态，也不会注册 `mnode`。填写 `/opt/proxy-node/config.json` 后，按脚本输出的服务管理命令启动。该脚本另有可选的 WARP / Brutal 安装流程，按需选择；这些选项不属于统一入口的交互流程。

## 常见问题

### 找不到 Bash 或 curl

先安装它们。Debian / Ubuntu 可用：

```bash
apt-get update
apt-get install -y bash curl ca-certificates
```

Alpine 可用：

```bash
apk add --no-cache bash curl ca-certificates
```

随后在 Bash 中重新执行一行安装命令。

### 提示“首次安装需要交互终端”

通过正常的 SSH 终端登录后执行命令，让脚本能读取配置输入。首次安装不能只通过无交互的任务执行器完成。

### 提示架构不匹配或 Exec format error

先用 `uname -m` 确认架构，再使用统一安装入口。手动运行本地脚本时，检查同目录的 `proxy-node` 是否来自表格中对应的仓库。

### 下载失败或 SHA-256 校验失败

检查服务器到 `raw.githubusercontent.com` 的 HTTPS 连通性及 CA 证书，再重新执行安装命令。保留校验流程；不要自行删掉校验步骤来强行安装。

### 安装后节点没有正常连接面板

先查看 `mnode status` 和 `mnode log`，核对面板后端地址、API KEY、节点编号和协议，以及实际需要的证书或本地补全字段。修改配置后执行 `mnode restart`。正常更新已有节点时，无需使用 `mnode config` 重新生成配置。

### 提示 mnode: command not found

确认 `/opt/proxy-node/mnode` 已存在，可以先通过完整路径查看状态：

```bash
bash /opt/proxy-node/mnode status
```

再检查 `/usr/local/bin` 是否在 `PATH` 中，以及 `/usr/local/bin/mnode` 或 `/usr/bin/mnode` 链接是否存在。

## 当前下载版本与维护

当前统一入口使用 2026-10-02 上传的两个二进制。下载地址固定到以下提交，避免脚本与二进制在更新期间混用：

| 文件 | 固定来源提交 |
| --- | --- |
| AMD64 `proxy-node` | [MXnode-amd64 · 6e36d9f](https://github.com/basumobai/MXnode-amd64/commit/6e36d9feb6136fb502c318e62ba23ce09b54242f) |
| ARM64 `proxy-node` | [moudu-X-used · 76849f2](https://github.com/basumobai/moudu-X-used/commit/76849f2148fe736174847c7e40189444f6783857) |
| 共用 `onekey.sh` | [moudu-X-used · 6831ac5](https://github.com/basumobai/moudu-X-used/commit/6831ac510a16acf7cbd9b3d576e9d2e57139bdc0) |

维护新版本时：

1. 上传对应架构的二进制，核对其 ELF 架构，并计算 SHA-256。
2. 更新 `install.sh` 中对应的 `BINARY_URL` 提交与 `BINARY_SHA256`。
3. 修改共用管理脚本时，先提交新的 `onekey.sh`，再更新入口的 `MANAGER_URL` 和 `MANAGER_SHA256`。
4. 同步两个仓库的统一入口和管理脚本；各仓库的 `SHA256SUMS` 使用本仓库文件的校验值。
5. 检查首次安装、已有配置更新、启停状态保留及校验失败时的退出行为。

仅上传新二进制不会改变入口所固定的版本；需要一并同步下载提交和校验值。不要在公开的 README、配置示例或排错日志中填写实际 API KEY 或私钥。

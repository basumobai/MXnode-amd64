# Mundo X Node

Linux AMD64 / ARM64 共用一个安装入口。两个仓库提供相同的 `install.sh`，自动识别服务器架构。

## 一行安装或更新

在 SSH 交互终端内用 root 执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/basumobai/moudu-X-used/main/install.sh)
```

| `uname -m` | 下载的新版程序 | 上传日期 |
| --- | --- | --- |
| `x86_64` / `amd64` | [MXnode-amd64/proxy-node](https://github.com/basumobai/MXnode-amd64/blob/main/proxy-node) | 2026-10-02 |
| `aarch64` / `arm64` | [moudu-X-used/proxy-node](https://github.com/basumobai/moudu-X-used/blob/main/proxy-node) | 2026-10-02 |

入口直接下载对应二进制和共用的管理脚本，无需 ZIP。下载地址固定到已核对的提交，并分别校验 SHA-256；架构不匹配或下载、校验失败时，不会停止旧服务。不支持的架构会直接停止安装。

首次安装交互填写面板地址、API KEY、节点 ID 和协议，注册服务与 `mnode`，默认启动；WARP 和 Brutal 默认不安装。完成后自动进入管理菜单。

## 管理命令

```bash
mnode
```

也可使用 `mnode status`、`mnode start`、`mnode stop`、`mnode restart`、`mnode log`。

## 更新现有节点

重新执行同一条安装命令即可，无需重新填写配置。

更新保留 `/opt/proxy-node/config.json`、`node_config.defaults.json`、证书和其他现有文件。默认保持原来的启停状态：运行中的节点更新后重新启动，已停止的节点保持停止。替换前会保存旧二进制到 `/opt/proxy-node/proxy-node.bak`（每次更新覆盖上一次备份），并先准备新文件再停止旧服务。

需要指定更新后的状态时使用：

```bash
PROXY_NODE_POST_INSTALL_STATE=start bash <(curl -fsSL https://raw.githubusercontent.com/basumobai/moudu-X-used/main/install.sh)
```

也可把 `start` 改成 `stop` 或 `keep`。已有配置的节点可在无交互终端的环境中更新，完成后不会打开菜单。

## 本地文件

每个仓库根目录的 `proxy-node` 只对应该仓库的架构。原上传的本地安装脚本保留为 `install-local.sh`：

```bash
sudo bash install-local.sh
```

此方式只生成占位配置，填写完成后再启动服务。如需交互生成配置及注册 `mnode`，可在同目录运行 `sudo bash onekey.sh`。当前提供的二进制均为 Linux，未提供 BSD 安装包。

本仓库的文件可通过 `sha256sum -c SHA256SUMS` 校验。维护新版本时须同步两个仓库的 `install.sh`，更新其中对应的二进制提交和校验值；管理脚本也使用固定提交与独立校验值。

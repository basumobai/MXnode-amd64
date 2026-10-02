#!/usr/bin/env bash
# One entry point for Linux AMD64 and ARM64; all downloaded files are SHA-256 checked.
set -Eeuo pipefail

MANAGER_URL="https://raw.githubusercontent.com/basumobai/moudu-X-used/6831ac510a16acf7cbd9b3d576e9d2e57139bdc0/onekey.sh"
MANAGER_SHA256="1b88ec412d309af6adf492bbf93186c3f7336da79384b157b7967a8ab0457683"

info() { printf '[+] %s\n' "$*"; }
die() { printf '[-] %s\n' "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 运行此安装命令"
[[ "$(uname -s)" == Linux ]] || die "当前安装入口仅支持 Linux"
case "$(uname -m)" in
  x86_64|amd64)
    ARCH=amd64
    BINARY_URL="https://raw.githubusercontent.com/basumobai/MXnode-amd64/6e36d9feb6136fb502c318e62ba23ce09b54242f/proxy-node"
    BINARY_SHA256="c7965d48c5d07d5e55da85c8c16d7805dbff674f8cf87f9dfc53f5e3aedf132b"
    ;;
  aarch64|arm64)
    ARCH=arm64
    BINARY_URL="https://raw.githubusercontent.com/basumobai/moudu-X-used/76849f2148fe736174847c7e40189444f6783857/proxy-node"
    BINARY_SHA256="c0c3435f4321a164c98226261789b307568606b55c34e3d653fa9e15daacdd5c"
    ;;
  *) die "不支持的 CPU 架构: $(uname -m)；当前提供 AMD64 和 ARM64" ;;
esac

install_dependencies() {
  local missing=()
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || missing+=(downloader)
  command -v sha256sum >/dev/null 2>&1 || missing+=(sha256sum)
  command -v od >/dev/null 2>&1 || missing+=(od)
  ((${#missing[@]} == 0)) && return 0

  info "第 1/3 步：安装必要工具"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl coreutils
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y ca-certificates curl coreutils
  elif command -v yum >/dev/null 2>&1; then
    yum install -y ca-certificates curl coreutils
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache ca-certificates curl coreutils bash
  else
    die "请先安装 curl 或 wget，以及 sha256sum、od"
  fi
}

download_verified() {
  local url="$1" output="$2" expected="$3" actual
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --connect-timeout 15 "$url" -o "$output"
  elif command -v wget >/dev/null 2>&1; then
    wget --tries=3 --timeout=15 -O "$output" "$url"
  else
    die "没有可用的下载工具"
  fi
  actual="$(sha256sum "$output")"
  [[ "${actual%% *}" == "$expected" ]] || die "$(basename "$output") 校验失败，已停止安装/更新"
}

has_tty=0
if (: </dev/tty) 2>/dev/null; then has_tty=1; fi
if [[ "$has_tty" -eq 0 && ! -f /opt/proxy-node/config.json ]]; then
  die "首次安装需要交互终端，请在 SSH 终端内执行一行安装命令"
fi

install_dependencies
work_dir="$(mktemp -d /tmp/mnode-install.XXXXXX)"
trap 'rm -rf -- "$work_dir"' EXIT
info "已识别架构: Linux ${ARCH}"
info "第 2/3 步：下载并校验对应架构的新版程序和管理脚本"
download_verified "$BINARY_URL" "$work_dir/proxy-node" "$BINARY_SHA256"
download_verified "$MANAGER_URL" "$work_dir/onekey.sh" "$MANAGER_SHA256"
chmod +x "$work_dir/proxy-node" "$work_dir/onekey.sh"

info "第 3/3 步：安装/更新服务并注册 mnode"
if [[ "$has_tty" -eq 1 ]]; then
  bash "$work_dir/onekey.sh" "$@" </dev/tty
else
  bash "$work_dir/onekey.sh" "$@"
fi

command -v mnode >/dev/null 2>&1 || die "安装程序已结束，但未找到 mnode 命令"
info "完成，以后输入 mnode 即可管理节点"
if [[ "$has_tty" -eq 1 ]]; then
  mnode </dev/tty
fi

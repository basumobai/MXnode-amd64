#!/bin/sh
# POSIX preamble - re-exec with bash if available
if [ -z "${BASH_VERSION:-}" ]; then
  if command -v bash >/dev/null 2>&1; then
    exec bash "$0" "$@"
  else
    echo "bash is required. Install it first:"
    case "$(uname -s)" in
      FreeBSD) echo "  pkg install bash" ;;
      OpenBSD) echo "  pkg_add bash" ;;
      Linux)   echo "  apt-get install bash  /  yum install bash  /  apk add bash" ;;
      *)       echo "  install bash via your package manager" ;;
    esac
    exit 1
  fi
fi
# onekey.sh - proxy-node 一键安装 & 管理脚本
# 和 install.sh 共存，默认不开 WARP、不配置 Brutal
# 首次运行: 交互生成配置 → 启动服务 → 注册 mnode 命令
# 再次运行: 更新同目录下的 proxy-node 二进制并重启
# 输入 mnode: 查看日志、启停、卸载、重新生成配置
# PROXY_NODE_POST_INSTALL_STATE=keep|start|stop 控制安装或更新后的运行状态，默认 start。
set -euo pipefail

##############################################################################
# 配置
##############################################################################
SERVICE_NAME="proxy-node"
BINARY_NAME="proxy-node"
INSTALL_DIR="/opt/proxy-node"
CONFIG_FILE="${INSTALL_DIR}/config.json"
NODE_DEFAULTS_FILE="${INSTALL_DIR}/node_config.defaults.json"
BINARY_PATH="${INSTALL_DIR}/${BINARY_NAME}"
MNODE_PATH="${INSTALL_DIR}/mnode"
MNODE_LINK="/usr/local/bin/mnode"
LOG_FILE="/var/log/${SERVICE_NAME}.log"
FREEBSD_RC_SCRIPT="/usr/local/etc/rc.d/${SERVICE_NAME}"
OPENBSD_RC_NAME="${SERVICE_NAME//-/_}"
OPENBSD_RC_SCRIPT="/etc/rc.d/${OPENBSD_RC_NAME}"
OPENBSD_LEGACY_RC_SCRIPT="/etc/rc.d/${SERVICE_NAME}"
OPENBSD_WATCHDOG="${INSTALL_DIR}/openbsd-watchdog.ksh"
OPENBSD_CHILD_PID="/var/run/${OPENBSD_RC_NAME}.child.pid"
POST_INSTALL_STATE="${PROXY_NODE_POST_INSTALL_STATE:-start}"

##############################################################################
# 颜色输出
##############################################################################
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[-]${NC} $*"; exit 1; }
ask()   { echo -e "${CYAN}[?]${NC} $*"; }

##############################################################################
# OS 检测
##############################################################################
is_linux()   { [[ "$(uname -s)" == "Linux" ]]; }
is_freebsd() { [[ "$(uname -s)" == "FreeBSD" ]]; }
is_openbsd() { [[ "$(uname -s)" == "OpenBSD" ]]; }

is_root() { [[ $EUID -eq 0 ]]; }

service_installed() {
  [[ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]] || \
  [[ -f "/etc/init.d/${SERVICE_NAME}" ]] || \
  [[ -f "${FREEBSD_RC_SCRIPT}" ]] || \
  [[ -f "${OPENBSD_RC_SCRIPT}" ]] || \
  [[ -f "${OPENBSD_LEGACY_RC_SCRIPT}" ]] || \
  [[ -f "/etc/supervisor/conf.d/${SERVICE_NAME}.conf" ]] || \
  [[ -f "/etc/supervisord.d/${SERVICE_NAME}.conf" ]]
}

service_running() {
  if is_freebsd && [[ -x "${FREEBSD_RC_SCRIPT}" ]]; then
    service "${SERVICE_NAME}" onestatus &>/dev/null && return 0
  fi
  if is_openbsd; then
    if [[ -x "${OPENBSD_RC_SCRIPT}" ]]; then
      if rcctl check "${OPENBSD_RC_NAME}" &>/dev/null && pgrep -f "^${BINARY_PATH} -c ${CONFIG_FILE}$" &>/dev/null; then
        return 0
      fi
    fi
    pgrep -f "^${BINARY_PATH} -c ${CONFIG_FILE}$" &>/dev/null && return 0
  fi
  if command -v systemctl &>/dev/null && systemctl list-unit-files "${SERVICE_NAME}.service" &>/dev/null 2>&1; then
    systemctl is-active --quiet "${SERVICE_NAME}" && return 0
  fi
  if command -v rc-service &>/dev/null && [[ -f "/etc/init.d/${SERVICE_NAME}" ]]; then
    rc-service "${SERVICE_NAME}" status &>/dev/null && return 0
  fi
  if command -v supervisorctl &>/dev/null; then
    supervisorctl status "${SERVICE_NAME}" 2>/dev/null | grep -q RUNNING && return 0
  fi
  pgrep -f "${BINARY_PATH} -c ${CONFIG_FILE}" &>/dev/null
}

stop_service() {
  info "停止 ${SERVICE_NAME}..."
  if is_freebsd && [[ -x "${FREEBSD_RC_SCRIPT}" ]]; then
    service "${SERVICE_NAME}" stop &>/dev/null || true
  elif is_openbsd; then
    if [[ -x "${OPENBSD_RC_SCRIPT}" ]]; then
      rcctl stop "${OPENBSD_RC_NAME}" &>/dev/null || true
    fi
    # 旧版 rc.local 及此前失败的更新可能留下多个监护进程；全部停止后再换二进制。
    local pattern pids attempt
    for pattern in "${OPENBSD_WATCHDOG}" "^${BINARY_PATH} -c ${CONFIG_FILE}$"; do
      pids="$(pgrep -f "$pattern" 2>/dev/null || true)"
      [[ -z "$pids" ]] || kill -TERM $pids 2>/dev/null || true
    done
    for ((attempt=0; attempt<10; attempt++)); do
      if ! pgrep -f "${OPENBSD_WATCHDOG}" &>/dev/null && ! pgrep -f "^${BINARY_PATH} -c ${CONFIG_FILE}$" &>/dev/null; then
        break
      fi
      sleep 1
    done
    for pattern in "${OPENBSD_WATCHDOG}" "^${BINARY_PATH} -c ${CONFIG_FILE}$"; do
      pids="$(pgrep -f "$pattern" 2>/dev/null || true)"
      [[ -z "$pids" ]] || kill -KILL $pids 2>/dev/null || true
    done
    rm -f "${OPENBSD_CHILD_PID}"
    for ((attempt=0; attempt<3; attempt++)); do
      if ! pgrep -f "${OPENBSD_WATCHDOG}" &>/dev/null && ! pgrep -f "^${BINARY_PATH} -c ${CONFIG_FILE}$" &>/dev/null; then
        break
      fi
      sleep 1
    done
    if pgrep -f "${OPENBSD_WATCHDOG}" &>/dev/null || pgrep -f "^${BINARY_PATH} -c ${CONFIG_FILE}$" &>/dev/null; then
      error "仍有旧 proxy-node 或监护进程运行，已中止更新以避免端口冲突"
    fi
    info "OpenBSD 旧监护进程和节点进程已退出"
  elif command -v systemctl &>/dev/null && systemctl list-unit-files "${SERVICE_NAME}.service" &>/dev/null 2>&1; then
    systemctl stop "${SERVICE_NAME}" &>/dev/null || true
  elif command -v rc-service &>/dev/null && [[ -f "/etc/init.d/${SERVICE_NAME}" ]]; then
    rc-service "${SERVICE_NAME}" stop &>/dev/null || true
  elif command -v supervisorctl &>/dev/null; then
    supervisorctl stop "${SERVICE_NAME}" &>/dev/null || true
  else
    pkill -f "${BINARY_PATH} -c ${CONFIG_FILE}" &>/dev/null || true
  fi
  sleep 1
}

start_service() {
  info "启动 ${SERVICE_NAME}..."
  if is_freebsd && [[ -x "${FREEBSD_RC_SCRIPT}" ]]; then
    service "${SERVICE_NAME}" start
  elif is_openbsd; then
    if [[ -x "${OPENBSD_RC_SCRIPT}" ]]; then
      rcctl start "${OPENBSD_RC_NAME}"
      local attempt
      for ((attempt=0; attempt<10; attempt++)); do
        sleep 1
        if rcctl check "${OPENBSD_RC_NAME}" &>/dev/null && pgrep -f "^${BINARY_PATH} -c ${CONFIG_FILE}$" &>/dev/null; then
          sleep 1
          if rcctl check "${OPENBSD_RC_NAME}" &>/dev/null && pgrep -f "^${BINARY_PATH} -c ${CONFIG_FILE}$" &>/dev/null; then
            return 0
          fi
        fi
      done
      tail -n 20 "${LOG_FILE}" 2>/dev/null || true
      error "OpenBSD 监护脚本已启动，但 proxy-node 未能持续运行；请检查上面的日志"
    else
      nohup "${BINARY_PATH}" -c "${CONFIG_FILE}" >> "${LOG_FILE}" 2>&1 &
      warn "未发现 ${OPENBSD_RC_SCRIPT}，已临时直接启动；请重新运行 onekey.sh 修复自启动"
    fi
  elif command -v systemctl &>/dev/null && systemctl list-unit-files "${SERVICE_NAME}.service" &>/dev/null 2>&1; then
    systemctl start "${SERVICE_NAME}"
  elif command -v rc-service &>/dev/null && [[ -f "/etc/init.d/${SERVICE_NAME}" ]]; then
    rc-service "${SERVICE_NAME}" start
  elif command -v supervisorctl &>/dev/null; then
    supervisorctl start "${SERVICE_NAME}" || true
  else
    nohup "${BINARY_PATH}" -c "${CONFIG_FILE}" >> "${LOG_FILE}" 2>&1 &
    warn "未检测到支持的 init 系统，已直接启动进程（崩溃或退出后需手动重启）"
  fi
}

print_status() {
  echo ""
  echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "  ${GREEN}proxy-node${NC} 安装目录: ${INSTALL_DIR}"
  echo ""
  if service_running; then
    echo -e "  状态: ${GREEN}运行中${NC}"
  else
    echo -e "  状态: ${RED}已停止${NC}"
  fi
  echo ""
  echo "  配置: ${CONFIG_FILE}"
  echo "  日志: ${LOG_FILE}"
  echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
}

##############################################################################
# 服务安装
##############################################################################
install_systemd_service() {
  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<SYSDEOF
[Unit]
Description=Proxy Node
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${BINARY_PATH} -c ${CONFIG_FILE}
Restart=always
RestartSec=3
StartLimitIntervalSec=0
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SYSDEOF
  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}"
  info "systemd 服务已安装"
}

install_openrc_service() {
  local run_dir="/run/${SERVICE_NAME}"
  mkdir -p "$run_dir"
  cat > "/etc/init.d/${SERVICE_NAME}" <<OPENRCDEOF
#!/sbin/openrc-run
name="${SERVICE_NAME}"
description="Proxy Node"
supervisor="supervise-daemon"
command="${BINARY_PATH}"
command_args="-c ${CONFIG_FILE}"
command_user="root:root"
directory="${INSTALL_DIR}"
pidfile="/run/${SERVICE_NAME}/${SERVICE_NAME}.pid"
respawn_delay=3
respawn_max=0
output_log="${LOG_FILE}"
error_log="${LOG_FILE}"

depend() {
  need net
  after firewall
}

start_pre() {
  checkpath -d -m 0755 -o root:root "${run_dir}"
}
OPENRCDEOF
  chmod +x "/etc/init.d/${SERVICE_NAME}"
  rc-update add "${SERVICE_NAME}" default
  info "OpenRC 服务已安装"
}

install_freebsd_service() {
  mkdir -p "$(dirname "${FREEBSD_RC_SCRIPT}")"
  cat > "${FREEBSD_RC_SCRIPT}" <<FBSDEOF
#!/bin/sh
# PROVIDE: proxy_node
# REQUIRE: NETWORKING
# KEYWORD: shutdown

. /etc/rc.subr

name="proxy_node"
rcvar="proxy_node_enable"
load_rc_config "\$name"
: \${proxy_node_enable:="NO"}

pidfile="/var/run/${SERVICE_NAME}.pid"
command="/usr/sbin/daemon"
command_args="-f -P \${pidfile} -r -R 3 -o ${LOG_FILE} ${BINARY_PATH} -c ${CONFIG_FILE}"
required_files="${BINARY_PATH} ${CONFIG_FILE}"
start_precmd="proxy_node_prestart"

proxy_node_prestart() {
  ulimit -S -n "\$(ulimit -H -n)" 2>/dev/null || true
}

run_rc_command "\$1"
FBSDEOF
  chmod 555 "${FREEBSD_RC_SCRIPT}"
  sysrc proxy_node_enable=YES >/dev/null
  info "FreeBSD rc.d 服务已安装"
}

remove_legacy_openbsd_autostart() {
  if [[ -f /etc/rc.local ]] && grep -Fqx "${OPENBSD_LEGACY_RC_SCRIPT} start" /etc/rc.local; then
    local cleaned
    cleaned="$(mktemp /etc/rc.local.proxy_node.XXXXXXXX)" || error "无法清理旧 OpenBSD rc.local 启动项"
    grep -Fvx "${OPENBSD_LEGACY_RC_SCRIPT} start" /etc/rc.local > "$cleaned" || true
    cat "$cleaned" > /etc/rc.local
    rm -f "$cleaned"
  fi
}

install_openbsd_service() {
  # rcctl 负责开机与启停；独立监护进程负责运行期间的异常退出重启。
  cat > "${OPENBSD_WATCHDOG}" <<OBSDEOF
#!/bin/ksh
child=""
stop_watchdog() {
  trap - TERM INT HUP
  if [ -n "\$child" ]; then
    kill -TERM "\$child" 2>/dev/null || true
    wait "\$child" 2>/dev/null || true
  fi
  rm -f "${OPENBSD_CHILD_PID}"
  exit 0
}
trap stop_watchdog TERM INT HUP
exec </dev/null >> "${LOG_FILE}" 2>&1
while :; do
  "${BINARY_PATH}" -c "${CONFIG_FILE}" &
  child=\$!
  printf '%s\n' "\$child" > "${OPENBSD_CHILD_PID}.tmp.\$\$"
  mv -f "${OPENBSD_CHILD_PID}.tmp.\$\$" "${OPENBSD_CHILD_PID}"
  wait "\$child"
  status=\$?
  child=""
  rm -f "${OPENBSD_CHILD_PID}"
  printf '[watchdog] proxy-node 已退出 (code=%s)，3 秒后重启\n' "\$status"
  sleep 3 &
  child=\$!
  wait "\$child"
  child=""
done
OBSDEOF
  chmod 555 "${OPENBSD_WATCHDOG}"
  cat > "${OPENBSD_RC_SCRIPT}" <<OBSDEOF
#!/bin/ksh
# \$OpenBSD\$

daemon="/bin/ksh ${OPENBSD_WATCHDOG}"

. /etc/rc.d/rc.subr
# rc.subr 的默认 pexp 与 daemon 相同，必须包含 /bin/ksh；rc_check 使用 -xf 精确匹配。
rc_bg=YES
rc_reload=NO

rc_pre() {
  rm -f "${OPENBSD_CHILD_PID}"
}

rc_stop() {
  pkill -f "\$pexp" 2>/dev/null || true
  pkill -f '^${BINARY_PATH} -c ${CONFIG_FILE}\$' 2>/dev/null || true
  rm -f "${OPENBSD_CHILD_PID}"
}

rc_cmd \$1
OBSDEOF
  chmod 555 "${OPENBSD_RC_SCRIPT}"
  rm -f "${OPENBSD_LEGACY_RC_SCRIPT}" /var/run/${SERVICE_NAME}.pid "${OPENBSD_CHILD_PID}"
  remove_legacy_openbsd_autostart
  rcctl enable "${OPENBSD_RC_NAME}" || error "无法通过 rcctl 启用 OpenBSD 开机自启动"
  info "OpenBSD rc.d 服务已安装：开机启动，进程退出后由 watchdog 延迟 3 秒重启 (${OPENBSD_RC_NAME})"
}

install_supervisor_service() {
  local conf_dir="/etc/supervisor/conf.d"
  [[ -d "$conf_dir" ]] || conf_dir="/etc/supervisord.d"
  mkdir -p "$conf_dir"
  cat > "${conf_dir}/${SERVICE_NAME}.conf" <<SUPDEOF
[program:${SERVICE_NAME}]
command=${BINARY_PATH} -c ${CONFIG_FILE}
directory=${INSTALL_DIR}
autostart=true
autorestart=true
startsecs=3
startretries=999
redirect_stderr=true
stdout_logfile=${LOG_FILE}
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=3
SUPDEOF
  supervisorctl reread && supervisorctl update || true
  info "supervisord 配置已安装"
}

install_service() {
  if is_freebsd; then
    install_freebsd_service
  elif is_openbsd; then
    install_openbsd_service
  elif is_linux; then
    if command -v systemctl &>/dev/null && systemctl --version &>/dev/null 2>&1 && [[ ! -f /etc/alpine-release ]]; then
      install_systemd_service
    elif command -v rc-update &>/dev/null && ([[ -x /sbin/openrc-run ]] || [[ -x /usr/bin/openrc-run ]]); then
      install_openrc_service
    elif command -v supervisorctl &>/dev/null; then
      install_supervisor_service
    else
      warn "未检测到支持的 init 系统，跳过服务注册（进程崩溃或退出后需手动重启）"
    fi
  else
    warn "不支持的操作系统: $(uname -s)，跳过服务注册"
  fi
}

remove_service() {
  info "清理服务..."
  stop_service

  # systemd
  if [[ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]]; then
    systemctl disable "${SERVICE_NAME}" &>/dev/null || true
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    systemctl daemon-reload &>/dev/null || true
  fi

  # OpenRC
  if [[ -f "/etc/init.d/${SERVICE_NAME}" ]]; then
    rc-update del "${SERVICE_NAME}" &>/dev/null || true
    rm -f "/etc/init.d/${SERVICE_NAME}"
  fi

  # FreeBSD rc.d
  if [[ -f "${FREEBSD_RC_SCRIPT}" ]]; then
    sysrc -x proxy_node_enable &>/dev/null || true
    rm -f "${FREEBSD_RC_SCRIPT}"
  fi

  # OpenBSD
  if is_openbsd; then
    if [[ -f "${OPENBSD_RC_SCRIPT}" ]]; then
      rcctl disable "${OPENBSD_RC_NAME}" &>/dev/null || true
    fi
    rm -f "${OPENBSD_RC_SCRIPT}" "${OPENBSD_LEGACY_RC_SCRIPT}" "${OPENBSD_WATCHDOG}" "${OPENBSD_CHILD_PID}" /var/run/${SERVICE_NAME}.pid
    remove_legacy_openbsd_autostart
  fi

  # supervisor
  rm -f "/etc/supervisor/conf.d/${SERVICE_NAME}.conf" "/etc/supervisord.d/${SERVICE_NAME}.conf"
  supervisorctl reread &>/dev/null 2>&1 && supervisorctl update &>/dev/null 2>&1 || true
}

##############################################################################
# config 生成
##############################################################################
generate_config() {
  echo ""
  echo -e "${GREEN}============================================================${NC}"
  echo -e "${GREEN}  proxy-node 配置生成${NC}"
  echo -e "${GREEN}============================================================${NC}"
  echo ""

  # 1. 面板后端
  while true; do
    ask "面板后端地址（需 http:// 或 https:// 开头）:"
    read -r panel_host
    if [[ "$panel_host" =~ ^https?:// ]]; then
      break
    fi
    warn "地址必须以 http:// 或 https:// 开头"
  done

  # 2. API KEY
  while true; do
    ask "API KEY:"
    read -r api_key
    if [[ -n "$api_key" ]]; then
      break
    fi
    warn "API KEY 不能为空"
  done

  # 3. Node ID
  while true; do
    ask "Node ID [1]:"
    read -r node_id
    [[ -z "$node_id" ]] && node_id="1"
    if [[ "$node_id" =~ ^[0-9]+$ ]] && [[ "$node_id" -gt 0 ]]; then
      break
    fi
    warn "Node ID 必须为大于 0 的数字"
  done

  # 4. 协议
  while true; do
    echo ""
    echo "  [1] mx"
    echo "  [2] vless"
    echo "  [3] vmess"
    echo "  [4] trojan"
    echo "  [5] anytls"
    echo "  [6] jatp"
    echo "  [7] socks"
    echo "  [8] shadowsocks"
    echo "  [9] v2node"
    echo "  [0] 取消"
    ask "协议 [1]:"
    read -r protocol
    case "${protocol:-1}" in
      1) node_type="mx"; break ;;
      2) node_type="vless"; break ;;
      3) node_type="vmess"; break ;;
      4) node_type="trojan"; break ;;
      5) node_type="anytls"; break ;;
      6) node_type="jatp"; break ;;
      7) node_type="socks"; break ;;
      8) node_type="shadowsocks"; break ;;
      9) node_type="v2node"; break ;;
      0) info "已取消"; return 1 ;;
      *) warn "无效选项: ${protocol}" ;;
    esac
  done

  echo ""
  info "配置预览:"
  echo "  面板:   ${panel_host}"
  echo "  KEY:    ${api_key}"
  echo "  Node:   ${node_id}"
  echo "  协议:   ${node_type}"

  # 写入 node_config.defaults.json
  cat > "$NODE_DEFAULTS_FILE" <<NCDEOF
{
  "tls_settings": {
    "short_id": "",
    "private_key": ""
  }
}
NCDEOF

  # 转义路径中的反斜杠（Windows 兼容，虽然此脚本跑在 Linux/BSD）
  local escaped_dir="${INSTALL_DIR}"
  # 写入 config.json
  cat > "$CONFIG_FILE" <<CFGEOF
{
  "log_level": "info",
  "panel": {
    "api_host": "${panel_host}",
    "api_key": "${api_key}",
    "node_id": ${node_id},
    "node_type": "${node_type}",
    "pull_interval": 60,
    "push_interval": 120,
    "node_config_defaults_path": "${escaped_dir}/node_config.defaults.json"
  },
  "panels": [],
  "mundoproxy": {
    "asset_path": "${escaped_dir}",
    "log_level": "warning",
    "listen_ip": "0.0.0.0",
    "brutalMbps": -1,
    "report_min_traffic_kb": 10
  },
  "cert": {
    "mode": "self",
    "cert_file": "${escaped_dir}/cert.pem",
    "key_file": "${escaped_dir}/key.pem"
  }
}
CFGEOF

  info "配置已生成: ${CONFIG_FILE}"
}

##############################################################################
# mnode 注册
##############################################################################
register_mnode() {
  # 复制自身到安装目录作为 mnode
  cp "$0" "$MNODE_PATH"
  chmod +x "$MNODE_PATH"
  info "mnode → ${MNODE_PATH}"

  # 创建 symlink 到 PATH
  mkdir -p "$(dirname "$MNODE_LINK")"
  ln -sf "$MNODE_PATH" "$MNODE_LINK" 2>/dev/null || {
    # 如果 /usr/local/bin 不可写，尝试 /usr/bin
    MNODE_LINK="/usr/bin/mnode"
    ln -sf "$MNODE_PATH" "$MNODE_LINK" 2>/dev/null || warn "无法创建 mnode 链接，请手动: ln -sf ${MNODE_PATH} /usr/local/bin/mnode"
  }
  info "mnode 命令已注册: ${MNODE_LINK}"
}

##############################################################################
# mnode 管理命令
##############################################################################
mnode_show_menu() {
  while true; do
    echo ""
    if service_running; then
      echo -e "  当前mnode状态：【${GREEN}已运行${NC}】"
    else
      echo -e "  当前mnode状态：【${RED}已停止${NC}】"
    fi
    echo ""
    echo -e "  ${CYAN}[1]${NC} 查看日志"
    echo -e "  ${CYAN}[2]${NC} 启动服务"
    echo -e "  ${CYAN}[3]${NC} 停止服务"
    echo -e "  ${CYAN}[4]${NC} 重启服务"
    echo -e "  ${CYAN}[5]${NC} 重新生成配置"
    echo -e "  ${CYAN}[6]${NC} 卸载"
    echo -e "  ${CYAN}[0]${NC} 退出"
    echo ""
    read -r -p "  请输入: " choice
    case "$choice" in
      1) mnode_exec log ;;
      2) mnode_exec start ;;
      3) mnode_exec stop ;;
      4) mnode_exec restart ;;
      5) mnode_exec config ;;
      6) mnode_exec uninstall ;;
      0|x|X|q|Q|exit) echo ""; info "已退出 mnode"; break ;;
      *) warn "无效选项: ${choice}" ;;
    esac
  done
}

mnode_exec() {
  local cmd="${1:-}"

  case "$cmd" in
    log|logs)
      echo -e "${GREEN}=== proxy-node 日志 ===${NC}"
      if is_freebsd || is_openbsd; then
        tail -n 100 "${LOG_FILE}" 2>/dev/null || echo "(暂无日志)"
      elif command -v journalctl &>/dev/null && systemctl list-unit-files "${SERVICE_NAME}.service" &>/dev/null 2>&1; then
        journalctl -u "${SERVICE_NAME}" -f --no-pager -n 100
      else
        tail -n 100 "${LOG_FILE}" 2>/dev/null || echo "(暂无日志)"
      fi
      ;;
    start)
      is_root || error "启动服务需要 root 权限"
      start_service
      ;;
    stop)
      is_root || error "停止服务需要 root 权限"
      stop_service
      info "服务已停止"
      ;;
    restart)
      is_root || error "重启服务需要 root 权限"
      stop_service
      start_service
      ;;
    status|info)
      print_status
      ;;
    config|reconfig)
      is_root || error "重新生成配置需要 root 权限"
      echo ""
      warn "将重新生成配置（旧配置备份为 config.json.bak）"
      read -r -p "确认继续? [y/N]: " confirm
      case "$confirm" in
        y|Y|yes|YES) ;;
        *) info "已取消"; return 0 ;;
      esac
      cp "$CONFIG_FILE" "${CONFIG_FILE}.bak" 2>/dev/null || true
      generate_config || return 0
      stop_service
      start_service
      info "配置已更新并重启服务"
      ;;
    uninstall)
      is_root || error "卸载需要 root 权限"
      echo ""
      warn "即将完全卸载 proxy-node："
      echo "  - 停止并删除服务"
      echo "  - 删除 ${INSTALL_DIR}"
      echo "  - 删除 mnode 命令"
      echo "  - 删除本脚本自身"
      read -r -p "确认卸载? [y/N]: " confirm
      case "$confirm" in
        y|Y|yes|YES) ;;
        *) info "已取消"; return 0 ;;
      esac
      remove_service
      rm -rf "$INSTALL_DIR"
      rm -f "$MNODE_LINK" "/usr/bin/mnode"
      info "proxy-node 已卸载"
      echo ""
      warn "本脚本即将自删: $0"
      rm -f "$0"
      ;;
    *)
      echo "未知命令: ${cmd}"
      echo "可用: 1~6 / log / start / stop / restart / status / config / uninstall"
      ;;
  esac
}

mnode_main() {
  local cmd="${1:-}"

  # 数字映射到文本命令
  case "$cmd" in
    1) cmd="log" ;;
    2) cmd="start" ;;
    3) cmd="stop" ;;
    4) cmd="restart" ;;
    5) cmd="config" ;;
    6) cmd="uninstall" ;;
  esac

  # 无参数 → 交互菜单
  if [[ -z "$cmd" ]]; then
    mnode_show_menu
    return 0
  fi

  # 直接执行
  mnode_exec "$cmd"
}

##############################################################################
# 安装流程
##############################################################################
do_install() {
  echo ""
  echo -e "${GREEN}============================================================${NC}"
  echo -e "${GREEN}  proxy-node 一键安装${NC}"
  echo -e "${GREEN}============================================================${NC}"

  # 创建安装目录
  mkdir -p "$INSTALL_DIR"

  # 二进制
  local src_binary
  src_binary="$(cd "$(dirname "$0")" && pwd)/${BINARY_NAME}"
  if [[ -f "$src_binary" ]]; then
    install -m755 "$src_binary" "$BINARY_PATH"
    info "安装 proxy-node → ${BINARY_PATH}"
  else
    error "找不到 ${BINARY_NAME}，请把它和本脚本放在同一目录"
  fi

  # scripts 目录
  local script_dir scripts_src
  script_dir="$(cd "$(dirname "$0")" && pwd)"
  if [[ -d "${script_dir}/scripts" ]]; then
    mkdir -p "${INSTALL_DIR}/scripts"
    cp -R "${script_dir}/scripts/." "${INSTALL_DIR}/scripts/"
    info "复制 JS 脚本"
  fi

  # 生成配置（交互式）
  generate_config || return 0

  # 安装服务
  install_service

  # 注册 mnode
  register_mnode

  # 首装前没有运行中的服务；保持原样与停止服务都不启动。
  if [[ "$POST_INSTALL_STATE" != "start" ]]; then
    info "按安装后启动状态要求，服务保持停止"
  else
    start_service
    sleep 1
  fi

  # 检测编辑器
  local editor=""
  for e in vim vi nano; do
    command -v "$e" &>/dev/null && { editor="$e"; break; }
  done

  echo ""
  echo -e "${GREEN}============================================================${NC}"
  echo -e "${GREEN}  安装完成！${NC}"
  echo ""
  echo "  目录: ${INSTALL_DIR}"
  echo "  配置: ${CONFIG_FILE}"
  echo ""
  if is_freebsd; then
    echo "  启动: service ${SERVICE_NAME} start"
    echo "  停止: service ${SERVICE_NAME} stop"
    echo "  日志: tail -f ${LOG_FILE}"
  elif is_openbsd; then
    echo "  启动: rcctl start ${OPENBSD_RC_NAME}"
    echo "  停止: rcctl stop ${OPENBSD_RC_NAME}"
    echo "  日志: tail -f ${LOG_FILE}"
  elif command -v systemctl &>/dev/null && [[ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]]; then
    echo "  日志: journalctl -fu ${SERVICE_NAME}"
  else
    echo "  日志: tail -f ${LOG_FILE}"
  fi
  echo ""
  if [[ -n "$editor" ]]; then
    echo "  如需更换证书: ${editor} ${CONFIG_FILE} 修改 cert 部分"
  else
    echo "  如需更换证书: 编辑 ${CONFIG_FILE} 修改 cert 部分"
  fi
  echo "  修改后执行: mnode restart"
  echo ""
  echo -e "  ${GREEN}输入 mnode 管理${NC}"
  echo -e "${GREEN}============================================================${NC}"
}

##############################################################################
# 更新流程
##############################################################################
do_update() {
  local script_dir src_binary
  script_dir="$(cd "$(dirname "$0")" && pwd)"
  src_binary="${script_dir}/${BINARY_NAME}"

  if [[ ! -f "$src_binary" ]]; then
    info "当前目录未找到 ${BINARY_NAME}，跳过更新"
    echo "  如需管理，请直接输入: mnode"
    exit 0
  fi

  echo ""
  echo -e "${GREEN}=== proxy-node 更新 ===${NC}"

  local was_running=0
  if service_running; then
    was_running=1
  fi

  stop_service
  install -m755 "$src_binary" "$BINARY_PATH"
  info "已更新 proxy-node → ${BINARY_PATH}"

  # 同步更新 mnode（避免自己复制到自己）
  local self_real mn_real
  self_real="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  mn_real="$(cd "$(dirname "$MNODE_PATH")" && pwd)/$(basename "$MNODE_PATH")"
  if [[ "$self_real" != "$mn_real" ]]; then
    cp "$0" "$MNODE_PATH"
    chmod +x "$MNODE_PATH"
    info "mnode 脚本已同步更新"
  fi

  # 更新旧版 OpenBSD 安装时，把 rc.local 和带连字符的 rc.d 脚本迁移到 rcctl。
  if is_openbsd; then
    install_openbsd_service
  fi

  case "$POST_INSTALL_STATE" in
    start)
      start_service
      info "更新完成，服务已启动"
      ;;
    stop)
      info "更新完成，服务保持停止"
      ;;
    keep)
      if [[ "$was_running" -eq 1 ]]; then
        start_service
        info "更新完成，恢复更新前运行状态"
      else
        info "更新完成，保持更新前停止状态"
      fi
      ;;
  esac

  echo ""
  info "输入 mnode 管理"
}

##############################################################################
# 入口
##############################################################################
main() {
  # 判断是否以 mnode 身份运行
  local script_name
  script_name="$(basename "$0")"
  if [[ "$script_name" == "mnode" ]] || [[ "$0" == *"/mnode" ]]; then
    mnode_main "$@"
    exit $?
  fi

  is_root || error "请用 root 运行: sudo bash $0"

  case "$POST_INSTALL_STATE" in
    keep|start|stop) ;;
    *) error "PROXY_NODE_POST_INSTALL_STATE 只能为 keep、start 或 stop" ;;
  esac

  if service_installed; then
    do_update "$@"
  else
    do_install "$@"
  fi
}

main "$@"

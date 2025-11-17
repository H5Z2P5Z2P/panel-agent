#!/usr/bin/env bash

set -euo pipefail

SERVICE_NAME="ptm-agent"
INSTALL_DIR="/opt/ptm-agent"
PANEL_ENDPOINT=""
AD_KEY=""
REPORT_INTERVAL=""
VERSION="latest"
BINARY_URL=""
EXTRA_ARGS=""

log()  { echo -e "[INFO] $*"; }
warn() { echo -e "[WARN] $*" >&2; }
err()  { echo -e "[ERROR] $*" >&2; }

usage() {
    cat <<EOF
用法: sudo ./install_agent.sh [参数]

可选参数：
  --dir <path>             安装目录（默认 /opt/ptm-agent）
  --service-name <name>    systemd 服务名（默认 ptm-agent）
  -e <url>                 面板地址（等同于 agent 的 -e）
  --auto-discovery <key>   自动发现 AD Key（等同于 agent 的 --auto-discovery）
  --interval <seconds>     心跳/上报周期（等同于 agent 的 --interval）
  --version <tag>          下载的版本号（默认 latest）
  --url <download_url>     自定义二进制下载地址（覆盖 version）
  --extra-args "<args>"    运行 agent 时附加的参数
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir) INSTALL_DIR="$2"; shift 2 ;;
        --service-name) SERVICE_NAME="$2"; shift 2 ;;
        -e|--endpoint) PANEL_ENDPOINT="$2"; shift 2 ;;
        --auto-discovery) AD_KEY="$2"; shift 2 ;;
        --interval) REPORT_INTERVAL="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        --url) BINARY_URL="$2"; shift 2 ;;
        --extra-args) EXTRA_ARGS="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *)
            warn "未知参数: $1"
            usage
            exit 1
            ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    err "请使用 root 权限运行该脚本"
    exit 1
fi

OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
case "$OS" in
    linux) OS="linux" ;;
    *)
        err "当前系统不受支持: $OS"
        exit 1
        ;;
esac

case "$ARCH" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *)
        err "当前架构不受支持: $ARCH"
        exit 1
        ;;
esac

mkdir -p "$INSTALL_DIR"
BIN_PATH="$INSTALL_DIR/iptables-agent"
CONFIG_PATH="$INSTALL_DIR/config.json"

download_agent() {
    local url="$1"
    local tmpfile
    tmpfile="$(mktemp)"
    log "Downloading agent: $url"
    if command -v curl >/dev/null 2>&1; then
        curl -L "$url" -o "$tmpfile"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$tmpfile" "$url"
    else
        err "需要 curl 或 wget"
        exit 1
    fi
    install -m 755 "$tmpfile" "$BIN_PATH"
    rm -f "$tmpfile"
}

BINARY_URL="${BINARY_URL:-https://github.com/H5Z2P5Z2P/panel-agent/raw/refs/heads/main/agent_${OS}_${ARCH}}"

download_agent "$BINARY_URL"

auto_discovery() {
    if [[ -z "$PANEL_ENDPOINT" || -z "$AD_KEY" ]]; then
        warn "未提供面板地址或 AD Key，跳过自动发现。请手动更新 $CONFIG_PATH"
        return
    fi
    log "执行自动发现..."
    "$BIN_PATH" --config "$CONFIG_PATH" --auto-discovery "$AD_KEY" -e "$PANEL_ENDPOINT" >"$INSTALL_DIR/discovery.log" 2>&1 &
    local pid=$!
    for _ in {1..60}; do
        sleep 2
        if grep -q '"agent_uid":[ ]*"[^"]\+"' "$CONFIG_PATH" 2>/dev/null && grep -q '"agent_token":[ ]*"[^"]\+"' "$CONFIG_PATH" 2>/dev/null; then
            log "自动发现完成，停止临时进程"
            kill "$pid" >/dev/null 2>&1 || true
            wait "$pid" 2>/dev/null || true
            return
        fi
        if ! kill -0 "$pid" >/dev/null 2>&1; then
            break
        fi
    done
    kill "$pid" >/dev/null 2>&1 || true
    err "自动发现失败，请检查 $INSTALL_DIR/discovery.log 并重试"
    exit 1
}

auto_discovery

SERVICE_EXEC="${BIN_PATH} --config ${CONFIG_PATH}"
if [[ -n "${PANEL_ENDPOINT}" ]]; then
    SERVICE_EXEC="${SERVICE_EXEC} -e ${PANEL_ENDPOINT}"
fi
if [[ -n "${AD_KEY}" ]]; then
    SERVICE_EXEC="${SERVICE_EXEC} --auto-discovery ${AD_KEY}"
fi
if [[ -n "${REPORT_INTERVAL}" ]]; then
    SERVICE_EXEC="${SERVICE_EXEC} --interval ${REPORT_INTERVAL}"
fi
SERVICE_EXEC="${SERVICE_EXEC} ${EXTRA_ARGS}"

cat >/etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=PTM Agent
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=${SERVICE_EXEC}
WorkingDirectory=${INSTALL_DIR}
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}.service"

log "Agent 已安装至 ${INSTALL_DIR}"
log "systemd 服务 ${SERVICE_NAME} 已启动"

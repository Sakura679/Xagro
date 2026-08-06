#!/usr/bin/env bash
# ============================================================
# VMess WS + Argo Tunnel 统一abb部署脚本
# 支持: Debian/Ubuntu, CentOS/RHEL/Fedora, Alpine, Arch, openSUSE
# 架构: x86_64, aarch64, armv7
# 模式: 临时隧道 / 固定隧道
# 功能: 安装、更新临时域名、卸载清理、查看节点
# ============================================================
set -euo pipefail

# ---------- 全局常量 ----------
SCRIPT_VERSION="2.0.0"
WORK_DIR="/etc/vmess-argo"
STATE_FILE="${WORK_DIR}/state.env"
XRAY_BIN="/usr/local/bin/xray"
CLOUDFLARED_BIN="/usr/local/bin/cloudflared"
XRAY_CONF_DIR="/usr/local/etc/xray"
CLOUDFLARED_CONF_DIR="/etc/cloudflared"
SYSTEMD_DIR="/etc/systemd/system"
OPENRC_DIR="/etc/init.d"

# 颜色
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' BLUE='\033[0;34m' NC='\033[0m'
log()   { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
hint()  { echo -e "${BLUE}[HINT]${NC} $*"; }

# ---------- 工具函数 ----------
command_exists() { command -v "$1" >/dev/null 2>&1; }

gen_uuid() { cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || od -x /dev/urandom | head -1 | awk '{OFS="-"; print $2$3,$4,$5,$6,$7$8$9}'; }
gen_port() { shuf -i 10000-65535 -n 1; }
gen_path() { tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 12; }

save_state() {
    mkdir -p "$WORK_DIR"
    cat > "$STATE_FILE" <<EOF
# VMess-Argo State - $(date)
VERSION="${SCRIPT_VERSION}"
UUID="${UUID:-}"
PORT="${PORT:-}"
PATH="${WSPATH:-}"
TUNNEL_MODE="${TUNNEL_MODE:-}"      # temp / fixed
TUNNEL_ID="${TUNNEL_ID:-}"
TUNNEL_TOKEN="${TUNNEL_TOKEN:-}"
DOMAIN="${DOMAIN:-}"
CLOUDFLARED_URL="${CLOUDFLARED_URL:-}"
ARCH="${ARCH:-}"
OS_ID="${OS_ID:-}"
INSTALL_DATE="${INSTALL_DATE:-$(date +%s)}"
EOF
    chmod 600 "$STATE_FILE"
}

load_state() {
    [[ -f "$STATE_FILE" ]] && source "$STATE_FILE"
}

# ---------- 系统探测模块 ----------
detect_os() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        OS_ID="${ID}"
        OS_VERSION="${VERSION_ID:-}"
    elif command_exists lsb_release; then
        OS_ID=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
        OS_VERSION=$(lsb_release -sr)
    else
        err "无法检测操作系统"; exit 1
    fi

    case "$OS_ID" in
        debian|ubuntu|linuxmint|pop|kali|raspbian) PKG_MGR="apt"; INIT_SYS="systemd" ;;
        centos|rhel|fedora|rocky|almalinux|ol)     PKG_MGR="dnf"; command_exists yum && PKG_MGR="yum"; INIT_SYS="systemd" ;;
        alpine)                                    PKG_MGR="apk"; INIT_SYS="openrc" ;;
        arch|manjaro|endeavouros|garuda)           PKG_MGR="pacman"; INIT_SYS="systemd" ;;
        opensuse*|sles)                            PKG_MGR="zypper"; INIT_SYS="systemd" ;;
        *) err "不支持的发行版: $OS_ID"; exit 1 ;;
    esac

    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64)   ARCH="amd64" ;;
        aarch64|arm64)  ARCH="arm64" ;;
        armv7l|armhf)   ARCH="armv7" ;;
        *) err "不支持的架构: $ARCH"; exit 1 ;;
    esac
    log "检测到: $PRETTY_NAME ($ARCH) | 包管理器: $PKG_MGR | 初始化: $INIT_SYS"
}

install_base_deps() {
    log "安装基础依赖..."
    case "$PKG_MGR" in
        apt)    apt-get update && apt-get install -y curl wget jq qrencode procps grep coreutils iproute2 ;;
        dnf|yum) $PKG_MGR install -y curl wget jq qrencode procps-ng grep coreutils iproute ;;
        apk)    apk add --no-cache curl wget jq qrencode procps grep coreutils iproute2 ;;
        pacman) pacman -Sy --noconfirm curl wget jq qrencode procps-ng grep coreutils iproute2 ;;
        zypper) zypper refresh && zypper install -y curl wget jq qrencode procps grep coreutils iproute2 ;;
    esac
}

# ---------- Xray 模块 ----------
install_xray() {
    log "安装 Xray 核心..."
    local url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${ARCH}.zip"
    local tmpdir=$(mktemp -d)
    curl -fL# "$url" -o "${tmpdir}/xray.zip" || { err "Xray 下载失败"; exit 1; }
    unzip -qo "${tmpdir}/xray.zip" -d "$tmpdir"
    install -m 755 "${tmpdir}/xray" "$XRAY_BIN"
    rm -rf "$tmpdir"
    "$XRAY_BIN" version | head -1
}

config_xray() {
    UUID=$(gen_uuid)
    PORT=$(gen_port)
    WSPATH="/$(gen_path)"
    log "生成配置: UUID=$UUID | Port=$PORT | Path=$WSPATH"

    mkdir -p "$XRAY_CONF_DIR"
    cat > "${XRAY_CONF_DIR}/config.json" <<EOF
{
  "log": { "loglevel": "none" },
  "inbounds": [{
    "listen": "127.0.0.1",
    "port": ${PORT},
    "protocol": "vmess",
    "settings": {
      "clients": [{ "id": "${UUID}", "alterId": 0 }]
    },
    "streamSettings": {
      "network": "ws",
      "wsSettings": { "path": "${WSPATH}" }
    }
  }],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF
}

# ---------- Cloudflared 模块 ----------
install_cloudflared() {
    log "安装 Cloudflared..."
    local url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}"
    [[ "$ARCH" == "armv7" ]] && url="${url}-arm"
    curl -fL# "$url" -o "$CLOUDFLARED_BIN" || { err "Cloudflared 下载失败"; exit 1; }
    chmod +x "$CLOUDFLARED_BIN"
    "$CLOUDFLARED_BIN" --version | head -1
}

config_cloudflared_temp() {
    TUNNEL_MODE="temp"
    # systemd/openrc 服务直接运行 `cloudflared tunnel --url http://127.0.0.1:PORT --no-autoupdate`
    # URL 需要从 stdout 解析，由服务启动脚本处理
    log "模式: 临时隧道"
}

config_cloudflared_fixed() {
    TUNNEL_MODE="fixed"
    hint "固定隧道需要 Cloudflare 账号已登录 (cloudflared tunnel login)"
    hint "请确保已在 Cloudflare Dashboard 添加域名并托管 NS"
    read -rp "请输入已托管的根域名 (例: example.com): " ROOT_DOMAIN
    read -rp "请输入子域名 (例: vmess, 留空用根域名): " SUB_DOMAIN
    DOMAIN="${SUB_DOMAIN:+${SUB_DOMAIN}.}${ROOT_DOMAIN}"

    read -rp "请输入 Tunnel ID (或留空自动创建): " TUNNEL_ID
    if [[ -z "$TUNNEL_ID" ]]; then
        log "自动创建 Tunnel..."
        TUNNEL_ID=$("$CLOUDFLARED_BIN" tunnel create "vmess-argo-${UUID:0:8}" 2>&1 | grep -oP '(?<=Created tunnel ).*' | tr -d ' ')
        [[ -z "$TUNNEL_ID" ]] && { err "创建失败，请手动执行 cloudflared tunnel create"; exit 1; }
        log "创建成功: $TUNNEL_ID"
    fi

    # 凭证文件路径
    local cred_file="${CLOUDFLARED_CONF_DIR}/${TUNNEL_ID}.json"
    if [[ ! -f "$cred_file" ]]; then
        warn "未找到凭证文件: $cred_file"
        hint "请先在信任机器执行 'cloudflared tunnel login' 并 'cloudflared tunnel route dns <id> <domain>'"
        hint "然后将生成的 .json 文件放置到 $cred_file"
        read -rp "准备好后按回车继续..."
    fi

    mkdir -p "$CLOUDFLARED_CONF_DIR"
    cat > "${CLOUDFLARED_CONF_DIR}/config.yml" <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: ${cred_file}
loglevel: warn
transport: quic
ingress:
  - hostname: ${DOMAIN}
    service: http://127.0.0.1:${PORT}
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
    log "固定隧道配置完成: https://${DOMAIN}${WSPATH}"
}

# ---------- 服务管理模块 (systemd / openrc) ----------
install_service() {
    log "安装系统服务..."
    if [[ "$INIT_SYS" == "systemd" ]]; then
        install_systemd_service
    else
        install_openrc_service
    fi
}

install_systemd_service() {
    # Xray Service
    cat > "${SYSTEMD_DIR}/xray-vmess.service" <<EOF
[Unit]
Description=Xray VMess WebSocket
After=network.target nss-lookup.target
[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
ExecStart=${XRAY_BIN} run -config ${XRAY_CONF_DIR}/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
StandardOutput=journal
StandardError=journal
[Install]
WantedBy=multi-user.target
EOF

    # Cloudflared Service
    if [[ "$TUNNEL_MODE" == "temp" ]]; then
        cat > "${SYSTEMD_DIR}/cloudflared-temp.service" <<EOF
[Unit]
Description=Cloudflare Argo Temporary Tunnel
After=network.target
[Service]
Type=simple
User=root
ExecStart=/bin/bash -c '${CLOUDFLARED_BIN} tunnel --url http://127.0.0.1:${PORT} --no-autoupdate --edge-ip-version auto 2>&1 | tee /dev/stderr | grep -oE "https://[a-z0-9-]+\.trycloudflare\.com" | head -1 | xargs -I{} sh -c "echo {} > ${WORK_DIR}/temp_url.txt && logger -t argo-temp {}"'
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
[Install]
WantedBy=multi-user.target
EOF
    else
        cat > "${SYSTEMD_DIR}/cloudflared-fixed.service" <<EOF
[Unit]
Description=Cloudflare Argo Fixed Tunnel
After=network.target
[Service]
Type=simple
User=root
ExecStart=${CLOUDFLARED_BIN} tunnel --config ${CLOUDFLARED_CONF_DIR}/config.yml run
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
[Install]
WantedBy=multi-user.target
EOF
    fi

    systemctl daemon-reload
    systemctl enable --now xray-vmess
    if [[ "$TUNNEL_MODE" == "temp" ]]; then
        systemctl enable --now cloudflared-temp
    else
        systemctl enable --now cloudflared-fixed
    fi
}

install_openrc_service() {
    # Xray
    cat > "${OPENRC_DIR}/xray-vmess" <<EOF
#!/sbin/openrc-run
name="Xray VMess"
command="${XRAY_BIN}"
command_args="run -config ${XRAY_CONF_DIR}/config.json"
command_background=true
pidfile="/run/xray-vmess.pid"
output_log="/dev/null"
error_log="/dev/null"
depend() { need net; }
EOF
    chmod +x "${OPENRC_DIR}/xray-vmess"
    rc-update add xray-vmess default
    rc-service xray-vmess start

    # Cloudflared
    if [[ "$TUNNEL_MODE" == "temp" ]]; then
        cat > "${OPENRC_DIR}/cloudflared-temp" <<EOF
#!/sbin/openrc-run
name="Cloudflared Temp"
command="/bin/sh"
command_args="-c '${CLOUDFLARED_BIN} tunnel --url http://127.0.0.1:${PORT} --no-autoupdate 2>&1 | grep -oE \"https://[a-z0-9-]+\\.trycloudflare\\.com\" | head -1 > ${WORK_DIR}/temp_url.txt'"
command_background=true
pidfile="/run/cloudflared-temp.pid"
depend() { need net; }
EOF
        rc-update add cloudflared-temp default
        rc-service cloudflared-temp start
    else
        cat > "${OPENRC_DIR}/cloudflared-fixed" <<EOF
#!/sbin/openrc-run
name="Cloudflared Fixed"
command="${CLOUDFLARED_BIN}"
command_args="tunnel --config ${CLOUDFLARED_CONF_DIR}/config.yml run"
command_background=true
pidfile="/run/cloudflared-fixed.pid"
depend() { need net; }
EOF
        rc-update add cloudflared-fixed default
        rc-service cloudflared-fixed start
    fi
}

# ---------- 防火墙模块 ----------
setup_firewall() {
    log "配置防火墙 (仅放行 SSH 和必要端口)..."
    local ssh_port=$(grep -i "^Port" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
    ssh_port=${ssh_port:-22}

    if command_exists ufw; then
        ufw allow "$ssh_port"/tcp comment 'SSH'
        ufw --force enable
    elif command_exists firewall-cmd; then
        firewall-cmd --permanent --add-port="${ssh_port}/tcp"
        firewall-cmd --reload
    elif command_exists iptables; then
        iptables -C INPUT -p tcp --dport "$ssh_port" -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport "$ssh_port" -j ACCEPT
        # 保持规则持久化提示
        hint "iptables 规则非持久化，请自行配置 iptables-save / netfilter-persistent"
    fi
}

# ---------- 核心流程 ----------
do_install() {
    detect_os
    install_base_deps
    install_xray
    install_cloudflared
    config_xray

    echo "请选择 Argo 隧道模式:"
    echo "  1) 临时隧道 - 免费、无需域名、重启域名变化、适合测试"
    echo "  2) 固定隧道 - 需域名、需 CF 账号、域名固定、生产推荐"
    read -rp "选择 [1/2]: " choice
    case "$choice" in
        1) config_cloudflared_temp ;;
        2) config_cloudflared_fixed ;;
        *) err "无效选择"; exit 1 ;;
    esac

    install_service
    setup_firewall

    # 等待临时隧道生成 URL
    if [[ "$TUNNEL_MODE" == "temp" ]]; then
        log "等待临时隧道建立 (约 10-20s)..."
        sleep 15
        if [[ -f "${WORK_DIR}/temp_url.txt" ]]; then
            CLOUDFLARED_URL=$(cat "${WORK_DIR}/temp_url.txt")
        else
            # 尝试从 journal 获取
            CLOUDFLARED_URL=$(journalctl -u cloudflared-temp -n 20 --no-pager 2>/dev/null | grep -oE "https://[a-z0-9-]+\.trycloudflare\.com" | tail -1)
        fi
    else
        CLOUDFLARED_URL="https://${DOMAIN}"
    fi

    save_state
    show_node_info
}

# ---------- 临时隧道更新 ----------
update_temp_tunnel() {
    load_state
    [[ "$TUNNEL_MODE" != "temp" ]] && { err "仅临时隧道支持更新"; exit 1; }
    log "重启临时隧道服务以获取新域名..."
    if [[ "$INIT_SYS" == "systemd" ]]; then
        systemctl restart cloudflared-temp
    else
        rc-service cloudflared-temp restart
    fi
    sleep 10
    local new_url=""
    if [[ -f "${WORK_DIR}/temp_url.txt" ]]; then new_url=$(cat "${WORK_DIR}/temp_url.txt"); fi
    [[ -z "$new_url" ]] && new_url=$(journalctl -u cloudflared-temp -n 20 --no-pager 2>/dev/null | grep -oE "https://[a-z0-9-]+\.trycloudflare\.com" | tail -1)
    [[ -z "$new_url" ]] && new_url=$(rc-service cloudflared-temp status 2>/dev/null | grep -oE "https://[a-z0-9-]+\.trycloudflare\.com" | tail -1)

    if [[ -n "$new_url" ]]; then
        CLOUDFLARED_URL="$new_url"
        save_state
        log "临时隧道已更新: $CLOUDFLARED_URL"
        show_node_info
    else
        err "获取新域名失败，请稍后手动查看日志: journalctl -u cloudflared-temp -f"
    fi
}

# ---------- 卸载清理 ----------
do_uninstall() {
    load_state
    log "开始卸载清理..."

    # 1. 停止服务
    if [[ "$INIT_SYS" == "systemd" ]]; then
        systemctl disable --now xray-vmess 2>/dev/null || true
        systemctl disable --now cloudflared-temp 2>/dev/null || true
        systemctl disable --now cloudflared-fixed 2>/dev/null || true
        rm -f "${SYSTEMD_DIR}/xray-vmess.service"
        rm -f "${SYSTEMD_DIR}/cloudflared-temp.service"
        rm -f "${SYSTEMD_DIR}/cloudflared-fixed.service"
        systemctl daemon-reload
    else
        rc-service xray-vmess stop 2>/dev/null || true
        rc-service cloudflared-temp stop 2>/dev/null || true
        rc-service cloudflared-fixed stop 2>/dev/null || true
        rc-update del xray-vmess default 2>/dev/null || true
        rc-update del cloudflared-temp default 2>/dev/null || true
        rc-update del cloudflared-fixed default 2>/dev/null || true
        rm -f "${OPENRC_DIR}/xray-vmess"
        rm -f "${OPENRC_DIR}/cloudflared-temp"
        rm -f "${OPENRC_DIR}/cloudflared-fixed"
    fi

    # 2. 删除二进制
    rm -f "$XRAY_BIN" "$CLOUDFLARED_BIN"

    # 3. 删除配置目录
    rm -rf "$XRAY_CONF_DIR" "$CLOUDFLARED_CONF_DIR" "$WORK_DIR"

    # 4. 清理防火墙 (尽力而为，不强求)
    if command_exists ufw; then
        ufw delete allow 22/tcp 2>/dev/null || true
    fi

    log "卸载完成，无残留文件。"
}

# ---------- 显示节点信息 ----------
show_node_info() {
    load_state
    [[ -z "$UUID" ]] && { err "未找到安装状态，请先安装"; return; }

    local server_addr="${CLOUDFLARED_URL#https://}"
    local vmess_link="vmess://$(echo -n "{\"v\":\"2\",\"ps\":\"VMess-Argo\",\"add\":\"${server_addr}\",\"port\":\"443\",\"id\":\"${UUID}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${server_addr}\",\"path\":\"${PATH}\",\"tls\":\"tls\",\"sni\":\"${server_addr}\",\"alpn\":\"\"}" | base64 -w0)"

    echo -e "\n${GREEN}========== 节点信息 ==========${NC}"
    echo -e "协议: VMess over WebSocket over TLS (Argo)"
    echo -e "地址: ${server_addr}"
    echo -e "端口: 443"
    echo -e "UUID: ${UUID}"
    echo -e "AlterId: 0"
    echo -e "加密: auto"
    echo -e "传输: ws"
    echo -e "路径: ${PATH}"
    echo -e "TLS: 开启 (SNI: ${server_addr})"
    echo -e "ALPN: h2, http/1.1"
    echo -e "${GREEN}------------------------------${NC}"
    echo -e "分享链接:"
    echo -e "${vmess_link}"
    echo -e "${GREEN}------------------------------${NC}"
    command_exists qrencode && qrencode -t ANSIUTF8 "$vmess_link"
    echo -e "${GREEN}==============================${NC}\n"
}

# ---------- 菜单 ----------
main_menu() {
    while true; do
        clear
        echo -e "${BLUE}VMess + Argo Tunnel 管理脚本 v${SCRIPT_VERSION}${NC}"
        echo "————————————————————————————————————"
        load_state
        if [[ -n "$UUID" ]]; then
            echo -e "状态: ${GREEN}已安装${NC} | 模式: ${TUNNEL_MODE} | 域名: ${CLOUDFLARED_URL:-获取中...}"
        else
            echo -e "状态: ${RED}未安装${NC}"
        fi
        echo "————————————————————————————————————"
        echo " 1. 安装 / 重装"
        echo " 2. 查看节点信息 / 二维码"
        echo " 3. 更新临时隧道域名 (仅临时模式)"
        echo " 4. 卸载 (彻底清理)"
        echo " 0. 退出"
        echo "————————————————————————————————————"
        read -rp "请选择: " opt
        case "$opt" in
            1) do_install ;;
            2) show_node_info ;;
            3) update_temp_tunnel ;;
            4) read -rp "确认卸载? (y/N): " c && [[ "$c" == "y" ]] && do_uninstall ;;
            0) exit 0 ;;
            *) warn "无效选项" ;;
        esac
        read -rp "按回车继续..."
    done
}

# ---------- 入口 ----------
[[ $EUID -ne 0 ]] && { err "请以 root 权限运行"; exit 1; }
mkdir -p "$WORK_DIR"
main_menu

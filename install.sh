#!/bin/bash

# ============================================
# VPS代理节点+Argo隧道+CF优选 一键安装脚本
# 支持系统: Debian 10+, Ubuntu 18+, Alpine 3.12+
# 用法: bash <(curl -Ls xxx.sh)          # 安装
#      bash <(curl -Ls xxx.sh) uninstall # 卸载
# ============================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 配置文件路径
CONFIG_FILE="/opt/xray/node_config.txt"
XRAY_DIR="/opt/xray"
LOG_DIR="/var/log/xray"

# ============================================
# 卸载函数
# ============================================

uninstall() {
    echo -e "${YELLOW}[卸载] 开始卸载Xray+Argo隧道...${NC}"
    
    # 检查是否为root
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}❌ 卸载需要root权限，请使用 sudo 运行${NC}"
        exit 1
    fi
    
    # 第一步：停止服务
    echo -e "${YELLOW}[1/5] 停止服务...${NC}"
    
    systemctl stop xray 2>/dev/null || true
    systemctl stop cloudflared-temp 2>/dev/null || true
    echo -e "${GREEN}✓ 服务已停止${NC}"
    
    # 第二步：禁用服务
    echo -e "${YELLOW}[2/5] 禁用服务...${NC}"
    
    systemctl disable xray 2>/dev/null || true
    systemctl disable cloudflared-temp 2>/dev/null || true
    echo -e "${GREEN}✓ 服务已禁用${NC}"
    
    # 第三步：删除systemd服务文件
    echo -e "${YELLOW}[3/5] 删除systemd服务文件...${NC}"
    
    rm -f /etc/systemd/system/xray.service
    rm -f /etc/systemd/system/cloudflared-temp.service
    rm -f /etc/systemd/system/cloudflared-fixed.service 2>/dev/null || true
    systemctl daemon-reload
    echo -e "${GREEN}✓ 服务文件已删除${NC}"
    
    # 第四步：卸载软件包
    echo -e "${YELLOW}[4/5] 卸载软件包...${NC}"
    
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    fi
    
    if [ "$OS" = "debian" ] || [ "$OS" = "ubuntu" ]; then
        apt-get remove -y cloudflared 2>/dev/null || true
        apt-get autoremove -y 2>/dev/null || true
    elif [ "$OS" = "alpine" ]; then
        apk del cloudflared 2>/dev/null || true
    fi
    echo -e "${GREEN}✓ 软件包已卸载${NC}"
    
    # 第五步：删除文件和目录
    echo -e "${YELLOW}[5/5] 删除文件和目录...${NC}"
    
    # 删除Xray目录
    if [ -d "$XRAY_DIR" ]; then
        rm -rf "$XRAY_DIR"
        echo -e "${GREEN}✓ 已删除 $XRAY_DIR${NC}"
    fi
    
    # 删除日志目录
    if [ -d "$LOG_DIR" ]; then
        rm -rf "$LOG_DIR"
        echo -e "${GREEN}✓ 已删除 $LOG_DIR${NC}"
    fi
    
    # 删除cloudflared配置
    rm -rf /root/.cloudflared 2>/dev/null || true
    rm -f /etc/cloudflared/config.yml 2>/dev/null || true
    
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}✓ 卸载完成！${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "${YELLOW}已删除的内容：${NC}"
    echo "  • Xray核心程序"
    echo "  • Cloudflared隧道客户端"
    echo "  • 所有配置文件"
    echo "  • 日志文件"
    echo "  • Systemd服务"
    echo ""
    exit 0
}

# ============================================
# 系统检测
# ============================================

echo -e "${YELLOW}[1/5] 系统检测中...${NC}"

# 检测系统类型
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    VER=$VERSION_ID
else
    echo -e "${RED}❌ 无法识别系统${NC}"
    exit 1
fi

echo -e "${GREEN}✓ 系统: $OS $VER${NC}"

# 检测架构
ARCH=$(uname -m)
case $ARCH in
    x86_64)
        ARCH_NAME="amd64"
        ;;
    aarch64)
        ARCH_NAME="arm64"
        ;;
    armv7l)
        ARCH_NAME="armv7"
        ;;
    *)
        echo -e "${RED}❌ 不支持的架构: $ARCH${NC}"
        exit 1
        ;;
esac

echo -e "${GREEN}✓ 架构: $ARCH_NAME${NC}"

# ============================================
# 检查命令行参数
# ============================================

if [ "$1" = "uninstall" ]; then
    uninstall
fi

# ============================================
# 第二步：依赖检查与安装
# ============================================

echo -e "${YELLOW}[2/5] 依赖检查与安装...${NC}"

if [ "$OS" = "debian" ] || [ "$OS" = "ubuntu" ]; then
    apt-get update
    apt-get install -y curl wget unzip jq openssl
elif [ "$OS" = "alpine" ]; then
    apk add --no-cache curl wget unzip jq openssl
else
    echo -e "${RED}❌ 不支持的系统${NC}"
    exit 1
fi

echo -e "${GREEN}✓ 依赖安装完成${NC}"

# ============================================
# 第三步：安装Xray
# ============================================

echo -e "${YELLOW}[3/5] 安装Xray内核...${NC}"

# 下载Xray
XRAY_VERSION=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest 2>/dev/null | \
    grep '"tag_name"' | head -1 | sed 's/.*"\([^"]*\)".*/\1/')
XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/v26.3.27/Xray-linux-64.zip"

mkdir -p $XRAY_DIR
cd $XRAY_DIR

echo "下载Xray ${XRAY_VERSION}..."
wget -q "$XRAY_URL" -O xray.zip
unzip -o xray.zip
rm xray.zip
chmod +x xray

echo -e "${GREEN}✓ Xray安装完成${NC}"

# ============================================
# 第四步：配置Xray
# ============================================

echo -e "${YELLOW}[4/5] 配置Xray...${NC}"

# 生成UUID
UUID=$(xray uuid)
echo "生成的UUID: $UUID"

# 生成随机路径
WS_PATH="/$(head -c 16 /dev/urandom | base64 | tr -d '=+/' | cut -c1-16)"
echo "WebSocket路径: $WS_PATH"

# 创建配置文件
cat > $XRAY_DIR/config.json << EOF
{
  "log": {
    "access": "$LOG_DIR/access.log",
    "error": "$LOG_DIR/error.log",
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": 443,
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "level": 0,
            "alterId": 0
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "wsSettings": {
          "path": "$WS_PATH"
        },
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "$XRAY_DIR/cert.pem",
              "keyFile": "$XRAY_DIR/key.pem"
            }
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    }
  ]
}
EOF

mkdir -p $LOG_DIR
chmod 755 $LOG_DIR

echo -e "${GREEN}✓ Xray配置完成${NC}"

# ============================================
# 第五步：安装Cloudflared（Argo隧道）
# ============================================

echo -e "${YELLOW}[5/5] 安装Cloudflared...${NC}"

if [ "$OS" = "debian" ] || [ "$OS" = "ubuntu" ]; then
    # 添加Cloudflare官方仓库
    mkdir -p /usr/share/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflared.list
    apt-get update
    apt-get install -y cloudflared
elif [ "$OS" = "alpine" ]; then
    apk add --no-cache cloudflared
fi

echo -e "${GREEN}✓ Cloudflared安装完成${NC}"

# ============================================
# 生成自签证书
# ============================================

echo -e "${YELLOW}生成自签证书...${NC}"

openssl req -x509 -newkey rsa:2048 -keyout $XRAY_DIR/key.pem -out $XRAY_DIR/cert.pem -days 365 -nodes -subj "/CN=example.com"

chmod 644 $XRAY_DIR/cert.pem
chmod 600 $XRAY_DIR/key.pem

echo -e "${GREEN}✓ 证书生成完成${NC}"

# ============================================
# 创建systemd服务
# ============================================

echo -e "${YELLOW}创建系统服务...${NC}"

# Xray服务
cat > /etc/systemd/system/xray.service << 'EOF'
[Unit]
Description=Xray Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/opt/xray/xray -c /opt/xray/config.json
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Cloudflared服务（临时隧道）
cat > /etc/systemd/system/cloudflared-temp.service << 'EOF'
[Unit]
Description=Cloudflared Temporary Tunnel
After=network.target xray.service

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate --metrics localhost:3001 --url http://localhost:443
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable xray
systemctl enable cloudflared-temp

echo -e "${GREEN}✓ 系统服务创建完成${NC}"

# ============================================
# 启动服务
# ============================================

echo -e "${YELLOW}启动服务...${NC}"

systemctl start xray
sleep 2

if systemctl is-active --quiet xray; then
    echo -e "${GREEN}✓ Xray启动成功${NC}"
else
    echo -e "${RED}❌ Xray启动失败${NC}"
    systemctl status xray
    exit 1
fi

systemctl start cloudflared-temp
sleep 3

echo -e "${GREEN}✓ Cloudflared启动成功${NC}"

# ============================================
# 获取Argo隧道信息
# ============================================

echo -e "${YELLOW}获取Argo隧道信息...${NC}"

# 等待cloudflared启动完全
sleep 5

# 从metrics端口获取隧道域名
TUNNEL_DOMAIN=$(curl -s http://localhost:3001/quicktunnel 2>/dev/null | jq -r '.hostname' 2>/dev/null || echo "")

if [ -z "$TUNNEL_DOMAIN" ] || [ "$TUNNEL_DOMAIN" = "null" ]; then
    echo -e "${YELLOW}⚠ 无法自动获取隧道域名，请手动查看日志${NC}"
    echo -e "${YELLOW}查看日志命令: journalctl -u cloudflared-temp -n 20${NC}"
    TUNNEL_DOMAIN="获取失败，请查看日志"
else
    echo -e "${GREEN}✓ 隧道域名: $TUNNEL_DOMAIN${NC}"
fi

# ============================================
# 生成节点配置
# ============================================

echo -e "${YELLOW}生成节点配置...${NC}"

# VMess配置（Base64编码）
VMESS_CONFIG=$(cat << EOF | base64 -w 0
{
  "v": "2",
  "ps": "Xray-Argo-Node",
  "add": "$TUNNEL_DOMAIN",
  "port": 443,
  "id": "$UUID",
  "aid": 0,
  "net": "ws",
  "type": "none",
  "host": "$TUNNEL_DOMAIN",
  "path": "$WS_PATH",
  "tls": "tls"
}
EOF
)

VMESS_LINK="vmess://$VMESS_CONFIG"

# 保存配置到文件
cat > $CONFIG_FILE << EOF
=== Xray节点配置信息 ===

【基本信息】
UUID: $UUID
WebSocket路径: $WS_PATH
Argo隧道域名: $TUNNEL_DOMAIN
端口: 443
协议: VMess + TLS + WebSocket

【VMess链接】
$VMESS_LINK

【手动配置参数】
地址: $TUNNEL_DOMAIN
端口: 443
用户ID: $UUID
加密: auto
传输协议: ws
路径: $WS_PATH
TLS: 启用
SNI: $TUNNEL_DOMAIN

【二维码】
请使用支持VMess的客户端扫描下方二维码或复制链接

EOF

echo -e "${GREEN}✓ 节点配置生成完成${NC}"

# ============================================
# 输出总结
# ============================================

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✓ 安装完成！${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}【重要信息】${NC}"
echo "1. 节点配置已保存到: $CONFIG_FILE"
echo "2. Xray日志: journalctl -u xray -f"
echo "3. Cloudflared日志: journalctl -u cloudflared-temp -f"
echo ""
echo -e "${YELLOW}【下一步操作】${NC}"
echo ""
echo "【选项A】使用临时隧道（推荐测试）"
echo "  - 已自动启动，无需额外配置"
echo "  - 服务器重启后隧道域名会变化"
echo "  - 需要定期更新节点配置"
echo ""
echo "【选项B】使用固定隧道（推荐生产）"
echo "  1. 在Cloudflare Zero Trust创建隧道"
echo "  2. 获取Token和域名"
echo "  3. 编辑 /etc/systemd/system/cloudflared-fixed.service"
echo "  4. 运行: systemctl restart cloudflared-fixed"
echo ""
echo -e "${YELLOW}【CF优选配置】${NC}"
echo "  1. 使用CloudflareSpeedTest找到最快IP"
echo "  2. 修改本地hosts或DNS"
echo "  3. 将节点地址改为优选IP"
echo ""
echo -e "${YELLOW}【卸载方法】${NC}"
echo "  运行: bash <(curl -Ls xxx.sh) uninstall"
echo ""

cat $CONFIG_FILE

echo ""
echo -e "${GREEN}祝你使用愉快！${NC}"
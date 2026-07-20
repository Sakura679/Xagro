#!/bin/bash

# ============================================
# VPS代理节点+Argo隧道+CF优选 一键安装脚本
# 支持系统: Debian 10+, Ubuntu 18+, Alpine 3.12+
# ============================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ============================================
# 第一步：系统检测
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
# 第二步：依赖检查与安装
# ============================================

echo -e "${YELLOW}[2/5] 依赖检查与安装...${NC}"

if [ "$OS" = "debian" ] || [ "$OS" = "ubuntu" ]; then
    apt-get update
    apt-get install -y curl wget unzip jq
elif [ "$OS" = "alpine" ]; then
    apk add --no-cache curl wget unzip jq
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
XRAY_VERSION=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep tag_name | cut -d'"' -f4)
XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-${ARCH_NAME}.zip"

mkdir -p /opt/xray
cd /opt/xray

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
cat > /opt/xray/config.json << EOF
{
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
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
              "certificateFile": "/opt/xray/cert.pem",
              "keyFile": "/opt/xray/key.pem"
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

mkdir -p /var/log/xray
chmod 755 /var/log/xray

echo -e "${GREEN}✓ Xray配置完成${NC}"

# ============================================
# 第五步：安装Cloudflared（Argo隧道）
# ============================================

echo -e "${YELLOW}[5/5] 安装Cloudflared...${NC}"

if [ "$OS" = "debian" ] || [ "$OS" = "ubuntu" ]; then
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | apt-key add -
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

openssl req -x509 -newkey rsa:2048 -keyout /opt/xray/key.pem -out /opt/xray/cert.pem -days 365 -nodes -subj "/CN=example.com"

chmod 644 /opt/xray/cert.pem
chmod 600 /opt/xray/key.pem

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
TUNNEL_DOMAIN=$(curl -s http://localhost:3001/quicktunnel | jq -r '.hostname' 2>/dev/null || echo "获取失败")

if [ "$TUNNEL_DOMAIN" = "获取失败" ] || [ -z "$TUNNEL_DOMAIN" ]; then
    echo -e "${YELLOW}⚠ 无法自动获取隧道域名，请手动查看日志${NC}"
    journalctl -u cloudflared-temp -n 20
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
cat > /opt/xray/node_config.txt << EOF
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
echo "1. 节点配置已保存到: /opt/xray/node_config.txt"
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

cat /opt/xray/node_config.txt

echo ""
echo -e "${GREEN}祝你使用愉快！${NC}"
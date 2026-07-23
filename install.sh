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
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}[卸载] 开始卸载Xray+Argo隧道...${NC}"
    echo -e "${YELLOW}========================================${NC}"
    echo ""
    
    # 检查是否为root
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}❌ 卸载需要root权限，请使用 sudo 运行${NC}"
        exit 1
    fi
    
    # 第一步：停止服务
    echo -e "${YELLOW}[1/5] 停止服务...${NC}"
    systemctl stop xray 2>/dev/null || true
    systemctl stop cloudflared-temp 2>/dev/null || true
    systemctl stop cloudflared-fixed 2>/dev/null || true
    echo -e "${GREEN}✓ 服务已停止${NC}"
    
    # 第二步：禁用服务
    echo -e "${YELLOW}[2/5] 禁用服务...${NC}"
    systemctl disable xray 2>/dev/null || true
    systemctl disable cloudflared-temp 2>/dev/null || true
    systemctl disable cloudflared-fixed 2>/dev/null || true
    echo -e "${GREEN}✓ 服务已禁用${NC}"
    
    # 第三步：删除systemd服务文件
    echo -e "${YELLOW}[3/5] 删除systemd服务文件...${NC}"
    rm -f /etc/systemd/system/xray.service
    rm -f /etc/systemd/system/cloudflared-temp.service
    rm -f /etc/systemd/system/cloudflared-fixed.service
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
    
    if [ -d "$XRAY_DIR" ]; then
        rm -rf "$XRAY_DIR"
        echo -e "${GREEN}✓ 已删除 $XRAY_DIR${NC}"
    fi
    
    if [ -d "$LOG_DIR" ]; then
        rm -rf "$LOG_DIR"
        echo -e "${GREEN}✓ 已删除 $LOG_DIR${NC}"
    fi
    
    rm -rf /root/.cloudflared 2>/dev/null || true
    rm -f /etc/cloudflared/config.yml 2>/dev/null || true
    rm -f /etc/apt/sources.list.d/cloudflared.list 2>/dev/null || true
    rm -f /usr/share/keyrings/cloudflare-main.gpg 2>/dev/null || true
    
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}✓ 卸载完成！${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    exit 0
}

# ============================================
# 检查命令行参数
# ============================================

if [ "${1:-}" = "uninstall" ]; then
    uninstall
fi

# ============================================
# 第一步：系统检测
# ============================================

echo -e "${YELLOW}[1/5] 系统检测中...${NC}"

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
    apt-get update -qq
    apt-get install -y curl wget unzip jq openssl >/dev/null 2>&1
elif [ "$OS" = "alpine" ]; then
    apk add --no-cache curl wget unzip jq openssl >/dev/null 2>&1
else
    echo -e "${RED}❌ 不支持的系统${NC}"
    exit 1
fi

echo -e "${GREEN}✓ 依赖安装完成${NC}"

# ============================================
# 第三步：安装Xray
# ============================================

echo -e "${YELLOW}[3/5] 安装Xray内核...${NC}"

# 获取最新版本号（改进方法）
echo "获取最新版本信息..."
XRAY_VERSION=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest 2>/dev/null | \
    grep '"tag_name"' | head -1 | sed 's/.*"\([^"]*\)".*/\1/')

if [ -z "$XRAY_VERSION" ]; then
    echo -e "${YELLOW}⚠ 无法获取最新版本，使用默认版本 v1.8.7${NC}"
    XRAY_VERSION="v1.8.7"
fi

echo -e "${GREEN}✓ 最新版本: $XRAY_VERSION${NC}"

# 构建下载URL
# 判断 ARCH_NAME 如果是 amd64 则 XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-64.zip"
# 如果是 arm64 则 XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-${ARCH_NAME}.zip"
if [ "$ARCH_NAME" = "amd64" ]; then
    XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-64.zip"
fi

if [ "$ARCH_NAME" = "arm64" ]; then
    XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-${ARCH_NAME}.zip"
fi

mkdir -p $XRAY_DIR
cd $XRAY_DIR

echo "下载Xray ${XRAY_VERSION}..."
if ! wget -q --timeout=30 "$XRAY_URL" -O xray.zip 2>/dev/null; then
    echo -e "${RED}❌ 下载失败，请检查网络连接${NC}"
    exit 1
fi

if ! unzip -o xray.zip >/dev/null 2>&1; then
    echo -e "${RED}❌ 解压失败${NC}"
    exit 1
fi

rm -f xray.zip
chmod +x xray

echo -e "${GREEN}✓ Xray安装完成${NC}"

# ============================================
# 第四步：配置Xray
# ============================================

echo -e "${YELLOW}[4/5] 配置Xray...${NC}"

# 生成UUID
UUID=$(./xray uuid 2>/dev/null || echo "$(cat /proc/sys/kernel/random/uuid)")
echo "生成的UUID: $UUID"

# 生成随机路径
WS_PATH="/$(head -c 16 /dev/urandom | base64 | tr -d '=+/' | cut -c1-16)"
echo "WebSocket路径: $WS_PATH"

# 创建日志目录
mkdir -p $LOG_DIR
chmod 755 $LOG_DIR

# 生成自签证书
echo "生成自签证书..."
openssl req -x509 -newkey rsa:2048 -keyout $XRAY_DIR/key.pem -out $XRAY_DIR/cert.pem \
    -days 365 -nodes -subj "/CN=example.com" 2>/dev/null

chmod 644 $XRAY_DIR/cert.pem
chmod 600 $XRAY_DIR/key.pem

# 创建Xray配置文件
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

echo -e "${GREEN}✓ Xray配置完成${NC}"

# ============================================
# 第五步：安装Cloudflared
# ============================================

echo -e "${YELLOW}[5/5] 安装Cloudflared...${NC}"

if [ "$OS" = "debian" ] || [ "$OS" = "ubuntu" ]; then
    # 添加Cloudflare官方仓库
    mkdir -p /usr/share/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg 2>/dev/null | \
        tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" | \
        tee /etc/apt/sources.list.d/cloudflared.list >/dev/null
    apt-get update -qq
    apt-get install -y cloudflared >/dev/null 2>&1
elif [ "$OS" = "alpine" ]; then
    apk add --no-cache cloudflared >/dev/null 2>&1
fi

echo -e "${GREEN}✓ Cloudflared安装完成${NC}"

# ============================================
# 创建systemd服务
# ============================================

echo -e "${YELLOW}创建系统服务...${NC}"

# Xray服务
cat > /etc/systemd/system/xray.service << 'XRAY_SERVICE'
[Unit]
Description=Xray Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/xray
ExecStart=/opt/xray/xray -c /opt/xray/config.json
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
XRAY_SERVICE

# Cloudflared临时隧道服务
cat > /etc/systemd/system/cloudflared-temp.service << 'CLOUDFLARED_SERVICE'
[Unit]
Description=Cloudflared Temporary Tunnel
After=network.target xray.service

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate --metrics localhost:3001 --url http://localhost:443
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
CLOUDFLARED_SERVICE

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

# 从日志获取隧道域名
TUNNEL_DOMAIN=$(journalctl -u cloudflared-temp -n 50 --no-pager 2>/dev/null | \
    grep -oP '(?<=https://)[a-z0-9.-]+\.trycloudflare\.com' | head -1)

if [ -z "$TUNNEL_DOMAIN" ]; then
    echo -e "${YELLOW}⚠ 无法自动获取隧道域名${NC}"
    echo -e "${YELLOW}请运行以下命令查看日志:${NC}"
    echo "journalctl -u cloudflared-temp -f"
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
╔════════════════════════════════════════════════════════════╗
║         Xray + Argo隧道 节点配置信息                        ║
╚════════════════════════════════════════════════════════════╝

【基本信息】
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
UUID:              $UUID
WebSocket路径:     $WS_PATH
Argo隧道域名:      $TUNNEL_DOMAIN
端口:              443
协议:              VMess + TLS + WebSocket
加密方式:          auto
传输协议:          ws

【VMess链接】
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
$VMESS_LINK

【手动配置参数】
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
地址:              $TUNNEL_DOMAIN
端口:              443
用户ID:            $UUID
加密:              auto
传输协议:          ws
路径:              $WS_PATH
TLS:               启用
SNI:               $TUNNEL_DOMAIN

【客户端支持】
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✓ v2rayN (Windows)
✓ v2rayNG (Android)
✓ Shadowrocket (iOS)
✓ Clash (跨平台)
✓ Quantumult X (iOS)

【重要提示】
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
1. 隧道域名会在服务器重启后变化
2. 需要定期更新节点配置
3. 建议使用固定隧道以获得稳定域名
4. 配置文件位置: $CONFIG_FILE

【日志查看】
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Xray日志:          journalctl -u xray -f
Cloudflared日志:   journalctl -u cloudflared-temp -f

【服务管理】
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
启动服务:          systemctl start xray
停止服务:          systemctl stop xray
重启服务:          systemctl restart xray
查看状态:          systemctl status xray

【卸载方法】
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
bash <(curl -Ls https://raw.githubusercontent.com/Sakura679/Xagro/main/install.sh) uninstall

EOF

echo -e "${GREEN}✓ 节点配置生成完成${NC}"

# ============================================
# 输出总结
# ============================================

echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                    ✓ 安装完成！                            ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

echo -e "${YELLOW}【重要信息】${NC}"
echo "1. 节点配置已保存到: $CONFIG_FILE"
echo "2. 请立即查看配置文件获取节点信息"
echo "3. 隧道域名会在服务器重启后变化"
echo ""

echo -e "${YELLOW}【快速查看配置】${NC}"
echo "cat $CONFIG_FILE"
echo ""

echo -e "${YELLOW}【查看实时日志】${NC}"
echo "Xray:       journalctl -u xray -f"
echo "Cloudflared: journalctl -u cloudflared-temp -f"
echo ""

echo -e "${YELLOW}【下一步操作】${NC}"
echo ""
echo "【选项A】使用临时隧道（已启用）"
echo "  ✓ 无需额外配置"
echo "  ✗ 服务器重启后域名会变化"
echo "  ✗ 需要定期更新节点配置"
echo ""
echo "【选项B】使用固定隧道（推荐生产环境）"
echo "  1. 访问 https://dash.cloudflare.com/login"
echo "  2. 进入 Zero Trust > Tunnels"
echo "  3. 创建新隧道并获取Token"
echo "  4. 编辑 /etc/systemd/system/cloudflared-fixed.service"
echo "  5. 运行: systemctl restart cloudflared-fixed"
echo ""
echo "【选项C】使用CF优选IP加速"
echo "  1. 下载 CloudflareSpeedTest"
echo "  2. 找到最快的Cloudflare IP"
echo "  3. 修改本地hosts或DNS"
echo "  4. 将节点地址改为优选IP"
echo ""

echo -e "${YELLOW}【配置文件内容】${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
cat $CONFIG_FILE
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

echo -e "${GREEN}祝你使用愉快！${NC}"
echo ""

# ============================================
# 可选：创建固定隧道服务模板
# ============================================

cat > /etc/systemd/system/cloudflared-fixed.service << 'FIXED_SERVICE'
[Unit]
Description=Cloudflared Fixed Tunnel
After=network.target xray.service

[Service]
Type=simple
User=root
# 替换为你的Token和隧道名称
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate run --token YOUR_TOKEN_HERE
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
FIXED_SERVICE

# ============================================
# 创建更新脚本
# ============================================

cat > /opt/xray/update_config.sh << 'UPDATE_SCRIPT'
#!/bin/bash

# 更新节点配置脚本
# 用法: bash /opt/xray/update_config.sh

CONFIG_FILE="/opt/xray/node_config.txt"
LOG_DIR="/var/log/xray"

echo "正在获取最新隧道信息..."

# 从日志获取隧道域名
TUNNEL_DOMAIN=$(journalctl -u cloudflared-temp -n 100 --no-pager 2>/dev/null | \
    grep -oP '(?<=https://)[a-z0-9.-]+\.trycloudflare\.com' | tail -1)

if [ -z "$TUNNEL_DOMAIN" ]; then
    echo "❌ 无法获取隧道域名"
    echo "请检查cloudflared服务状态:"
    systemctl status cloudflared-temp
    exit 1
fi

echo "✓ 隧道域名: $TUNNEL_DOMAIN"

# 读取UUID和路径
UUID=$(grep "UUID:" $CONFIG_FILE | awk '{print $NF}')
WS_PATH=$(grep "WebSocket路径:" $CONFIG_FILE | awk '{print $NF}')

# 生成新的VMess链接
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

# 更新配置文件
cat > $CONFIG_FILE << EOF
╔════════════════════════════════════════════════════════════╗
║         Xray + Argo隧道 节点配置信息                        ║
║         更新时间: $(date '+%Y-%m-%d %H:%M:%S')                    ║
╚════════════════════════════════════════════════════════════╝

【基本信息】
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
UUID:              $UUID
WebSocket路径:     $WS_PATH
Argo隧道域名:      $TUNNEL_DOMAIN
端口:              443
协议:              VMess + TLS + WebSocket
加密方式:          auto
传输协议:          ws

【VMess链接】
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
$VMESS_LINK

【手动配置参数】
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
地址:              $TUNNEL_DOMAIN
端口:              443
用户ID:            $UUID
加密:              auto
传输协议:          ws
路径:              $WS_PATH
TLS:               启用
SNI:               $TUNNEL_DOMAIN

EOF

echo "✓ 配置文件已更新"
echo ""
echo "新的VMess链接:"
echo "$VMESS_LINK"
UPDATE_SCRIPT

chmod +x /opt/xray/update_config.sh

# ============================================
# 创建定时更新任务（可选）
# ============================================

# 创建cron任务脚本
cat > /opt/xray/cron_update.sh << 'CRON_SCRIPT'
#!/bin/bash

# 每小时检查一次隧道域名是否变化
# 如果变化则更新配置文件

CONFIG_FILE="/opt/xray/node_config.txt"
LAST_DOMAIN_FILE="/tmp/last_tunnel_domain.txt"

CURRENT_DOMAIN=$(journalctl -u cloudflared-temp -n 100 --no-pager 2>/dev/null | \
    grep -oP '(?<=https://)[a-z0-9.-]+\.trycloudflare\.com' | tail -1)

if [ -z "$CURRENT_DOMAIN" ]; then
    exit 1
fi

LAST_DOMAIN=$(cat $LAST_DOMAIN_FILE 2>/dev/null)

if [ "$CURRENT_DOMAIN" != "$LAST_DOMAIN" ]; then
    echo "$CURRENT_DOMAIN" > $LAST_DOMAIN_FILE
    /opt/xray/update_config.sh
    echo "隧道域名已变化，配置已更新" | logger -t xray-update
fi
CRON_SCRIPT

chmod +x /opt/xray/cron_update.sh

# ============================================
# 创建监控脚本
# ============================================

cat > /opt/xray/monitor.sh << 'MONITOR_SCRIPT'
#!/bin/bash

# 监控脚本 - 检查服务状态

echo "╔════════════════════════════════════════════════════════════╗"
echo "║              Xray + Argo 服务监控                          ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# 检查Xray
echo "【Xray服务】"
if systemctl is-active --quiet xray; then
    echo "✓ 状态: 运行中"
    echo "  进程ID: $(systemctl show -p MainPID --value xray)"
    echo "  内存占用: $(ps aux | grep '[x]ray' | awk '{print $6}')KB"
else
    echo "✗ 状态: 已停止"
fi
echo ""

# 检查Cloudflared
echo "【Cloudflared服务】"
if systemctl is-active --quiet cloudflared-temp; then
    echo "✓ 状态: 运行中"
    TUNNEL_DOMAIN=$(journalctl -u cloudflared-temp -n 50 --no-pager 2>/dev/null | \
        grep -oP '(?<=https://)[a-z0-9.-]+\.trycloudflare\.com' | head -1)
    echo "  隧道域名: $TUNNEL_DOMAIN"
else
    echo "✗ 状态: 已停止"
fi
echo ""

# 检查端口
echo "【端口监听】"
if netstat -tuln 2>/dev/null | grep -q ":443 "; then
    echo "✓ 443端口: 监听中"
else
        echo "✗ 443端口: 未监听"
fi
echo ""

# 检查日志错误
echo "【最近错误日志】"
ERROR_COUNT=$(journalctl -u xray -n 100 --no-pager 2>/dev/null | grep -i "error" | wc -l)
if [ $ERROR_COUNT -eq 0 ]; then
    echo "✓ 无错误"
else
    echo "⚠ 发现 $ERROR_COUNT 条错误日志"
    journalctl -u xray -n 10 --no-pager 2>/dev/null | grep -i "error" | head -3
fi
echo ""

# 检查磁盘空间
echo "【磁盘空间】"
DISK_USAGE=$(df /opt/xray | awk 'NR==2 {print $5}')
echo "  使用率: $DISK_USAGE"
echo ""

# 检查日志大小
echo "【日志文件大小】"
if [ -f /var/log/xray/access.log ]; then
    ACCESS_SIZE=$(du -h /var/log/xray/access.log | awk '{print $1}')
    echo "  access.log: $ACCESS_SIZE"
fi
if [ -f /var/log/xray/error.log ]; then
    ERROR_SIZE=$(du -h /var/log/xray/error.log | awk '{print $1}')
    echo "  error.log: $ERROR_SIZE"
fi
echo ""

echo "╔════════════════════════════════════════════════════════════╗"
echo "║                    监控完成                                ║"
echo "╚════════════════════════════════════════════════════════════╝"
MONITOR_SCRIPT

chmod +x /opt/xray/monitor.sh

# ============================================
# 创建日志清理脚本
# ============================================

cat > /opt/xray/clean_logs.sh << 'CLEAN_SCRIPT'
#!/bin/bash

# 日志清理脚本 - 清理超过7天的日志

LOG_DIR="/var/log/xray"
DAYS=7

echo "清理 $LOG_DIR 中超过 $DAYS 天的日志..."

if [ -d "$LOG_DIR" ]; then
    find "$LOG_DIR" -type f -name "*.log" -mtime +$DAYS -delete
    echo "✓ 清理完成"
else
    echo "✗ 日志目录不存在"
fi

# 压缩当前日志
if [ -f "$LOG_DIR/access.log" ]; then
    gzip -c "$LOG_DIR/access.log" > "$LOG_DIR/access.log.$(date +%Y%m%d).gz"
    > "$LOG_DIR/access.log"
fi

if [ -f "$LOG_DIR/error.log" ]; then
    gzip -c "$LOG_DIR/error.log" > "$LOG_DIR/error.log.$(date +%Y%m%d).gz"
    > "$LOG_DIR/error.log"
fi

echo "✓ 日志已压缩和清理"
CLEAN_SCRIPT

chmod +x /opt/xray/clean_logs.sh

# ============================================
# 创建快速命令别名
# ============================================

cat > /opt/xray/aliases.sh << 'ALIASES_SCRIPT'
#!/bin/bash

# 快速命令别名

alias xray-status='systemctl status xray'
alias xray-start='systemctl start xray'
alias xray-stop='systemctl stop xray'
alias xray-restart='systemctl restart xray'
alias xray-log='journalctl -u xray -f'
alias xray-config='cat /opt/xray/node_config.txt'
alias xray-monitor='/opt/xray/monitor.sh'
alias xray-update='/opt/xray/update_config.sh'
alias xray-clean='/opt/xray/clean_logs.sh'
alias cf-log='journalctl -u cloudflared-temp -f'
alias cf-status='systemctl status cloudflared-temp'

echo "✓ 别名已加载"
echo ""
echo "可用命令:"
echo "  xray-status      - 查看Xray状态"
echo "  xray-start       - 启动Xray"
echo "  xray-stop        - 停止Xray"
echo "  xray-restart     - 重启Xray"
echo "  xray-log         - 查看Xray日志"
echo "  xray-config      - 查看节点配置"
echo "  xray-monitor     - 监控服务状态"
echo "  xray-update      - 更新节点配置"
echo "  xray-clean       - 清理日志"
echo "  cf-log           - 查看Cloudflared日志"
echo "  cf-status        - 查看Cloudflared状态"
ALIASES_SCRIPT

chmod +x /opt/xray/aliases.sh
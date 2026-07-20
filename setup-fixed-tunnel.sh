#!/bin/bash

# ============================================
# Cloudflare固定隧道配置脚本
# ============================================

echo "=== Cloudflare固定隧道配置 ==="
echo ""
echo "请从Cloudflare Zero Trust获取以下信息："
echo ""

read -p "请输入Tunnel Token (eyJ...): " TUNNEL_TOKEN
read -p "请输入隧道域名 (如: proxy.example.com): " TUNNEL_DOMAIN
read -p "请输入回源端口 (默认8888): " TUNNEL_PORT
TUNNEL_PORT=${TUNNEL_PORT:-8888}

# 创建固定隧道服务
cat > /etc/systemd/system/cloudflared-fixed.service << EOF
[Unit]
Description=Cloudflare Fixed Tunnel
After=network.target xray.service

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate run --token $TUNNEL_TOKEN
Restart=on-failure
RestartSec=5
Environment="TUNNEL_METRICS=localhost:3001"

[Install]
WantedBy=multi-user.target
EOF

# 创建Cloudflare配置文件
mkdir -p /etc/cloudflared

cat > /etc/cloudflared/config.yml << EOF
tunnel: $(echo $TUNNEL_TOKEN | jq -r '.tunnel_id' 2>/dev/null || echo "your-tunnel-id")
credentials-file: /root/.cloudflared/cert.pem
protocol: quic

ingress:
  - hostname: $TUNNEL_DOMAIN
    service: http://localhost:$TUNNEL_PORT
  - service: http_status:404
EOF

systemctl daemon-reload
systemctl enable cloudflared-fixed

echo ""
echo "✓ 固定隧道配置完成"
echo ""
echo "【Cloudflare Zero Trust配置步骤】"
echo "1. 访问: https://dash.cloudflare.com/login"
echo "2. 左侧菜单 → Zero Trust → Networks → Tunnels"
echo "3. 创建新隧道，选择Cloudflared"
echo "4. 复制Token值"
echo "5. 在Public Hostname中添加:"
echo "   - 子域名: proxy"
echo "   - 域名: example.com"
echo "   - 服务: HTTP"
echo "   - URL: localhost:$TUNNEL_PORT"
echo ""
echo "【启动固定隧道】"
echo "systemctl start cloudflared-fixed"
echo "systemctl status cloudflared-fixed"
echo ""
#!/bin/bash

# ============================================
# Cloudflare固定隧道配置脚本
# ============================================

set -euo pipefail

echo "=== Cloudflare固定隧道配置 ==="
echo ""
echo "请从Cloudflare Zero Trust获取以下信息："
echo ""

read -rp "请输入Tunnel Token (eyJ...): " TUNNEL_TOKEN
read -rp "请输入隧道域名 (如: proxy.example.com): " TUNNEL_DOMAIN
read -rp "请输入回源端口 (默认8888): " TUNNEL_PORT
TUNNEL_PORT=${TUNNEL_PORT:-8888}

# 从 Token 中提取 Tunnel ID (JWT 格式，需 base64url 解码 payload)
# 如果解析失败，提示用户手动输入
TUNNEL_ID=""
if [[ "$TUNNEL_TOKEN" =~ ^eyJ ]]; then
    # JWT 格式: header.payload.signature
    local payload
    payload=$(echo "$TUNNEL_TOKEN" | cut -d'.' -f2)
    # base64url 解码需要补齐 padding
    local padded
    padded=$(printf '%s' "$payload" | sed 's/%/%25/g; s/-/+/g; s/_/\//g')
    local pad_len=$((4 - ${#padded} % 4))
    [[ $pad_len -lt 4 ]] && padded="${padded}$(printf '=%.0s' $(seq 1 $pad_len))"
    TUNNEL_ID=$(echo "$padded" | base64 -d 2>/dev/null | jq -r '.tunnel_id // empty' 2>/dev/null || echo "")
fi

[[ -z "$TUNNEL_ID" ]] && {
    read -rp "无法从 Token 自动解析 Tunnel ID，请手动输入: " TUNNEL_ID
    [[ -z "$TUNNEL_ID" ]] && { echo "❌ Tunnel ID 不能为空"; exit 1; }
}

# 创建固定隧道服务 (使用 token 方式，无需配置文件)
cat > /etc/systemd/system/cloudflared-fixed.service << EOF
[Unit]
Description=Cloudflare Fixed Tunnel
After=network.target xray.service

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate run --token ${TUNNEL_TOKEN}
Restart=on-failure
RestartSec=5
Environment="TUNNEL_METRICS=localhost:3001"

[Install]
WantedBy=multi-user.target
EOF

# 创建Cloudflare配置文件 (备用，token 模式下不需要)
mkdir -p /etc/cloudflared

cat > /etc/cloudflared/config.yml << EOF
tunnel: ${TUNNEL_ID}
credentials-file: /root/.cloudflared/cert.pem
protocol: quic

ingress:
  - hostname: ${TUNNEL_DOMAIN}
    service: http://localhost:${TUNNEL_PORT}
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
echo "   - URL: localhost:${TUNNEL_PORT}"
echo ""
echo "【启动固定隧道】"
echo "systemctl start cloudflared-fixed"
echo "systemctl status cloudflared-fixed"
echo ""
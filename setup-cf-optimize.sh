#!/bin/bash

# ============================================
# Cloudflare优选IP配置脚本
# ============================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 支持非交互模式：通过环境变量传参
# CFST_COLO="NRT,HND,KIX" CFST_TL=200 CFST_DN=5 CFST_SL=1 CFST_P=5
# CFST_MODE=hosts CFST_DOMAIN=proxy.example.com ./setup-cf-optimize.sh

echo -e "${YELLOW}=== Cloudflare优选IP配置 ===${NC}"
echo ""

# ============================================
# 第一步：下载CloudflareSpeedTest
# ============================================

echo -e "${YELLOW}[1/3] 下载CloudflareSpeedTest工具...${NC}"

ARCH=$(uname -m)
case $ARCH in
    x86_64)
        CFST_URL="https://github.com/XIU2/CloudflareSpeedTest/releases/download/v2.3.5/cfst_linux_amd64.tar.gz"
        ;;
    aarch64)
        CFST_URL="https://github.com/XIU2/CloudflareSpeedTest/releases/download/v2.3.5/cfst_linux_arm64.tar.gz"
        ;;
    *)
        echo -e "${RED}❌ 不支持的架构${NC}"
        exit 1
        ;;
esac

mkdir -p /opt/cfst
cd /opt/cfst

wget -q "$CFST_URL" -O cfst.tar.gz
tar -zxf cfst.tar.gz --strip-components=1
rm cfst.tar.gz
chmod +x cfst

echo -e "${GREEN}✓ 工具下载完成${NC}"

# ============================================
# 第二步：测速并找到最快IP
# ============================================

echo -e "${YELLOW}[2/3] 测速Cloudflare IP...${NC}"
echo "这可能需要2-5分钟，请耐心等待..."
echo ""

cd /opt/cfst

# 可配置参数 (环境变量优先，其次默认值)
CFST_COLO="${CFST_COLO:-NRT,HND,KIX,TPE,KHH,ICN,GMP,PUS,SIN,LAX,SJC}"
CFST_TL="${CFST_TL:-200}"
CFST_DN="${CFST_DN:-5}"
CFST_SL="${CFST_SL:-1}"
CFST_P="${CFST_P:-5}"

# 运行测速
./cfst -httping -cfcolo "$CFST_COLO" -tl "$CFST_TL" -dn "$CFST_DN" -sl "$CFST_SL" -p "$CFST_P"

echo ""
echo -e "${GREEN}✓ 测速完成${NC}"

# ============================================
# 第三步：提取最快IP并配置
# ============================================

echo -e "${YELLOW}[3/3] 配置最快IP...${NC}"

# 从result.csv提取第一个IP（最快的）
BEST_IP=$(tail -n +2 result.csv | head -n 1 | cut -d',' -f1)

if [ -z "$BEST_IP" ]; then
    echo -e "${RED}❌ 未找到可用IP${NC}"
    exit 1
fi

echo -e "${GREEN}✓ 最快IP: $BEST_IP${NC}"

# ============================================
# 配置方式选择 (支持非交互模式)
# ============================================

# 非交互模式：通过环境变量指定
# CFST_MODE=hosts CFST_DOMAIN=proxy.example.com
# CFST_MODE=dns
# CFST_MODE=show
CHOICE="${CFST_MODE:-}"
DOMAIN="${CFST_DOMAIN:-}"

if [[ -z "$CHOICE" ]]; then
    echo ""
    echo -e "${YELLOW}【配置方式选择】${NC}"
    echo "1. 修改本地hosts文件"
    echo "2. 修改DNS解析"
    echo "3. 仅显示结果"
    echo ""
    read -rp "请选择 (1-3): " CHOICE
fi

case $CHOICE in
    1|hosts)
        [[ -z "$DOMAIN" ]] && read -rp "请输入要加速的域名 (如: proxy.example.com): " DOMAIN
        [[ -z "$DOMAIN" ]] && { echo -e "${RED}❌ 域名不能为空${NC}"; exit 1; }

        # 备份hosts (带时间戳防并发覆盖)
        cp /etc/hosts "/etc/hosts.bak.$(date +%s)"

        # 移除旧记录
        sed -i "/$DOMAIN/d" /etc/hosts

        # 添加新记录
        echo "$BEST_IP  $DOMAIN" >> /etc/hosts

        echo -e "${GREEN}✓ hosts已更新${NC}"
        echo "  $BEST_IP  $DOMAIN"
        ;;
    2|dns)
        echo -e "${YELLOW}请在你的DNS服务商添加以下A记录:${NC}"
        echo "  记录类型: A"
        echo "  记录值: $BEST_IP"
        ;;
    3|show|*)
        echo -e "${GREEN}✓ 测速结果已保存到: /opt/cfst/result.csv${NC}"
        ;;
esac

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✓ CF优选配置完成！${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "【完整结果】"
cat result.csv
echo ""
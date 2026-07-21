#!/bin/bash

# ============================================
# Cloudflare优选IP配置脚本
# ============================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

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
tar -zxf cfst.tar.gz
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

# 运行测速
# -tl 200: 延迟上限200ms
# -dn 10: 下载测速前10个IP
# -sl 1: 下载速度下限1MB/s
./cfst -cfcolo KHH,NRT,LAX,SEA,SJC,FRA,MAD -tl 200 -dn 25 -sl 1 -p 25

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
# 配置方式选择
# ============================================

echo ""
echo -e "${YELLOW}【配置方式选择】${NC}"
echo "1. 修改本地hosts文件"
echo "2. 修改DNS解析"
echo "3. 仅显示结果"
echo ""

read -p "请选择 (1-3): " CHOICE

case $CHOICE in
    1)
        read -p "请输入要加速的域名 (如: proxy.example.com): " DOMAIN
        
        # 备份hosts
        cp /etc/hosts /etc/hosts.bak
        
        # 移除旧记录
        sed -i "/$DOMAIN/d" /etc/hosts
        
        # 添加新记录
        echo "$BEST_IP  $DOMAIN" >> /etc/hosts
        
        echo -e "${GREEN}✓ hosts已更新${NC}"
        echo "  $BEST_IP  $DOMAIN"
        ;;
    2)
        echo -e "${YELLOW}请在你的DNS服务商添加以下A记录:${NC}"
        echo "  记录类型: A"
        echo "  记录值: $BEST_IP"
        ;;
    3)
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
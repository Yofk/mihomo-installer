#!/bin/bash

#================================================================
# mihomo (Meta) 一键安装脚本
#
# 版本: 2.0 (自动获取最新 Release)
# 系统支持: Linux (Debian, Ubuntu, CentOS)
# 架构支持: x86_64(amd64), aarch64(arm64), armv7l(armv7)
# 脚本作者: Gemini (基于 https://wiki.metacubex.one/startup/service/)
#================================================================

# --- 配置 ---
BINARY_PATH="/usr/local/bin/mihomo"
CONFIG_DIR="/etc/mihomo"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
SERVICE_FILE="/etc/systemd/system/mihomo.service"
GEOIP_URL="https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/country.mmdb"
API_URL="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# --- 函数 ---

# 打印错误信息
error() {
    echo -e "${RED}错误: $1${NC}"
    exit 1
}

# 打印成功信息
success() {
    echo -e "${GREEN}$1${NC}"
}

# 打印提示信息
info() {
    echo -e "${YELLOW}$1${NC}"
}

# 1. 检查 root 权限
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
       error "此脚本必须以 root 身份运行。"
    fi
}

# 2. 检查依赖
check_deps() {
    info "正在检查依赖 (curl, gzip, sed, grep)..."
    command -v curl >/dev/null 2>&1 || error "需要 'curl'，请先安装。"
    command -v gzip >/dev/null 2>&1 || error "需要 'gzip'，请先安装。"
    command -v sed >/dev/null 2>&1 || error "需要 'sed'，请先安装。"
    command -v grep >/dev/null 2>&1 || error "需要 'grep'，请先安装。"
}

# 3. 确定架构
get_arch() {
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) MIHOMO_ARCH="amd64" ;;
        aarch64) MIHOMO_ARCH="arm64" ;;
        armv7l) MIHOMO_ARCH="armv7" ;;
        *) 
            error "不支持的架构: $ARCH"
            ;;
    esac
    info "检测到架构: $MIHOMO_ARCH"
}

# 4. 下载和安装 mihomo
install_mihomo() {
    # 停止现有服务 (如果存在)
    if systemctl is-active --quiet mihomo; then
        info "检测到 mihomo 正在运行，正在停止服务..."
        systemctl stop mihomo
    fi
    
    # 自动获取最新版本号
    info "正在从 GitHub API 获取最新版本号..."
    # 使用 curl, grep 和 sed 提取最新版本号 (tag_name)，避免对 jq 的依赖
    LATEST_TAG=$(curl -s "$API_URL" | grep '"tag_name":' | sed -E 's/.*"tag_name": "([^"]+)".*/\1/')

    if [ -z "$LATEST_TAG" ]; then
        error "无法获取最新的 release-tag。请检查网络或 GitHub API 限制。"
    fi
    
    success "获取到最新版本: $LATEST_TAG"

    # 构建下载 URL (根据 GitHub Release 的命名规则)
    DOWNLOAD_URL="https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_TAG}/mihomo-linux-${MIHOMO_ARCH}-${LATEST_TAG}.gz"
    
    info "将从以下 URL 下载: $DOWNLOAD_URL"
    
    # 下载
    curl -L -o /tmp/mihomo.gz "$DOWNLOAD_URL"
    if [ $? -ne 0 ]; then
        error "下载 mihomo 失败。请检查 URL 或网络连接。"
    fi
    
    # 检查文件大小 (如果文件太小，说明下载失败)
    FILE_SIZE=$(ls -l /tmp/mihomo.gz | awk '{print $5}')
    if [ "$FILE_SIZE" -lt 1000000 ]; then # 假设 mihomo 压缩后至少大于 1MB
        error "下载的文件过小 ($FILE_SIZE 字节)，可能未下载成功。脚本终止。"
    fi

    # 解压和安装
    info "正在解压并安装到 $BINARY_PATH ..."
    gzip -df /tmp/mihomo.gz
    if [ $? -ne 0 ]; then
        error "解压失败。文件可能已损坏或格式不正确。"
    fi
    
    mv /tmp/mihomo "$BINARY_PATH"
    chmod +x "$BINARY_PATH"
    
    success "mihomo 二进制文件安装/更新成功。 ($($BINARY_PATH -v))"
}

# 5. 创建配置目录和文件
create_config() {
    mkdir -p "$CONFIG_DIR"
    
    # 下载 GeoIP 数据库
    info "正在下载 Country.mmdb..."
    curl -L -o "$CONFIG_DIR/Country.mmdb" "$GEOIP_URL"
    if [ $? -ne 0 ]; then
        info "警告: Country.mmdb 下载失败。mihomo 可能无法正常进行基于 IP 的规则匹配。"
    else
        success "Country.mmdb 下载成功。"
    fi
    
    # 创建最小配置文件 (如果不存在)
    if [ ! -f "$CONFIG_FILE" ]; then
        info "正在创建最小配置文件: $CONFIG_FILE"
        cat << EOF > "$CONFIG_FILE"
# mihomo 最小配置文件
# 更多信息请参考: https://wiki.metacubex.one/

# 外部控制 API (用于 Web UI)
external-controller: '0.0.0.0:9090'
# secret: '' # (可选) 设置 API 密钥

# 占位符 - 请添加您的代理和规则
proxies: []
proxy-groups: []
rules:
  - MATCH,DIRECT
EOF
    else
        info "检测到已存在的配置文件: $CONFIG_FILE，跳过创建。"
    fi
}

# 6. 创建 systemd 服务 (根据你提供的文档)
create_service() {
    info "正在创建 systemd 服务: $SERVICE_FILE"
    cat << EOF > "$SERVICE_FILE"
[Unit]
Description=mihomo daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=$BINARY_PATH -d $CONFIG_DIR
Restart=on-failure
RestartSec=10
LimitNPROC=500
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
}

# 7. 启动服务
start_service() {
    info "正在重载 systemd 并启用/启动 mihomo 服务..."
    systemctl daemon-reload
    systemctl enable --now mihomo
    
    # 检查服务状态
    if systemctl is-active --quiet mihomo; then
        success "mihomo 服务启动成功！"
    else
        error "mihomo 服务启动失败。请使用 'journalctl -u mihomo -f' 查看日志。"
    fi
}

# --- 主执行流程 ---
main() {
    check_root
    check_deps
    get_arch
    install_mihomo
    create_config
    create_service
    start_service
    
    # 最终提示
    echo ""
    success "----------------------------------------"
    success "mihomo 安装并启动成功！"
    info ""
    info "配置文件路径: $CONFIG_FILE"
    info "请立即编辑此文件以添加您的代理和规则配置。"
    info ""
    info "常用命令:"
    info "  查看服务状态: systemctl status mihomo"
    info "  查看实时日志: journalctl -u mihomo -f"
    info "  重启服务:     systemctl restart mihomo"
    info "  停止服务:     systemctl stop mihomo"
    success "----------------------------------------"
}

# 运行主函数
main

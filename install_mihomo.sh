#!/bin/bash

#================================================================
# mihomo (Meta) 一键管理脚本
#
# 版本: 3.1 (简洁化输出 / 动态生成 SS 密码)
# 系统支持: Linux (Debian, Ubuntu, CentOS)
# 架构支持: x86_64(amd64), aarch64(arm64), armv7l(armv7)
# 脚本作者: Gemini (根据用户需求定制)
#================================================================

# --- 配置 ---
BINARY_PATH="/usr/local/bin/mihomo"
CONFIG_DIR="/etc/mihomo"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
SERVICE_FILE="/etc/systemd/system/mihomo.service"
API_URL="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- 辅助函数 ---
error() {
    echo -e "${RED}错误: $1${NC}"
    exit 1
}

success() {
    echo -e "${GREEN}$1${NC}"
}

info() {
    echo -e "${YELLOW}$1${NC}"
}

# --- 检查函数 ---
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
       error "此脚本必须以 root 身份运行。"
    fi
}

check_deps() {
    info "正在检查依赖 (curl, gzip, sed, grep, cat, openssl)..."
    command -v curl >/dev/null 2>&1 || error "需要 'curl'，请先安装。"
    command -v gzip >/dev/null 2>&1 || error "需要 'gzip'，请先安装。"
    command -v sed >/dev/null 2>&1 || error "需要 'sed'，请先安装。"
    command -v grep >/dev/null 2>&1 || error "需要 'grep'，请先安装。"
    command -v cat >/dev/null 2>&1 || error "需要 'cat'，请先安装。"
    command -v openssl >/dev/null 2>&1 || error "需要 'openssl' ，请先安装。"
}

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
    # (已按要求移除 "检测到架构" 的输出)
}

# --- 核心功能函数 ---

# 4. 下载和安装 mihomo
install_mihomo_binary() {
    if systemctl is-active --quiet mihomo; then
        info "检测到 mihomo 正在运行，将在更新后重启服务..."
        systemctl stop mihomo
    fi
    
    info "正在从 GitHub API 获取最新版本号..."
    LATEST_TAG=$(curl -s "$API_URL" | grep '"tag_name":' | sed -E 's/.*"tag_name": "([^"]+)".*/\1/')

    if [ -z "$LATEST_TAG" ]; then
        error "无法获取最新的 release-tag。请检查网络或 GitHub API 限制。"
    fi
    success "获取到最新版本: $LATEST_TAG"

    FILENAME="mihomo-linux-${MIHOMO_ARCH}-${LATEST_TAG}.gz"
    local CPU_LEVEL="N/A" # 默认为 N/A (非 amd64)

    if [ "$MIHOMO_ARCH" = "amd64" ]; then
        local CPU_FLAGS
        CPU_FLAGS=$(cat /proc/cpuinfo)

        if echo "$CPU_FLAGS" | grep -q "avx2"; then
            CPU_LEVEL="v3 (avx2)"
            FILENAME="mihomo-linux-amd64-${LATEST_TAG}.gz"
        elif echo "$CPU_FLAGS" | grep -q "sse4_2" && echo "$CPU_FLAGS" | grep -q "popcnt"; then
            CPU_LEVEL="v2 (sse4_2)"
            FILENAME="mihomo-linux-amd64-v2-${LATEST_TAG}.gz"
        else
            CPU_LEVEL="v1 (compatible)"
            FILENAME="mihomo-linux-amd64-compatible-${LATEST_TAG}.gz"
        fi
        info "CPU 支持级别: ${CPU_LEVEL}。将下载 ${FILENAME}。"
    fi

    DOWNLOAD_URL="https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_TAG}/${FILENAME}"
    
    info "将从以下 URL 下载: $DOWNLOAD_URL"
    
    curl -L -o /tmp/mihomo.gz "$DOWNLOAD_URL"
    if [ $? -ne 0 ]; then error "下载 mihomo 失败。"; fi
    
    FILE_SIZE=$(ls -l /tmp/mihomo.gz | awk '{print $5}')
    if [ "$FILE_SIZE" -lt 1000000 ]; then
        error "下载的文件过小 ($FILE_SIZE 字节)，可能未下载成功。脚本终止。"
    fi

    info "正在解压并安装到 $BINARY_PATH ..."
    gzip -df /tmp/mihomo.gz
    if [ $? -ne 0 ]; then error "解压失败。"; fi
    
    mv /tmp/mihomo "$BINARY_PATH"
    chmod +x "$BINARY_PATH"
    
    success "mihomo 二进制文件安装/更新成功。 ($($BINARY_PATH -v))"
}

# 5. 创建配置目录和文件 (动态生成 SS 密码)
create_config() {
    mkdir -p "$CONFIG_DIR"
    
    if [ ! -f "$CONFIG_FILE" ]; then
        info "正在生成 Shadowsocks 随机密码..."
        SS_PASSWORD=$(openssl rand -base64 16)
        
        info "正在创建默认配置文件: $CONFIG_FILE"
        cat << EOF > "$CONFIG_FILE"
# mihomo 默认配置文件
# 配置了一个 Shadowsocks 入站
log-level: info
mode: rule
ipv6: false
find-process-mode: off
tcp-concurrent: true
unified-delay: false
allow-lan: false

dns:
  enable: true
  ipv6: false
  use-hosts: true
  use-system-hosts: true
  nameserver-policy: {}
  nameserver:
    - system
  enhanced-mode: normal

sniffer:
  enable: true
  override-destination: false

listeners:
  - name: "ss-in"
    type: shadowsocks
    port: 41200
    cipher: 2022-blake3-aes-128-gcm
    password: "${SS_PASSWORD}"
    udp: true
    udp-over-tcp: false

proxies:
  - name: "Direct"
    type: direct
    ip-version: ipv4-prefer
    udp: true

rules:
  - MATCH,Direct
EOF
        success "默认配置文件创建成功。"
        # 关键: 告诉用户新密码
        echo -e "${YELLOW}您的 Shadowsocks 密码已自动生成:${NC}"
        echo -e "${GREEN}${SS_PASSWORD}${NC}"
        info "该密码已保存在 $CONFIG_FILE 中。"
    else
        info "检测到已存在的配置文件: $CONFIG_FILE，跳过创建。"
    fi
}

# 6. 创建 systemd 服务
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
    
    if systemctl is-active --quiet mihomo; then
        success "mihomo 服务启动成功！"
    else
        error "mihomo 服务启动失败。请使用 'journalctl -u mihomo -f' 查看日志。"
    fi
}

# 8. 打印安装总结
print_summary() {
    echo ""
    success "----------------------------------------"
    success "mihomo 安装/更新并启动成功！"
    info ""
    info "配置文件路径: $CONFIG_FILE"
    info "默认配置包含一个 Shadowsocks 入站 (端口 41200)"
    info "(请查看上方显示的自动生成的密码)"
    info ""
    info "常用命令:"
    info "  查看服务状态: systemctl status mihomo"
    info "  查看实时日志: journalctl -u mihomo -f"
    info "  重启服务:     systemctl restart mihomo"
    info "  停止服务:     systemctl stop mihomo"
    success "----------------------------------------"
}

# --- 流程封装 ---

# 1. 安装/更新流程
install_mihomo_workflow() {
    info "开始 [安装/更新] mihomo..."
    check_root
    check_deps
    get_arch
    install_mihomo_binary
    create_config
    create_service
    start_service
    print_summary
}

# 2. 卸载流程
uninstall_mihomo_workflow() {
    info "开始 [卸载] mihomo..."
    check_root
    
    if ! systemctl is-active --quiet mihomo && [ ! -f "$BINARY_PATH" ]; then
        error "mihomo 似乎未安装。卸载中止。"
    fi

    info "正在停止并禁用 mihomo 服务..."
    systemctl stop mihomo
    systemctl disable mihomo
    
    info "正在删除服务文件和二进制文件..."
    rm -f "$SERVICE_FILE"
    rm -f "$BINARY_PATH"
    
    info "正在重载 systemd..."
    systemctl daemon-reload
    
    echo ""
    # 关键步骤：询问是否删除配置
    read -p "$(echo -e ${YELLOW}"是否删除配置文件目录 $CONFIG_DIR? (包含您的所有配置) [y/N]: "${NC})" confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        rm -rf "$CONFIG_DIR"
        success "已删除 $CONFIG_DIR。"
    else
        info "已保留 $CONFIG_DIR。"
    fi
    
    success "mihomo 卸载完成。"
}

# --- 主菜单 ---
main_menu() {
    clear
    echo -e "${CYAN}mihomo (Meta) 一键管理脚本 v3.1${NC}"
    echo "========================================"
    echo "请选择要执行的操作:"
    echo ""
    echo -e "  ${GREEN}1.${NC} 安装 / 更新 mihomo"
    echo -e "  ${RED}2.${NC} 卸载 mihomo"
    echo ""
    echo "  0. 退出脚本"
    echo "========================================"
    read -p "请输入选项 [1, 2, 0]: " choice

    case $choice in
        1)
            install_mihomo_workflow
            ;;
        2)
            uninstall_mihomo_workflow
            ;;
        0)
            echo "已退出脚本。"
            exit 0
            ;;
        *)
            error "无效选项。"
            sleep 2
            main_menu
            ;;
    esac
}

# --- 脚本入口 ---
main_menu
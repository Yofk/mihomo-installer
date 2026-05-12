#!/bin/bash

# ==========================================
# 说明: shadowsocks-rust 一键部署管理脚本 (增加日志功能)
# 默认配置: 41200端口, 2022-blake3-aes-128-gcm, 开启UDP
# ==========================================

# 颜色代码
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

# 全局变量
CONFIG_DIR="/etc/shadowsocks-rust"
CONFIG_FILE="${CONFIG_DIR}/config.json"
SERVICE_FILE="/etc/systemd/system/shadowsocks-rust.service"
BIN_FILE="/usr/local/bin/ssserver"

PORT=41200
METHOD="2022-blake3-aes-128-gcm"

# 检查 root 权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误：本脚本必须以 root 身份运行！${PLAIN}"
        exit 1
    fi
}

# 检查并安装依赖
install_dependencies() {
    echo -e "${YELLOW}正在检查并安装必要依赖...${PLAIN}"
    if command -v apt &> /dev/null; then
        apt update -y
        apt install -y curl wget tar xz-utils jq openssl systemd
    elif command -v yum &> /dev/null; then
        yum install -y curl wget tar xz jq openssl systemd
    else
        echo -e "${RED}不支持的包管理器，请手动安装 curl, wget, tar, xz, jq, openssl${PLAIN}"
        exit 1
    fi
}

# 获取系统架构
get_arch() {
    ARCH=$(uname -m)
    if [[ "$ARCH" == "x86_64" ]]; then
        RELEASE_ARCH="x86_64-unknown-linux-musl"
    elif [[ "$ARCH" == "aarch64" ]]; then
        RELEASE_ARCH="aarch64-unknown-linux-musl"
    else
        echo -e "${RED}不支持的系统架构: $ARCH${PLAIN}"
        exit 1
    fi
}

# 获取最新版本号
get_latest_version() {
    echo -e "${YELLOW}正在获取 shadowsocks-rust 最新版本号...${PLAIN}"
    LATEST_VERSION=$(curl -s https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [[ -z "$LATEST_VERSION" ]]; then
        echo -e "${RED}获取最新版本失败，请检查网络连接或 GitHub API 限制。${PLAIN}"
        exit 1
    fi
    echo -e "${GREEN}最新版本为: ${LATEST_VERSION}${PLAIN}"
}

# 开放防火墙端口
open_ports() {
    echo -e "${YELLOW}正在尝试开放端口 ${PORT}...${PLAIN}"
    if command -v ufw &> /dev/null; then
        ufw allow ${PORT}/tcp
        ufw allow ${PORT}/udp
    elif command -v firewall-cmd &> /dev/null; then
        firewall-cmd --zone=public --add-port=${PORT}/tcp --permanent
        firewall-cmd --zone=public --add-port=${PORT}/udp --permanent
        firewall-cmd --reload
    elif command -v iptables &> /dev/null; then
        iptables -A INPUT -p tcp --dport ${PORT} -j ACCEPT
        iptables -A INPUT -p udp --dport ${PORT} -j ACCEPT
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi
}

# 安装 shadowsocks-rust
install_ss() {
    if [[ -f "$BIN_FILE" ]]; then
        echo -e "${GREEN}shadowsocks-rust 已经安装！${PLAIN}"
        return
    fi

    install_dependencies
    get_arch
    get_latest_version

    echo -e "${YELLOW}正在下载 shadowsocks-rust ${LATEST_VERSION} ...${PLAIN}"
    DOWNLOAD_URL="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${LATEST_VERSION}/shadowsocks-${LATEST_VERSION}.${RELEASE_ARCH}.tar.xz"
    
    wget -N --no-check-certificate -O ss-rust.tar.xz "$DOWNLOAD_URL" || { echo -e "${RED}下载失败，请检查网络！${PLAIN}"; exit 1; }

    echo -e "${YELLOW}正在解压并安装...${PLAIN}"
    
    # 熔断机制：解压失败立刻退出，防止生成残缺的服务
    tar -xvf ss-rust.tar.xz ssserver || { echo -e "${RED}解压失败！可能是 xz 工具未正确安装或下载文件损坏。${PLAIN}"; exit 1; }
    
    mv ssserver "$BIN_FILE"
    chmod +x "$BIN_FILE"
    rm -f ss-rust.tar.xz

    # 生成配置
    echo -e "${YELLOW}正在生成配置文件...${PLAIN}"
    mkdir -p "$CONFIG_DIR"
    PASSWORD=$(openssl rand -base64 16)
    
    cat > "$CONFIG_FILE" <<EOF
{
    "server": "0.0.0.0",
    "server_port": ${PORT},
    "password": "${PASSWORD}",
    "method": "${METHOD}",
    "mode": "tcp_and_udp",
    "fast_open": true
}
EOF

    # 配置 Systemd 守护进程
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Shadowsocks-Rust Server Service
After=network.target

[Service]
Type=simple
User=root
LimitNOFILE=65535
ExecStart=${BIN_FILE} -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable shadowsocks-rust
    systemctl start shadowsocks-rust

    open_ports

    echo -e "${GREEN}shadowsocks-rust 安装并启动成功！${PLAIN}"
    show_info
}

# 更新 shadowsocks-rust
update_ss() {
    if [[ ! -f "$BIN_FILE" ]]; then
        echo -e "${RED}尚未安装 shadowsocks-rust！${PLAIN}"
        return
    fi

    get_arch
    get_latest_version

    echo -e "${YELLOW}正在更新到 ${LATEST_VERSION} ...${PLAIN}"
    DOWNLOAD_URL="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${LATEST_VERSION}/shadowsocks-${LATEST_VERSION}.${RELEASE_ARCH}.tar.xz"
    
    wget -N --no-check-certificate -O ss-rust.tar.xz "$DOWNLOAD_URL" || { echo -e "${RED}下载失败！${PLAIN}"; exit 1; }
    
    tar -xvf ss-rust.tar.xz ssserver || { echo -e "${RED}解压失败！${PLAIN}"; exit 1; }
    
    systemctl stop shadowsocks-rust
    mv ssserver "$BIN_FILE"
    chmod +x "$BIN_FILE"
    rm -f ss-rust.tar.xz
    systemctl start shadowsocks-rust

    echo -e "${GREEN}更新完成，已自动重启服务！${PLAIN}"
}

# 卸载 shadowsocks-rust
uninstall_ss() {
    echo -e "${YELLOW}准备卸载 shadowsocks-rust...${PLAIN}"
    systemctl stop shadowsocks-rust
    systemctl disable shadowsocks-rust
    
    rm -f "$BIN_FILE"
    rm -rf "$CONFIG_DIR"
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload

    echo -e "${GREEN}卸载成功！${PLAIN}"
}

# 查看服务状态和配置信息
show_info() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}配置文件不存在，请确认是否已安装。${PLAIN}"
        return
    fi

    CONF_PORT=$(jq -r '.server_port' < "$CONFIG_FILE")
    CONF_PWD=$(jq -r '.password' < "$CONFIG_FILE")
    CONF_METHOD=$(jq -r '.method' < "$CONFIG_FILE")
    SERVER_IP=$(curl -s4 icanhazip.com || curl -s4 ifconfig.me)

    echo -e "==========================================="
    echo -e "${GREEN}Shadowsocks-Rust 配置信息：${PLAIN}"
    echo -e " 服务器 IP   : ${GREEN}${SERVER_IP}${PLAIN}"
    echo -e " 端口号 (Port) : ${GREEN}${CONF_PORT}${PLAIN}"
    echo -e " 密码 (Pwd)  : ${GREEN}${CONF_PWD}${PLAIN}"
    echo -e " 加密 (Method): ${GREEN}${CONF_METHOD}${PLAIN}"
    echo -e " 运行状态    : $(systemctl is-active shadowsocks-rust)"
    echo -e "==========================================="
    echo -e "${YELLOW}注意: SS-2022 (AEAD) 协议需要较新的客户端支持 (如 v2rayN, Shadowrocket, Surge 等)。${PLAIN}"
}

# 查看实时日志
view_logs() {
    if [[ ! -f "$SERVICE_FILE" ]]; then
        echo -e "${RED}服务尚未安装，无法查看日志！${PLAIN}"
        return
    fi
    echo -e "${YELLOW}正在拉取 shadowsocks-rust 实时日志...${PLAIN}"
    echo -e "${GREEN}提示：按 Ctrl + C 即可退出日志查看状态。${PLAIN}"
    echo -e "-------------------------------------------"
    journalctl -u shadowsocks-rust -n 50 -f
}

# 服务管理
manage_service() {
    case $1 in
        start) systemctl start shadowsocks-rust && echo -e "${GREEN}服务已启动${PLAIN}" ;;
        stop) systemctl stop shadowsocks-rust && echo -e "${YELLOW}服务已停止${PLAIN}" ;;
        restart) systemctl restart shadowsocks-rust && echo -e "${GREEN}服务已重启${PLAIN}" ;;
    esac
}

# 主菜单
menu() {
    check_root
    clear
    echo -e "==========================================="
    echo -e " ${GREEN}Shadowsocks-Rust 一键部署与管理脚本${PLAIN}"
    echo -e "==========================================="
    echo -e " ${GREEN}1.${PLAIN} 安装 Shadowsocks-Rust"
    echo -e " ${GREEN}2.${PLAIN} 更新 Shadowsocks-Rust"
    echo -e " ${GREEN}3.${PLAIN} 卸载 Shadowsocks-Rust"
    echo -e "-------------------------------------------"
    echo -e " ${GREEN}4.${PLAIN} 启动 服务"
    echo -e " ${GREEN}5.${PLAIN} 停止 服务"
    echo -e " ${GREEN}6.${PLAIN} 重启 服务"
    echo -e " ${GREEN}7.${PLAIN} 查看 配置与状态信息"
    echo -e " ${GREEN}8.${PLAIN} 查看 实时日志"
    echo -e "-------------------------------------------"
    echo -e " ${GREEN}0.${PLAIN} 退出脚本"
    echo -e "==========================================="
    read -p "请输入数字 [0-8]: " num
    case "$num" in
        1) install_ss ;;
        2) update_ss ;;
        3) uninstall_ss ;;
        4) manage_service start ;;
        5) manage_service stop ;;
        6) manage_service restart ;;
        7) show_info ;;
        8) view_logs ;;
        0) exit 0 ;;
        *) echo -e "${RED}请输入正确的数字！${PLAIN}" ;;
    esac
}

# 运行菜单
menu

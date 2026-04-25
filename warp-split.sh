#!/usr/bin/env bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

#=================================================
#   基于 vpszdm.com/warp-google.sh 改造
#   功能：WARP 分流 —— 只让 Gemini + BitMart 走 WARP
#         其余流量全部走原生 IP
#   守护：每 60s 检测连通性，每 6h 自动更新 IP
#   重启：开机自动恢复所有规则
#=================================================

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
BLUE=$'\033[0;36m'
CYAN=$'\033[0;96m'
BOLD=$'\033[1m'
PLAIN=$'\033[0m'

info()  { echo -e "${BLUE}[INFO]${PLAIN}  $*"; }
ok()    { echo -e "${GREEN}[  OK]${PLAIN}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${PLAIN}  $*"; }
error() { echo -e "${RED}[FAIL]${PLAIN}  $*"; }
die()   { error "$*"; exit 1; }
hr()    { echo -e "${BLUE}──────────────────────────────────────────────────────${PLAIN}"; }

banner() {
    echo -e "${CYAN}"
    echo "  ╔══════════════════════════════════════════════════════╗"
    echo "  ║                                                      ║"
    echo "  ║     WARP 分流脚本  v1.0                              ║"
    echo "  ║     Gemini + BitMart → WARP                          ║"
    echo "  ║     其余流量 → 原生 IP                               ║"
    echo "  ║                                                      ║"
    echo "  ╚══════════════════════════════════════════════════════╝"
    echo -e "${PLAIN}"
}

[[ $EUID -ne 0 ]] && die "请使用 root 用户运行此脚本"

# ────────────── 系统检测 ──────────────
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS=$ID
    VER=$VERSION_ID
    CODENAME=${VERSION_CODENAME:-""}
else
    die "不支持的操作系统"
fi
DPKG_ARCH=$(dpkg --print-architecture 2>/dev/null || echo "amd64")

# ────────────── 安装依赖 ──────────────
install_deps() {
    hr
    info "安装依赖（redsocks / iptables / dnsutils）..."

    # 写好配置再安装，避免 apt 启动 redsocks 失败
    mkdir -p /etc/
    cat > /etc/redsocks.conf <<'REOF'
base {
    log_debug = off;
    log_info  = on;
    log       = "syslog:daemon";
    daemon    = on;
    redirector = iptables;
}
redsocks {
    local_ip   = 127.0.0.1;
    local_port = 12345;
    ip         = 127.0.0.1;
    port       = 40000;
    type       = socks5;
}
REOF

    # 阻止 apt 安装后自动启动 redsocks
    echo '#!/bin/sh
exit 101' > /usr/sbin/policy-rc.d
    chmod +x /usr/sbin/policy-rc.d

    case $OS in
        ubuntu|debian)
            apt-get update -qq
            apt-get install -y -qq redsocks iptables dnsutils curl
            ;;
        centos|rhel|rocky|almalinux|fedora)
            if command -v dnf &>/dev/null; then
                dnf install -y redsocks iptables bind-utils curl 2>/dev/null
            else
                yum install -y redsocks iptables bind-utils curl 2>/dev/null
            fi
            ;;
        *)
            die "不支持的系统: $OS"
            ;;
    esac

    rm -f /usr/sbin/policy-rc.d
    ok "依赖安装完成"
}

# ────────────── 安装 WARP（如未安装）──────────────
install_warp() {
    hr
    info "检查 Cloudflare WARP 客户端..."

    if command -v warp-cli &>/dev/null; then
        ok "warp-cli 已安装，跳过"
        return 0
    fi

    info "安装 warp-cli..."
    case $OS in
        ubuntu|debian)
            apt-get install -y -qq gnupg curl wget lsb-release
            curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
                | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
            echo "deb [arch=${DPKG_ARCH} signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] \
https://pkg.cloudflareclient.com/ ${CODENAME} main" \
                > /etc/apt/sources.list.d/cloudflare-client.list
            apt-get update -qq
            apt-get install -y cloudflare-warp
            ;;
        centos|rhel|rocky|almalinux|fedora)
            cat > /etc/yum.repos.d/cloudflare-warp.repo <<'EOF'
[cloudflare-warp]
name=Cloudflare WARP
baseurl=https://pkg.cloudflareclient.com/rpm
enabled=1
gpgcheck=1
gpgkey=https://pkg.cloudflareclient.com/pubkey.gpg
EOF
            command -v dnf &>/dev/null && dnf install -y cloudflare-warp \
                || yum install -y cloudflare-warp
            ;;
    esac

    command -v warp-cli &>/dev/null || die "WARP 安装失败"
    ok "warp-cli 安装完成"
}

# ────────────── 配置并连接 WARP ──────────────
configure_warp() {
    hr
    info "配置 WARP（proxy 模式，端口 40000）..."

    local tos_dir="/var/lib/cloudflare-warp"
    mkdir -p "$tos_dir"
    [[ ! -f "${tos_dir}/accepted-tos.json" ]] && echo '{"accepted":true}' > "${tos_dir}/accepted-tos.json"

    systemctl restart warp-svc 2>/dev/null || true
    sleep 2

    warp-cli --accept-tos registration new 2>/dev/null \
        || warp-cli --accept-tos register 2>/dev/null || true

    warp-cli --accept-tos mode proxy 2>/dev/null \
        || warp-cli mode proxy 2>/dev/null || true

    warp-cli --accept-tos proxy port 40000 2>/dev/null \
        || warp-cli proxy port 40000 2>/dev/null || true

    warp-cli --accept-tos connect 2>/dev/null \
        || warp-cli connect 2>/dev/null || true

    sleep 3
    ok "WARP 状态: $(warp-cli status 2>/dev/null | head -1)"
}

# ────────────── 写守护脚本 ──────────────
write_guard() {
    hr
    info "写入守护脚本 /root/warp_guard.sh ..."

    cat > /root/warp_guard.sh << 'GUARD'
#!/bin/bash
# WARP 分流守护脚本
# 每 60s 检测连通性；每 6h 自动更新 Gemini / BitMart IP

update_ips() {
    GEMINI_IPS=$(dig +short gemini.google.com generativelanguage.googleapis.com \
        | grep -E '^[0-9]+\.')
    BITMART_IPS=$(dig +short bitmart.com www.bitmart.com \
        | grep -E '^[0-9]+\.')

    # 重建 iptables 链
    iptables -t nat -F WARP_GOOGLE 2>/dev/null

    for ip in $GEMINI_IPS; do
        iptables -t nat -A WARP_GOOGLE -p tcp -d "$ip" -j REDIRECT --to-ports 12345
    done
    for ip in $BITMART_IPS; do
        iptables -t nat -A WARP_GOOGLE -p tcp -d "$ip" -j REDIRECT --to-ports 12345
    done

    echo "$(date) [UPDATE] Gemini: $GEMINI_IPS"
    echo "$(date) [UPDATE] BitMart: $BITMART_IPS"
}

# 启动时先初始化
update_ips

while true; do
    # 检查 WARP 连接
    if ! warp-cli status 2>/dev/null | grep -qi connected; then
        echo "$(date) [WARN] WARP 断线，尝试重连..."
        warp-cli connect 2>/dev/null
        sleep 5
    fi

    # 检查 redsocks
    if ! pgrep -x redsocks > /dev/null; then
        echo "$(date) [WARN] redsocks 未运行，正在启动..."
        systemctl start redsocks 2>/dev/null || redsocks -c /etc/redsocks.conf
        sleep 3
    fi

    # 检查 Gemini 连通性
    if ! curl -s --max-time 10 https://gemini.google.com > /dev/null 2>&1; then
        echo "$(date) [WARN] Gemini 不可达，重启 redsocks 并重连 WARP..."
        systemctl restart redsocks 2>/dev/null
        warp-cli disconnect 2>/dev/null
        sleep 3
        warp-cli connect 2>/dev/null
        sleep 5
        echo "$(date) [INFO] 重连完成"
    fi

    # 每 6 小时更新 IP（0/6/12/18 点整）
    current_min=$(date +%M)
    current_hour=$(date +%H)
    if [[ "$current_min" == "00" ]] && echo "0 6 12 18" | grep -qw "$current_hour"; then
        update_ips
    fi

    sleep 60
done
GUARD

    chmod +x /root/warp_guard.sh
    ok "守护脚本已写入"
}

# ────────────── 初始化 iptables 链 ──────────────
init_iptables() {
    hr
    info "初始化 iptables 分流规则..."

    # 创建链
    iptables -t nat -N WARP_GOOGLE 2>/dev/null || iptables -t nat -F WARP_GOOGLE

    # 挂载到 OUTPUT
    iptables -t nat -C OUTPUT -j WARP_GOOGLE 2>/dev/null \
        || iptables -t nat -A OUTPUT -j WARP_GOOGLE

    ok "iptables 链已就绪（IP 将由守护脚本填入）"
}

# ────────────── systemd 服务（开机自启）──────────────
write_systemd() {
    hr
    info "注册 systemd 开机服务..."

    cat > /etc/systemd/system/warp-split.service << 'EOF'
[Unit]
Description=WARP Split Routing Guard (Gemini + BitMart)
After=network.target warp-svc.service
Wants=warp-svc.service

[Service]
Type=simple
ExecStartPre=/bin/sleep 5
ExecStart=/bin/bash /root/warp_guard.sh
Restart=always
RestartSec=10
StandardOutput=append:/var/log/warp_guard.log
StandardError=append:/var/log/warp_guard.log

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable warp-split 2>/dev/null
    ok "systemd 服务 warp-split 已注册并设为开机自启"
}

# ────────────── 启动守护进程 ──────────────
start_guard() {
    hr
    info "启动守护进程..."

    # 停掉旧进程
    pkill -f warp_guard.sh 2>/dev/null
    systemctl stop warp-split 2>/dev/null
    sleep 2

    systemctl start warp-split
    sleep 3

    if systemctl is-active --quiet warp-split; then
        ok "守护进程已启动（systemd 管理）"
    else
        # fallback：手动后台启动
        nohup /bin/bash /root/warp_guard.sh >> /var/log/warp_guard.log 2>&1 &
        ok "守护进程已启动（PID: $!）"
    fi
}

# ────────────── 测试连通性 ──────────────
test_connectivity() {
    hr
    info "等待规则生效..."
    sleep 5

    local gemini_code bitmart_code
    gemini_code=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" https://gemini.google.com 2>/dev/null)
    bitmart_code=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" https://www.bitmart.com 2>/dev/null)

    [[ "$gemini_code" == "200" ]] \
        && ok "Gemini 连接成功！（HTTP $gemini_code）" \
        || warn "Gemini 测试返回: $gemini_code"

    [[ "$bitmart_code" =~ ^(200|301|302)$ ]] \
        && ok "BitMart 连接成功！（HTTP $bitmart_code）" \
        || warn "BitMart 测试返回: $bitmart_code"

    hr
    info "当前 iptables 分流规则："
    iptables -t nat -L WARP_GOOGLE -n
}

# ────────────── 主安装流程 ──────────────
do_install() {
    install_deps
    install_warp
    configure_warp
    init_iptables
    write_guard
    write_systemd
    start_guard
    test_connectivity

    echo ""
    echo -e "${GREEN}  ╔══════════════════════════════════════════════════════╗${PLAIN}"
    echo -e "${GREEN}  ║   🎉  安装完成！                                    ║${PLAIN}"
    echo -e "${GREEN}  ║   Gemini + BitMart → WARP                           ║${PLAIN}"
    echo -e "${GREEN}  ║   其余流量 → 原生 IP                                ║${PLAIN}"
    echo -e "${GREEN}  ╚══════════════════════════════════════════════════════╝${PLAIN}"
    echo ""
    echo -e "  常用命令："
    echo -e "  ${CYAN}systemctl status warp-split${PLAIN}     查看守护状态"
    echo -e "  ${CYAN}cat /var/log/warp_guard.log${PLAIN}     查看运行日志"
    echo -e "  ${CYAN}iptables -t nat -L WARP_GOOGLE -n${PLAIN}  查看分流规则"
    echo -e "  ${CYAN}warp-cli status${PLAIN}                 查看 WARP 状态"
    echo ""
}

# ────────────── 卸载 ──────────────
do_uninstall() {
    hr
    info "卸载 WARP 分流..."

    systemctl stop warp-split 2>/dev/null
    systemctl disable warp-split 2>/dev/null
    pkill -f warp_guard.sh 2>/dev/null
    rm -f /etc/systemd/system/warp-split.service
    rm -f /root/warp_guard.sh
    systemctl daemon-reload

    iptables -t nat -D OUTPUT -j WARP_GOOGLE 2>/dev/null
    iptables -t nat -F WARP_GOOGLE 2>/dev/null
    iptables -t nat -X WARP_GOOGLE 2>/dev/null

    warp-cli disconnect 2>/dev/null
    systemctl disable --now warp-svc 2>/dev/null

    case $OS in
        ubuntu|debian)
            apt-get remove -y cloudflare-warp redsocks 2>/dev/null
            rm -f /etc/apt/sources.list.d/cloudflare-client.list
            ;;
        centos|rhel|rocky|almalinux|fedora)
            yum remove -y cloudflare-warp redsocks 2>/dev/null \
                || dnf remove -y cloudflare-warp redsocks 2>/dev/null
            rm -f /etc/yum.repos.d/cloudflare-warp.repo
            ;;
    esac

    rm -f /etc/redsocks.conf /var/log/warp_guard.log
    ok "卸载完成"
}

# ────────────── 菜单 ──────────────
show_menu() {
    clear
    banner
    hr
    echo -e "  ${BOLD}请选择操作：${PLAIN}"
    echo ""
    echo -e "  ${GREEN}1.${PLAIN}  安装 WARP 分流（Gemini + BitMart → WARP）"
    echo -e "  ${GREEN}2.${PLAIN}  卸载"
    echo -e "  ${GREEN}3.${PLAIN}  查看状态"
    echo -e "  ${GREEN}4.${PLAIN}  查看日志"
    echo -e "  ${GREEN}0.${PLAIN}  退出"
    echo ""
    hr
    read -rp "  请输入选项 [0-4]: " choice
    echo ""

    case $choice in
        1)
            do_install
            ;;
        2)
            read -rp "  确认卸载？[y/N]: " c
            [[ "$c" =~ ^[Yy]$ ]] && do_uninstall || warn "已取消"
            ;;
        3)
            hr
            echo -e "  ${CYAN}WARP 状态:${PLAIN}"
            warp-cli status 2>/dev/null || echo "未运行"
            echo ""
            echo -e "  ${CYAN}守护进程:${PLAIN}"
            systemctl is-active warp-split 2>/dev/null || pgrep -f warp_guard.sh > /dev/null \
                && echo "运行中" || echo "未运行"
            echo ""
            echo -e "  ${CYAN}iptables 分流规则:${PLAIN}"
            iptables -t nat -L WARP_GOOGLE -n 2>/dev/null || echo "无规则"
            hr
            ;;
        4)
            hr
            tail -50 /var/log/warp_guard.log 2>/dev/null || echo "暂无日志"
            hr
            ;;
        0)
            echo -e "${GREEN}  再见！${PLAIN}"
            exit 0
            ;;
        *)
            error "无效选项"
            ;;
    esac

    echo ""
    read -n1 -rp "  按任意键继续..." _
    echo ""
    show_menu
}

# ════════ 入口 ════════
clear
banner
show_menu

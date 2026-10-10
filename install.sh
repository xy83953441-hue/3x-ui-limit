#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
yellow='\033[0;33m'
plain='\033[0m'

cur_dir=$(pwd)

xui_folder="${XUI_MAIN_FOLDER:=/usr/local/x-ui}"
xui_service="${XUI_SERVICE:=/etc/systemd/system}"

# check root
[[ $EUID -ne 0 ]] && echo -e "${red}Fatal error: ${plain} Please run this script with root privilege \n " && exit 1

# Check OS and set release variable
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    release=$ID
elif [[ -f /usr/lib/os-release ]]; then
    source /usr/lib/os-release
    release=$ID
else
    echo "Failed to check the system OS, please contact the author!" >&2
    exit 1
fi
echo "The OS release is: $release"

arch() {
    case "$(uname -m)" in
        x86_64 | x64 | amd64) echo 'amd64' ;;
        i*86 | x86) echo '386' ;;
        armv8* | armv8 | arm64 | aarch64) echo 'arm64' ;;
        armv7* | armv7 | arm) echo 'armv7' ;;
        armv6* | armv6) echo 'armv6' ;;
        armv5* | armv5) echo 'armv5' ;;
        s390x) echo 's390x' ;;
        *) echo -e "${green}Unsupported CPU architecture! ${plain}" && rm -f install.sh && exit 1 ;;
    esac
}

echo "Arch: $(arch)"

# Simple helpers

# Port helpers


# Keep renewal ports open without disabling the firewall or reloading other rules.


# Verify files and matching keys before configuring TLS. Never log private keys.

# Derive the displayed scheme from configured, usable files, never from a menu choice.

install_base() {
    if [[ "$release" == centos && "${VERSION_ID:-}" == 7* ]]; then
        echo '提示：CentOS 7 已结束维护；软件源失败时请检查归档源，建议迁移到受支持系统。'
    fi
    case "${release}" in
        ubuntu | debian | armbian)
            apt-get update && apt-get install -y -q cron curl tar tzdata socat ca-certificates openssl
            ;;
        fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
            dnf install -y -q cronie curl tar tzdata socat ca-certificates openssl
            ;;
        centos)
            if [[ "${VERSION_ID}" =~ ^7 ]]; then
                yum install -y cronie curl tar tzdata socat ca-certificates openssl
            else
                dnf install -y -q cronie curl tar tzdata socat ca-certificates openssl
            fi
            ;;
        arch | manjaro | parch)
            pacman -S --needed --noconfirm cronie curl tar tzdata socat ca-certificates openssl
            ;;
        opensuse-tumbleweed | opensuse-leap)
            zypper refresh && zypper -q install -y cron curl tar timezone socat ca-certificates openssl
            ;;
        alpine)
            apk update && apk add dcron curl tar tzdata socat ca-certificates openssl
            ;;
        *)
            apt-get update && apt-get install -y -q cron curl tar tzdata socat ca-certificates openssl
            ;;
    esac
}

gen_random_string() {
    local length="$1"
    openssl rand -base64 $((length * 2)) \
        | tr -dc 'a-zA-Z0-9' \
        | head -c "$length"
}



# Issue Let's Encrypt IP certificate with shortlived profile (~6 days validity)
# Requires acme.sh and port 80 open for HTTP-01 challenge

# Comprehensive manual SSL certificate issuance via acme.sh

# Reusable interactive SSL setup (domain or IP)
# Sets global `SSL_HOST` to the chosen domain/IP for Access URL usage

# BEGIN GENERATED SSL
#!/usr/bin/env bash
# Canonical TLS helpers. Embedded in install.sh by scripts/sync_ssl.py.
is_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && return 0 || return 1
}

is_ipv6() {
    [[ "$1" =~ : ]] && return 0 || return 1
}

is_ip() {
    is_ipv4 "$1" || is_ipv6 "$1"
}

is_domain() {
    [[ "$1" =~ ^([A-Za-z0-9](-*[A-Za-z0-9])*\.)+(xn--[a-z0-9]{2,}|[A-Za-z]{2,})$ ]] && return 0 || return 1
}

is_port_in_use() {
    local port="$1"
    if command -v ss > /dev/null 2>&1; then
        ss -ltn 2> /dev/null | awk -v p=":${port}$" '$4 ~ p {found=1} END {exit !found}'
        return
    fi
    if command -v netstat > /dev/null 2>&1; then
        netstat -lnt 2> /dev/null | awk -v p=":${port}$" '$4 ~ p {found=1} END {exit !found}'
        return
    fi
    if command -v lsof > /dev/null 2>&1; then
        lsof -nP -iTCP:${port} -sTCP:LISTEN > /dev/null 2>&1 && return 0
    fi
    return 1
}

open_ssl_port() {
    local port="$1" iface zone
    [[ "$port" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)) || return 1
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        iface=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
        if [[ -z "$iface" ]]; then
            echo "无法确定公网网卡，请手动放行 TCP $port。" >&2
            return 1
        fi
        zone=$(firewall-cmd --get-zone-of-interface="$iface" 2>/dev/null)
        [[ -n "$zone" && "$zone" != "no zone" ]] || zone=$(firewall-cmd --get-default-zone)
        firewall-cmd --zone="$zone" --add-port="$port/tcp" &&
            firewall-cmd --permanent --zone="$zone" --add-port="$port/tcp" || return 1
        echo "已在 firewalld 区域 $zone 放行 TCP $port（含永久规则）。"
    elif command -v ufw >/dev/null 2>&1 && LC_ALL=C ufw status 2>/dev/null | grep -q '^Status: active'; then
        ufw allow "$port/tcp" || return 1
    else
        echo "未检测到运行中的 firewalld/UFW，请确认其他防火墙允许 TCP $port。"
    fi
    echo "云平台安全组也需允许 TCP $port；本机规则不能保证公网可达。"
}

ensure_renewal_service() {
    if [[ "$release" == "alpine" ]]; then
        rc-update add crond default && rc-service crond start
    else
        local service
        case "$release" in
            ubuntu|debian|armbian|opensuse-*) service=cron ;;
            *) service=crond ;;
        esac
        systemctl enable --now "$service" && systemctl is-active --quiet "$service"
    fi
}

valid_certificate_pair() {
    local cert="$1" key="$2" cert_pub key_pub
    [[ -s "$cert" && -s "$key" ]] || return 1
    openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1 || return 1
    cert_pub=$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null) || return 1
    key_pub=$(openssl pkey -in "$key" -pubout 2>/dev/null) || return 1
    [[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]]
}

refresh_ssl_scheme() {
    local settings cert key
    SSL_SCHEME="http"
    settings=$("${xui_folder}/x-ui" setting -getCert true) || return 1
    cert=$(printf '%s\n' "$settings" | sed -n 's/^cert: *//p')
    key=$(printf '%s\n' "$settings" | sed -n 's/^key: *//p')
    if valid_certificate_pair "$cert" "$key"; then
        SSL_SCHEME="https"
    fi
}

install_acme() {
    local installer
    installer=$(mktemp) || return 1
    echo "正在安装 acme.sh..."
    if ! curl -fLsS --connect-timeout 15 --max-time 120 https://get.acme.sh -o "$installer"; then
        rm -f "$installer"
        return 1
    fi
    # Use a subshell: changing the installer's working directory breaks later extraction.
    (cd /root && sh "$installer")
    local result=$?
    rm -f "$installer"
    [[ $result -eq 0 && -x /root/.acme.sh/acme.sh ]]
}

setup_ip_certificate() {
    local ipv4="$1" ipv6="${2:-}" issue_status
    local acme="/root/.acme.sh/acme.sh"
    local certDir="/root/cert/ip" log="/var/log/x-ui/acme-ip.log"
    local -a domains=(-d "$ipv4")
    is_ipv4 "$ipv4" || { echo "无效 IPv4 地址：$ipv4"; return 1; }
    if [[ -n "$ipv6" ]]; then
        is_ipv6 "$ipv6" || return 1
        domains+=(-d "$ipv6")
    fi
    # The default automatic path uses public TCP 80 end-to-end.
    if ! command -v ss >/dev/null && ! command -v netstat >/dev/null && ! command -v lsof >/dev/null; then
        echo "无法检查端口占用，请安装 ss、netstat 或 lsof 后重试。" >&2
        return 1
    fi
    if is_port_in_use 80; then
        echo "TCP 80 已被占用，未停止现有服务。请使用域名/webroot 方式，或释放端口后重试。" >&2
        return 1
    fi
    command -v socat >/dev/null || { echo "缺少 socat，无法启动证书验证服务。"; return 1; }
    ensure_renewal_service || { echo "自动续期所需的 cron 服务无法启动，停止申请。"; return 1; }
    open_ssl_port 80 || return 1
    [[ -x "$acme" ]] || install_acme || return 1
    if ! "$acme" --help | grep -q -- '--certificate-profile'; then
        "$acme" --upgrade || return 1
        "$acme" --help | grep -q -- '--certificate-profile' || return 1
    fi
    "$acme" --install-cronjob || return 1
    crontab -l 2>/dev/null | grep -F 'acme.sh' | grep -q -- '--cron' ||
        { echo "未找到 acme.sh 自动续期任务，停止申请。"; return 1; }
    mkdir -p "$certDir" /var/log/x-ui || return 1
    touch "$log" && chmod 600 "$log" || return 1

    echo "正在自动申请 IP 证书；有效期约 6 天，设置每 3 天续期。"
    "$acme" --issue "${domains[@]}" --standalone --server letsencrypt \
        --certificate-profile shortlived --keylength ec-256 --days 3 --httpport 80 --log "$log"
    issue_status=$?
    # acme.sh returns 2 when an existing certificate is not yet due for renewal.
    if [[ $issue_status -ne 0 && $issue_status -ne 2 ]]; then
        echo "证书申请失败，详细日志：$log"
        echo "请检查云平台 TCP 80 放行、IP 公网可达性、验证服务和 CA 返回的错误。"
        echo "已保留原有证书及 ACME 账户，不会显示虚假的 HTTPS 成功提示。"
        return 1
    fi
    # Skip restarting only on first install; renewal must report real restart errors.
    local reloadCmd='if command -v systemctl >/dev/null 2>&1 && systemctl cat x-ui.service >/dev/null 2>&1; then systemctl restart x-ui; elif [ -x /etc/init.d/x-ui ]; then rc-service x-ui restart; fi'
    "$acme" --install-cert -d "$ipv4" --ecc \
        --key-file "$certDir/privkey.pem" --fullchain-file "$certDir/fullchain.pem" \
        --reloadcmd "$reloadCmd" --log "$log" || return 1
    valid_certificate_pair "$certDir/fullchain.pem" "$certDir/privkey.pem" ||
        { echo "证书无效、过期或与私钥不匹配，未启用 HTTPS。"; return 1; }
    chmod 600 "$certDir/privkey.pem" || return 1
    chmod 644 "$certDir/fullchain.pem" || return 1
    "${xui_folder}/x-ui" cert -webCert "$certDir/fullchain.pem" -webCertKey "$certDir/privkey.pem" ||
        { echo "证书已签发，但写入面板配置失败。"; return 1; }
    echo "IP 证书已配置，自动续期任务已检查。请保持公网 TCP 80 可达。"
}

setup_ssl_certificate() {
    local domain="$1" acme=/root/.acme.sh/acme.sh code
    is_domain "$domain" || { echo '请输入有效域名。'; return 1; }
    is_port_in_use 80 && { echo 'TCP 80 已占用，请使用已有证书或 DNS 验证。'; return 1; }
    ensure_renewal_service && open_ssl_port 80 || return 1
    [[ -x "$acme" ]] || install_acme || return 1
    "$acme" --install-cronjob || return 1
    crontab -l 2>/dev/null | grep -F 'acme.sh' | grep -q -- '--cron' || return 1
    local certDir="/root/cert/$domain" log=/var/log/x-ui/acme-domain.log
    mkdir -p "$certDir" /var/log/x-ui || return 1
    touch "$log" && chmod 600 "$log" || return 1
    "$acme" --issue -d "$domain" --standalone --server letsencrypt --keylength ec-256 --httpport 80 --log "$log"
    code=$?
    [[ $code == 0 || $code == 2 ]] || { echo "申请失败，请查看 $log；已保留原证书。"; return 1; }
    local reloadCmd='if command -v systemctl >/dev/null 2>&1 && systemctl cat x-ui.service >/dev/null 2>&1; then systemctl restart x-ui; elif [ -x /etc/init.d/x-ui ]; then rc-service x-ui restart; fi'
    "$acme" --install-cert -d "$domain" --ecc --key-file "$certDir/privkey.pem" --fullchain-file "$certDir/fullchain.pem" --reloadcmd "$reloadCmd" --log "$log" || return 1
    valid_certificate_pair "$certDir/fullchain.pem" "$certDir/privkey.pem" || return 1
    chmod 600 "$certDir/privkey.pem"
    "${xui_folder}/x-ui" cert -webCert "$certDir/fullchain.pem" -webCertKey "$certDir/privkey.pem"
}

prompt_and_setup_ssl() {
    local panel_port="$1" web_base_path="$2" server_ip="$3"
    local choice domain ipv6 cert key subport answer
    SSL_HOST="$server_ip"
    echo 'SSL 证书设置：1.域名自动申请  2.IP 自动申请  3.使用已有证书  4.跳过'
    echo '自动申请会放行 TCP 80 并保留续期规则；云平台防火墙需自行放行。'
    read -rp '请选择 [默认 2]：' choice
    case "${choice:-2}" in
        1)
            read -rp '域名（需解析到此服务器）：' domain
            setup_ssl_certificate "$domain" || return 1
            SSL_HOST="$domain";;
        2)
            read -rp '附加 IPv6（留空跳过）：' ipv6
            setup_ip_certificate "$server_ip" "$ipv6" || return 1;;
        3)
            read -rp '证书对应的域名或 IP：' domain
            read -rp '证书完整路径：' cert
            read -rp '私钥完整路径：' key
            valid_certificate_pair "$cert" "$key" || { echo '证书无效、过期或私钥不匹配。'; return 1; }
            "${xui_folder}/x-ui" cert -webCert "$cert" -webCertKey "$key" || return 1
            SSL_HOST="$domain"
            echo '已有证书由外部续期程序负责更新。';;
        4)
            echo '保留现有证书设置；没有证书时请通过 SSH 隧道或 HTTPS 反向代理访问。'
            refresh_ssl_scheme
            return;;
        *) echo '无效选项。'; return 1;;
    esac
    refresh_ssl_scheme || return 1
    [[ "$SSL_SCHEME" == https ]] || { echo '证书写入后校验失败，未确认 HTTPS。'; return 1; }
    open_ssl_port "$panel_port" || return 1
    read -rp '是否放行订阅 TCP 端口？输入端口号，留空不修改：' subport
    if [[ -n "$subport" ]]; then open_ssl_port "$subport" || return 1; fi
    echo "HTTPS 配置已保存：https://$SSL_HOST:$panel_port/${web_base_path#/}"
    echo '面板和订阅服务在启动/重启后应用新证书。'
}

setup_cloudflare_certificate() (
    local domain token acme=/root/.acme.sh/acme.sh code
    read -rp 'Cloudflare 托管的域名：' domain
    is_domain "$domain" || { echo '域名无效。'; return 1; }
    read -rsp 'Cloudflare API Token（需对此域名有 DNS 编辑权限）：' token
    echo
    [[ -n "$token" ]] || return 1
    export CF_Token="$token"
    ensure_renewal_service || return 1
    [[ -x "$acme" ]] || install_acme || return 1
    "$acme" --install-cronjob || return 1
    crontab -l 2>/dev/null | grep -F 'acme.sh' | grep -q -- '--cron' || return 1
    local certDir="/root/cert/$domain" log=/var/log/x-ui/acme-domain.log
    mkdir -p "$certDir" /var/log/x-ui || return 1
    touch "$log" && chmod 600 "$log" || return 1
    "$acme" --issue --dns dns_cf -d "$domain" -d "*.$domain" --server letsencrypt --keylength ec-256 --log "$log"
    code=$?
    [[ $code == 0 || $code == 2 ]] || { echo "申请失败，查看 $log"; return 1; }
    local reloadCmd='if command -v systemctl >/dev/null 2>&1; then systemctl restart x-ui; else rc-service x-ui restart; fi'
    "$acme" --install-cert -d "$domain" --ecc --key-file "$certDir/privkey.pem" --fullchain-file "$certDir/fullchain.pem" --reloadcmd "$reloadCmd" --log "$log" || return 1
    valid_certificate_pair "$certDir/fullchain.pem" "$certDir/privkey.pem" || return 1
    chmod 600 "$certDir/privkey.pem"
    "${xui_folder}/x-ui" cert -webCert "$certDir/fullchain.pem" -webCertKey "$certDir/privkey.pem" || return 1
    if [[ "$release" == alpine ]]; then rc-service x-ui restart; else systemctl restart x-ui; fi
    echo 'Cloudflare DNS 证书已配置。可用菜单 27 检查有效期及续期任务。'
)
# END GENERATED SSL

config_after_install() {
    local info old_default port path username='' password='' answer server_ip=''
    info=$("$xui_folder/x-ui" setting -show true) || return 1
    old_default=$(printf '%s\n' "$info" | sed -n 's/^hasDefaultCredential: *//p')
    port=$(printf '%s\n' "$info" | sed -n 's/^port: *//p')
    path=$(printf '%s\n' "$info" | sed -n 's/^webBasePath: *//p')
    if [[ "$old_default" == true ]]; then
        username=$(gen_random_string 12)
        password=$(gen_random_string 20)
        [[ ${#username} == 12 && ${#password} == 20 ]] || return 1
        read -rp '面板 TCP 端口（留空随机选择）：' port
        [[ -n "$port" ]] || port=$(shuf -i 1024-62000 -n 1)
        [[ "$port" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)) || { echo '端口无效。'; return 1; }
        if is_port_in_use "$port"; then echo '面板端口已被其他服务占用。'; return 1; fi
        "$xui_folder/x-ui" setting -username "$username" -password "$password" -port "$port" || return 1
    fi
    if [[ ${#path} -lt 4 ]]; then
        path=$(gen_random_string 18)
        [[ ${#path} == 18 ]] || return 1
        "$xui_folder/x-ui" setting -webBasePath "$path" || return 1
    fi
    for endpoint in https://api.ipify.org https://ipv4.icanhazip.com; do
        server_ip=$(curl -4fLsS --connect-timeout 3 --max-time 6 "$endpoint" 2>/dev/null)
        is_ipv4 "$server_ip" && break
        server_ip=''
    done
    while ! is_ipv4 "$server_ip"; do
        read -rp '请输入服务器公网 IPv4 地址：' server_ip || return 1
    done
    SSL_HOST="$server_ip"
    refresh_ssl_scheme || return 1
    if [[ "$SSL_SCHEME" != https ]]; then
        prompt_and_setup_ssl "$port" "$path" "$server_ip" || echo '证书配置未完成，请按上方错误排查。'
    else
        echo '已有有效证书，已保留。访问时应使用该证书对应的域名或 IP。'
    fi
    refresh_ssl_scheme || return 1
    echo '========== 面板初始化结果 =========='
    if [[ -n "$username" ]]; then
        echo "账号：$username"
        echo "密码：$password"
        echo '请妥善保存；菜单 6 可以重置账号密码。'
    else
        echo '账号密码：保留原设置；忘记时使用菜单 6 重置。'
    fi
    echo "面板端口：$port"
    echo "访问路径：/${path#/}"
    echo "访问地址：$SSL_SCHEME://$SSL_HOST:$port/${path#/}"
    echo "证书状态：$SSL_SCHEME（服务启动后生效）"
    info=$("$xui_folder/x-ui" setting -show true) || return 1
    echo "订阅端口：$(printf '%s\n' "$info" | sed -n 's/^subPort: *//p')"
    echo 'FlClash：复制二维码窗口中的 Clash / FlClash 订阅。'
    echo '本机和云平台均需放行对应端口；菜单 27 可查看防火墙及续期状态。'
}

install_x-ui() {
    if [[ -x "$xui_folder/x-ui" ]]; then
        echo '已检测到面板。请运行 x-ui update 安全更新；重新测试请先从菜单卸载。'
        return 1
    fi
    cd ${xui_folder%/x-ui}/

    # Download resources
    if [ $# == 0 ]; then
        tag_version=$(curl -Ls "https://api.github.com/repos/xy83953441-hue/3x-ui-limit/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [[ ! -n "$tag_version" ]]; then
            echo -e "${yellow}Trying to fetch version with IPv4...${plain}"
            tag_version=$(curl -4 -Ls "https://api.github.com/repos/xy83953441-hue/3x-ui-limit/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
            if [[ ! -n "$tag_version" ]]; then
                echo -e "${red}Failed to fetch x-ui version, it may be due to GitHub API restrictions, please try it later${plain}"
                exit 1
            fi
        fi
        echo -e "Got x-ui latest version: ${tag_version}, beginning the installation..."
        curl -4fLRo ${xui_folder}-linux-$(arch).tar.gz https://github.com/xy83953441-hue/3x-ui-limit/releases/download/${tag_version}/x-ui-linux-$(arch).tar.gz
        if [[ $? -ne 0 ]]; then
            echo -e "${red}Downloading x-ui failed, please be sure that your server can access GitHub ${plain}"
            exit 1
        fi
    else
        tag_version=$1
        [[ "$tag_version" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
        url="https://github.com/xy83953441-hue/3x-ui-limit/releases/download/${tag_version}/x-ui-linux-$(arch).tar.gz"
        echo -e "Beginning to install x-ui $1"
        curl -4fLRo ${xui_folder}-linux-$(arch).tar.gz ${url}
        if [[ $? -ne 0 ]]; then
            echo -e "${red}Download x-ui $1 failed, please check if the version exists ${plain}"
            exit 1
        fi
    fi
    local asset="x-ui-linux-$(arch).tar.gz" sums
    sums=$(mktemp) || return 1
    if ! curl -fLsS --connect-timeout 15 --max-time 120 "https://github.com/xy83953441-hue/3x-ui-limit/releases/download/$tag_version/SHA256SUMS" -o "$sums"; then
        rm -f "$sums"
        echo '此版本缺少校验文件，请等待完整新版发布后重试。'
        return 1
    fi
    local checksum
    checksum=$(awk -v name="$asset" '$2==name {print $1}' "$sums")
    rm -f "$sums"
    [[ "$checksum" =~ ^[a-fA-F0-9]{64}$ ]] || return 1
    printf '%s  %s\n' "$checksum" "$asset" | sha256sum -c - || return 1
    if tar -tzf "$asset" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then return 1; fi
    tar -tzf "$asset" | grep -qv '^x-ui\(/\|$\)' && return 1
    tar -tvzf "$asset" | awk 'substr($0,1,1)!="-" && substr($0,1,1)!="d" {bad=1} END {exit bad}' || return 1
    tar -xzf "$asset" --no-same-owner || return 1
    rm -f "$asset"
    bash -n x-ui/x-ui.sh || return 1
    [[ -s x-ui/scripts/lib/ssl.sh ]] || return 1
    cd x-ui
    chmod +x x-ui
    chmod +x x-ui.sh

    # Check the system's architecture and rename the file accordingly
    if [[ $(arch) == "armv5" || $(arch) == "armv6" || $(arch) == "armv7" ]]; then
        mv bin/xray-linux-$(arch) bin/xray-linux-arm
        chmod +x bin/xray-linux-arm
    fi
    chmod +x x-ui bin/xray-linux-*

    # Update x-ui cli and se set permission
    install -m 755 x-ui.sh /usr/bin/x-ui || return 1
    chmod +x /usr/bin/x-ui
    mkdir -p /var/log/x-ui
    config_after_install || return 1

    # Etckeeper compatibility
    if [ -d "/etc/.git" ]; then
        if [ -f "/etc/.gitignore" ]; then
            if ! grep -q "x-ui/x-ui.db" "/etc/.gitignore"; then
                echo "" >> "/etc/.gitignore"
                echo "x-ui/x-ui.db" >> "/etc/.gitignore"
                echo -e "${green}Added x-ui.db to /etc/.gitignore for etckeeper${plain}"
            fi
        else
            echo "x-ui/x-ui.db" > "/etc/.gitignore"
            echo -e "${green}Created /etc/.gitignore and added x-ui.db for etckeeper${plain}"
        fi
    fi

    if [[ $release == "alpine" ]]; then
        curl -4fLRo /etc/init.d/x-ui https://raw.githubusercontent.com/xy83953441-hue/3x-ui-limit/main/x-ui.rc
        if [[ $? -ne 0 ]]; then
            echo -e "${red}Failed to download x-ui.rc${plain}"
            exit 1
        fi
        chmod +x /etc/init.d/x-ui
        rc-update add x-ui
        rc-service x-ui start
    else
        # Install systemd service file
        service_installed=false

        if [ -f "x-ui.service" ]; then
            echo -e "${green}Found x-ui.service in extracted files, installing...${plain}"
            cp -f x-ui.service ${xui_service}/ > /dev/null 2>&1
            if [[ $? -eq 0 ]]; then
                service_installed=true
            fi
        fi

        if [ "$service_installed" = false ]; then
            case "${release}" in
                ubuntu | debian | armbian)
                    if [ -f "x-ui.service.debian" ]; then
                        echo -e "${green}Found x-ui.service.debian in extracted files, installing...${plain}"
                        cp -f x-ui.service.debian ${xui_service}/x-ui.service > /dev/null 2>&1
                        if [[ $? -eq 0 ]]; then
                            service_installed=true
                        fi
                    fi
                    ;;
                arch | manjaro | parch)
                    if [ -f "x-ui.service.arch" ]; then
                        echo -e "${green}Found x-ui.service.arch in extracted files, installing...${plain}"
                        cp -f x-ui.service.arch ${xui_service}/x-ui.service > /dev/null 2>&1
                        if [[ $? -eq 0 ]]; then
                            service_installed=true
                        fi
                    fi
                    ;;
                *)
                    if [ -f "x-ui.service.rhel" ]; then
                        echo -e "${green}Found x-ui.service.rhel in extracted files, installing...${plain}"
                        cp -f x-ui.service.rhel ${xui_service}/x-ui.service > /dev/null 2>&1
                        if [[ $? -eq 0 ]]; then
                            service_installed=true
                        fi
                    fi
                    ;;
            esac
        fi

        # If service file not found in tar.gz, download from GitHub
        if [ "$service_installed" = false ]; then
            echo -e "${yellow}Service files not found in tar.gz, downloading from GitHub...${plain}"
            case "${release}" in
                ubuntu | debian | armbian)
                    curl -4fLRo ${xui_service}/x-ui.service https://raw.githubusercontent.com/xy83953441-hue/3x-ui-limit/main/x-ui.service.debian > /dev/null 2>&1
                    ;;
                arch | manjaro | parch)
                    curl -4fLRo ${xui_service}/x-ui.service https://raw.githubusercontent.com/xy83953441-hue/3x-ui-limit/main/x-ui.service.arch > /dev/null 2>&1
                    ;;
                *)
                    curl -4fLRo ${xui_service}/x-ui.service https://raw.githubusercontent.com/xy83953441-hue/3x-ui-limit/main/x-ui.service.rhel > /dev/null 2>&1
                    ;;
            esac

            if [[ $? -ne 0 ]]; then
                echo -e "${red}Failed to install x-ui.service from GitHub${plain}"
                exit 1
            fi
            service_installed=true
        fi

        if [ "$service_installed" = true ]; then
            echo -e "${green}Setting up systemd unit...${plain}"
            chown root:root ${xui_service}/x-ui.service > /dev/null 2>&1
            chmod 644 ${xui_service}/x-ui.service > /dev/null 2>&1
            systemctl daemon-reload
            systemctl enable x-ui
            systemctl start x-ui
        else
            echo -e "${red}Failed to install x-ui.service file${plain}"
            exit 1
        fi
    fi

    # systemctl start may succeed before the process exits; verify service state.
    sleep 2
    if [[ "$release" == "alpine" ]]; then
        rc-service x-ui status >/dev/null 2>&1 || { echo "面板启动失败，请检查 x-ui 日志。"; return 1; }
    else
        systemctl is-active --quiet x-ui || { echo "面板启动失败，请执行 journalctl -u x-ui -n 50 --no-pager。"; return 1; }
    fi
    echo "订阅端口请查看面板订阅设置；Clash / FlClash 链接可直接在客户端二维码窗口复制。"
    echo "一键检查：x-ui diagnose；忘记账号密码：菜单 6。"
    echo -e "${green}x-ui ${tag_version}${plain} 安装完成，服务正在运行。证书状态请以上方实际结果为准。"
    echo -e ""
    echo -e "┌───────────────────────────────────────────────────────┐
│  ${blue}x-ui control menu usages (subcommands):${plain}              │
│                                                       │
│  ${blue}x-ui${plain}              - Admin Management Script          │
│  ${blue}x-ui start${plain}        - Start                            │
│  ${blue}x-ui stop${plain}         - Stop                             │
│  ${blue}x-ui restart${plain}      - Restart                          │
│  ${blue}x-ui status${plain}       - Current Status                   │
│  ${blue}x-ui settings${plain}     - Current Settings                 │
│  ${blue}x-ui enable${plain}       - Enable Autostart on OS Startup   │
│  ${blue}x-ui disable${plain}      - Disable Autostart on OS Startup  │
│  ${blue}x-ui log${plain}          - Check logs                       │
│  ${blue}x-ui banlog${plain}       - Check Fail2ban ban logs          │
│  ${blue}x-ui update${plain}       - Update                           │
│  ${blue}x-ui legacy${plain}       - Legacy version                   │
│  ${blue}x-ui install${plain}      - Install                          │
│  ${blue}x-ui uninstall${plain}    - Uninstall                        │
└───────────────────────────────────────────────────────┘"
}

echo -e "${green}Running...${plain}"
install_base || { echo "基础依赖安装失败，停止安装。"; exit 1; }
install_x-ui "$@"

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

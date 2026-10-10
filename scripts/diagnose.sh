#!/usr/bin/env bash
# Read-only diagnostics; no credentials, private keys or subscription tokens printed.
set -u
folder=${XUI_MAIN_FOLDER:-/usr/local/x-ui}
echo '===== 面板和节点诊断 ====='
echo "内核：$(uname -r)"
if command -v systemctl >/dev/null; then
    systemctl is-active x-ui
    echo '续期调度服务：'
    systemctl is-active cron crond 2>/dev/null || true
else
    rc-service x-ui status
    rc-service crond status
fi
echo '配置端口与订阅格式：'
"$folder/x-ui" setting -show true | grep -E '^(port|subPort|subEnable|subClashEnable|subClashPath):'
echo '监听端口（面板、订阅和节点分别使用独立端口）：'
if command -v ss >/dev/null; then ss -lntup; else netstat -lntup; fi
echo '本机防火墙：'
if command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --get-active-zones
    for zone in $(firewall-cmd --get-active-zones | awk '/^[^ ]/{print $1}'); do
        echo "区域：$zone"
        firewall-cmd --zone="$zone" --list-ports
        echo '重启后保留的端口：'
        firewall-cmd --permanent --zone="$zone" --list-ports
    done
elif command -v ufw >/dev/null; then ufw status; else echo '未发现 firewalld/UFW，请检查其他防火墙。'; fi
echo '云平台安全组和公网可达性无法由本机规则确认。'
echo '证书：'
settings=$("$folder/x-ui" setting -getCert true) || exit 1
cert=$(printf '%s\n' "$settings" | sed -n 's/^cert: *//p')
if [[ -n "$cert" && -f "$cert" ]]; then
    openssl x509 -in "$cert" -noout -subject -dates
    if openssl x509 -in "$cert" -noout -checkend 86400 >/dev/null; then
        echo '证书有效期超过 24 小时。'
    else echo '证书已过期或不足 24 小时，请检查续期日志。'; fi
else echo '未配置可读取的证书。'; fi
if crontab -l 2>/dev/null | grep -F 'acme.sh' | grep -q -- '--cron'; then
    echo 'ACME 续期任务：已登记（不代表上次续期成功）。'
else echo 'ACME 续期任务：未发现；自定义证书请检查外部续期工具。'; fi
for log in /var/log/x-ui/acme-ip.log /var/log/x-ui/acme-domain.log; do
    if [[ -f "$log" ]]; then
        echo "续期日志及最后写入时间：$(stat -c '%y %n' "$log")"
        # Only recognizable outcomes; do not dump the CA/account log.
        grep -E 'Cert success|Renew success|Skip, Next renewal time is|Error|error' "$log" | tail -3
    fi
done
echo '订阅格式：FlClash 使用二维码窗口的 Clash / FlClash；通用订阅可能是 Base64，不能当作 YAML。'
echo '节点端口需要独立放行，可用 x-ui open-node-port；TCP 节点不需要为此额外开放 UDP。'
echo '需要排查启动失败时：journalctl -u x-ui -n 50 --no-pager'

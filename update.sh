#!/usr/bin/env bash
# Validate before stopping; preserve service settings and restore SQLite on failure.
set -Eeuo pipefail
umask 077
repo=xy83953441-hue/3x-ui-limit
xui_folder=${XUI_MAIN_FOLDER:-/usr/local/x-ui}
db_folder=${XUI_DB_FOLDER:-/etc/x-ui}
stage='' backup='' stopped=0 changed=0 committed=0
service_call() {
    if command -v systemctl >/dev/null 2>&1; then systemctl "$1" x-ui;
    else rc-service x-ui "$1"; fi
}
service_alive() {
    if command -v systemctl >/dev/null 2>&1; then systemctl is-active --quiet x-ui;
    else rc-service x-ui status >/dev/null; fi
}
finish() {
    local status=$?
    trap - EXIT INT TERM
    if ((stopped && !committed)); then
        echo '更新失败，正在恢复旧版本。' >&2
        service_call stop || true
        if ((changed)); then
            cp -a "$backup/program/." "$xui_folder/" || status=1
            find "$db_folder" -maxdepth 1 -name 'x-ui.db*' -type f -delete
            cp -a "$backup/data/." "$db_folder/" || status=1
            cp -a "$backup/menu" /usr/bin/x-ui || status=1
        fi
        if ! service_call start || ! service_alive; then
            echo "恢复后仍未启动，请检查日志。备份保留于：$backup" >&2
        fi
        status=1
    fi
    [[ -z "$stage" ]] || rm -rf -- "$stage"
    exit "$status"
}
download() { curl -fLsS --retry 2 --connect-timeout 15 --max-time 600 "$1" -o "$2"; }
update_main() {
    [[ $EUID == 0 ]] || { echo '请使用 root 运行。'; return 1; }
    [[ "$xui_folder" == /usr/local/x-ui && "$db_folder" == /etc/x-ui ]] || {
        echo '自定义目录请人工升级，以避免备份错误位置。'; return 1;
    }
    for envfile in /etc/default/x-ui /etc/sysconfig/x-ui /usr/local/x-ui/.env; do
        if [[ -f "$envfile" ]] && grep -Eq '^[[:space:]]*(export[[:space:]]+)?XUI_(DB|MAIN)_FOLDER=' "$envfile"; then
            echo "检测到 $envfile 自定义路径，请人工升级。"; return 1
        fi
    done
    [[ -x "$xui_folder/x-ui" && -f /usr/bin/x-ui ]] || { echo '未发现完整安装。'; return 1; }
    for cmd in curl tar sha256sum flock; do command -v "$cmd" >/dev/null || { echo "缺少 $cmd"; return 1; }; done
    exec 9>/run/x-ui-update.lock
    flock -n 9 || { echo '另一个更新任务正在运行。'; return 1; }
    case "$(uname -m)" in
        x86_64) arch=amd64;; i?86) arch=386;; aarch64) arch=arm64;;
        armv7*) arch=armv7;; armv6*) arch=armv6;; armv5*) arch=armv5;; s390x) arch=s390x;;
        *) echo '不支持此架构。'; return 1;;
    esac
    stage=$(mktemp -d /usr/local/.x-ui-update.XXXXXX)
    trap finish EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    download "https://api.github.com/repos/$repo/releases/latest" "$stage/release.json"
    tag=$(sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' "$stage/release.json" | head -1)
    [[ "$tag" =~ ^[A-Za-z0-9._-]+$ ]] || { echo '无法读取版本号。'; return 1; }
    asset="x-ui-linux-$arch.tar.gz"
    base="https://github.com/$repo/releases/download/$tag"
    echo "正在下载并验证 $tag，现有服务继续运行。"
    download "$base/$asset" "$stage/$asset"
    download "$base/SHA256SUMS" "$stage/SHA256SUMS"
    (cd "$stage"; grep -F "  $asset" SHA256SUMS > selected.sha256; test -s selected.sha256; sha256sum -c selected.sha256)
    tar -tzf "$stage/$asset" > "$stage/members"
    if grep -Eq '(^/|(^|/)\.\.(/|$))' "$stage/members" || grep -qv '^x-ui\(/\|$\)' "$stage/members"; then
        echo '安装包包含不安全路径。'; return 1
    fi
    tar -tvzf "$stage/$asset" | awk 'substr($0,1,1)!="-" && substr($0,1,1)!="d" {bad=1} END {exit bad}'
    tar -xzf "$stage/$asset" -C "$stage" --no-same-owner
    for file in x-ui x-ui.sh bin/xray-linux-$arch scripts/lib/ssl.sh; do
        [[ -s "$stage/x-ui/$file" ]] || { echo "安装包缺少 $file"; return 1; }
    done
    bash -n "$stage/x-ui/x-ui.sh"
    chmod +x "$stage/x-ui/x-ui" "$stage/x-ui/bin/xray-linux-$arch"
    "$stage/x-ui/x-ui" -v
    "$stage/x-ui/bin/xray-linux-$arch" version
    case "$arch" in armv*) mv "$stage/x-ui/bin/xray-linux-$arch" "$stage/x-ui/bin/xray-linux-arm";; esac
    mkdir -p /var/backups
    backup=$(mktemp -d /var/backups/x-ui-update.XXXXXX)
    mkdir "$backup/program" "$backup/data"
    stopped=1
    service_call stop
    cp -a "$xui_folder/." "$backup/program/"
    cp -a "$db_folder/." "$backup/data/"
    cp -a /usr/bin/x-ui "$backup/menu"
    echo "恢复备份：$backup"
    changed=1
    cp -a "$stage/x-ui/." "$xui_folder/"
    install -m 755 "$stage/x-ui/x-ui.sh" /usr/bin/x-ui
    service_call start
    for ((i=0; i<10; i++)); do sleep 1; service_alive; done
    port=$("$xui_folder/x-ui" setting -show true | sed -n 's/^port: *//p')
    [[ "$port" =~ ^[0-9]+$ ]] || { echo '无法确认面板端口。'; return 1; }
    if ! (echo >/dev/tcp/127.0.0.1/"$port") 2>/dev/null; then
        echo '本机端口未响应；自定义绑定地址请人工升级。'; return 1
    fi
    committed=1
    echo "更新成功：$tag。账号、节点和证书配置已保留。"
    echo "备份保留于 $backup；确认正常后可手动清理。"
    echo '检查证书、订阅及端口：x-ui diagnose'
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then update_main "$@"; fi

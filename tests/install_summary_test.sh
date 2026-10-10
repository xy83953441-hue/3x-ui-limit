#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source <(sed -n '/^config_after_install() {$/,/^}$/p' install.sh)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
xui_folder=/mock
function /mock/x-ui {
    if [[ "$*" == 'setting -show true' ]]; then
        printf 'hasDefaultCredential: true\nport: 2053\nwebBasePath: /\nsubPort: 2096\n'
    else printf '%s\n' "$*" >> "$tmp/settings"; fi
}
gen_random_string() { printf "%${1}s" '' | tr ' ' a; }
is_port_in_use() { return 1; }
is_ipv4() { [[ "$1" == 203.0.113.1 ]]; }
curl() { echo 203.0.113.1; }
refresh_ssl_scheme() { SSL_SCHEME=http; }
prompt_and_setup_ssl() { return 1; }
config_after_install <<< '4212' > "$tmp/output"
grep -q '面板端口：4212' "$tmp/output"
grep -q '订阅端口：2096' "$tmp/output"
grep -q '账号：aaaaaaaaaaaa' "$tmp/output"
grep -q '密码：aaaaaaaaaaaaaaaaaaaa' "$tmp/output"
grep -q 'http://203.0.113.1:4212/' "$tmp/output"
! grep -q 'https://' "$tmp/output"
rm "$tmp/settings"
! config_after_install <<< '70000' > "$tmp/invalid"
[[ ! -f "$tmp/settings" ]]
echo 'PASS: installation shows credentials, separate ports and actual HTTP state; rejects invalid port before writes'

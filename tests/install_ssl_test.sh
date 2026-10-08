#!/usr/bin/env bash
# Isolated tests: never source installer entrypoint or change real services/firewalls.
set -euo pipefail
cd "$(dirname "$0")/.."
for fn in is_ipv4 is_ipv6 is_port_in_use open_ssl_port ensure_renewal_service valid_certificate_pair refresh_ssl_scheme setup_ip_certificate prompt_and_setup_ssl; do
    source <(sed -n "/^${fn}() {$/,/^}$/p" install.sh)
done
red='' green='' yellow='' plain='' blue=''
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
checks=0
pass() { checks=$((checks + 1)); echo "PASS: $1"; }

# Regression: awk END must not override the successful matching-port result.
ss() { printf 'LISTEN 0 128 [::]:80 [::]:*\n'; }
is_port_in_use 80
! is_port_in_use 8080
pass 'listener detection matches exact port'

printf '[req]\ndistinguished_name=dn\nprompt=no\n[dn]\nCN=localhost\n' > "$tmp/openssl.cnf"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/key" -out "$tmp/cert" -days 1 -config "$tmp/openssl.cnf" >/dev/null 2>&1
openssl genrsa -out "$tmp/other-key" 2048 >/dev/null 2>&1
valid_certificate_pair "$tmp/cert" "$tmp/key"
! valid_certificate_pair "$tmp/cert" "$tmp/other-key"
! valid_certificate_pair "$tmp/missing" "$tmp/key"
pass 'valid, missing and mismatched certificate files'

xui_folder="$tmp"
cat > "$tmp/x-ui" <<'SH'
#!/usr/bin/env bash
printf 'cert: %s\nkey: %s\n' "$TEST_CERT" "$TEST_KEY"
SH
chmod +x "$tmp/x-ui"
export TEST_CERT="$tmp/cert" TEST_KEY="$tmp/key"
refresh_ssl_scheme
[[ "$SSL_SCHEME" == https ]]
TEST_KEY="$tmp/other-key"
refresh_ssl_scheme
[[ "$SSL_SCHEME" == http ]]
pass 'HTTPS shown only for usable configured certificate pair'

(
    ip() { echo '1.1.1.1 dev eth0 src 203.0.113.1'; }
    firewall-cmd() {
        printf '%s\n' "$*" >> "$tmp/firewall"
        case "$1" in --get-zone-of-interface=*) echo public ;; esac
    }
    open_ssl_port 80
    grep -q -- '--zone=public --add-port=80/tcp' "$tmp/firewall"
    grep -q -- '--permanent --zone=public --add-port=80/tcp' "$tmp/firewall"
    ! grep -q -- '--reload' "$tmp/firewall"
)
pass 'firewalld uses interface zone and writes runtime plus permanent rules'
(
    ip() { echo '1.1.1.1 dev eth0'; }
    firewall-cmd() { case "$1" in --state) return 0 ;; --get-zone-of-interface=*) echo public ;; *) return 1 ;; esac; }
    ! open_ssl_port 80
)
pass 'firewall failure propagates'
(
    systemctl() { printf '%s\n' "$*" >> "$tmp/cron"; }
    release=centos
    ensure_renewal_service
    grep -q 'enable --now crond' "$tmp/cron"
    release=ubuntu
    ensure_renewal_service
    grep -q 'enable --now cron' "$tmp/cron"
)
pass 'renewal service selected for CentOS and Ubuntu'

# Mock all effects used by IP issuance; no certificate authority contact occurs.
run_ip_case() (
    set +e
    issue_result="$1" install_result="$2" config_result="$3"
    is_port_in_use() { return 1; }
    socat() { :; }
    ensure_renewal_service() { :; }
    open_ssl_port() { :; }
    install_acme() { :; }
    crontab() { echo '0 0 * * * /root/.acme.sh/acme.sh --cron'; }
    mkdir() { :; }; touch() { :; }; chmod() { :; }
    valid_certificate_pair() { return 0; }
    function /root/.acme.sh/acme.sh {
        case "$1" in
            --help) echo --certificate-profile ;;
            --issue) printf '%s\n' "$*" > "$tmp/issue-args"; return "$issue_result" ;;
            --install-cert) return "$install_result" ;;
        esac
    }
    xui_folder=/mock
    function /mock/x-ui { return "$config_result"; }
    setup_ip_certificate 203.0.113.1 ''
)
run_ip_case 0 0 0
grep -q -- '--days 3' "$tmp/issue-args"
grep -q -- '--keylength ec-256' "$tmp/issue-args"
! grep -q -- '--force' "$tmp/issue-args"
run_ip_case 2 0 0
! run_ip_case 1 0 0
! run_ip_case 0 1 0
! run_ip_case 0 0 1
pass 'issuance success, not-due reuse, CA failure, installation failure and config failure'
(
    is_port_in_use() { return 0; }
    ! setup_ip_certificate 203.0.113.1 ''
)
pass 'occupied TCP 80 aborts before changing services or requesting certificate'
(
    release=centos
    systemctl() { :; }
    setup_ip_certificate() { return 1; }
    refresh_ssl_scheme() { SSL_SCHEME=http; }
    open_ssl_port() { echo 'unexpected open' > "$tmp/unexpected"; }
    prompt_and_setup_ssl 7241 path 203.0.113.1 <<< $'2\n\n'
    [[ "$SSL_SCHEME" == http && ! -e "$tmp/unexpected" ]]
)
pass 'failed IP setup neither announces HTTPS nor opens panel port'
echo "$checks test groups passed (mocked issuance; live Linux/CA validation still required)."

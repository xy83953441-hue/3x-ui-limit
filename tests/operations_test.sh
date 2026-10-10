#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
repo_dir=$PWD
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for file in install.sh update.sh x-ui.sh scripts/lib/ssl.sh scripts/diagnose.sh; do bash -n "$file"; done

# Rollback uses real temporary files and mocked service calls, never real services.
mkdir -p "$tmp/backup/program" "$tmp/backup/data" "$tmp/program" "$tmp/data"
printf old > "$tmp/backup/program/x-ui"
printf old-db > "$tmp/backup/data/x-ui.db"
printf old-menu > "$tmp/backup/menu"
printf new > "$tmp/program/x-ui"
printf migrated > "$tmp/data/x-ui.db"
printf wal > "$tmp/data/x-ui.db-wal"
export TEST_TMP="$tmp" TEST_REPO="$repo_dir"
cat > "$tmp/rollback.sh" <<'SH'
#!/usr/bin/env bash
source "$TEST_REPO/update.sh"
backup="$TEST_TMP/backup" xui_folder="$TEST_TMP/program" db_folder="$TEST_TMP/data"
stopped=1 changed=1
service_call() { echo "$1" >> "$TEST_TMP/services"; }
service_alive() { return 0; }
cp() {
    if [[ "${!#}" == /usr/bin/x-ui ]]; then command cp "$backup/menu" "$TEST_TMP/menu";
    else command cp "$@"; fi
}
trap finish EXIT
exit 17
SH
if bash "$tmp/rollback.sh"; then echo 'Expected update failure'; exit 1; fi
[[ $(cat "$tmp/program/x-ui") == old ]]
[[ $(cat "$tmp/data/x-ui.db") == old-db ]]
[[ ! -e "$tmp/data/x-ui.db-wal" ]]
[[ $(cat "$tmp/menu") == old-menu ]]
[[ $(cat "$tmp/services") == $'stop\nstart' ]]
echo 'PASS: failed update restores executable, database, WAL and menu then restarts'

# A failure before the first mutation must not touch the old installation.
sed 's/stopped=1 changed=1/stopped=0 changed=0/' "$tmp/rollback.sh" > "$tmp/preflight.sh"
rm "$tmp/services"
if bash "$tmp/preflight.sh"; then exit 1; fi
[[ ! -e "$tmp/services" ]]
echo 'PASS: preflight failure leaves service untouched'

# BBR failure must not write a configuration file or invoke sysctl -w.
(
    source <(sed -n '/^enable_bbr() {$/,/^}$/p' x-ui.sh)
    sysctl() { [[ "$*" != *'-w'* ]] || exit 99; echo 'cubic reno'; }
    modprobe() { return 1; }
    ! enable_bbr
)
echo 'PASS: unsupported BBR returns without writes'

# Atomic menu download failure must keep the installed command intact.
(
    source <(sed -n '/^update_menu() {$/,/^}$/p' x-ui.sh)
    mktemp() { command mktemp "$TEST_TMP/menu.XXXXXX"; }
    curl() { return 22; }
    mv() { echo 'unexpected replacement'; exit 99; }
    ! update_menu
)
echo 'PASS: failed menu download cannot replace installed menu'

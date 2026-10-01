#!/bin/bash
# Explicit, administrator-run development installation; never invokes sudo.
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

base='/Library/Application Support/RV'
directory="$base/phase2a-development"
manifest="$base/peer-trust.json"

fail() { printf 'phase2a trust: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'EOF'
Usage:
  phase2a-development-trust.sh install --host PATH --service PATH [--cli PATH]
  phase2a-development-trust.sh uninstall

Run explicitly as an administrator after building the binaries. Installation
refuses existing trust configuration. It copies and re-signs only the installed
copies, using hardened ad-hoc signatures and exact CDHash requirements.
EOF
}

protected() {
    local path="$1" details
    while :; do
        [[ ! -L "$path" && -e "$path" ]] || fail "unsafe/missing path: $path"
        [[ $(stat -f '%u' "$path") == 0 ]] || fail "not root owned: $path"
        local mode
        mode=$(stat -f '%Lp' "$path")
        (( (8#$mode & 8#022) == 0 )) || fail "writable protected path: $path"
        details=$(ls -lde "$path")
        if printf '%s\n' "$details" | awk '/^[[:space:]]*[0-9]+:.* allow / { found = 1 } END { exit !found }'; then
            fail "ACL allow entry on protected path: $path"
        fi
        [[ "$path" == / ]] && break
        path=$(dirname "$path")
    done
}

[[ ${1:-} != --help ]] || { usage; exit 0; }
[[ $(uname -s) == Darwin ]] || fail 'macOS is required'
[[ $(id -u) == 0 ]] || fail 'explicit administrator execution is required; this script never invokes sudo'
umask 022
operation=${1:-}
[[ $# -gt 0 ]] && shift

if [[ "$operation" == uninstall ]]; then
    [[ $# == 0 ]] || fail 'uninstall accepts no arguments'
    protected "$directory"
    protected "$directory/receipt.sha256"
    protected "$manifest"
    # Refuse cleanup if any installed bytes or the fixed trust manifest changed.
    (cd "$directory" && shasum -a 256 --check receipt.sha256) || fail 'installation changed; cleanup refused'
    for name in rv-workspace-host rvd rv; do
        [[ ! -e "$directory/$name" ]] || protected "$directory/$name"
    done
    # No recursive deletion and no discovery of arbitrary paths from a receipt.
    rm "$manifest" "$directory/receipt.sha256" "$directory/rv-workspace-host" "$directory/rvd"
    [[ ! -e "$directory/rv" ]] || rm "$directory/rv"
    rmdir "$directory"
    # Preserve the shared RV directory when any unrelated files remain.
    rmdir "$base" 2>/dev/null || true
    printf 'Development trust removed. Restart surviving RV processes.\n'
    exit 0
fi

[[ "$operation" == install ]] || { usage; exit 2; }
host_source='' service_source='' cli_source=''
while [[ $# -gt 0 ]]; do
    [[ $# -ge 2 ]] || fail 'option requires a path'
    case "$1" in
        --host) [[ -z "$host_source" ]] || fail 'duplicate --host'; host_source=$2 ;;
        --service) [[ -z "$service_source" ]] || fail 'duplicate --service'; service_source=$2 ;;
        --cli) [[ -z "$cli_source" ]] || fail 'duplicate --cli'; cli_source=$2 ;;
        *) fail "unknown option: $1" ;;
    esac
    shift 2
done
[[ -n "$host_source" && -n "$service_source" ]] || fail '--host and --service are required'
for source in "$host_source" "$service_source" ${cli_source:+"$cli_source"}; do
    [[ "$source" == /* && -f "$source" && -x "$source" ]] || fail "not an absolute executable file: $source"
done
protected '/Library/Application Support'
if [[ -e "$base" || -L "$base" ]]; then
    [[ -d "$base" ]] || fail 'RV parent is not a directory'
    protected "$base"
else
    mkdir "$base"
fi
[[ ! -e "$manifest" && ! -L "$manifest" ]] || fail 'existing trust manifest; installation refused'
[[ ! -e "$directory" && ! -L "$directory" ]] || fail 'existing development installation; installation refused'
mkdir "$directory"
published=0
complete=0
rollback() {
    if [[ "$complete" == 0 ]]; then
        [[ "$published" == 0 ]] || rm -f "$manifest"
        rm -f "$directory/rv-workspace-host" "$directory/rvd" "$directory/rv" \
            "$directory/manifest.tmp" "$directory/receipt.sha256"
        rmdir "$directory" 2>/dev/null || true
        rmdir "$base" 2>/dev/null || true
    fi
}
trap rollback EXIT

install_component() {
    local source="$1" name="$2"
    cp "$source" "$directory/$name"
    chmod -N "$directory/$name"
    chmod 755 "$directory/$name"
    # Exact development identity; no entitlements and no injection exceptions.
    codesign --force --sign - --options runtime --identifier "dev.rv.phase2a.$name" "$directory/$name"
    codesign --verify --strict "$directory/$name"
    protected "$directory/$name"
}
install_component "$host_source" rv-workspace-host
install_component "$service_source" rvd
[[ -z "$cli_source" ]] || install_component "$cli_source" rv

entry() {
    local role="$1" name="$2" hash
    hash=$(codesign --display --verbose=4 "$directory/$name" 2>&1 | sed -n 's/^CDHash=//p')
    [[ "$hash" =~ ^[0-9a-f]{40}$ ]] || fail "missing exact CDHash for $name"
    printf '{"role":"%s","requirement":"cdhash H\\\"%s\\\"","developmentCDHash":"%s","developmentExecutablePath":"%s/%s"}' \
        "$role" "$hash" "$hash" "$directory" "$name"
}
{
    printf '['
    entry workspaceHost rv-workspace-host
    printf ','
    entry service rvd
    if [[ -n "$cli_source" ]]; then printf ','; entry cli rv; fi
    printf ']\n'
} > "$directory/manifest.tmp"
chmod 644 "$directory/manifest.tmp"
protected "$directory/manifest.tmp"
# Publish without overwriting a manifest created after our initial check.
ln "$directory/manifest.tmp" "$manifest"
published=1
rm "$directory/manifest.tmp"
protected "$manifest"
(
    cd "$directory"
    shasum -a 256 ../peer-trust.json rv-workspace-host rvd
    [[ -z "$cli_source" ]] || shasum -a 256 rv
) > "$directory/receipt.sha256"
chmod 644 "$directory/receipt.sha256"
protected "$directory/receipt.sha256"
complete=1
printf 'Installed exact development roles at %s\nUse the installed copies; restart RV processes.\n' "$directory"

#!/usr/bin/env bash
# Scripts/sign-macos.sh — Developer ID sign, verify, and notarize a release stage.
# Compatible with macOS /bin/bash 3.2. Never prints secret values.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: Scripts/sign-macos.sh [--dry-run] [--keychain-from-env] STAGE

  codesign (hardened runtime, secure timestamp, identifier dev.rv.<name>)
    libswiftCompatibilitySpan.dylib (when staged), rv, rv-cli, rvd,
    rv-workspace-host, rv-pty-claim; codesign --verify --strict each;
  notarytool submit --wait (App Store Connect API key) a zip of them;
  spctl assessment once notarized.

Bare Mach-O files cannot be stapled: Gatekeeper fetches the ticket online.
rv-agent-bin symlinks and *_RVPacks bundles are not code and are not signed.

A staged RVApprovals.app (the MCP approvals custodian) is the one exception
that carries entitlements: its data-protection keychain key needs the
keychain-access-groups entitlement, which macOS only honors from a signed
bundle whose embedded provisioning profile grants that group. Supply the
profile with RV_CUSTODIAN_PROVISIONING_PROFILE; without it a real run skips
custodian signing with a warning (a dry run still prints the full plan),
and MCP approvals stay disabled on installs from that stage.

  Portal step (operator, once): in the Apple Developer portal create the
  App ID dev.rv.mcp-custodian with a keychain-access-groups capability for
  the team-prefixed group <TEAMID>.dev.rv.mcp-custodian, then download a
  Developer ID provisioning profile for it and point
  RV_CUSTODIAN_PROVISIONING_PROFILE at the .provisionprofile file. No
  profile is bundled with this repository.

Environment (real runs):
  DEVELOPER_ID_APP     signing identity, "Developer ID Application: NAME (TEAM)"
  NOTARY_KEY_ID        App Store Connect API key id
  NOTARY_ISSUER_ID     App Store Connect issuer id
  NOTARY_KEY_P8        base64 of the AuthKey_*.p8 (or NOTARY_KEY_PATH: a file)
  RV_CUSTODIAN_PROVISIONING_PROFILE
                       Developer ID provisioning profile for dev.rv.mcp-custodian
  --keychain-from-env also needs, for a temporary keychain:
  MACOS_CERT_P12       base64 of the Developer ID Application .p12
  MACOS_CERT_PASSWORD  its password

--dry-run prints the exact commands with <PLACEHOLDERS>; it runs on any OS
and needs none of the variables.
EOF
}

dry_run=0
from_env=0
stage=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dry-run) dry_run=1 ;;
    --keychain-from-env) from_env=1 ;;
    -*)
      printf 'sign: unknown option %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -n "$stage" ]]; then
        printf 'sign: one STAGE only\n' >&2
        exit 2
      fi
      stage="$1"
      ;;
  esac
  shift
done
if [[ -z "$stage" ]]; then
  usage >&2
  exit 2
fi

fail() { printf 'sign: %s\n' "$*" >&2; exit 1; }

# Dependencies first: the hardened runtime's library validation refuses a
# dylib that is not signed by the same team as the binary loading it.
binaries=()
if [[ -e "$stage/libswiftCompatibilitySpan.dylib" || -L "$stage/libswiftCompatibilitySpan.dylib" ]]; then
  binaries+=(libswiftCompatibilitySpan.dylib)
fi
binaries+=(rv rv-cli rvd rv-workspace-host rv-pty-claim)
for name in "${binaries[@]}"; do
  path="$stage/$name"
  [[ ! -L "$path" ]] || fail "$name in the stage is a symlink; refusing to sign through it"
  [[ -f "$path" ]] || fail "stage is missing $name: $stage"
done

# The custodian bundle is optional in a stage (older stages lack it), but a
# half-assembled bundle is a staging bug, not a cue to skip silently.
custodian_app="$stage/RVApprovals.app"
custodian_bin="$custodian_app/Contents/MacOS/rv-mcp-custodian"
has_custodian=0
if [[ -e "$custodian_app" || -L "$custodian_app" ]]; then
  [[ ! -L "$custodian_app" && ! -L "$custodian_bin" ]] \
    || fail "RVApprovals.app in the stage is a symlink; refusing to sign through it"
  [[ -f "$custodian_bin" ]] || fail "RVApprovals.app is missing Contents/MacOS/rv-mcp-custodian: $stage"
  [[ -f "$custodian_app/Contents/Info.plist" ]] || fail "RVApprovals.app is missing Contents/Info.plist: $stage"
  has_custodian=1
fi
script_dir="$(cd "$(dirname "$0")" && pwd)"
custodian_entitlements="$script_dir/custodian/RVApprovals.entitlements"
custodian_profile="${RV_CUSTODIAN_PROVISIONING_PROFILE:-}"
if [[ "$dry_run" -eq 0 && -n "$custodian_profile" && ! -f "$custodian_profile" ]]; then
  fail "RV_CUSTODIAN_PROVISIONING_PROFILE is not a file: $custodian_profile"
fi
# Without a profile a real run cannot sign the custodian (amfid kills an
# entitlement-carrying binary with no matching profile); a dry run still
# prints every custodian command with a placeholder profile path.
custodian_signable=0
if [[ "$has_custodian" -eq 1 ]]; then
  if [[ "$dry_run" -eq 1 || -n "$custodian_profile" ]]; then
    custodian_signable=1
  fi
fi
if [[ "$dry_run" -eq 1 && -z "$custodian_profile" ]]; then
  custodian_profile="<RV_CUSTODIAN_PROVISIONING_PROFILE>"
fi

if [[ "$dry_run" -eq 0 ]]; then
  missing=()
  [[ -n "${DEVELOPER_ID_APP:-}" ]] || missing+=(DEVELOPER_ID_APP)
  [[ -n "${NOTARY_KEY_ID:-}" ]] || missing+=(NOTARY_KEY_ID)
  [[ -n "${NOTARY_ISSUER_ID:-}" ]] || missing+=(NOTARY_ISSUER_ID)
  if [[ -z "${NOTARY_KEY_P8:-}" && -z "${NOTARY_KEY_PATH:-}" ]]; then
    missing+=("NOTARY_KEY_P8 (or NOTARY_KEY_PATH)")
  fi
  if [[ "$from_env" -eq 1 ]]; then
    [[ -n "${MACOS_CERT_P12:-}" ]] || missing+=(MACOS_CERT_P12)
    [[ -n "${MACOS_CERT_PASSWORD:-}" ]] || missing+=(MACOS_CERT_PASSWORD)
  fi
  if [[ ${#missing[@]} -gt 0 ]]; then
    joined="$(printf ', %s' "${missing[@]}")"
    printf 'sign: missing environment: %s\n' "${joined#, }" >&2
    exit 2
  fi
  [[ "$(uname -s)" == "Darwin" ]] || fail "macOS is required (use --dry-run elsewhere)"
fi

# A dry run substitutes placeholders for every secret-derived argument, so
# the printed commands are safe to log.
if [[ "$dry_run" -eq 1 ]]; then
  identity="<DEVELOPER_ID_APP>"
  key_id="<NOTARY_KEY_ID>"
  issuer="<NOTARY_ISSUER_ID>"
  key_file="<NOTARY_KEY_P8 file>"
  work="<work dir>"
  keychain="<temporary keychain>"
  keychain_password="<random keychain password>"
  p12_file="<MACOS_CERT_P12 file>"
  cert_password="<MACOS_CERT_PASSWORD>"
else
  identity="$DEVELOPER_ID_APP"
  key_id="$NOTARY_KEY_ID"
  issuer="$NOTARY_ISSUER_ID"
  work="$(mktemp -d "${TMPDIR:-/tmp}/rv-sign.XXXXXX")"
  keychain="$work/rv-signing.keychain-db"
  keychain_password=""
  p12_file="$work/cert.p12"
  cert_password="${MACOS_CERT_PASSWORD:-}"
  key_file="${NOTARY_KEY_PATH:-$work/AuthKey.p8}"
fi

# Echo-and-run. Real runs print the step name only: arguments can hold secrets.
run() {
  if [[ "$dry_run" -eq 1 ]]; then
    printf '+'
    printf ' %s' "$@"
    printf '\n'
  else
    "$@"
  fi
}
say() { printf '%s\n' "$*"; }

original_keychains=()
keychain_created=0
cleanup() {
  if [[ "$dry_run" -eq 1 ]]; then
    if [[ "$keychain_created" -eq 1 ]]; then
      run security list-keychains -d user -s "<existing keychains>"
      run security delete-keychain "$keychain"
    fi
    return 0
  fi
  if [[ "$keychain_created" -eq 1 ]]; then
    if [[ ${#original_keychains[@]} -gt 0 ]]; then
      security list-keychains -d user -s "${original_keychains[@]}" >/dev/null 2>&1 || true
    fi
    security delete-keychain "$keychain" >/dev/null 2>&1 || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

# Decoded secrets live only inside $work, which mktemp -d creates 0700.
keychain_args=()
if [[ "$from_env" -eq 1 ]]; then
  say "Importing the Developer ID certificate into a temporary keychain"
  if [[ "$dry_run" -eq 0 ]]; then
    keychain_password="$(openssl rand -hex 24)"
    printf '%s' "$MACOS_CERT_P12" | base64 --decode > "$p12_file"
    while IFS= read -r line; do
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%\"}"
      line="${line#\"}"
      [[ -n "$line" ]] && original_keychains+=("$line")
    done < <(security list-keychains -d user)
  fi
  run security create-keychain -p "$keychain_password" "$keychain"
  keychain_created=1
  run security set-keychain-settings -lut 3600 "$keychain"
  run security unlock-keychain -p "$keychain_password" "$keychain"
  run security import "$p12_file" -k "$keychain" -P "$cert_password" -T /usr/bin/codesign
  run security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_password" "$keychain"
  if [[ "$dry_run" -eq 1 ]]; then
    run security list-keychains -d user -s "$keychain" "<existing keychains>"
  else
    run security list-keychains -d user -s "$keychain" ${original_keychains[@]+"${original_keychains[@]}"}
    rm -f "$p12_file"
  fi
  keychain_args=(--keychain "$keychain")
fi

say "Signing ${#binaries[@]} files in $stage"
for name in "${binaries[@]}"; do
  identifier="dev.rv.$name"
  [[ "$name" != libswiftCompatibilitySpan.dylib ]] || identifier="dev.rv.libswiftCompatibilitySpan"
  run codesign --force --options runtime --timestamp ${keychain_args[@]+"${keychain_args[@]}"} \
    --identifier "$identifier" --sign "$identity" "$stage/$name"
done
for name in "${binaries[@]}"; do
  run codesign --verify --strict --verbose=2 "$stage/$name"
  if [[ "$dry_run" -eq 0 ]]; then
    details="$(codesign -dvv "$stage/$name" 2>&1)"
    [[ "$details" == *"Authority=Developer ID Application:"* ]] || fail "$name is not signed by a Developer ID Application certificate"
    [[ "$details" == *"(runtime)"* ]] || fail "$name is missing the hardened runtime flag"
    [[ "$details" == *"Timestamp="* ]] || fail "$name has no secure timestamp"
  fi
done

if [[ "$has_custodian" -eq 1 && "$custodian_signable" -eq 0 ]]; then
  say "sign: warning: RVApprovals.app left unsigned: RV_CUSTODIAN_PROVISIONING_PROFILE is not set (see --help for the one-time portal step); MCP approvals stay disabled for this stage"
fi
if [[ "$custodian_signable" -eq 1 ]]; then
  say "Signing RVApprovals.app (approvals custodian)"
  # codesign does not expand $(TeamIdentifierPrefix); expand it from the
  # identity's team suffix into a scratch entitlements file.
  team_prefix="<TEAM_ID>."
  if [[ "$dry_run" -eq 0 ]]; then
    team_id="${identity##*\(}"
    team_id="${team_id%\)*}"
    [[ -n "$team_id" && "$team_id" != "$identity" ]] \
      || fail "cannot read the team id from DEVELOPER_ID_APP"
    team_prefix="$team_id."
    sed "s/\$(TeamIdentifierPrefix)/$team_prefix/" \
      "$custodian_entitlements" > "$work/RVApprovals.entitlements"
  else
    run sed "s/\$(TeamIdentifierPrefix)/$team_prefix/" \
      "$custodian_entitlements"
  fi
  expanded_entitlements="$work/RVApprovals.entitlements"
  run cp -p "$custodian_profile" "$custodian_app/Contents/embedded.provisionprofile"
  if [[ -f "$custodian_app/Contents/MacOS/libswiftCompatibilitySpan.dylib" ]]; then
    run codesign --force --options runtime --timestamp ${keychain_args[@]+"${keychain_args[@]}"} \
      --identifier dev.rv.libswiftCompatibilitySpan --sign "$identity" \
      "$custodian_app/Contents/MacOS/libswiftCompatibilitySpan.dylib"
  fi
  run codesign --force --options runtime --timestamp ${keychain_args[@]+"${keychain_args[@]}"} \
    --entitlements "$expanded_entitlements" \
    --identifier dev.rv.mcp-custodian --sign "$identity" "$custodian_bin"
  run codesign --force --options runtime --timestamp ${keychain_args[@]+"${keychain_args[@]}"} \
    --entitlements "$expanded_entitlements" \
    --identifier dev.rv.mcp-custodian --sign "$identity" "$custodian_app"
  run codesign --verify --deep --strict --verbose=2 "$custodian_app"
fi

say "Notarizing"
if [[ "$dry_run" -eq 0 && -z "${NOTARY_KEY_PATH:-}" ]]; then
  printf '%s' "$NOTARY_KEY_P8" | base64 --decode > "$key_file"
fi
run mkdir -p "$work/rv-notarize"
for name in "${binaries[@]}"; do
  run cp -p "$stage/$name" "$work/rv-notarize/$name"
done
if [[ "$custodian_signable" -eq 1 ]]; then
  run cp -R -p "$custodian_app" "$work/rv-notarize/RVApprovals.app"
fi
run ditto -c -k --keepParent "$work/rv-notarize" "$work/rv-notarize.zip"
if [[ "$dry_run" -eq 1 ]]; then
  run xcrun notarytool submit "$work/rv-notarize.zip" --key "$key_file" --key-id "$key_id" \
    --issuer "$issuer" --wait --timeout 30m --output-format json
else
  set +e
  xcrun notarytool submit "$work/rv-notarize.zip" --key "$key_file" --key-id "$key_id" \
    --issuer "$issuer" --wait --timeout 30m --output-format json > "$work/notary.json"
  notary_status=$?
  set -e
  submission="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id", ""))' "$work/notary.json" 2>/dev/null || true)"
  verdict="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status", ""))' "$work/notary.json" 2>/dev/null || true)"
  if [[ "$notary_status" -ne 0 || "$verdict" != "Accepted" ]]; then
    printf 'sign: notarization returned %s (exit %s)\n' "${verdict:-no status}" "$notary_status" >&2
    if [[ -n "$submission" ]]; then
      xcrun notarytool log "$submission" --key "$key_file" --key-id "$key_id" --issuer "$issuer" >&2 || true
    fi
    exit 1
  fi
  say "Notarization accepted (submission $submission)"
fi
say "Stapling: bare Mach-O binaries cannot be stapled; Gatekeeper fetches the ticket online"
if [[ "$custodian_signable" -eq 1 ]]; then
  run xcrun stapler staple "$custodian_app"
  run xcrun stapler validate "$custodian_app"
fi

say "Assessing"
for name in "${binaries[@]}"; do
  [[ "$name" != libswiftCompatibilitySpan.dylib ]] || continue
  if [[ "$dry_run" -eq 1 ]]; then
    run spctl -a -t open --context context:primary-signature -vv "$stage/$name"
    continue
  fi
  # The ticket can take a moment to become visible to Gatekeeper's lookup.
  # Accepted means spctl exits 0, the verdict line for this exact path says
  # accepted, and the source is Notarized — a rejected binary can still
  # print a Notarized source line.
  verdict=""
  accepted=0
  for _ in 1 2 3 4 5 6; do
    if verdict="$(spctl -a -t open --context context:primary-signature -vv "$stage/$name" 2>&1)" \
      && printf '%s\n' "$verdict" | grep -Fqx -- "$stage/$name: accepted" \
      && printf '%s\n' "$verdict" | grep -Fqx -- "source=Notarized Developer ID"; then
      accepted=1
      break
    fi
    sleep 10
  done
  [[ "$accepted" -eq 1 ]] || fail "Gatekeeper does not accept $name as notarized: $verdict"
done
if [[ "$custodian_signable" -eq 1 ]]; then
  if [[ "$dry_run" -eq 1 ]]; then
    run spctl -a -t open --context context:primary-signature -vv "$custodian_app"
  else
    # The ticket is stapled onto the bundle, so no online wait is needed.
    verdict="$(spctl -a -t open --context context:primary-signature -vv "$custodian_app" 2>&1)" \
      || fail "Gatekeeper does not accept RVApprovals.app as notarized: $verdict"
  fi
fi
if [[ "$dry_run" -eq 1 ]]; then
  say "Dry run: nothing was signed"
else
  say "Signed and notarized $stage"
fi

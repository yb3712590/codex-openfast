#!/usr/bin/env bash
set -euo pipefail

PATH="${PATH}:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin"

APP_PATH="${CODEX_APP_PATH:-/Applications/Codex.app}"
ASAR_PATH="${APP_PATH}/Contents/Resources/app.asar"
INFO_PLIST_PATH="${APP_PATH}/Contents/Info.plist"
PATCH_ROOT="${HOME}/.codex/patches/codex-fast-mode"
SIGN_IDENTITY="${CODEX_SIGN_IDENTITY:--}"
ASAR_CLI="${CODEX_ASAR_CLI:-@electron/asar}"
PATCH_VERSION="force-fast-ui-ct-only-v1"
PATCH_SUMMARY="Force statsig fast gate helper to return true, keep model fast-tier gate intact"

MODE="${1:-help}"
ARG2="${2:-}"

usage() {
  cat <<'EOF'
Usage:
  patch_codex_fast_mode.sh backup
  patch_codex_fast_mode.sh apply
  patch_codex_fast_mode.sh restore [backup_dir]
  patch_codex_fast_mode.sh status

Environment overrides:
  CODEX_APP_PATH=/path/to/Codex.app
  CODEX_SIGN_IDENTITY='Developer ID Application: ...'

Notes:
  - patch version: force-fast-ui-ct-only-v1
  - backup: create a backup of app.asar + Info.plist only
  - apply: backup current app, patch the statsig/auth fast gate helper to always return true,
    repack, update ElectronAsarIntegrity, and re-sign
  - restore: restore from a backup dir (default: latest backup), then recompute ElectronAsarIntegrity
  - status: show hash match, target JS file, and whether the ct-like gate looks original or patched
EOF
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing command: $cmd" >&2
    exit 1
  fi
}

check_paths() {
  if [[ ! -d "$APP_PATH" ]]; then
    echo "Codex app not found: $APP_PATH" >&2
    exit 1
  fi
  if [[ ! -f "$ASAR_PATH" ]]; then
    echo "asar not found: $ASAR_PATH" >&2
    exit 1
  fi
  if [[ ! -f "$INFO_PLIST_PATH" ]]; then
    echo "Info.plist not found: $INFO_PLIST_PATH" >&2
    exit 1
  fi
}

ad_hoc_resign() {
  codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_PATH" >/dev/null
}

latest_backup_dir() {
  if [[ ! -d "$PATCH_ROOT" ]]; then
    return 1
  fi
  ls -1dt "$PATCH_ROOT"/backup-* 2>/dev/null | head -n 1
}

current_asar_header_hash() {
  ASAR_TO_HASH="$ASAR_PATH" node <<'NODE'
const crypto = require('crypto');
const fs = require('fs');

const asarPath = process.env.ASAR_TO_HASH;
const fd = fs.openSync(asarPath, 'r');
const sizeBuf = Buffer.alloc(8);
fs.readSync(fd, sizeBuf, 0, 8, 0);

const headerPickleSize = sizeBuf.readUInt32LE(4);
const headerPickleBuf = Buffer.alloc(headerPickleSize);
fs.readSync(fd, headerPickleBuf, 0, headerPickleSize, 8);
fs.closeSync(fd);

const headerStringLen = headerPickleBuf.readUInt32LE(4);
const headerStringBuf = headerPickleBuf.subarray(8, 8 + headerStringLen);
process.stdout.write(crypto.createHash('sha256').update(headerStringBuf).digest('hex'));
NODE
}

plist_asar_hash() {
  /usr/libexec/PlistBuddy -c 'Print :ElectronAsarIntegrity:Resources/app.asar:hash' "$INFO_PLIST_PATH" 2>/dev/null || true
}

write_plist_asar_hash() {
  local hash="$1"
  /usr/libexec/PlistBuddy -c "Set :ElectronAsarIntegrity:Resources/app.asar:hash $hash" "$INFO_PLIST_PATH"
}

ct_gate_state() {
  local file="$1"
  python3 - "$file" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()

name = r'[A-Za-z_$][A-Za-z0-9_$]*'
quote = r'[`"\']'
original = re.compile(
    rf'function {name}\(\)\{{let e=\(0,{name}\.c\)\(3\),\{{authMethod:t\}}={name}\(\),\[n\]={name}\({quote}statsig_default_enable_features{quote}\),r;return e\[0\]!==t\|\|e\[1\]!==n\?\.fast_mode\?\(r=n\?\.fast_mode===!0&&{name}\(t\),e\[0\]=t,e\[1\]=n\?\.fast_mode,e\[2\]=r\):r=e\[2\],r\}}'
)
patched = re.compile(
    rf'function {name}\(\)\{{let e=\(0,{name}\.c\)\(3\),\{{authMethod:t\}}={name}\(\),\[n\]={name}\({quote}statsig_default_enable_features{quote}\),r;return e\[0\]!==t\|\|e\[1\]!==n\?\.fast_mode\?\(r=n\?\.fast_mode===!0&&{name}\(t\),e\[0\]=t,e\[1\]=n\?\.fast_mode,e\[2\]=r\):r=e\[2\],true\}}'
)

if patched.search(text):
    print("patched")
elif original.search(text):
    print("original")
else:
    print("missing")
PY
}

locate_target_file() {
  local extracted_dir="$1"
  python3 - "$extracted_dir" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1]) / "webview" / "assets"
if not root.exists():
    sys.exit(0)

name = r'[A-Za-z_$][A-Za-z0-9_$]*'
quote = r'[`"\']'
pattern = re.compile(
    rf'function {name}\(\)\{{let e=\(0,{name}\.c\)\(3\),\{{authMethod:t\}}={name}\(\),\[n\]={name}\({quote}statsig_default_enable_features{quote}\),r;return e\[0\]!==t\|\|e\[1\]!==n\?\.fast_mode\?\(r=n\?\.fast_mode===!0&&{name}\(t\),e\[0\]=t,e\[1\]=n\?\.fast_mode,e\[2\]=r\):r=e\[2\],(?:r|true)\}}'
)

for path in sorted(root.glob("*.js")):
    try:
        text = path.read_text()
    except Exception:
        continue
    if "statsig_default_enable_features" not in text:
        continue
    if pattern.search(text):
        print(path)
        break
PY
}

patch_text_file() {
  local file="$1"
  python3 - "$file" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()

name = r'[A-Za-z_$][A-Za-z0-9_$]*'
quote = r'(?:[`"\'])'
pattern = re.compile(
    rf'(function {name}\(\)\{{let e=\(0,{name}\.c\)\(3\),\{{authMethod:t\}}={name}\(\),\[n\]={name}\({quote}statsig_default_enable_features{quote}\),r;return e\[0\]!==t\|\|e\[1\]!==n\?\.fast_mode\?\(r=n\?\.fast_mode===!0&&{name}\(t\),e\[0\]=t,e\[1\]=n\?\.fast_mode,e\[2\]=r\):r=e\[2\],)r(\}})'
)

text2, count = pattern.subn(r'\1true\2', text, count=1)
if count != 1:
    raise SystemExit("Did not find exactly one ct-like fast gate to patch.")

path.write_text(text2)
PY
}

write_backup_readme() {
  local backup_dir="$1"
  local ts="$2"
  local target_rel="${3:-}"
  local target_state="${4:-}"
  local header_hash="${5:-}"
  cat > "${backup_dir}/README.txt" <<EOF
Codex fast-mode ct-only patch record

- Patch version: $PATCH_VERSION
- Patch summary: $PATCH_SUMMARY
- Timestamp (UTC): $ts
- App path: $APP_PATH
- Asar path: $ASAR_PATH
- Info.plist path: $INFO_PLIST_PATH
- Signing identity: $SIGN_IDENTITY
- Target JS file inside asar: $target_rel
- Target gate state after action: $target_state
- ElectronAsarIntegrity header hash after action: $header_hash

Restore:
  cp "${backup_dir}/app.asar.original" "$ASAR_PATH"
  cp "${backup_dir}/Info.plist.original" "$INFO_PLIST_PATH"
  codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_PATH"
EOF
}

cmd_backup() {
  check_paths

  local ts backup_dir
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  backup_dir="${PATCH_ROOT}/backup-${ts}"
  mkdir -p "$backup_dir"

  cp "$ASAR_PATH" "${backup_dir}/app.asar.original"
  cp "$INFO_PLIST_PATH" "${backup_dir}/Info.plist.original"

  write_backup_readme "$backup_dir" "$ts" "" "backup-only" "$(current_asar_header_hash)"
  echo "BACKUP_DIR=$backup_dir"
}

cmd_apply() {
  require_cmd npx
  require_cmd node
  require_cmd python3
  require_cmd codesign
  check_paths

  local ts backup_dir tmp_dir extracted_dir target_file target_state new_hash target_rel
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  backup_dir="${PATCH_ROOT}/backup-${ts}"
  tmp_dir="$(mktemp -d -t codex-fastpatch-ct-only-XXXXXX)"
  extracted_dir="${tmp_dir}/extracted"
  mkdir -p "$PATCH_ROOT" "$backup_dir"

  npx --yes "$ASAR_CLI" extract "$ASAR_PATH" "$extracted_dir" >/dev/null
  target_file="$(locate_target_file "$extracted_dir")"
  if [[ -z "$target_file" || ! -f "$target_file" ]]; then
    rm -rf "$tmp_dir"
    echo "Could not locate a ct-like statsig fast gate in extracted bundle." >&2
    exit 1
  fi

  target_state="$(ct_gate_state "$target_file")"
  if [[ "$target_state" == "patched" ]]; then
    cp "$ASAR_PATH" "${backup_dir}/app.asar.original"
    cp "$INFO_PLIST_PATH" "${backup_dir}/Info.plist.original"
    cp "$target_file" "${backup_dir}/target.before.js"
    cp "$target_file" "${backup_dir}/target.after.js"
    target_rel="${target_file#${extracted_dir}/}"
    write_backup_readme "$backup_dir" "$ts" "$target_rel" "already-patched" "$(current_asar_header_hash)"
    rm -rf "$tmp_dir"
    echo "Patch already applied."
    return 0
  fi

  if [[ "$target_state" != "original" ]]; then
    rm -rf "$tmp_dir"
    echo "Found candidate file, but ct-like gate pattern did not match the expected original shape." >&2
    exit 1
  fi

  cp "$ASAR_PATH" "${backup_dir}/app.asar.original"
  cp "$INFO_PLIST_PATH" "${backup_dir}/Info.plist.original"
  cp "$target_file" "${backup_dir}/target.before.js"

  patch_text_file "$target_file"
  cp "$target_file" "${backup_dir}/target.after.js"

  target_state="$(ct_gate_state "$target_file")"
  if [[ "$target_state" != "patched" ]]; then
    rm -rf "$tmp_dir"
    echo "ct-like gate patch did not stick; aborting." >&2
    exit 1
  fi

  npx --yes "$ASAR_CLI" pack "$extracted_dir" "${tmp_dir}/app.asar.patched" >/dev/null
  cp "${tmp_dir}/app.asar.patched" "$ASAR_PATH"
  new_hash="$(current_asar_header_hash)"
  write_plist_asar_hash "$new_hash"
  ad_hoc_resign

  target_rel="${target_file#${extracted_dir}/}"
  write_backup_readme "$backup_dir" "$ts" "$target_rel" "$target_state" "$new_hash"

  rm -rf "$tmp_dir"
  echo "Patch applied."
  echo "BACKUP_DIR=$backup_dir"
}

cmd_restore() {
  require_cmd node
  require_cmd codesign
  check_paths

  local backup_dir="$ARG2"
  if [[ -z "$backup_dir" ]]; then
    backup_dir="$(latest_backup_dir || true)"
  fi
  if [[ -z "$backup_dir" || ! -f "${backup_dir}/app.asar.original" ]]; then
    echo "Backup not found. Provide backup dir explicitly." >&2
    exit 1
  fi

  cp "${backup_dir}/app.asar.original" "$ASAR_PATH"
  if [[ -f "${backup_dir}/Info.plist.original" ]]; then
    cp "${backup_dir}/Info.plist.original" "$INFO_PLIST_PATH"
  fi

  write_plist_asar_hash "$(current_asar_header_hash)"
  ad_hoc_resign
  echo "Restored from: $backup_dir"
}

cmd_status() {
  require_cmd npx
  require_cmd node
  require_cmd python3
  check_paths

  local tmp_dir extracted_dir target_file target_state plist_hash actual_hash integrity_match target_rel
  tmp_dir="$(mktemp -d -t codex-fastpatch-status-ct-only-XXXXXX)"
  extracted_dir="${tmp_dir}/extracted"

  npx --yes "$ASAR_CLI" extract "$ASAR_PATH" "$extracted_dir" >/dev/null
  target_file="$(locate_target_file "$extracted_dir")"
  target_state="missing"
  target_rel=""
  if [[ -n "$target_file" && -f "$target_file" ]]; then
    target_state="$(ct_gate_state "$target_file")"
    target_rel="${target_file#${extracted_dir}/}"
  fi

  plist_hash="$(plist_asar_hash)"
  actual_hash="$(current_asar_header_hash)"
  integrity_match=0
  if [[ -n "$plist_hash" && "$plist_hash" == "$actual_hash" ]]; then
    integrity_match=1
  fi

  echo "APP_PATH=$APP_PATH"
  echo "ASAR_PATH=$ASAR_PATH"
  echo "INFO_PLIST_PATH=$INFO_PLIST_PATH"
  echo "PATCH_VERSION=$PATCH_VERSION"
  echo "PATCH_SUMMARY=$PATCH_SUMMARY"
  echo "TARGET_FILE=$target_rel"
  echo "TARGET_GATE_STATE=$target_state"
  echo "PLIST_ASAR_HASH=$plist_hash"
  echo "ACTUAL_ASAR_HEADER_HASH=$actual_hash"
  echo "INTEGRITY_MATCH=$integrity_match"

  rm -rf "$tmp_dir"
}

case "$MODE" in
  backup)
    cmd_backup
    ;;
  apply)
    cmd_apply
    ;;
  restore)
    cmd_restore
    ;;
  status)
    cmd_status
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    echo "Unknown mode: $MODE" >&2
    usage
    exit 1
    ;;
esac

#!/usr/bin/env bash
set -euo pipefail

PATH="${PATH}:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin"

APP_PATH="${CODEX_APP_PATH:-/Applications/Codex.app}"
ASAR_PATH="${APP_PATH}/Contents/Resources/app.asar"
INFO_PLIST_PATH="${APP_PATH}/Contents/Info.plist"
PATCH_ROOT="${HOME}/.codex/patches/codex-fast-mode"
SIGN_IDENTITY="${CODEX_SIGN_IDENTITY:--}"
ASAR_CLI="${CODEX_ASAR_CLI:-@electron/asar}"
# Shareable patch version:
# - force-fast-ui-v2: force fast UI visibility, remove auth gating,
#   keep native serviceTier request flow, and use the correct ASAR header hash.
PATCH_VERSION="force-fast-ui-v2"
PATCH_SUMMARY="Force fast UI visibility, remove auth gating, keep native serviceTier flow"

MODE="${1:-help}"
ARG2="${2:-}"

usage() {
  cat <<'EOF'
Usage:
  patch_codex_fast_mode.sh apply
  patch_codex_fast_mode.sh restore [backup_dir]
  patch_codex_fast_mode.sh status

Environment overrides:
  CODEX_APP_PATH=/path/to/Codex.app
  CODEX_SIGN_IDENTITY='Developer ID Application: ...'

Notes:
  - patch version: force-fast-ui-v2
  - apply: backup current app.asar + Info.plist, force fast-mode UI availability, remove auth gating, repack, update Electron's ASAR header hash, re-sign.
  - restore: restore app.asar + Info.plist from a backup dir (default: latest backup), then recompute the header hash.
  - status: check ElectronAsarIntegrity header hash match and gate markers.
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
  # Re-sign to avoid macOS signature breakage after resources patch.
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

locate_target_file() {
  local extracted_dir="$1"
  local target_file=""
  local candidate=""

  # Pattern matches any 1-2 letter function name (e.g., Wt, Gt, Dt, etc.)
  local gate_pattern='function [A-Za-z]{1,2}\(e\)\{return e===`chatgpt`\}|function [A-Za-z]{1,2}\(e\)\{return e==="chatgpt"\}|function [A-Za-z]{1,2}\(e\)\{return e==='\''chatgpt'\''\}'
  local fast_mode_check='fast_mode===!0&&[A-Za-z]{1,2}\(t\)'

  if [[ -d "${extracted_dir}/webview/assets" ]]; then
    while IFS= read -r candidate; do
      if rg -q "$gate_pattern|$fast_mode_check" "$candidate"; then
        target_file="$candidate"
        break
      fi
    done < <(rg --files "${extracted_dir}/webview/assets" | rg '/general-settings-.*\.js$' | sort)
  fi

  if [[ -z "$target_file" ]]; then
    target_file="$(rg -l "$gate_pattern|$fast_mode_check" "$extracted_dir" | rg '/general-settings-.*\.js$' | head -n 1 || true)"
  fi

  if [[ -z "$target_file" ]]; then
    target_file="$(rg -l "$gate_pattern|$fast_mode_check" "$extracted_dir" | head -n 1 || true)"
  fi

  printf '%s\n' "$target_file"
}

target_has_original_gate() {
  local file="$1"
  # Match any 1-2 letter function name for auth gate
  rg -q 'function [A-Za-z]{1,2}\(e\)\{return e===`chatgpt`\}|function [A-Za-z]{1,2}\(e\)\{return e==="chatgpt"\}|function [A-Za-z]{1,2}\(e\)\{return e==='\''chatgpt'\''\}|fast_mode===!0&&[A-Za-z]{1,2}\(t\)' "$file"
}

target_has_patched_marker() {
  local file="$1"
  # Match any 1-2 letter function name that has been patched to return true
  rg -q 'function [A-Za-z]{1,2}\(e\)\{return!0\}|fast_mode===!0&&!0' "$file"
}

patch_text_file() {
  local file="$1"

  # Use heredoc to avoid shell escaping issues with backticks and special chars
  perl -0777 -i -pe "$(cat <<'PERL'
    # Primary target: fast mode gating helper - match any 1-2 letter function name
    s/function ([A-Za-z]{1,2})\(e\)\{return e===`chatgpt`\}/function $1(e){return!0}/g;
    s/function ([A-Za-z]{1,2})\(e\)\{return e==="chatgpt"\}/function $1(e){return!0}/g;
    s/function ([A-Za-z]{1,2})\(e\)\{return e==='chatgpt'\}/function $1(e){return!0}/g;

    # Fallback target: inline gating expression
    s/fast_mode===!0&&([A-Za-z]{1,2})\(t\)/fast_mode===!0&&!0/g;
PERL
)" "$file"
}

cmd_apply() {
  require_cmd npx
  require_cmd rg
  require_cmd node
  require_cmd codesign
  check_paths

  local ts backup_dir tmp_dir extracted_dir
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  backup_dir="${PATCH_ROOT}/backup-${ts}"
  tmp_dir="$(mktemp -d -t codex-fastpatch-XXXXXX)"
  extracted_dir="${tmp_dir}/extracted"

  npx --yes "$ASAR_CLI" extract "$ASAR_PATH" "$extracted_dir" >/dev/null

  local target_file
  target_file="$(locate_target_file "$extracted_dir")"
  if [[ -z "$target_file" ]]; then
    echo "Could not locate fast-mode auth gate in extracted bundle." >&2
    rm -rf "$tmp_dir"
    exit 1
  fi

  if target_has_patched_marker "$target_file"; then
    rm -rf "$tmp_dir"
    echo "Patch already applied for version: $PATCH_VERSION"
    return 0
  fi

  mkdir -p "$PATCH_ROOT"
  mkdir -p "$backup_dir"
  cp "$ASAR_PATH" "${backup_dir}/app.asar.original"
  cp "$INFO_PLIST_PATH" "${backup_dir}/Info.plist.original"
  cp "$target_file" "${backup_dir}/target.before.js"
  patch_text_file "$target_file"
  cp "$target_file" "${backup_dir}/target.after.js"

  if ! target_has_patched_marker "$target_file"; then
    echo "Patch pattern not applied; aborting to keep app unchanged." >&2
    rm -rf "$tmp_dir"
    exit 1
  fi

  npx --yes "$ASAR_CLI" pack "$extracted_dir" "${tmp_dir}/app.asar.patched" >/dev/null
  cp "${tmp_dir}/app.asar.patched" "$ASAR_PATH"
  local new_hash
  new_hash="$(current_asar_header_hash)"
  write_plist_asar_hash "$new_hash"
  ad_hoc_resign

  cat > "${backup_dir}/README.txt" <<EOF
Codex fast-mode gate patch record

- Patch version: $PATCH_VERSION
- Patch summary: $PATCH_SUMMARY
- Applied at (UTC): $ts
- App path: $APP_PATH
- Asar path: $ASAR_PATH
- Info.plist path: $INFO_PLIST_PATH
- Signing identity: $SIGN_IDENTITY
- Target JS file inside asar: ${target_file#${extracted_dir}/}
- ElectronAsarIntegrity header hash after patch: $new_hash

Restore:
  cp "${backup_dir}/app.asar.original" "$ASAR_PATH"
  cp "${backup_dir}/Info.plist.original" "$INFO_PLIST_PATH"
  # If Info.plist.original is missing, recompute the hash from app.asar and write it back.
  codesign --force --deep --sign - "$APP_PATH"
EOF

  rm -rf "$tmp_dir"
  echo "Patch applied."
  echo "Backup: $backup_dir"
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

  # Always recompute the header hash so restore still works even if Info.plist.original is missing.
  write_plist_asar_hash "$(current_asar_header_hash)"
  ad_hoc_resign
  echo "Restored from: $backup_dir"
}

cmd_status() {
  require_cmd npx
  require_cmd node
  check_paths

  local tmp_dir extracted_dir target_file plist_hash actual_hash integrity_match
  local has_original has_patched
  has_original=0
  has_patched=0
  tmp_dir="$(mktemp -d -t codex-fastpatch-status-XXXXXX)"
  extracted_dir="${tmp_dir}/extracted"

  npx --yes "$ASAR_CLI" extract "$ASAR_PATH" "$extracted_dir" >/dev/null
  target_file="$(locate_target_file "$extracted_dir")"

  if [[ -n "$target_file" ]]; then
    if target_has_original_gate "$target_file"; then
      has_original=1
    fi
    if target_has_patched_marker "$target_file"; then
      has_patched=1
    fi
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
  echo "PLIST_ASAR_HASH=$plist_hash"
  echo "ACTUAL_ASAR_HEADER_HASH=$actual_hash"
  echo "INTEGRITY_MATCH=$integrity_match"
  echo "TARGET_FILE=${target_file#${extracted_dir}/}"
  echo "HAS_ORIGINAL_GATE=$has_original"
  echo "HAS_PATCH_MARKER=$has_patched"

  rm -rf "$tmp_dir"
}

case "$MODE" in
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
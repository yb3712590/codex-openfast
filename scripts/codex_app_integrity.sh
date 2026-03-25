#!/usr/bin/env bash
set -euo pipefail

# 业务说明：
# 该脚本服务于本机 Codex 桌面端的安全维护，负责备份、完整性校验与恢复。
# 它只处理 Electron ASAR 与 Info.plist 的一致性，不提供任何去鉴权、强开功能或权限绕过能力。

PATH="${PATH}:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin"

APP_PATH="${CODEX_APP_PATH:-/Applications/Codex.app}"
ASAR_PATH="${APP_PATH}/Contents/Resources/app.asar"
INFO_PLIST_PATH="${APP_PATH}/Contents/Info.plist"
BACKUP_ROOT="${CODEX_BACKUP_ROOT:-${HOME}/.codex/backups/codex-app-integrity}"
SIGN_IDENTITY="${CODEX_SIGN_IDENTITY:--}"

MODE="${1:-help}"
ARG2="${2:-}"

# 业务说明：
# 给运维场景提供统一的脚本入口提示，避免误用不存在的模式。
usage() {
  cat <<'EOF'
Usage:
  codex_app_integrity.sh backup
  codex_app_integrity.sh restore [backup_dir]
  codex_app_integrity.sh status

Environment overrides:
  CODEX_APP_PATH=/path/to/Codex.app
  CODEX_SIGN_IDENTITY='Developer ID Application: ...'
  CODEX_BACKUP_ROOT=/path/to/backup-root
EOF
}

# 业务说明：
# 在执行备份、恢复、校验前先确认基础命令存在，避免运行到中途才失败，影响应用维护流程。
require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing command: $cmd" >&2
    exit 1
  fi
}

# 业务说明：
# 统一校验应用包关键路径，确保当前操作针对的确实是一个完整的 Codex 安装。
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

# 业务说明：
# 恢复应用资源后需要重新签名，避免 macOS 因签名失效阻止桌面端启动。
ad_hoc_resign() {
  codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_PATH" >/dev/null
}

# 业务说明：
# 恢复默认使用最新一次备份，减少运维人工翻找目录的成本。
latest_backup_dir() {
  if [[ ! -d "$BACKUP_ROOT" ]]; then
    return 1
  fi
  ls -1dt "$BACKUP_ROOT"/backup-* 2>/dev/null | head -n 1
}

# 业务说明：
# Electron 会校验 app.asar 头部摘要，本方法用于计算真实摘要，作为完整性判断的唯一依据。
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

# 业务说明：
# 从 Info.plist 中读取 Electron 记录的 asar 摘要，用于与真实摘要比对，判断资源是否被合法恢复。
plist_asar_hash() {
  /usr/libexec/PlistBuddy -c 'Print :ElectronAsarIntegrity:Resources/app.asar:hash' "$INFO_PLIST_PATH" 2>/dev/null || true
}

# 业务说明：
# 恢复场景必须同步回写新的摘要，否则 Electron 会把合法恢复后的包也视为损坏。
write_plist_asar_hash() {
  local hash="$1"
  /usr/libexec/PlistBuddy -c "Set :ElectronAsarIntegrity:Resources/app.asar:hash $hash" "$INFO_PLIST_PATH"
}

# 业务说明：
# 生成可追溯的运维备份，确保后续恢复可以精确回到某个时间点的桌面端状态。
cmd_backup() {
  check_paths

  local ts backup_dir
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  backup_dir="${BACKUP_ROOT}/backup-${ts}"
  mkdir -p "$backup_dir"

  cp "$ASAR_PATH" "${backup_dir}/app.asar.original"
  cp "$INFO_PLIST_PATH" "${backup_dir}/Info.plist.original"

  cat > "${backup_dir}/README.txt" <<EOF
Codex app integrity backup

- Created at (UTC): $ts
- App path: $APP_PATH
- Asar path: $ASAR_PATH
- Info.plist path: $INFO_PLIST_PATH
- ElectronAsarIntegrity hash at backup time: $(plist_asar_hash)
- Actual app.asar header hash at backup time: $(current_asar_header_hash)
EOF

  echo "BACKUP_DIR=$backup_dir"
}

# 业务说明：
# 从已知良好的备份恢复桌面端资源，并重建摘要与签名，保证恢复后应用仍可正常启动。
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

  echo "RESTORED_FROM=$backup_dir"
  echo "ACTUAL_ASAR_HEADER_HASH=$(current_asar_header_hash)"
}

# 业务说明：
# 这是日常巡检入口，只读输出当前摘要一致性，帮助判断安装是否完整或是否需要恢复。
cmd_status() {
  require_cmd node
  check_paths

  local plist_hash actual_hash integrity_match
  plist_hash="$(plist_asar_hash)"
  actual_hash="$(current_asar_header_hash)"
  integrity_match=0
  if [[ -n "$plist_hash" && "$plist_hash" == "$actual_hash" ]]; then
    integrity_match=1
  fi

  echo "APP_PATH=$APP_PATH"
  echo "ASAR_PATH=$ASAR_PATH"
  echo "INFO_PLIST_PATH=$INFO_PLIST_PATH"
  echo "PLIST_ASAR_HASH=$plist_hash"
  echo "ACTUAL_ASAR_HEADER_HASH=$actual_hash"
  echo "INTEGRITY_MATCH=$integrity_match"
}

case "$MODE" in
  backup)
    cmd_backup
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

#!/bin/bash
# cc-clean-ghosts.sh — 終了/クラッシュした(プロセスが生きていない)セッションの
# state ファイルを削除する。SwiftBar の「終了済みを掃除」から呼ばれる。

STATE_DIR="$HOME/.claude/cc-notification-center/state"
[ -d "$STATE_DIR" ] || exit 0

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

shopt -s nullglob
for f in "$STATE_DIR"/*.json; do
  pid=$(jq -r '.claude_pid // 0' "$f" 2>/dev/null)
  # PID 不明(0)は判定できないので残す
  [ -z "$pid" ] && continue
  [ "$pid" -eq 0 ] && continue
  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$f"
  fi
done

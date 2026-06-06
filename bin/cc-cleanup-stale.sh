#!/bin/bash
# cc-cleanup-stale.sh — 再起動で消えたセッションの状態ファイルを掃除する。
#
# 「現在の OS 起動時刻(kern.boottime)より前に最終更新された状態ファイル」を削除する。
# 再起動前のセッションは必ず boot より前の更新なので確実に消え、
# 再起動後に始まった新しいセッションには触れない(PID 再利用の誤判定も起きない)。
#
# ログイン時に LaunchAgent から実行される。手動実行も可。

STATE_DIR="$HOME/.claude/cc-notification-center/state"
[ -d "$STATE_DIR" ] || exit 0

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# OS 起動時刻(epoch 秒)。出力例: { sec = 1780360637, usec = 426671 } ...
# usec を誤って拾わないよう、10 桁の epoch 秒を先頭から取る。
BOOT=$(sysctl -n kern.boottime 2>/dev/null | grep -oE '[0-9]{10}' | head -1)
case "$BOOT" in ''|*[!0-9]*) exit 0 ;; esac

shopt -s nullglob
for f in "$STATE_DIR"/*.json; do
  upd=$(jq -r '.updated_at // 0' "$f" 2>/dev/null)
  case "$upd" in ''|*[!0-9]*) upd=0 ;; esac
  if [ "$upd" -lt "$BOOT" ]; then
    rm -f "$f"
  fi
done

# 古い focus-request も掃除(残っていても害は無いが念のため)
rm -f "$HOME/.claude/cc-notification-center/focus-request.json" 2>/dev/null

# seen マーカーは pid 単位。再起動で前回 boot の pid は無意味になるため一掃する。
rm -f "$HOME/.claude/cc-notification-center/seen/"* 2>/dev/null

exit 0

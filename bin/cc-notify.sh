#!/bin/bash
# cc-notify.sh — macOS デスクトップ通知を出す。
#
# cc-record-state.sh から、注意が必要な状態(承認待ち/質問/完了)になった時に呼ばれる。
# terminal-notifier があればクリックで該当ターミナルへジャンプできる通知を、
# 無ければ osascript の通知(クリック動作なし)にフォールバックする。
#
# 使い方:
#   cc-notify.sh <state> <project> <shell_pid> <cwd> <session_id> <message>
#
# 無効化: ~/.claude/cc-notification-center/notify.off を作成すると通知しない。

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

BASE="$HOME/.claude/cc-notification-center"
# オプトアウト
[ -f "$BASE/notify.off" ] && exit 0

STATE="${1:-}"
PROJECT="${2:-(unknown)}"
SHELL_PID="${3:-0}"
CWD="${4:-}"
SID="${5:-}"
MSG="${6:-}"

# 状態 → 絵文字 / ラベル / 既定メッセージ
case "$STATE" in
  needs_permission) EMOJI="🟠"; LABEL="承認待ち";      DEF="ツールの実行許可を待っています" ;;
  needs_input)      EMOJI="🟣"; LABEL="質問";          DEF="確認したいことがあります" ;;
  waiting)          EMOJI="🟢"; LABEL="完了・返信待ち"; DEF="応答が完了しました" ;;
  *)                EMOJI="🔔"; LABEL="通知";          DEF="" ;;
esac

# 表示メッセージ(無ければ既定文)
BODY="$MSG"
[ -z "$BODY" ] && BODY="$DEF"

TITLE="$EMOJI $PROJECT"

# クリック時にジャンプさせるコマンド(該当ターミナル/ウィンドウを前面化)
REPO="$(cd "$(dirname "$0")/.." && pwd)"
FOCUS="$REPO/bin/cc-focus-session.sh"
EXEC="bash '$FOCUS' '${SHELL_PID}@@${CWD}'"

# 状態色の自前アイコンを通知の右側に表示(-contentImage)。
# ※ 最近の macOS では左のアプリアイコン(-appIcon/-sender)は差し替え不可のため、
#    右側の contentImage で状態色を示す。クリック→ジャンプは維持される。
ICON="$REPO/assets/notify/${STATE}.png"
ICON_ARGS=()
[ -f "$ICON" ] && ICON_ARGS=(-contentImage "file://$ICON")

if command -v terminal-notifier >/dev/null 2>&1; then
  terminal-notifier \
    -title "$TITLE" \
    -subtitle "$LABEL" \
    -message "$BODY" \
    -group "ccnc-${SID}" \
    "${ICON_ARGS[@]}" \
    -execute "$EXEC" \
    -sound default >/dev/null 2>&1
else
  # フォールバック(クリック動作なし)。文字列内の " を無害化。
  safe() { printf '%s' "$1" | sed 's/"/\\"/g'; }
  osascript -e "display notification \"$(safe "$BODY")\" with title \"$(safe "$TITLE")\" subtitle \"$(safe "$LABEL")\" sound name \"default\"" >/dev/null 2>&1
fi

exit 0

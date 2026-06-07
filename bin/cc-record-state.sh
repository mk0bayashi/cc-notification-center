#!/bin/bash
# cc-record-state.sh — Claude Code セッションの状態を記録する hook スクリプト
#
# 各 hook イベント(SessionStart / UserPromptSubmit / PostToolUse /
# Notification / Stop / SessionEnd)から呼ばれ、stdin の JSON を解釈して
# ~/.claude/cc-notification-center/state/<session_id>.json を更新する。
#
# 使い方(settings.json の hook command):
#   bash <repo>/bin/cc-record-state.sh <EventName>
#
# 第1引数の EventName は信頼できる状態ソース(payload の hook_event_name が
# 欠ける場合に備える)。なければ payload の hook_event_name を使う。

set -u

STATE_DIR="$HOME/.claude/cc-notification-center/state"
SEEN_DIR="$HOME/.claude/cc-notification-center/seen"
mkdir -p "$STATE_DIR" "$SEEN_DIR" 2>/dev/null

# 通知スクリプト(このスクリプトと同じ bin/ にある)
NOTIFY="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/cc-notify.sh"

# jq が PATH に無い環境(GUI 起動等)でも動くよう保険
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

ARG_EVENT="${1:-}"

SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
[ -z "$SID" ] && exit 0

CWD=$(printf '%s' "$INPUT"     | jq -r '.cwd // empty' 2>/dev/null)
HOOK_EVENT=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)
NTYPE=$(printf '%s' "$INPUT"   | jq -r '.notification_type // empty' 2>/dev/null)
PMODE=$(printf '%s' "$INPUT"   | jq -r '.permission_mode // empty' 2>/dev/null)
MSG=$(printf '%s' "$INPUT"     | jq -r '.last_assistant_message // empty' 2>/dev/null | tr '\n' ' ' | cut -c1-200)
BG=$(printf '%s' "$INPUT"      | jq -r '(.background_tasks // []) | length' 2>/dev/null)
[ -z "$BG" ] && BG=0

EV="${ARG_EVENT:-$HOOK_EVENT}"
PROJECT=$(basename "${CWD:-unknown}" 2>/dev/null)

# --- イベント → 状態 の対応づけ ------------------------------------------
case "$EV" in
  SessionStart)              STATE="ready" ;;
  UserPromptSubmit)          STATE="working" ;;
  PreToolUse|PostToolUse)    STATE="working" ;;
  Notification)
    case "$NTYPE" in
      permission_prompt)     STATE="needs_permission" ;;
      elicitation_dialog)    STATE="needs_input" ;;
      idle_prompt)           STATE="idle" ;;
      *)                     STATE="notify" ;;
    esac ;;
  Stop)                      STATE="waiting" ;;
  SessionEnd)                STATE="ended" ;;
  *)                         STATE="unknown" ;;
esac

# --- 在処(ありか)の特定材料を集める --------------------------------------
# このセッションの claude プロセス PID(生存確認用)。
# hook の親をたどり、claude / node の祖先を探す。
find_claude_pid() {
  local pid=$PPID
  local i comm
  for i in 1 2 3 4 5 6 7 8; do
    { [ -z "$pid" ] || [ "$pid" -le 1 ]; } && break
    comm=$(ps -o comm= -p "$pid" 2>/dev/null)
    case "$comm" in
      *claude*|*node*) echo "$pid"; return ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  done
}
CLAUDE_PID=$(find_claude_pid)
[ -z "$CLAUDE_PID" ] && CLAUDE_PID=0

# claude の親 = VSCode 統合ターミナルが起動したシェル。
# これは VSCode 拡張側の terminal.processId と一致するので、
# ウィンドウ/タブ特定の決め手になる。
SHELL_PID=0
if [ "$CLAUDE_PID" -gt 0 ]; then
  SHELL_PID=$(ps -o ppid= -p "$CLAUDE_PID" 2>/dev/null | tr -d ' ')
fi
[ -z "$SHELL_PID" ] && SHELL_PID=0

# 完了(Stop)/終了(SessionEnd)時は seen マーカーを消す。
# Stop = 新しい完了 → 「まだ見ていない(返信待ち)」状態にリセットする。
if [ "$SHELL_PID" -gt 0 ] 2>/dev/null; then
  case "$EV" in
    Stop|SessionEnd) rm -f "$SEEN_DIR/$SHELL_PID" 2>/dev/null ;;
  esac
fi

# 制御端末(どのターミナルか)。hook 自身の stdout は pipe なので、
# claude プロセスの制御端末を見るのが正しい(複数ターミナルの区別に使う)。
TTY=""
if [ "$CLAUDE_PID" -gt 0 ]; then
  TTY=$(ps -o tty= -p "$CLAUDE_PID" 2>/dev/null | tr -d ' ')
fi
[ -z "$TTY" ] && TTY=$(ps -o tty= -p $$ 2>/dev/null | tr -d ' ')
[ "$TTY" = "??" ] && TTY=""

NOW=$(date +%s)
ISO=$(date "+%Y-%m-%d %H:%M:%S")

# SessionEnd は痕跡を残さず削除(クラッシュ時は PID 生存確認側で処理)
if [ "$EV" = "SessionEnd" ]; then
  rm -f "$STATE_DIR/$SID.json" 2>/dev/null
  exit 0
fi

TMP="$STATE_DIR/.$SID.$$.tmp"
jq -n \
  --arg sid "$SID" \
  --arg cwd "$CWD" \
  --arg project "$PROJECT" \
  --arg state "$STATE" \
  --arg event "$EV" \
  --arg ntype "$NTYPE" \
  --arg msg "$MSG" \
  --arg tty "$TTY" \
  --arg pmode "$PMODE" \
  --argjson bg "${BG:-0}" \
  --argjson claude_pid "${CLAUDE_PID:-0}" \
  --argjson shell_pid "${SHELL_PID:-0}" \
  --argjson now "$NOW" \
  --arg iso "$ISO" \
  '{
     session_id: $sid,
     cwd: $cwd,
     project: $project,
     state: $state,
     event: $event,
     notification_type: $ntype,
     message: $msg,
     tty: $tty,
     permission_mode: $pmode,
     bg_tasks: $bg,
     claude_pid: $claude_pid,
     shell_pid: $shell_pid,
     updated_at: $now,
     updated_iso: $iso
   }' > "$TMP" 2>/dev/null && mv -f "$TMP" "$STATE_DIR/$SID.json" 2>/dev/null

# --- macOS 通知 ----------------------------------------------------------
# 注意が必要な状態になった瞬間だけ通知(各イベントは1回限りなのでスパムにならない)。
# Stop→waiting / permission_prompt→needs_permission / elicitation_dialog→needs_input。
case "$STATE" in
  needs_permission|needs_input|waiting)
    [ -x "$NOTIFY" ] && bash "$NOTIFY" "$STATE" "$PROJECT" "$SHELL_PID" "$CWD" "$SID" "$MSG" >/dev/null 2>&1 &
    ;;
esac

exit 0

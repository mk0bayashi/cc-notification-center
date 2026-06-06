#!/bin/bash
# cc-focus-session.sh — メニューバーのクリックから呼ばれ、
# VSCode 拡張(cc-session-focus)へ「このセッションのターミナルを前面化せよ」
# という要求を focus-request.json として書き出す。
#
# SwiftBar の param 番号付け(0始まり/1始まり)に依存しないよう、
# 「最後の引数」に "shellPid@@cwd" をまとめて渡す方式にしている。

DIR="$HOME/.claude/cc-notification-center"
mkdir -p "$DIR"

ARG="${@: -1}"
SHELL_PID="${ARG%%@@*}"
CWD="${ARG#*@@}"

# 数値でなければ 0
case "$SHELL_PID" in
  ''|*[!0-9]*) SHELL_PID=0 ;;
esac

# requestId(毎回ユニーク)。nanosecond + pid
RID="$(date +%s)-$(date +%N 2>/dev/null || echo 0)-$$"

# JSON を安全に生成(cwd の特殊文字対策に jq があれば使う)
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
TMP="$DIR/.focus-request.$$.tmp"
if command -v jq >/dev/null 2>&1; then
  jq -n --arg rid "$RID" --argjson sp "${SHELL_PID:-0}" --arg cwd "$CWD" \
    '{requestId:$rid, shellPid:$sp, cwd:$cwd}' > "$TMP"
else
  printf '{"requestId":"%s","shellPid":%s,"cwd":"%s"}\n' "$RID" "${SHELL_PID:-0}" "$CWD" > "$TMP"
fi
mv -f "$TMP" "$DIR/focus-request.json"

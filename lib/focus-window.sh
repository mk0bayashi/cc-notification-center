#!/bin/bash
# focus-window.sh — Claude セッションの cwd に対応する VSCode ウィンドウを前面化する
#
# VSCode のウィンドウタイトルは "<ファイル名> — <ルートフォルダ名>" 形式。
# セッションの cwd はルートフォルダのサブフォルダのこともあるため、
# cwd の「各階層名」を深い方から順にウィンドウタイトルと照合し、
# 最初に一致したウィンドウを AXRaise する。
#
# 使い方:
#   focus-window.sh <cwd-path>        例: /Users/me/projects/my-app/server
#   focus-window.sh <project-name>    後方互換(スラッシュ無しなら単一候補として扱う)
#
# SwiftBar から param0/param1 のどちらで渡っても動くよう、最後の引数を採用する。

ARG="${@: -1}"
LOG="$HOME/.claude/cc-notification-center/focus.log"

if [ -z "$ARG" ]; then
  echo "usage: focus-window.sh <cwd-path|project-name>" >&2
  exit 1
fi

# cwd の各階層を深い順に候補化(汎用的すぎる名前は除外)
build_candidates() {
  local p="$1"
  # スラッシュが無ければそのまま単一候補
  case "$p" in
    */*) : ;;
    *) printf '%s\n' "$p"; return ;;
  esac
  local IFS='/'
  local parts=() seg
  for seg in $p; do
    [ -n "$seg" ] && parts+=("$seg")
  done
  # 深い順に出力。Users / ホーム名 など汎用語は除外
  local i name
  for (( i=${#parts[@]}-1; i>=0; i-- )); do
    name="${parts[$i]}"
    case "$name" in
      Users|home|var|tmp|opt|usr|"$(id -un)") continue ;;
    esac
    # 1文字の階層はノイズになりやすいので除外
    [ ${#name} -le 1 ] && continue
    printf '%s\n' "$name"
  done
}

CANDIDATES=$(build_candidates "$ARG")

# AppleScript に候補リストを渡し、最初に一致したウィンドウを前面化
MATCHED=$(osascript <<EOF 2>>"$LOG"
set candidateText to "$(printf '%s' "$CANDIDATES" | tr '\n' '|')"
set AppleScript's text item delimiters to "|"
set candidateList to text items of candidateText
set AppleScript's text item delimiters to ""

tell application "System Events"
  if not (exists (process "Code")) then return "NO_CODE"
  tell process "Code"
    repeat with cand in candidateList
      if (cand as string) is not "" then
        repeat with w in windows
          if name of w contains (cand as string) then
            perform action "AXRaise" of w
            return "MATCH:" & (cand as string) & ":" & (name of w)
          end if
        end repeat
      end if
    end repeat
  end tell
  return "NO_MATCH"
end tell
EOF
)

# VSCode をアクティブ化(一致しなくても最低限アプリは前面に)
osascript -e 'tell application "Visual Studio Code" to activate' 2>>"$LOG"

# 記録(デバッグ用)
printf '%s  arg=%s  -> %s\n' "$(date '+%H:%M:%S')" "$ARG" "$MATCHED" >> "$LOG"

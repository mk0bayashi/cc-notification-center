#!/bin/bash
# install.sh — cc-notification-center の一括セットアップ
#
#   1. 状態ディレクトリ作成
#   2. SwiftBar を導入(未導入なら brew install)
#   3. SwiftBar のプラグインフォルダを設定し、プラグインを symlink
#   4. ~/.claude/settings.json に状態記録 hook を追記(バックアップ付)
#   5. SwiftBar を起動
#
# 何度実行しても安全(冪等)。

set -e

REPO="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="$HOME/.claude/cc-notification-center/state"
PLUGIN_DIR="$HOME/.swiftbar-plugins"
PLUGIN_SRC="$REPO/plugin/cc-sessions.3s.sh"
PLUGIN_LINK="$PLUGIN_DIR/cc-sessions.3s.sh"

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

echo "▶ cc-notification-center セットアップ"
echo "  REPO: $REPO"

# --- 0. 実行権限 ---------------------------------------------------------
chmod +x "$REPO"/bin/*.sh "$REPO"/lib/*.sh "$REPO"/plugin/*.sh "$REPO"/plugin/*.js 2>/dev/null || true

# --- 1. 状態ディレクトリ -------------------------------------------------
mkdir -p "$STATE_DIR"
echo "✓ 状態ディレクトリ: $STATE_DIR"

# --- 1.5 jq(状態記録スクリプトが利用) ----------------------------------
if ! command -v jq >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    echo "▶ jq を導入します (brew install jq)…"
    brew install jq
  else
    echo "✗ jq が見つかりません。Homebrew で導入してください: brew install jq" >&2
    exit 1
  fi
else
  echo "✓ jq は導入済み"
fi

# --- 1.6 terminal-notifier(任意: クリックでジャンプできる通知) ----------
if ! command -v terminal-notifier >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    echo "▶ terminal-notifier を導入します (brew install terminal-notifier)…"
    brew install terminal-notifier || echo "△ terminal-notifier 導入失敗(osascript にフォールバックします)"
  else
    echo "△ terminal-notifier 未導入(osascript 通知にフォールバックします)"
  fi
else
  echo "✓ terminal-notifier は導入済み"
fi

# --- 2. SwiftBar -------------------------------------------------------
if [ ! -d "/Applications/SwiftBar.app" ] && ! ls -d "$HOME/Applications/SwiftBar.app" >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    echo "▶ SwiftBar を導入します (brew install --cask swiftbar)…"
    brew install --cask swiftbar
  else
    echo "✗ Homebrew が見つかりません。SwiftBar を手動で導入してください: https://swiftbar.app" >&2
    exit 1
  fi
else
  echo "✓ SwiftBar は導入済み"
fi

# --- 3. プラグインフォルダ & symlink ------------------------------------
mkdir -p "$PLUGIN_DIR"
ln -sf "$PLUGIN_SRC" "$PLUGIN_LINK"
echo "✓ プラグイン配置: $PLUGIN_LINK -> $PLUGIN_SRC"

# SwiftBar にプラグインフォルダを設定(初回のフォルダ選択ダイアログを回避)
defaults write com.ameba.SwiftBar PluginDirectory "$PLUGIN_DIR" 2>/dev/null || true

# --- 3.5 VSCode 拡張(正確なターミナル/ウィンドウ ジャンプ用) -----------
EXT_LINK="$HOME/.vscode/extensions/local.cc-session-focus-0.1.0"
if [ -d "$HOME/.vscode/extensions" ]; then
  ln -sfn "$REPO/vscode-extension" "$EXT_LINK"
  echo "✓ VSCode 拡張を配置: $EXT_LINK"
  echo "  ※ 反映には VSCode の再起動(または各ウィンドウで Developer: Reload Window)が必要です"
else
  echo "△ ~/.vscode/extensions が無いため VSCode 拡張はスキップ(VSCode 未導入?)"
fi

# --- 4. settings.json に hook 追記 --------------------------------------
echo "▶ settings.json に状態記録 hook を追記…"
node "$REPO/install/patch-settings.js"

# --- 5. ログイン時の自動起動 & 状態クリーンアップ -----------------------
# SwiftBar をログイン項目に登録(再起動後もメニューバーが自動復活)
if ! osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null | tr ',' '\n' | grep -qi swiftbar; then
  osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/SwiftBar.app", hidden:false}' >/dev/null 2>&1 \
    && echo "✓ SwiftBar をログイン項目に登録" || true
else
  echo "✓ SwiftBar は既にログイン項目"
fi

# ログイン時に「再起動で消えたセッション」の状態ファイルを掃除する LaunchAgent
PLIST="$HOME/Library/LaunchAgents/com.cc-notification-center.cleanup.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.cc-notification-center.cleanup</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${REPO}/bin/cc-cleanup-stale.sh</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
PL
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST" 2>/dev/null && echo "✓ ログイン時クリーンアップを登録" || true

# --- 6. SwiftBar 起動 / 再読み込み --------------------------------------
echo "▶ SwiftBar を起動…"
open -a SwiftBar 2>/dev/null || true
# 既に起動中ならプラグイン再読み込みを要求
open "swiftbar://refreshallplugins" 2>/dev/null || true

cat <<'DONE'

✅ 完了しました。

  • メニューバーに状態アイコン(SF Symbols)が表示されます。
  • 既存の Claude Code セッションは、次に何か操作(プロンプト送信・完了・承認待ち等)
    した時点で一覧に出てきます。新しいセッションは SessionStart で即出ます。
  • アイコンをクリック → セッション一覧 → 行をクリックで該当ターミナル/ウィンドウへジャンプ。
  • Mac 再起動後も SwiftBar は自動起動し、前回のセッションは自動で掃除されます。
  • VSCode 拡張は各ウィンドウで一度 "Developer: Reload Window" すると有効化されます
    (再起動後に開いたウィンドウは自動で有効)。

アンインストール:
  node <repo>/install/patch-settings.js --remove        # hook を除去
  rm ~/.swiftbar-plugins/cc-sessions.3s.sh              # プラグイン削除
  rm ~/.vscode/extensions/local.cc-session-focus-0.1.0  # VSCode 拡張削除
  launchctl unload ~/Library/LaunchAgents/com.cc-notification-center.cleanup.plist
  rm ~/Library/LaunchAgents/com.cc-notification-center.cleanup.plist
  # SwiftBar をログイン項目から外す: システム設定 > 一般 > ログイン項目
DONE

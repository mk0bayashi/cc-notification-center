#!/bin/bash
# cc-sessions.3s.sh — SwiftBar プラグイン本体(ラッパー)
#
# SwiftBar はファイル名の ".3s." を更新間隔(3秒)として読む。
# このラッパーは (1) 自身の実体パスからリポジトリを特定し、
# (2) node を探して、(3) 表示ロジック cc-render.js を実行する。
# node の場所は環境により異なる(Homebrew arm/intel, nvm 等)ため動的に探索する。

# --- 自身の実体パス(symlink 経由でも解決) → リポジトリ/plugin を特定 ---
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
done
PLUGIN_DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"
RENDER="$PLUGIN_DIR/cc-render.js"

# --- node を探す ---------------------------------------------------------
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.volta/bin:$PATH"
NODE="$(command -v node 2>/dev/null)"
if [ -z "$NODE" ]; then
  for c in /opt/homebrew/bin/node /usr/local/bin/node \
           "$HOME"/.nvm/versions/node/*/bin/node \
           "$HOME"/.volta/bin/node /usr/bin/node; do
    [ -x "$c" ] && { NODE="$c"; break; }
  done
fi

if [ -z "$NODE" ]; then
  echo ":exclamationmark.triangle: node なし | sfcolor=red"
  echo "---"
  echo "node が見つかりません。Node.js を導入してください。"
  exit 0
fi

exec "$NODE" "$RENDER"

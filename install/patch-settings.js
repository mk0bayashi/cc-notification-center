#!/usr/bin/env node
/*
 * patch-settings.js — ~/.claude/settings.json に cc-notification-center の
 * 状態記録 hook を冪等(べきとう)に追記する。
 *
 *  - 既存の hook は一切変更しない(自分のエントリを追加するだけ)
 *  - 実行のたびにタイムスタンプ付きバックアップを作成
 *  - 既に追加済み(command に cc-record-state.sh を含む)ならスキップ
 *
 * 使い方:  node patch-settings.js          # 追記
 *          node patch-settings.js --remove # 自分の hook を除去
 */

const fs = require('fs');
const path = require('path');
const os = require('os');

const REPO = path.resolve(__dirname, '..');
const RECORDER = path.join(REPO, 'bin', 'cc-record-state.sh');
const SETTINGS = path.join(os.homedir(), '.claude', 'settings.json');
const MARKER = 'cc-record-state.sh';

// どのイベントでどの引数を渡して記録するか
const EVENTS = [
  'SessionStart',
  'UserPromptSubmit',
  'PostToolUse',
  'Notification',
  'Stop',
  'SessionEnd',
];

const remove = process.argv.includes('--remove');

if (!fs.existsSync(SETTINGS)) {
  console.error(`settings.json が見つかりません: ${SETTINGS}`);
  process.exit(1);
}

const raw = fs.readFileSync(SETTINGS, 'utf8');
let cfg;
try { cfg = JSON.parse(raw); }
catch (e) { console.error('settings.json の JSON 解析に失敗:', e.message); process.exit(1); }

// バックアップ
const ts = new Date().toISOString().replace(/[:.]/g, '-');
const bak = `${SETTINGS}.bak.${ts}`;
fs.writeFileSync(bak, raw);
console.log(`バックアップ: ${bak}`);

cfg.hooks = cfg.hooks || {};

function entryHasMarker(entry) {
  return (entry.hooks || []).some(h => typeof h.command === 'string' && h.command.includes(MARKER));
}

let added = 0, removed = 0;

for (const ev of EVENTS) {
  const list = Array.isArray(cfg.hooks[ev]) ? cfg.hooks[ev] : [];

  if (remove) {
    const before = list.length;
    cfg.hooks[ev] = list.filter(e => !entryHasMarker(e));
    removed += before - cfg.hooks[ev].length;
    if (cfg.hooks[ev].length === 0) delete cfg.hooks[ev];
    continue;
  }

  // 既に追加済みならスキップ
  if (list.some(entryHasMarker)) {
    cfg.hooks[ev] = list;
    continue;
  }

  list.push({
    matcher: '',
    hooks: [{ type: 'command', command: `bash "${RECORDER}" ${ev}` }],
  });
  cfg.hooks[ev] = list;
  added++;
}

fs.writeFileSync(SETTINGS, JSON.stringify(cfg, null, 2) + '\n');

if (remove) {
  console.log(`除去した hook エントリ: ${removed} 件`);
} else {
  console.log(`追加した hook イベント: ${added} 件 (既存はスキップ)`);
  console.log(`記録スクリプト: ${RECORDER}`);
}

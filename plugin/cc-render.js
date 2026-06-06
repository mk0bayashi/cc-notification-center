#!/usr/bin/env node
/*
 * cc-render.js — SwiftBar プラグインの描画ロジック
 *                 (ラッパー cc-sessions.3s.sh から node で起動される)
 *
 * ~/.claude/cc-notification-center/state/*.json を読み、
 *   - メニューバーアイコン: 最も注意が必要な状態を色で表示
 *   - ドロップダウン: 全セッションを状態順に一覧、クリックで該当VSCodeを前面化
 * を出力する。SwiftBar が数秒ごとに再実行して表示を更新する。
 */

const fs = require('fs');
const path = require('path');
const os = require('os');

const HOME = os.homedir();
const STATE_DIR = path.join(HOME, '.claude', 'cc-notification-center', 'state');
const SEEN_DIR = path.join(HOME, '.claude', 'cc-notification-center', 'seen');
// リポジトリ位置はこのファイルの実体パスから解決(symlink 経由でも Node が realpath 解決)
const REPO = path.resolve(__dirname, '..');
const FOCUS = path.join(REPO, 'bin', 'cc-focus-session.sh');
const CLEAN = path.join(REPO, 'bin', 'cc-clean-ghosts.sh');

// 状態の表示メタ情報(pri が高いほど注目度が高い)
// sym = SF Symbol 名(ピクトグラム), color = sfcolor(HEX)
// dot = メニューバー用カラー絵文字(メニューバーは SF Symbol を単色描画するため確実に色が出る絵文字を使う)
// sym/color = ドロップダウン用 SF Symbol(ピクトグラム)とその色
const META = {
  needs_permission: { dot: '🟠', sym: 'hand.raised.fill',            color: '#FF9F0A', label: '承認待ち',      short: '承認待ち', pri: 5, attention: true },
  needs_input:      { dot: '🟣', sym: 'questionmark.circle.fill',    color: '#BF5AF2', label: '入力待ち(質問)', short: '質問',     pri: 4, attention: true },
  waiting:          { dot: '🟢', sym: 'checkmark.circle.fill',       color: '#30D158', label: '完了・返信待ち', short: '返信待ち', pri: 3, attention: true },
  notify:           { dot: '🔔', sym: 'bell.fill',                   color: '#FF9F0A', label: '通知',          short: '通知',     pri: 3, attention: true },
  idle:             { dot: '⚪', sym: 'moon.zzz.fill',               color: '#8E8E93', label: '待機中(放置)',   short: '待機',     pri: 2, attention: false },
  working:          { dot: '🔵', sym: 'arrow.triangle.2.circlepath', color: '#0A84FF', label: '処理中…',        short: '処理中',   pri: 1, attention: false },
  ready:            { dot: '⚪', sym: 'circle',                       color: '#8E8E93', label: '準備完了',       short: '準備OK',   pri: 0, attention: false },
  unknown:          { dot: '⚫', sym: 'questionmark',                color: '#8E8E93', label: '不明',          short: '不明',     pri: -1, attention: false },
};
const BASE_DOT = '⚪';        // 稼働中だが静観 / セッション無しのときの中立ドット
const BASE_SYM = 'terminal';

function meta(state) { return META[state] || META.unknown; }

// SwiftBar の区切り文字 "|" と改行を無害化
function san(s) {
  return String(s == null ? '' : s).replace(/\|/g, '¦').replace(/[\r\n]+/g, ' ').trim();
}

function ageStr(sec) {
  if (sec < 0) sec = 0;
  if (sec < 60) return `${sec}s`;
  if (sec < 3600) return `${Math.floor(sec / 60)}m`;
  if (sec < 86400) return `${Math.floor(sec / 3600)}h`;
  return `${Math.floor(sec / 86400)}d`;
}

function alive(pid) {
  if (!pid || pid <= 0) return true; // PID 不明なら生存扱い(誤って隠さない)
  try { process.kill(pid, 0); return true; }
  catch (e) { return e.code === 'EPERM'; } // EPERM=存在するが別権限 / ESRCH=不在
}

// 実効状態: 完了系(waiting/idle)は「該当ウィンドウを見たか(seen マーカー)」で振り分ける。
//  - seen あり → idle(待機中)   - seen なし → waiting(返信待ち)
// これにより idle_prompt のタイマーではなく「見たか」で切り替わる。
function effectiveState(s) {
  const st = s.state;
  if (st !== 'waiting' && st !== 'idle') return st;       // 完了系以外はそのまま
  if (!s.shell_pid || s.shell_pid <= 0) return st;        // shell_pid 不明 → 従来挙動にフォールバック
  try {
    if (fs.existsSync(path.join(SEEN_DIR, String(s.shell_pid)))) return 'idle';
  } catch (_) {}
  return 'waiting';
}

// --- 読み込み ------------------------------------------------------------
let sessions = [];
try {
  const files = fs.readdirSync(STATE_DIR).filter(f => f.endsWith('.json'));
  const now = Math.floor(Date.now() / 1000);
  for (const f of files) {
    try {
      const s = JSON.parse(fs.readFileSync(path.join(STATE_DIR, f), 'utf8'));
      s._age = now - (s.updated_at || now);
      s._alive = alive(s.claude_pid);
      s._effState = effectiveState(s);
      s._meta = meta(s._effState);
      sessions.push(s);
    } catch (_) { /* 壊れたファイルは無視 */ }
  }
} catch (_) { /* state ディレクトリ未作成 */ }

const live = sessions.filter(s => s._alive);
const dead = sessions.filter(s => !s._alive);

// 状態順 → 古い順(放置が長いほど上)にソート
const sortFn = (a, b) => (b._meta.pri - a._meta.pri) || (b._age - a._age);
live.sort(sortFn);
dead.sort((a, b) => b._age - a._age);

// --- メニューバーのアイコン ----------------------------------------------
// メニューバーは SF Symbol を単色(テンプレート)描画するため色が出ない。
// 確実に色を出すためカラー絵文字ドットを使う(状態色)。件数/ラベルも併記。
const attention = live.filter(s => s._meta.attention);
const working = live.filter(s => s.state === 'working');

const out = [];
let barDot, barText, barColor;
if (attention.length > 0) {
  const top = attention[0]._meta;           // pri 降順済み
  barDot = top.dot;
  barColor = top.color;
  barText = attention.length > 1 ? `${top.short} ${attention.length}` : top.short;
} else if (working.length > 0) {
  barDot = META.working.dot;
  barColor = META.working.color;
  barText = working.length > 1 ? `${META.working.short} ${working.length}` : META.working.short;
} else if (live.length > 0) {
  barDot = BASE_DOT;
  barColor = '#8E8E93';
  barText = '待機';
} else {
  barDot = BASE_DOT;
  barColor = '#8E8E93';
  barText = 'CC';
}
out.push(`${barDot} ${barText} | color=${barColor} size=13`);
out.push('---');

// --- ヘッダ --------------------------------------------------------------
out.push(`Claude Code セッション: ${live.length} | size=12 color=#888888`);
out.push('---');

// --- 稼働中セッション一覧 ------------------------------------------------
if (live.length === 0) {
  out.push('稼働中のセッションはありません | color=#888888');
}
for (const s of live) {
  const m = s._meta;
  const proj = san(s.project || '(unknown)');
  const age = ageStr(s._age);
  const bg = s.bg_tasks > 0 ? `  ⚙ ${s.bg_tasks}` : '';
  const cwd = san(s.cwd || proj);
  // shellPid と cwd を 1 つの引数にまとめて渡す(SwiftBar の param 番号差異を吸収)
  const arg = `${s.shell_pid || 0}@@${cwd}`;
  // メイン行: 行頭に状態カラードット + 文字も状態色。クリックで前面化
  out.push(
    `${m.dot} ${proj} — ${m.label}  ·${age}${bg} | ` +
    `color=${m.color} ` +
    `bash="${FOCUS}" param0="${arg}" param1="${arg}" terminal=false refresh=false`
  );
  // サブメニュー: 詳細
  const detail = [];
  if (s.message) detail.push(san(s.message).slice(0, 120));
  detail.push(`mode: ${san(s.permission_mode) || '-'} / tty: ${san(s.tty) || '-'}`);
  detail.push(`path: ${san(s.cwd)}`);
  detail.push(`更新: ${san(s.updated_iso)} (${age} 前)`);
  for (const d of detail) out.push(`--${d} | size=11 color=#999999`);
  out.push(`--↪ このターミナルへ移動 | bash="${FOCUS}" param0="${arg}" param1="${arg}" terminal=false refresh=false`);
}

// --- 終了/不明(ゴースト) -------------------------------------------------
if (dead.length > 0) {
  out.push('---');
  out.push(`⚫ 終了/不明: ${dead.length} | color=#888888`);
  for (const s of dead) {
    out.push(`--${san(s.project)} — ${s._meta.label}  ·${ageStr(s._age)} 前 | color=#999999`);
  }
}

// --- 凡例(各状態のピクトグラムを実物で確認できる) -----------------------
out.push('---');
out.push('凡例 | size=11 color=#888888');
for (const st of ['needs_permission', 'needs_input', 'waiting', 'working', 'idle', 'ready']) {
  const m = META[st];
  out.push(`--${m.dot} ${m.label} | color=${m.color} size=12`);
}

// --- フッタ --------------------------------------------------------------
out.push('---');
out.push('🔄 今すぐ更新 | refresh=true');
if (dead.length > 0) {
  out.push(`🧹 終了済みを掃除 (${dead.length}) | bash="${CLEAN}" terminal=false refresh=true`);
}

process.stdout.write(out.join('\n') + '\n');

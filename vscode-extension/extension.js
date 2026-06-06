// cc-session-focus — cc-notification-center 用 VSCode 拡張
//
// 仕組み:
//   メニューバー(SwiftBar)のセッション行をクリックすると helper が
//   ~/.claude/cc-notification-center/focus-request.json を書き換える。
//   この拡張は全 VSCode ウィンドウで起動し、そのファイルを監視する。
//   要求に含まれる shell_pid(= VSCode の terminal.processId)に一致する
//   ターミナルを「持っているウィンドウ」だけが反応し:
//     1) そのターミナルタブをフォーカス (terminal.show)
//     2) 自ウィンドウを OS 前面化 (`code <folder>` トリック)
//   を行う。terminals API はウィンドウ毎なので、この「全ウィンドウで監視し、
//   持ち主だけが動く」方式が複数ウィンドウ/マルチルート/別Spaceでも確実。

const vscode = require('vscode');
const fs = require('fs');
const path = require('path');
const os = require('os');
const cp = require('child_process');

const DIR = path.join(os.homedir(), '.claude', 'cc-notification-center');
const REQ = path.join(DIR, 'focus-request.json');
const LOG = path.join(DIR, 'extension.log');
const SEEN_DIR = path.join(DIR, 'seen'); // seen/<shell_pid> = そのターミナルを見た印

let lastHandled = '';
let busy = false;

function log(msg) {
  try { fs.appendFileSync(LOG, `${new Date().toISOString()} [${process.pid}] ${msg}\n`); } catch (_) {}
}

function activate(context) {
  try { fs.mkdirSync(DIR, { recursive: true }); } catch (_) {}
  try { fs.mkdirSync(SEEN_DIR, { recursive: true }); } catch (_) {}
  log('activated');

  // ディレクトリを監視(ファイルが無い状態からの作成も拾える)
  let watcher;
  try {
    watcher = fs.watch(DIR, (event, filename) => {
      if (!filename || filename === 'focus-request.json') {
        handleRequest().catch(e => log('handle error: ' + e));
      }
    });
    context.subscriptions.push({ dispose: () => { try { watcher.close(); } catch (_) {} } });
  } catch (e) {
    log('watch error: ' + e);
  }

  // --- seen マーカー: フォーカス中のアクティブターミナルを「見た」と記録 ---
  // 完了(返信待ち)のセッションは、該当ターミナルを見るまで返信待ちのまま。
  // 見た時点で seen/<shell_pid> を作り、表示側が待機中へ降格する。
  context.subscriptions.push(
    vscode.window.onDidChangeWindowState((e) => { if (e.focused) markSeen(); }),
    vscode.window.onDidChangeActiveTerminal(() => markSeen())
  );
  // フォーカス中は定期的に再記録(完了時すでに注視しているケースも数秒で待機中へ)
  const seenTimer = setInterval(() => {
    if (vscode.window.state.focused) markSeen();
  }, 10000);
  context.subscriptions.push({ dispose: () => clearInterval(seenTimer) });

  // 起動直後にも一度チェック
  handleRequest().catch(e => log('initial handle error: ' + e));
  markSeen();
}

// フォーカス中のアクティブターミナルの processId(=shell_pid) を seen として記録
async function markSeen() {
  try {
    if (!vscode.window.state.focused) return;
    const term = vscode.window.activeTerminal;
    if (!term) return;
    const pid = await term.processId;
    if (!pid) return;
    fs.writeFile(path.join(SEEN_DIR, String(pid)), '', () => {});
  } catch (_) { /* noop */ }
}

async function handleRequest() {
  if (busy) return;
  let req;
  try {
    req = JSON.parse(fs.readFileSync(REQ, 'utf8'));
  } catch (_) { return; }
  if (!req || !req.requestId || req.requestId === lastHandled) return;

  busy = true;
  try {
    const term = await findTerminal(req);
    if (!term) return; // このウィンドウは持ち主ではない → 別ウィンドウが処理する
    lastHandled = req.requestId;
    log(`match: req=${req.requestId} shellPid=${req.shellPid} cwd=${req.cwd}`);

    term.show(false);          // ターミナルタブをフォーカス(focus を奪う)
    raiseThisWindow();         // ウィンドウを OS 前面化
  } finally {
    busy = false;
  }
}

// 前面化対象のパス(マルチルートは .code-workspace、単一フォルダはそのフォルダ)
function raiseTarget() {
  if (vscode.workspace.workspaceFile && vscode.workspace.workspaceFile.scheme === 'file') {
    return vscode.workspace.workspaceFile.fsPath;
  }
  const folders = vscode.workspace.workspaceFolders;
  if (folders && folders.length) return folders[0].uri.fsPath;
  return null;
}

async function findTerminal(req) {
  const terms = vscode.window.terminals || [];

  // 1) shell pid 一致(最も確実)
  if (req.shellPid && req.shellPid > 0) {
    for (const t of terms) {
      try {
        const pid = await t.processId;
        if (pid && pid === req.shellPid) return t;
      } catch (_) {}
    }
  }

  // 2) shell integration の cwd 一致(フォールバック)
  if (req.cwd) {
    for (const t of terms) {
      try {
        const c = t.shellIntegration && t.shellIntegration.cwd;
        if (c && c.fsPath === req.cwd) return t;
      } catch (_) {}
    }
  }

  return null;
}

function raiseThisWindow() {
  const target = raiseTarget();
  if (!target) { log('no workspace target to raise'); return; }

  // `open -a` は起動中の VSCode に Apple Event を送るだけ(node 起動なし)。
  // 既存ウィンドウを別 Space でも前面化し、新規ウィンドウは作らない。最速・許可不要。
  cp.execFile('/usr/bin/open', ['-a', 'Visual Studio Code', target], (err) => {
    if (!err) { log('raised via open -a (' + target + ')'); return; }
    // 念のためのフォールバック(基本到達しない)
    log('open -a error: ' + err.message + ' -> code fallback');
    const codeBin = path.join(vscode.env.appRoot, 'bin', 'code');
    cp.execFile(codeBin, [target], (e2) => {
      if (e2) log('code raise error: ' + e2.message);
      else log('raised via code (' + target + ')');
    });
  });
}

function deactivate() {}

module.exports = { activate, deactivate };

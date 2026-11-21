// Turnipot Bridge — plain JS, no deps, no build step.
//
// Contract:
//  - Works in VSCodium, VS Code and Cursor (any VS Code-family editor).
//  - On activate: mkdir -p ~/Library/Application Support/Turnipot, unlink + listen on
//    vscode-<editor>-<process.pid>.sock there (net.createServer). Remove socket on deactivate.
//    <editor> is a slug of the host app bundle (e.g. "vscodium", "visual-studio-code"), so
//    the number of open windows per editor can be counted from the socket names.
//  - Newline-delimited JSON. Requests:
//      {"type":"focus","shellPid":N}         -> find terminal whose (await t.processId) === N,
//                                               t.show(false) (+ raise window if this editor has
//                                               several windows) -> {"ok":true,"appPath":"/Applications/X.app"}
//                                               The app activates appPath (no process spawned here).
//      {"type":"send","shellPid":N,"text":S} -> t.sendText(S) then Enter (separately) -> {"ok":true}
//    Not found / bad request -> {"ok":false}. One response line per request line.
'use strict';

const vscode = require('vscode');
const net = require('net');
const fs = require('fs');
const os = require('os');
const path = require('path');
const childProcess = require('child_process');

const RUNTIME_DIR = path.join(os.homedir(), 'Library', 'Application Support', 'Turnipot');
// appRoot = /Applications/<Editor>.app/Contents/Resources/app
const APP_PATH = path.resolve(vscode.env.appRoot, '..', '..', '..');
const EDITOR_SLUG = (path.basename(APP_PATH, '.app').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '')) || 'editor';
const SOCKET_PATH = path.join(RUNTIME_DIR, `vscode-${EDITOR_SLUG}-${process.pid}.sock`);

// One socket per window of this editor (stale ones are cleaned up by the app).
function windowCount() {
  try {
    return fs.readdirSync(RUNTIME_DIR).filter((n) => n.startsWith(`vscode-${EDITOR_SLUG}-`) && n.endsWith('.sock')).length;
  } catch (_) { return 1; }
}
const MAX_LINE = 1024 * 1024;

let server = null;
let output = null;

function log(msg) {
  if (output) output.appendLine(`[${new Date().toISOString()}] ${msg}`);
}

// processId can stay pending for a terminal whose process never started (or a
// pseudo-terminal), so every lookup is bounded and all terminals are queried in parallel.
const PID_TIMEOUT_MS = 500;

function pidOf(t) {
  return new Promise((resolve) => {
    const timer = setTimeout(() => resolve(undefined), PID_TIMEOUT_MS);
    Promise.resolve(t.processId).then(
      (pid) => { clearTimeout(timer); resolve(pid); },
      () => { clearTimeout(timer); resolve(undefined); });
  });
}

async function findTerminal(shellPid) {
  const terminals = vscode.window.terminals.slice();
  const pids = await Promise.all(terminals.map(pidOf));
  const i = pids.findIndex((pid) => pid === shellPid);
  return i >= 0 ? terminals[i] : null;
}

const delay = (ms) => new Promise((r) => setTimeout(r, ms));

// Best effort: raise *this* window (VS Code has no API for that). Running the bundled CLI with
// --reuse-window on this window's workspace focuses the window that already has it open.
function raiseWindow() {
  const cfg = vscode.workspace.getConfiguration('turnipot');
  if (!cfg.get('raiseWindowViaCli', true)) return;
  const target = vscode.workspace.workspaceFile && vscode.workspace.workspaceFile.scheme === 'file'
    ? vscode.workspace.workspaceFile.fsPath
    : (vscode.workspace.workspaceFolders && vscode.workspace.workspaceFolders[0]
      && vscode.workspace.workspaceFolders[0].uri.scheme === 'file'
      ? vscode.workspace.workspaceFolders[0].uri.fsPath : null);
  if (!target) return;
  const binDir = path.join(vscode.env.appRoot, 'bin');
  let cli = null;
  for (const name of ['codium', 'code', 'cursor']) {
    const p = path.join(binDir, name);
    if (fs.existsSync(p)) { cli = p; break; }
  }
  if (!cli) return;
  try {
    const child = childProcess.spawn(cli, ['--reuse-window', target], { detached: true, stdio: 'ignore' });
    child.on('error', (e) => log(`raiseWindow failed: ${e.message}`));
    child.unref();
  } catch (e) {
    log(`raiseWindow failed: ${e.message}`);
  }
}

async function handle(req) {
  if (!req || typeof req !== 'object' || typeof req.shellPid !== 'number') return { ok: false };
  if (req.type === 'focus') {
    const t = await findTerminal(req.shellPid);
    if (!t) return { ok: false };
    // The app activates the editor itself. Only with several windows of this editor do we need
    // the bundled CLI to pick the right window (it briefly shows a Dock icon, so avoid otherwise).
    if (windowCount() > 1) raiseWindow();
    t.show(false);
    log(`focus shellPid=${req.shellPid}`);
    return { ok: true, appPath: APP_PATH };
  }
  if (req.type === 'send') {
    if (typeof req.text !== 'string') return { ok: false };
    const t = await findTerminal(req.shellPid);
    if (!t) return { ok: false };
    // Claude Code's TUI treats text+CR arriving in one burst as a paste (the CR becomes a
    // newline instead of submitting), so type the text first and press Enter separately.
    t.sendText(req.text.replace(/\r?\n/g, ' '), false);
    await delay(120);
    t.sendText('\r', false);
    log(`send shellPid=${req.shellPid} (${req.text.length} chars)`);
    return { ok: true };
  }
  return { ok: false };
}

function onConnection(sock) {
  let buffer = '';
  let queue = Promise.resolve();
  sock.setEncoding('utf8');
  sock.on('error', () => {});
  sock.on('data', (chunk) => {
    buffer += chunk;
    if (buffer.length > MAX_LINE && buffer.indexOf('\n') < 0) { sock.destroy(); return; }
    let nl;
    while ((nl = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, nl).trim();
      buffer = buffer.slice(nl + 1);
      if (!line) continue;
      // Keep responses in request order.
      queue = queue.then(async () => {
        let res;
        try { res = await handle(JSON.parse(line)); } catch (e) { res = { ok: false }; log(`bad request: ${e.message}`); }
        if (!sock.destroyed) sock.write(JSON.stringify(res) + '\n');
      });
    }
  });
}

function cleanupSocket() {
  try { fs.unlinkSync(SOCKET_PATH); } catch (_) { /* not there */ }
}

function activate(context) {
  output = vscode.window.createOutputChannel('Turnipot Bridge');
  context.subscriptions.push(output);
  try {
    fs.mkdirSync(RUNTIME_DIR, { recursive: true });
  } catch (e) {
    log(`mkdir failed: ${e.message}`);
    return;
  }
  cleanupSocket();
  server = net.createServer(onConnection);
  server.on('error', (e) => log(`server error: ${e.message}`));
  server.listen(SOCKET_PATH, () => {
    try { fs.chmodSync(SOCKET_PATH, 0o600); } catch (_) { /* ignore */ }
    log(`listening on ${SOCKET_PATH}`);
  });
  context.subscriptions.push({ dispose: stop });
  // Also clean up if the extension host exits without calling deactivate.
  process.once('exit', cleanupSocket);
}

function stop() {
  if (server) {
    try { server.close(); } catch (_) { /* ignore */ }
    server = null;
  }
  cleanupSocket();
}

function deactivate() {
  stop();
}

module.exports = { activate, deactivate, _internal: { handle, findTerminal, SOCKET_PATH } };

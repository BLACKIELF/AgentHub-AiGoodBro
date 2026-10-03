// Run with the genuine signed Node bundled with Codex. Synthetic UNIX sockets
// only: no user app launch, credentials, upstream requests or auth modifications.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');
const {spawn} = require('node:child_process');
const [helper, addonPath, expected = 'authorized'] = process.argv.slice(2);
assert(helper && addonPath, 'Usage: signed-node script helper authorization-addon [authorized|rejected]');
assert(['authorized', 'rejected'].includes(expected));
const authorizer = require(path.resolve(addonPath));
const base = fs.mkdtempSync(path.join(os.tmpdir(), 'agb-peer-'));
fs.chmodSync(base, 0o700);
const results = [];

async function check(mode) {
  const socketPath = path.join(base, mode + '.sock');
  const peerCode = `const s=require('node:net').createConnection(${JSON.stringify(socketPath)});s.on('error',()=>process.exit(1));s.on('close',()=>process.exit(0));`;
  const appCode = `const c=require('node:child_process').spawn(process.execPath,['-e',${JSON.stringify(peerCode)}],{stdio:'inherit'});c.on('exit',code=>process.exit(code||0));`;
  let finish;
  const result = new Promise(resolve => { finish = resolve; });
  const server = net.createServer(socket => {
    try { finish(authorizer.authorizeSocketPeer(socket._handle.fd, false)); }
    catch { finish({error: 'peer authorization failed'}); }
    socket.destroy();
  });
  await new Promise(resolve => server.listen(socketPath, resolve));
  const environment = {...process.env, CODEX_HOME: base};
  delete environment.AIGOODBRO_PROXY_CONNECTION_FILE;
  let command = process.execPath;
  let args = ['-e', appCode];
  if (mode !== 'direct') {
    command = path.resolve(helper);
    const connection = path.join(base, 'connection.json');
    fs.writeFileSync(connection, JSON.stringify({schemaVersion: 1, endpoint: 'http://127.0.0.1:42123/v1', clientKey: 'k'.repeat(40), runID: 'peer-fixture', codexExecutable: process.execPath}), {mode: 0o600});
    environment.AIGOODBRO_PROXY_CONNECTION_FILE = connection;
    if (mode === 'app-server') {
      fs.writeFileSync(path.join(base, 'app-server'), appCode);
      args = ['app-server'];
    }
  }
  const child = spawn(command, args, {cwd: base, env: environment, stdio: ['pipe', 'ignore', 'pipe']});
  child.stderr.resume();
  const deadline = setTimeout(() => {child.kill('SIGKILL'); finish({timeout: true});}, 6000);
  try {
    const decision = await result;
    await new Promise(resolve => {if(child.exitCode !== null) resolve(); else child.once('exit', resolve);});
    const authorized = decision.authorized === true;
    results.push({mode, authorized, reason: decision.reason ?? null});
    assert.equal(authorized, mode === 'direct' || expected === 'authorized', JSON.stringify(results.at(-1)));
  } finally {
    clearTimeout(deadline);
    child.stdin.destroy();
    await new Promise(resolve => server.close(resolve));
  }
}
(async () => {
  try {
    for (const mode of ['direct', 'passthrough', 'app-server']) await check(mode);
    console.log(JSON.stringify({passed: true, results}));
  } finally { fs.rmSync(base, {recursive: true, force: true}); }
})().catch(error => {console.error(error); process.exitCode = 1;});

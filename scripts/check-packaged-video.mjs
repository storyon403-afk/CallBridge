// 使用解压包自带的 Node、网页和发送器；测试数据只进入内存，不连接摄像头或 OBS。
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {randomUUID} from 'node:crypto';
import {once} from 'node:events';
import {access} from 'node:fs/promises';
import path from 'node:path';
import {createInterface} from 'node:readline';

const bin = path.dirname(process.execPath);
const win = process.platform === 'win32';
assert.ok(win || process.platform === 'darwin', 'Requires the Node executable from a CallBridge release');
const root = path.resolve(bin, '..');
const host = win ? path.join(root, 'avatar-host') : path.join(root, 'Resources', 'Avatar');
const assets = win ? path.join(root, 'avatar') : path.join(host, 'site');
const sender = win ? path.join(root, 'camera', 'callbridge-camera-sender.exe') : path.join(bin, 'callbridge-camera-sender');
const server = path.join(host, 'server.mjs');
await Promise.all([server, sender, path.join(assets, 'index.html')].map(file => access(file)));
const env = {CB_AVATAR_ASSETS: assets, CB_AVATAR_SENDER: sender, CB_AVATAR_PORT: '0', CB_AVATAR_CAMERA: 'obs'};
// Windows 的子进程需要系统目录；不继承开发目录、云密钥、用户素材或 Node 注入选项。
for (const key of ['SystemRoot', 'TEMP', 'TMP', 'TMPDIR']) if (process.env[key]) env[key] = process.env[key];
const child = spawn(process.execPath, [server, '--app-host', '--memory-check'], {cwd: host, env, stdio: ['pipe', 'pipe', 'inherit']});
const closed = once(child, 'close');
const lines = createInterface({input: child.stdout});
const startup = setTimeout(() => child.kill(), 10000);
try {
  const {value, done} = await lines[Symbol.asyncIterator]().next();
  assert.ok(!done, 'Packaged video host exited before reporting its port');
  clearTimeout(startup);
  const {port} = JSON.parse(value);
  assert.ok(Number.isInteger(port) && port > 0 && port <= 65535);
  const origin = `http://127.0.0.1:${port}`;
  const request = (route, options = {}) => fetch(origin + route, {...options, redirect: 'error', signal: AbortSignal.timeout(6000)});
  for (const route of ['/', '/app.js', '/assets.json']) assert.equal((await request(route, {method: 'HEAD'})).status, 200, route);
  const info = await (await request('/camera/info')).json();
  assert.equal(info.active, false);
  assert.equal(info.memoryOnly, true);
  const headers = {Origin: origin, 'X-CB-Token': info.token, 'X-CB-Owner': randomUUID()};
  const post = (route, body, extra = {}) => request(route, {method: 'POST', headers: {...headers, ...extra}, body});
  const started = await (await post('/camera/start', '{"confirm":true}')).json();
  assert.equal(started.memoryOnly, true);
  // 最终画布必须完全不透明；不同 RGB 值还可检验原生 BGRA 通道顺序。
  const pixels = Buffer.alloc(1280 * 720 * 4, Buffer.from([17, 34, 51, 255]));
  const frame = await (await post('/camera/frame', pixels, {
    'Content-Type': 'application/octet-stream', 'X-CB-Session': started.session, 'X-CB-Sequence': '1', 'X-CB-Age-Ms': '0'
  })).json();
  assert.equal(frame.accepted, true, frame.error ?? frame.reason);
  assert.equal(frame.sequence, 1);
  if (!win) { assert.equal(frame.memoryOnly, true); assert.deepEqual(frame.firstBGRA, [51, 34, 17, 255]); }
  assert.equal((await (await post('/camera/stop', '{}')).json()).stopped, true);
  assert.equal((await (await request('/camera/info')).json()).active, false);
} finally {
  clearTimeout(startup);
  child.stdin.end();
  const timeout = setTimeout(() => child.kill('SIGKILL'), 5000);
  try { const [code] = await closed; assert.equal(code, 0, 'Packaged host did not exit cleanly'); }
  finally { clearTimeout(timeout); lines.close(); }
}
console.log(`PASS ${process.platform}/${process.arch}: packaged host, page assets, memory-only 720p frame, stop and exit`);

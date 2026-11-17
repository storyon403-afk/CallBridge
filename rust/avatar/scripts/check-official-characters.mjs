// 验证官方角色资源在现有渲染器中的真实蒙皮、取景及动作；所有设备和外网入口均拒绝。
import {chromium} from 'playwright-core';
import {readFile, mkdir, writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {fileURLToPath} from 'node:url';
import assert from 'node:assert/strict';
import {startServer} from './server.mjs';

const directory = fileURLToPath(new URL('../../../build/official-plugins/characters/', import.meta.url));
const output = fileURLToPath(new URL('../../build/official-character-check/', import.meta.url));
await mkdir(output, {recursive: true});
const browser = await chromium.launch({executablePath: process.env.CB_AVATAR_BROWSER ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true});
const deadline = setTimeout(() => browser.close(), 120000); deadline.unref();
const results = [];
try {
 for (const slug of ['spider-man', 'gg-bond']) {
  const file = directory + slug + '.vrm', bytes = await readFile(file);
  process.env.CB_CHARACTER_FILE = file;
  process.env.CB_CHARACTER_SHA = createHash('sha256').update(bytes).digest('hex');
  process.env.CB_CHARACTER_BYTES = String(bytes.length);
  const camera = {status: async () => ({available: false, active: false}), stop: async () => true,
   start: async () => {throw Error('Device output forbidden');}};
  const server = await startServer(0, {camera});
  const origin = `http://127.0.0.1:${server.address().port}`;
  const context = await browser.newContext({permissions: [], viewport: {width: 1000, height: 900}});
  const external = [], errors = [];
  try {
   await context.route('**/*', route => {
    if (route.request().url().startsWith(origin + '/')) return route.continue();
    external.push(route.request().url()); return route.abort();
   });
   await context.addInitScript(() => {
    window.callbridgeComposition = {person: 'avatar', background: 'plate', character: true};
    window.mediaCalls = 0;
    navigator.mediaDevices.getUserMedia = () => {window.mediaCalls++; throw Error('Capture forbidden');};
   });
   const page = await context.newPage(); page.on('pageerror', e => errors.push(e.message));
   await page.goto(origin);
   await page.waitForFunction(() => window.avatarLab?.stats.ready, null, {timeout: 30000});
   const initial = await page.evaluate(() => {
    const a = avatarLab, gl = a.renderer.getContext(), pixels = new Uint8Array(gl.drawingBufferWidth * gl.drawingBufferHeight * 4);
    a.renderer.render(a.scene, a.camera);
    gl.readPixels(0, 0, gl.drawingBufferWidth, gl.drawingBufferHeight, gl.RGBA, gl.UNSIGNED_BYTE, pixels);
    let opaque = 0; for (let i = 3; i < pixels.length; i += 4) if (pixels[i] > 200) opaque++;
    const bones = a.vrm.humanoid;
    const mappedEndNodes = Object.values(bones.rawHumanBones).map(b => b.node.name).filter(name => name.includes('_end_'));
    const head = bones.getRawBoneNode('head').getWorldPosition(a.camera.position.clone()).project(a.camera);
    return {opaque, total: pixels.length / 4, head: head.toArray(), mappedEndNodes, custom: a.stats.appearance.custom, mediaCalls: window.mediaCalls};
   });
   assert.equal(initial.custom, true); assert.equal(initial.mediaCalls, 0);
   assert.deepEqual(initial.mappedEndNodes, []);
   assert.ok(initial.opaque > 1000 && initial.opaque < initial.total * .9, JSON.stringify(initial));
   assert.ok(Math.abs(initial.head[0]) < 1 && Math.abs(initial.head[1]) < 1, JSON.stringify(initial));
   await page.screenshot({path: output + slug + '-preview.png'});
   const deformation = await page.evaluate(() => {
    const a = avatarLab, meshList = []; a.vrm.scene.traverse(n => {if (n.isSkinnedMesh) meshList.push(n);});
    const sample = () => meshList.flatMap(m => {
     m.updateMatrixWorld(true); m.skeleton.update(); const result = [];
     for (let i = 0; i < m.geometry.attributes.position.count; i += 20)
      result.push(...m.getVertexPosition(i, a.camera.position.clone()).applyMatrix4(m.matrixWorld).toArray());
     return result;
    });
    const before = sample();
    a.vrm.humanoid.getNormalizedBoneNode('neck').rotation.y += .35;
    a.vrm.humanoid.getNormalizedBoneNode('leftLowerArm').rotation.y += .45;
    a.vrm.update(.016); a.vrm.scene.updateMatrixWorld(true);
    const after = sample();
    return {meshes: meshList.length, moved: after.filter((x, i) => Math.abs(x - before[i]) > .001).length,
     finite: after.every(Number.isFinite)};
   });
   assert.ok(deformation.meshes > 0 && deformation.moved > 20, JSON.stringify(deformation));
   assert.equal(deformation.finite, true);
   await page.click('#demo');
   await page.waitForFunction(() => avatarLab.stats.mode === 'demo');
   await page.screenshot({path: output + slug + '-motion.png'});
   await page.click('#stop');
   if (slug === 'gg-bond') {
    // 全身与侧前视图仅用于审查资源比例，保留运行时原有的半身相机。
    await page.evaluate(() => {
     const a = avatarLab; a.camera.position.set(0, 1.16, 2.35); a.camera.lookAt(0, 1.16, 0);
    });
    await page.screenshot({path: output + slug + '-full.png'});
    await page.locator('#stage').screenshot({path: output + slug + '-model.png'});
    await page.evaluate(() => {
     const a = avatarLab; a.camera.position.set(.95, 1.25, 2.15); a.camera.lookAt(0, 1.16, 0);
    });
    await page.screenshot({path: output + slug + '-three-quarter.png'});
   }
   assert.equal(await page.evaluate(() => window.mediaCalls), 0);
   assert.deepEqual(errors, []); assert.deepEqual(external, []);
   results.push({slug, sha256: process.env.CB_CHARACTER_SHA, initial, deformation});
  } finally {await context.close(); await new Promise(resolve => server.close(resolve));}
 }
 await writeFile(output + 'results.json', JSON.stringify(results, null, 2) + '\n');
 console.log(JSON.stringify(results));
} finally {clearTimeout(deadline); await browser.close();}

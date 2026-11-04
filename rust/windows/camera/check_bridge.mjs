// 真实 Node → 子进程 → Rust 门控集成；强制 memoryOnly，绝不调用 OBS 或物理摄像头。
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {CameraBridge} from '../../avatar/scripts/camera-bridge.mjs';

if(!process.env.CB_TEST_CAMERA_SENDER) throw Error('Set CB_TEST_CAMERA_SENDER to the built worker or an explicit memory-only test shim');
const bridge=new CameraBridge({target:'obs',memoryOnly:true,executable:process.env.CB_TEST_CAMERA_SENDER});
const owner=randomUUID();
try {
 const {session,memoryOnly}=await bridge.start(owner);
 assert.equal(memoryOnly,true);
 const data=Buffer.alloc(1280*720*4);
 for(const sequence of [1,2]) {
  const result=await bridge.frame(owner,session,data,sequence,0);
  assert.equal(result.sequence,sequence);assert.equal(result.accepted,true);
 }
 await assert.rejects(()=>bridge.frame(owner,session,data,2,0));
 assert.equal(bridge.session,null);
 assert.equal(bridge.owner,null);
 console.log('PASS Node/Python/Rust memory-only handshake, frame acknowledgements, replay rejection and session invalidation');
} finally {await bridge.stop(bridge.owner);}

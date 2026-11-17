// 验证帧资源边界与数值驱动，不打开摄像头或虚拟设备。
import test from 'node:test';import assert from 'node:assert/strict';
import {FrameSelector,FrameAvatar,parseFrameAvatar} from '../src/frame-avatar.mjs';
const rig=(yaw=0,open=0,eye=1)=>({framing:{person:true},face:{head:{y:yaw,z:0,x:0},eye:{l:eye,r:eye},mouth:{shape:{A:open}}}});
test('微笑压过张嘴，表情连续确认与退出滞回，眨眼后恢复笑容',()=>{
 const s=new FrameSelector(),r=rig(0,1);r.frameSignals={smile:.9,frown:0,open:1};
 s.accept(r,0);assert.equal(s.tick(0).row,2);
 s.accept(r,80);assert.equal(s.tick(80).row,3);
 r.face.eye={l:0,r:0};s.accept(r,100);assert.equal(s.tick(100).row,1);
 r.face.eye={l:1,r:1};s.accept(r,140);assert.equal(s.tick(140).row,3);
 r.frameSignals.smile=.4;s.accept(r,200);assert.equal(s.tick(200).row,3);
 r.frameSignals.smile=0;s.accept(r,220);assert.equal(s.tick(220).row,3);
 s.accept(r,350);assert.equal(s.tick(350).row,2);
 r.frameSignals={smile:0,frown:.9,open:0};s.accept(r,400);s.tick(400);s.accept(r,480);assert.equal(s.tick(480).row,4);
 assert.equal(s.tick(1300).row,0);s.accept(rig(),1310);assert.equal(s.tick(1310).row,0);
});
test('单帧笑容毛刺不切换，停止清除表情待确认状态',()=>{
 const s=new FrameSelector(),r=rig();r.frameSignals={smile:1,frown:0,open:0};
 s.accept(r,0);s.tick(0);s.accept(rig(),100);assert.equal(s.tick(100).row,0);
 s.accept(r,120);s.tick(120);s.reset();s.accept(r,300);assert.equal(s.tick(300).row,0);
 s.accept(r,380);assert.equal(s.tick(380).row,3);
});
test('微笑眯眼不会被上游零眼权重吞掉，真正闭眼仍可眨眼',()=>{
 const s=new FrameSelector(),r=rig(0,0,0);r.frameSignals={smile:1,open:0,eyeLeft:.13,eyeRight:.12};
 s.accept(r,0);s.tick(0);s.accept(r,80);assert.equal(s.tick(80).expression,'smile');
 r.frameSignals.eyeLeft=.03;r.frameSignals.eyeRight=.02;s.accept(r,100);assert.equal(s.tick(100).expression,'blink');
});
test('渲染器不会把头歪和 Spine 绝对角施加到身体，肩斜最多两度',()=>{
 const rotations=[],context={clearRect(){},save(){},translate(){},rotate(a){rotations.push(a);},drawImage(){},restore(){}};
 const previous=globalThis.document;globalThis.document={createElement:()=>({width:640,height:480,getContext:()=>context})};
 try{
  const avatar=new FrameAvatar({width:1254,height:1254},{}),r=rig();r.face.head={x:.7,y:.3,z:.8};r.pose={Spine:{z:2.9}};
  for(let t=0;t<1000;t+=16){avatar.accept(r,t);avatar.render(640,480,t);}
  assert.ok(rotations.every(a=>a===0));
  r.shoulderTilt=.8;for(let t=1000;t<2000;t+=16){avatar.accept(r,t);avatar.render(640,480,t);}
  assert.ok(rotations.every(a=>Math.abs(a)<=.035));assert.ok(rotations.at(-1)>.03);
  r.shoulderTilt=null;for(let t=2000;t<3000;t+=16){avatar.accept(r,t);avatar.render(640,480,t);}
  assert.ok(Math.abs(rotations.at(-1))<1e-6);
 }finally{if(previous===undefined)delete globalThis.document;else globalThis.document=previous;}
});
test('角度边界滞回，失踪回中，停止清除旧帧',()=>{
 const s=new FrameSelector();s.accept(rig(.5),0);for(let n=0;n<500;n+=16)s.tick(n);assert.equal(s.column,4);
 s.accept(rig(.37),500);for(let n=500;n<680;n+=16)s.tick(n);assert.equal(s.column,4);
 for(let n=1300;n<2000;n+=16)s.tick(n);assert.equal(s.column,2);assert.equal(s.row,0);
 s.accept(rig(.5,1),2100);s.tick(2100);s.reset();assert.equal(s.tick(2101).index,2);
});
test('闭眼优先、开口滞回、无脸和非有限输入',()=>{
 const s=new FrameSelector();s.accept(rig(0,1),0);assert.equal(s.tick(0).row,2);
 s.accept(rig(0,.2),20);assert.equal(s.tick(20).row,2);
 s.accept(rig(0,1,0),40);assert.equal(s.tick(40).row,1);
 s.accept({framing:{person:false},...{face:rig(.5).face}},60);assert.equal(s.lastSeen,40);
 s.accept(rig(NaN,Infinity),80);assert.ok(Number.isFinite(s.tick(80).roll));
});
test('拒绝截断、超长头、外部字段和错误 PNG 尺寸',()=>{
 const make=extra=>{const meta={columns:5,rows:5,width:1254,height:1254,yaws:[-.5,-.25,0,.25,.5],expressions:['neutral','blink','talk','smile','frown'],...extra};const json=Buffer.from(JSON.stringify(meta));const png=Buffer.alloc(33);Buffer.from([137,80,78,71,13,10,26,10]).copy(png);png.writeUInt32BE(13,8);png.write('IHDR',12);png.writeUInt32BE(1254,16);png.writeUInt32BE(1254,20);png[24]=8;png[25]=6;const b=Buffer.alloc(12);b.write('CBFA');b.writeUInt32LE(1,4);b.writeUInt32LE(json.length,8);return Uint8Array.from(Buffer.concat([b,json,png])).buffer;};
 assert.equal(parseFrameAvatar(make()).meta.width,1254);
 assert.throws(()=>parseFrameAvatar(new ArrayBuffer(3)));
 assert.throws(()=>parseFrameAvatar(make({url:'https://example.com'})));
 assert.throws(()=>parseFrameAvatar(make({width:4097})));
 const b=make();new DataView(b).setUint32(8,99999,true);assert.throws(()=>parseFrameAvatar(b));
});

// 悬浮编辑器在窗口关闭后保留草稿和选区，播放与授权仍由原生会话处理。
'use strict';
const draft=byId('draft');
let composing=false, restoredDraft=false, monitorLayout;
function speechControls(){
  if(!state)return;
  const count=Array.from(draft.value).length;
  const valid=!composing && count<=280 && Boolean(draft.value.trim());
  byId('length').value=count+' / 280';
  draft.setAttribute('aria-invalid',String(count>280));
  byId('send-draft').disabled=!(valid && state.armed && state.sendOK);
  byId('listen-draft').disabled=!(valid && state.draftPreviewOK && state.monitor.selected);
  byId('prepare-draft').disabled=!(valid && state.prepareOK);
  byId('countdown-draft').disabled=!(valid && state.countdownOK && state.draft===draft.value);
}
let voiceLayout;
function draw(){
  byId('route-state').textContent=state.status;
  byId('global-stop').disabled=!state.stopOK;
  document.body.classList.toggle('solid',!state.glass);
  const voices=JSON.stringify(state.voice);
  if(voices!==voiceLayout){
    byId('voice-choices').replaceChildren(...choices(state.voice,'voice'));
    voiceLayout=voices;
  }
  if(!restoredDraft){draft.value=state.draft||'';restoredDraft=true;}
  speechControls();
  const monitors=JSON.stringify(state.monitor);
  if(monitorLayout!==monitors){
    byId('speech-monitors').replaceChildren(...choices(state.monitor,'monitor'));
    if(!state.monitor.selected)byId('speech-settings').open=true;
    monitorLayout=monitors;
  }
  byId('speech-voice').textContent=tr('音色')+' · '+state.voice.name;
  byId('speech-output').textContent=tr('通话设备')+' · '+(state.audio.name||tr('未连接'))+'　／　'+tr('本机试听')+' · '+(state.monitor.name||tr('未连接'));
  byId('speech-arm').setAttribute('aria-pressed',String(state.armed));
  byId('speech-arm').disabled=!state.armOK;
  const gain=byId('speech-gain');
  if(document.activeElement!==gain)gain.value=Math.round(100*state.speechGain);
  gain.disabled=!state.speechGainOK;
  byId('speech-percent').value=gain.value+'%';
}
// 输入走轻量消息，保留同一编辑节点的选区、撤销栈和中文候选状态。
function edit(action,value){
  window.webkit.messageHandlers.studio.postMessage({action,value}).catch(()=>{
    byId('route-state').textContent=tr('暂时无法读取工作区');
  });
}
draft.addEventListener('input',()=>{edit('draft',draft.value);speechControls();});
draft.addEventListener('compositionstart',()=>{composing=true;edit('composition','start');speechControls();});
draft.addEventListener('compositionend',()=>{edit('draft',draft.value);edit('composition','end');composing=false;speechControls();});
draft.addEventListener('keydown',e=>{
  if(!(e.metaKey||e.ctrlKey)||e.isComposing||composing||e.keyCode===229)return;
  if(e.key==='Enter'){e.preventDefault();byId('send-draft').click();}
  if(e.key==='.'){e.preventDefault();byId('global-stop').click();}
});
byId('speech-gain').addEventListener('input',e=>{byId('speech-percent').value=e.target.value+'%';});
byId('speech-gain').addEventListener('change',e=>request('speechGain',String(Number(e.target.value)/100)));

document.addEventListener('click',e=>{
  const b=e.target.closest('button');if(!b||b.disabled)return;
  const {action,value=''}=b.dataset;
  if(action==='pickVoice'){
    const voices=byId('voice-choices');
    voices.hidden=!voices.hidden;
    b.setAttribute('aria-expanded',String(!voices.hidden));return;
  }
  if(action==='voice'){
    byId('voice-choices').hidden=true;
    byId('speech-voice').setAttribute('aria-expanded','false');
  }
  if(['sendDraft','prepareDraft','countdownDraft','listenDraft'].includes(action)){
    if(!composing)void request(action,draft.value);return;
  }
  if(action)void request(action,value);
});
function focusDraft(){draft.focus({preventScroll:true});}
document.addEventListener('DOMContentLoaded',focusDraft);
new ResizeObserver(()=>{
  edit('speechHeight',String(Math.ceil(byId('speech').getBoundingClientRect().height)));
}).observe(byId('speech'));

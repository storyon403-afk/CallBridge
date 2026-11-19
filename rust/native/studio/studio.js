// 两个窗口从同一宿主读取状态，但各自保留独立的页面、焦点和刷新序号。
'use strict';
let state,revision=0;
const byId=id=>document.getElementById(id);
function element(tag,text,cls) {
  const n=document.createElement(tag);
  if(text) n.textContent=tr(text);
  if(cls)n.className=cls;
  return n;
}
function control(text,action,value='',enabled=true,pressed=null) {
  const b=element('button',text);
  Object.assign(b.dataset,{action,value});b.disabled=!enabled;
  if(pressed!==null)b.setAttribute('aria-pressed',String(pressed));
  return b;
}
function choices(group,key){
  return group.items.filter(o=>o.id).map(o=>control(o.name,key,o.id,group.enabled,group.selected===o.id));
}
let sessionSerial=0;
async function request(action,value=''){
  const serial=++sessionSerial;
  try {
    const fresh=await window.webkit.messageHandlers.studio.postMessage({action,value});
    if(serial<revision)return;
    revision=serial;
    if(JSON.stringify(state)===JSON.stringify(fresh))return;
    state=fresh;localize();draw();
  } catch {byId('route-state').textContent=tr('暂时无法读取工作区');}
}
const words={
  '关闭打字说话':['Close type to speak','読み上げ入力を閉じる'],
  '正在载入人物':['Loading avatar','アバターを読み込み中'],'人物预览不可用':['Avatar preview unavailable','アバターを表示できません'],'正在载入循环背景':['Loading loop','動画を読み込み中'],'视频预览不可用':['Video preview unavailable','動画を表示できません'],
  '本机试听':['Local preview','ローカル試聴'],'通话设备':['Call device','通話デバイス'],'未连接':['Disconnected','未接続'],'想说的话':['Your message','話す内容'],'输入想说的话…':['Type your message…','話したいことを入力…'],'⌘↩ 发送 · ⌘. 停止':['⌘↩ Send · ⌘. Stop','⌘↩ 送信 · ⌘. 停止'],'发送':['Send','送信'],'试听这段':['Preview message','この文章を試聴'],'语音设置':['Speech settings','音声設定'],'人声音量':['Speech volume','音声音量'],'准备语音':['Prepare speech','音声を準備'],'5 秒后播放':['Play in 5 seconds','5秒後に再生'],'混音设置':['Mixer','ミキサー'],'个人音色':['Personal voice','パーソナル音声'],
  '视频':['Video','動画'],'我的通话组合':['My call setup','通話の構成'],'打字说话':['Type to speak','入力して話す'],'组合台':['Studio','スタジオ'],'接线台':['Routing','接続'],'停止全部':['Stop all','すべて停止'],
  '构图预览':['Layout preview','構図プレビュー'],'取景':['Framing','構図'],'形象':['Avatar','アバター'],'真人':['Camera','本人'],'纯背景':['Backdrop only','背景のみ'],
  '当前组合':['Current setup','現在の構成'],'素材库':['Library','素材ライブラリ'],'导入插件':['Import plugin','プラグインを読み込む'],'全部':['All','すべて'],'音色':['Voice','音声'],'画面背景':['Backdrop','映像背景'],'背景音':['Ambience','環境音'],
  '落日海岸':['Sunset coast','夕暮れの海岸'],'窗边晨光':['Morning window','朝の窓辺'],'现场背景':['Camera background','現場の背景'],'流光 · 视频素材':['Aurora · video','オーロラ · 動画'],'窗景 · 2.5D':['Window · 2.5D','窓辺 · 2.5D'],'采集静态背景':['Captured plate','静止背景'],'澄 · 通话装':['Cheng · Call Outfit','澄 · 通話スタイル'],'真人 · 构图示意':['Camera framing guide','本人の構図ガイド'],
  '通话接线':['Call routing','通話の接続'],'环境输入':['Environment input','環境入力'],'插件与素材':['Plugins and media','プラグインと素材'],'官方插件':['Official plugins','公式プラグイン'],'画面插件管理':['Visual plugins','映像プラグイン管理'],'音频插件管理':['Audio plugins','音声プラグイン管理'],'其他设置':['More controls','その他の設定'],'声音输入':['Voice input','音声入力'],'云服务':['Cloud services','クラウドサービス'],'半透明背景':['Translucent panels','半透明パネル'],'刷新设备':['Refresh devices','デバイスを更新'],
  '换素材':['Replace','素材を変更'],'原声':['Original','原音'],'轻度降噪':['Light denoise','軽いノイズ除去'],'试听音色':['Preview voice','音声を試聴'],'导入背景音':['Import WAV','WAV を読み込む'],'播放背景':['Play ambience','背景音を再生'],'继续':['Resume','再開'],'暂停':['Pause','一時停止'],'循环':['Loop','ループ'],'移除':['Remove','取り外す'],'背景音量':['Ambience volume','背景音量'],'打开画面预览':['Open renderer','映像プレビューを開く'],'声音':['Audio','音声'],'画面':['Video','映像'],'允许发送语音':['Allow sending','音声送信を許可'],'混入环境音':['Mix microphone','マイク音をミックス'],'暂时无法读取工作区':['Workspace unavailable','ワークスペースに接続できません']
};
function tr(text){const i=state?.language==='en'?0:state?.language==='ja'?1:-1;return words[text]?.[i]??text;}
let localized=false;
function localize(){
  if(localized)return;localized=true;document.documentElement.lang=state.language;
  for(const node of document.querySelectorAll('h1,h2,h3,button,summary,label,#monitor-label,.speech-meter small,.stage-label,.frame-title')){
    if(node.childElementCount===0)node.textContent=tr(node.textContent);
  }
  if(byId('draft'))byId('draft').placeholder=tr('输入想说的话…');
  byId('framing')?.setAttribute('aria-label',tr('取景'));
}
async function sync(){
  if(!state||!document.hidden)await request('state');
  setTimeout(sync,850);
}
window.addEventListener('focus',()=>request('state'));
document.addEventListener('DOMContentLoaded',sync);

// 本文件的目的：集中维护对外展示短语；能力目录和功能入口保持与实际产品一致。
window.CALLBRIDGE_SHOWCASE = [
 {"id":"cloud","title":{"zh":"云端服务","en":"Cloud services"},"type":"features","heading":{"zh":"云端服务目录","en":"Cloud service catalog"},"cards":[
   {"title":{"zh":"Decart Lucy","en":"Decart Lucy"},"body":{"zh":"实时视频转换","en":"Live video effects"}},
   {"title":{"zh":"LiveAvatar","en":"LiveAvatar"},"body":{"zh":"音频驱动形象","en":"Audio-driven avatars"}},
   {"title":{"zh":"Tavus CVI","en":"Tavus CVI"},"body":{"zh":"AI 对话形象","en":"Conversational avatars"}},
   {"title":{"zh":"FASHN","en":"FASHN"},"body":{"zh":"图片换装","en":"Virtual try-on"}},
   {"title":{"zh":"ZEGO 即构","en":"ZEGO"},"body":{"zh":"实时数字人","en":"Realtime avatars"}},
   {"title":{"zh":"魔珐星云","en":"Xmov"},"body":{"zh":"3D 数字人","en":"3D avatars"}},
   {"title":{"zh":"HeyGen Video","en":"HeyGen Video"},"body":{"zh":"数字人视频","en":"Avatar videos"}},
   {"title":{"zh":"Synthesia","en":"Synthesia"},"body":{"zh":"企业内容视频","en":"Business videos"}}
 ]},
 {"id":"voice-input","title":{"zh":"声音转录","en":"Voice input"},"type":"features","heading":{"zh":"声音转录","en":"Voice input"},"cards":[
   {"title":{"zh":"麦克风","en":"Microphone"},"body":{"zh":"输入设备选择","en":"Choose your input"}},
   {"title":{"zh":"试听设备","en":"Preview device"},"body":{"zh":"独立输出选择","en":"Separate output"}},
   {"title":{"zh":"变声音色","en":"Voice profiles"},"body":{"zh":"插件与音色配置","en":"Plugin & voice settings"}},
   {"title":{"zh":"转文字设置","en":"Transcription settings"},"body":{"zh":"语言与引擎选择","en":"Language & engine options"}}
 ]},
 {"id":"updates","title":{"zh":"自动更新","en":"App updates"},"type":"features","heading":{"zh":"macOS 自动更新","en":"macOS app updates"},"cards":[
   {"title":{"zh":"自动检查","en":"Auto check"},"body":{"zh":"每天检查新版本","en":"Daily update checks"}},
   {"title":{"zh":"后台下载","en":"Background download"},"body":{"zh":"无需等待","en":"Download while you work"}},
   {"title":{"zh":"签名验证","en":"Signed updates"},"body":{"zh":"校验更新包","en":"Verified packages"}},
   {"title":{"zh":"退出安装","en":"Install on quit"},"body":{"zh":"下次打开即更新","en":"Ready next launch"}}
 ]},
 {"id":"plugins","title":{"zh":"插件管理","en":"Plugins"},"type":"features","heading":{"zh":"插件管理","en":"Plugins"},"cards":[
   {"title":{"zh":"官方目录","en":"Official catalog"},"body":{"zh":"浏览与下载","en":"Browse & download"}},
   {"title":{"zh":"本地导入","en":"Local import"},"body":{"zh":".cbplugin · ZIP","en":".cbplugin · ZIP"}},
   {"title":{"zh":"声音插件","en":"Voice plugins"},"body":{"zh":"音色 · 增强 · 背景音","en":"Voices · effects · ambience"}},
   {"title":{"zh":"画面插件","en":"Visual plugins"},"body":{"zh":"人物 · 动作 · 背景","en":"Characters · motion · backgrounds"}}
 ]},
 {"id":"windows","title":{"zh":"Windows","en":"Windows"},"type":"features","heading":{"zh":"Windows 11 便携版","en":"Windows 11 portable app"},"cards":[
   {"title":{"zh":"系统语音","en":"System speech"},"body":{"zh":"文字转语音","en":"Text to speech"}},
   {"title":{"zh":"背景混音","en":"Audio mixing"},"body":{"zh":"语音与背景音","en":"Speech & ambience"}},
   {"title":{"zh":"虚拟人物","en":"Virtual characters"},"body":{"zh":"Cheng · VRM","en":"Cheng · VRM"}},
   {"title":{"zh":"画面输出","en":"Video output"},"body":{"zh":"OBS Virtual Camera","en":"OBS Virtual Camera"}}
 ]},
 {id:'studio',title:{zh:'动手试试',en:'Try it'},description:{zh:'网页交互模拟 · 不采集、不合成、不发送。',en:'Browser simulation · no capture, synthesis or sending.'},type:'studio'},
 {id:'experience',title:{zh:'使用体验',en:'Experience'},description:{zh:'面板收起与恢复演示 · 使用早期界面截图。',en:'Panel and widget animation · earlier interface captures.'},type:'experience'},
 {id:'recordings',title:{zh:'微信实录',en:'WeChat recordings'},description:{zh:'微信端实录 · 点击播放声音。',en:'Recorded in WeChat · press play for audio.'},type:'recordings',items:[
  {title:{zh:'文字转语音',en:'Text to speech'},operation:'media/operation-01.mp4',operationPoster:'media/operation-01-poster.jpg',result:'media/effect-01.mp4',poster:'media/effect-01-poster.jpg'},
  {title:{zh:'背景音',en:'Background audio'},operation:'media/operation-02.mp4',operationPoster:'media/operation-02-poster.jpg',result:'media/effect-02.mp4',poster:'media/effect-02-poster.jpg'},
  {title:{zh:'环境音',en:'Live ambience'},operation:'media/operation-03.mp4',operationPoster:'media/operation-03-poster.jpg',result:'media/effect-03.mp4',poster:'media/effect-03-poster.jpg'}]},
 {id:'voice',title:{zh:'个人音色',en:'Personal voice'},description:{zh:'系统音色直接使用 · Pocket 与个人音色按需配置。',en:'System voices included · optional Pocket and personal voices.'},type:'image',src:'media/personal-voice.png'}
];

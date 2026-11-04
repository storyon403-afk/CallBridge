// 云端目录只描述经过核对的能力；接口适配不代表真实账号、媒体输出已经验收。
export const PROVIDERS = Object.freeze([
 {id:'decart',name:'Decart Lucy',capability:'realtime-video-transform',adapter:'control-plane',credentialEnv:'CB_DECART_API_KEY',models:['lucy-vton-3.6','lucy-vton-3.5'],docs:'https://docs.platform.decart.ai/getting-started/client-tokens',pricing:'https://docs.platform.decart.ai/getting-started/pricing',input:['camera-video','garment-image'],transport:'decart-webrtc',guide:'decart'},
 {id:'liveavatar',name:'LiveAvatar',capability:'audio-driven-avatar',adapter:'control-plane',credentialEnv:'CB_LIVEAVATAR_API_KEY',docs:'https://docs.liveavatar.com/docs/lite-mode/lifecycle',pricing:'https://www.liveavatar.com/',input:['submitted-audio'],transport:'livekit',guide:'liveavatar'},
 {id:'tavus',name:'Tavus CVI',capability:'conversational-avatar',adapter:'control-plane',credentialEnv:'CB_TAVUS_API_KEY',docs:'https://docs.tavus.io/api-reference/conversations/create-conversation',pricing:'https://www.tavus.io/pricing',input:['submitted-text','submitted-audio'],transport:'daily',guide:'tavus'},
 {id:'fashn',name:'FASHN',capability:'image-try-on',adapter:'control-plane',credentialEnv:'CB_FASHN_API_KEY',models:['tryon-v1.6'],docs:'https://docs.fashn.ai/api-reference/tryon-v1-6',pricing:'https://help.fashn.ai/plans-and-pricing/api-pricing',input:['person-image','garment-image'],transport:'image-job',guide:'fashn'},
 {id:'zego',name:'ZEGO 即构',capability:'audio-driven-avatar',adapter:'planned',docs:'https://doc-zh.zego.im/aigc-digital-human-server/introduction/overview',input:['submitted-audio'],transport:'zego-rtc',guide:'zego'},
 {id:'xmov',name:'魔珐星云',capability:'3d-avatar',adapter:'planned',docs:'https://xingyun3d.com/',pricing:'https://xingyun3d.com/support/51-182',input:['submitted-text','submitted-audio'],transport:'vendor-sdk',guide:'xmov'},
 {id:'heygen',name:'HeyGen Video',capability:'batch-avatar-video',adapter:'planned',docs:'https://docs.heygen.com/',pricing:'https://www.heygen.com/pricing',input:['submitted-text'],transport:'video-job',guide:'heygen'},
 {id:'synthesia',name:'Synthesia',capability:'batch-avatar-video',adapter:'planned',docs:'https://docs.synthesia.io/',pricing:'https://www.synthesia.io/pricing',input:['submitted-text'],transport:'video-job',guide:'synthesia'},
]);
export function providerById(id){return PROVIDERS.find(p=>p.id===id);}

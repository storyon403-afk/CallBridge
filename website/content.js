// 本文件的目的：预留展示素材接口。type 可为 pair / image / video；src 为 null 时仅显示待添加。
// 新增展示位只需增加一个条目；已上传的真实素材保留，不用示意界面代替实际效果。
window.CALLBRIDGE_SHOWCASE = [
 {id:'experience',title:{zh:'使用体验',en:'Experience'},type:'experience'},
 {id:'speech',title:{zh:'文字转语音',en:'Text to speech'},type:'pair',operation:'media/operation-01.mp4',operationPoster:'media/operation-01-poster.jpg',result:'media/effect-01.mp4',poster:'media/effect-01-poster.jpg'},
 {id:'background-audio',title:{zh:'背景音',en:'Background audio'},type:'pair',operation:'media/operation-02.mp4',operationPoster:'media/operation-02-poster.jpg',result:'media/effect-02.mp4',poster:'media/effect-02-poster.jpg'},
 {id:'ambient',title:{zh:'环境音',en:'Ambient sound'},type:'pair',operation:'media/operation-03.mp4',operationPoster:'media/operation-03-poster.jpg',result:'media/effect-03.mp4',poster:'media/effect-03-poster.jpg'},
 {id:'voice',title:{zh:'个人音色',en:'Personal voice'},type:'image',src:'media/personal-voice.png'},
 {id:'avatar',title:{zh:'虚拟形象',en:'Avatar'},type:'video',src:null,poster:null},
 {id:'background',title:{zh:'背景替换',en:'Background'},type:'video',src:null,poster:null}
];

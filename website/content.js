// 本文件的目的：集中配置网页展示；交互模拟与真实微信实录分开，新增素材不需要改布局。
window.CALLBRIDGE_SHOWCASE = [
 {id:'studio',title:{zh:'动手试试',en:'Try it'},type:'studio'},
 {id:'experience',title:{zh:'使用体验',en:'Experience'},type:'experience'},
 {id:'recordings',title:{zh:'微信实录',en:'WeChat recordings'},type:'recordings',items:[
  {title:{zh:'文字转语音',en:'Text to speech'},operation:'media/operation-01.mp4',operationPoster:'media/operation-01-poster.jpg',result:'media/effect-01.mp4',poster:'media/effect-01-poster.jpg'},
  {title:{zh:'背景音',en:'Background audio'},operation:'media/operation-02.mp4',operationPoster:'media/operation-02-poster.jpg',result:'media/effect-02.mp4',poster:'media/effect-02-poster.jpg'},
  {title:{zh:'环境音',en:'Live ambience'},operation:'media/operation-03.mp4',operationPoster:'media/operation-03-poster.jpg',result:'media/effect-03.mp4',poster:'media/effect-03-poster.jpg'}]},
 {id:'voice',title:{zh:'个人音色',en:'Personal voice'},type:'image',src:'media/personal-voice.png'}
];

/* 本文件的目的：官方英文模型的按需资源、个人音色与离线合成适配。 */
#import "plugin_store.h"
BOOL CBEnglishReady(void);
BOOL CBEnglishBusy(void);
BOOL CBEnglishChecking(void);
NSString *CBEnglishProblem(void);
NSURL *CBEnglishRoot(void);
NSString *CBEnglishIdentifier(void);
BOOL CBIsEnglishVoice(NSString *identifier);
NSArray<NSDictionary *> *CBEnglishVoices(void);
void CBEnglishRefresh(void (^completion)(NSString *error));
void CBEnglishInstall(NSString *token, void (^progress)(NSString *message), void (^completion)(NSString *error));
void CBEnglishCancelInstall(void);
void CBEnglishDownloadDialog(NSWindow *window, void (^progress)(NSString *message), void (^completion)(NSString *error));
id<CBVoiceTask> CBMakeEnglishTask(NSString *profile);
id<CBPocketOperation> CBEnglishCreateVoice(NSURL *sample, NSString *name, BOOL cleanReference, void (^completion)(NSString *identifier, NSString *error));
// 合成音轨的可选降噪；在 worker 处理完成后才交给原有音频管线。
void CBSetSpeechDenoise(BOOL enabled, float strength);
// 主线程传入已选择的插件快照；后台再次校验。nil 表示内置轻度降噪。
void CBSetSpeechDenoisePlugin(NSDictionary *plugin);
BOOL CBSpeechDenoiseEnabled(void);
NSData *CBDenoisePCM24(NSData *pcm, CBResourceTask *operation, NSString **error);

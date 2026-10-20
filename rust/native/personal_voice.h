/* 本文件的目的：个人音色独立面板。只准备本地参考状态，试听/发送沿用主面板。 */
#import <AppKit/AppKit.h>
@interface CBPersonalVoiceController : NSWindowController <NSWindowDelegate>
@property(nonatomic, readonly) BOOL busy;
@property(nonatomic, copy) BOOL (^canChange)(void);
@property(nonatomic, copy) void (^stateChanged)(void);
@property(nonatomic, copy) void (^created)(NSString *identifier);
- (void)present;
- (void)cancel;
@end

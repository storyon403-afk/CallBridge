/* 本文件的目的：组织音频面板的概要与详情；音频与混音共用布局，复用宿主控件及 action，不拥有第二套音频状态。 */
#import <AppKit/AppKit.h>
@interface CBAudioPanel : NSObject
- (instancetype)initWithWindow:(NSWindow *)window controls:(NSDictionary<NSString *,NSView *> *)controls;
- (instancetype)initMixingWithWindow:(NSWindow *)window controls:(NSDictionary<NSString *,NSView *> *)controls;
- (void)showPage:(NSString *)page;
- (void)showPageContainingView:(NSView *)view;
- (void)refreshVoice:(NSString *)name engine:(NSString *)engine;
- (BOOL)checkLayout;
@property(nonatomic,readonly,copy) NSString *currentPage;
@end

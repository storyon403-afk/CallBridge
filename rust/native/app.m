/*
本文件的目的：提供最小文字语音窗口，把“输入 → 合成 → 发送 → 停止”连接起来。

为什么 UI 留在 Objective-C？AppKit 和系统语音对象有原生生命周期，交给 ARC 管理，
而文本校验、会话代次和 PCM 播放交给 Rust；窗口不承担实时音频计算。
为什么先勾选再发送？BlackHole 是共享虚拟设备，其他监听者也可能收到声音，启动不能自动播。
为什么同时检查 generation 和 state？停止后旧合成结果可能迟到，不能仅凭“合成成功”就播放。

默认入口启动窗口；带 --*-smoke 参数时执行指定诊断。只有显式确认的 sender-smoke 才发送声音。
*/
#import <AppKit/AppKit.h>
#import <AVFAudio/AVFAudio.h>
#import "speech_job.h"
#include "app_core.h"
#include <CoreAudio/CoreAudio.h>
#include <stdio.h>

// 把底层数字错误转成可读提示；未单独映射的 OSStatus 仍显示原值，便于定位。
static NSString *sender_error(int32_t status) {
    if (status == -20001) return @"未找到可用的 BlackHole 16ch；不会切换到真实设备。";
    if (status == -20002) return @"BlackHole 格式不符合要求：需要 48 kHz、16 声道。";
    if (status == -20003) return @"音频回调格式异常，已停止发送。";
    if (status == -20005) return @"输入关闭状态验证失败，拒绝启动。";
    return [NSString stringWithFormat:@"音频设备错误：%d。已停止，请刷新设备。", status];
}

// 诊断统一输出 JSON，便于保存/比较；返回值同时作为进程退出码。
static int print_report(NSDictionary *report, int status) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
    if (data == nil) return 1;
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
    return status;
}

// 只读取三类默认路由：输入、普通输出、系统提示音输出。没有 SetProperty 操作。
static NSArray *default_routes(void) {
    NSMutableArray *result = [NSMutableArray array];
    const AudioObjectPropertySelector selectors[] = {
        kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice,
        kAudioHardwarePropertyDefaultSystemOutputDevice
    };
    for (uint32_t index = 0; index < 3; ++index) {
        AudioObjectPropertyAddress address = {selectors[index], kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        AudioDeviceID device = 0;
        UInt32 size = sizeof(device);
        if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, &device) != noErr
            || device == kAudioObjectUnknown) return nil;
        [result addObject:@(device)];
    }
    return result;
}

// 1. 无窗口冒烟：共用真实 SpeechJob / sender，而不是另写一套假实现。
static int smoke_test(BOOL sending, BOOL cancelling) {
    NSArray *before = default_routes();
    if (before == nil) return print_report(@{ @"passed": @NO, @"reason": @"routes_unavailable" }, 1);
    // __block 使异步 completion 能更新外部变量；这些会话操作都回到主线程执行。
    __block CallBridgeSession session = {0};
    NSData *text = [@"你好，这是 CallBridge 发送器测试。" dataUsingEncoding:NSUTF8StringEncoding];
    if (cb_session_begin(&session, text.bytes, (uint32_t)text.length) != 0) return 1;
    uint64_t token = session.generation;
    __block BOOL completed = NO;
    __block uint32_t frames = 0;
    __block NSString *failure = nil;
    __block CallBridgeSender *sender = NULL;
    CallBridgeSpeechJob *job = [[CallBridgeSpeechJob alloc] init];
    double started = NSProcessInfo.processInfo.systemUptime;
    [job startText:[[NSString alloc] initWithData:text encoding:NSUTF8StringEncoding]
        voice:@"com.apple.voice.compact.zh-CN.Tingting" completion:^(NSData *pcm, NSString *error) {
            if (cancelling) { failure = @"cancelled_job_delivered_completion"; completed = YES; return; }
            if (error != nil || cb_session_ready(&session, token) != 0) {
                failure = error ?: @"invalid_generation";
                completed = YES;
                return;
            }
            frames = (uint32_t)(pcm.length / sizeof(float));
            if (sending) {
                int32_t status = cb_sender_open(pcm.bytes, frames, &sender);
                if (status == 0) status = cb_sender_start(sender);
                if (status != 0) failure = sender_error(status);
            }
            completed = YES;
        }];
    if (cancelling) {
        cb_session_cancel(&session);
        [job cancel];
    }
    // 命令行也要驱动 RunLoop，主队列的合成完成回调才有机会执行；不是忙等空转。
    // 取消模式继续观察约一秒，检查是否错误地交付了已取消任务的结果。
    double limit = cancelling ? 1.0 : 27.0;
    while ((!completed || cancelling) && NSProcessInfo.processInfo.systemUptime - started < limit) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    uint32_t position = 0, done = 0;
    if (sending && completed && failure == nil) {
        // 发送期限由实际语音时长加余量得到；done 表示本地消费完成，不表示远端听到。
        double deadline = NSProcessInfo.processInfo.systemUptime + (double)frames / 48000 + 3;
        while (!done && NSProcessInfo.processInfo.systemUptime < deadline) {
            int32_t status = cb_sender_poll(sender, &position, &done);
            if (status != 0) { failure = sender_error(status); break; }
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
        }
        if (!done && failure == nil) failure = @"sender_timeout";
    }
    [job cancel];
    int32_t cleanup = cb_sender_close(&sender);
    // 前后对照默认路由；即使播放成功，只要清理失败或路由变了，也不能报告整体成功。
    BOOL unchanged = [before isEqual:default_routes()];
    BOOL passed = failure == nil && cleanup == 0 && unchanged
        && (cancelling ? (!completed && session.state == 0) : (completed && frames > 0 && (!sending || done)));
    return print_report(@{ @"passed": @(passed), @"mode": cancelling ? @"cancel-smoke" : (sending ? @"sender-smoke" : @"tts-smoke"),
        @"frames": @(frames), @"output_frames_including_drain": @(position),
        @"output_only_sender": @(sending), @"sender_done": @((BOOL)done),
        @"defaults_unchanged": @(unchanged), @"cleanup_status": @(cleanup),
        @"reason": failure ?: (passed ? @"ok" : @"incomplete_or_route_changed"),
        @"scope": @"No physical input or remote call tested. Sender mode explicitly disables AUHAL input; TTS/cancel modes start no audio IO."
    }, passed ? 0 : 1);
}

// 2. 原生控制器：遵循应用/窗口 delegate 协议，接收启动、关闭与退出事件。
// Objective-C 对象由 strong 属性持有；_sender 是 C 资源，必须显式 close，ARC 不会替它释放。
@interface CallBridgeApp : NSObject <NSApplicationDelegate, NSWindowDelegate> {
    CallBridgeSession _session;
    CallBridgeSender *_sender;
}
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NSTextView *editor;
@property(nonatomic, strong) NSTextField *status;
@property(nonatomic, strong) NSPopUpButton *voices;
@property(nonatomic, strong) NSButton *sendButton;
@property(nonatomic, strong) NSButton *stopButton;
@property(nonatomic, strong) NSButton *armButton;
@property(nonatomic, strong) NSButton *refreshButton;
@property(nonatomic, strong) CallBridgeSpeechJob *job;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic) BOOL deviceAvailable;
@property(nonatomic) BOOL cleanupFailed;
@property(nonatomic) BOOL uiSmoke;
@property(nonatomic) uint32_t lastPosition;
@property(nonatomic) double lastAdvance;
@end

@implementation CallBridgeApp
- (void)updateControls {
    // 从唯一会话状态推导按钮状态，避免界面另存一套互相矛盾的“正在发送”标志。
    BOOL idle = _session.state == 0;
    self.sendButton.enabled = idle && self.deviceAvailable && !self.cleanupFailed
        && self.voices.numberOfItems > 0 && self.armButton.state == NSControlStateValueOn;
    self.stopButton.enabled = !idle || _sender != NULL;
    self.refreshButton.enabled = idle && !self.cleanupFailed;
    self.voices.enabled = idle;
}
- (void)refresh:(id)sender {
    (void)sender;
    if (_session.state != 0) return;
    [self.voices removeAllItems];
    // 只列出允许且已安装的两种语音，不自动下载，也不靠显示名称回查 voice。
    for (NSString *voiceID in @[@"com.apple.voice.compact.zh-CN.Tingting", @"com.apple.voice.compact.en-US.Samantha"]) {
        AVSpeechSynthesisVoice *voice = [AVSpeechSynthesisVoice voiceWithIdentifier:voiceID];
        if (voice != nil) {
            [self.voices addItemWithTitle:[NSString stringWithFormat:@"%@ · %@", voice.name, voice.language]];
            // 用户看名字，代码取稳定标识；representedObject 存选项对应的业务数据。
            self.voices.lastItem.representedObject = voice.identifier;
        }
    }
    int32_t status = cb_sender_available();
    self.deviceAvailable = status == 0;
    self.status.stringValue = status == 0 ? @"BlackHole 16ch 就绪。请在通话软件中手动选它作为麦克风。"
                                          : sender_error(status);
    if (self.voices.numberOfItems == 0) self.status.stringValue = @"未找到 Tingting 或 Samantha 语音，请先安装系统语音再刷新。";
    [self updateControls];
}
- (void)armChanged:(id)sender {
    // 取消勾选不仅禁用下一次发送，还立即停止当前任务。
    (void)sender;
    if (self.armButton.state != NSControlStateValueOn) [self stop:nil];
    [self updateControls];
}
- (BOOL)closeSender {
    // 先停轮询，再关句柄，避免下一次 timer 又查询已经释放的 sender。
    [self.timer invalidate];
    self.timer = nil;
    int32_t status = cb_sender_close(&_sender);
    if (status != 0) {
        // 释放失败不能当作干净空闲；锁住后续发送，保留上下文直到安全清理或进程退出。
        self.cleanupFailed = YES;
        self.armButton.state = NSControlStateValueOff;
        self.status.stringValue = [NSString stringWithFormat:@"设备清理失败（%d），已禁止继续发送。请退出程序。", status];
        return NO;
    }
    return YES;
}
- (void)fail:(NSString *)message {
    // 故障也必须同时撤销 Rust 代次、原生合成任务和设备输出，不只是修改提示文字。
    cb_session_cancel(&_session);
    [self.job cancel];
    self.job = nil;
    self.armButton.state = NSControlStateValueOff;
    if ([self closeSender]) self.status.stringValue = message;
    [self updateControls];
}
- (void)send:(id)sender {
    (void)sender;
    if (!self.sendButton.enabled || self.cleanupFailed) return;
    // markedText 是输入法尚未确认的候选，不能把拼音组合中的半成品意外发出去。
    if (self.editor.hasMarkedText) { self.status.stringValue = @"请先确认输入法候选文字，再点击发送。"; return; }
    NSData *text = [self.editor.string dataUsingEncoding:NSUTF8StringEncoding];
    if (text.length > 4096 || cb_session_begin(&_session, text.bytes, (uint32_t)text.length) != 0) {
        self.status.stringValue = @"请输入 1–280 个字符的非空文字。";
        return;
    }
    // 保存本次任务编号。不是完成时再读“最新编号”，否则旧结果可能冒充新任务。
    uint64_t generation = _session.generation;
    self.status.stringValue = @"正在合成语音…尚未发送，可随时停止。";
    [self updateControls];
    self.job = [[CallBridgeSpeechJob alloc] init];
    // job 持有 completion，所以 completion 弱引用控制器；执行时再临时强引用。
    __weak CallBridgeApp *weakSelf = self;
    [self.job startText:self.editor.string voice:self.voices.selectedItem.representedObject
        completion:^(NSData *pcm, NSString *error) {
            CallBridgeApp *controller = weakSelf;
            // 先挡住控制器已退出、任务被取消或已切换的情况，再处理合成结果。
            if (controller == nil || controller->_session.generation != generation || controller->_session.state != 1) return;
            if (error != nil) { [controller fail:error]; return; }
            if (cb_session_ready(&controller->_session, generation) != 0) return;
            // NSData 长度是字节；当前是单声道 float，除以 sizeof(float) 就是帧数。
            int32_t status = cb_sender_open(pcm.bytes, (uint32_t)(pcm.length / sizeof(float)), &controller->_sender);
            if (status == 0) status = cb_sender_start(controller->_sender);
            if (status != 0) { [controller fail:sender_error(status)]; return; }
            controller.lastPosition = 0;
            controller.lastAdvance = NSProcessInfo.processInfo.systemUptime;
            controller.status.stringValue = @"正在发送到 BlackHole。是否被对方听见仍需通话确认。";
            controller.timer = [NSTimer timerWithTimeInterval:0.1 target:controller selector:@selector(tick:) userInfo:nil repeats:YES];
            // CommonModes 让菜单/拖动等常见交互期间也能检查状态；timer 不负责生成声音。
            [NSRunLoop.mainRunLoop addTimer:controller.timer forMode:NSRunLoopCommonModes];
        }];
}
- (void)tick:(NSTimer *)timer {
    // 每 100 ms 在控制线程查询一次，不把设备查询塞进实时回调。
    (void)timer;
    uint32_t position = 0, done = 0;
    int32_t status = cb_sender_poll(_sender, &position, &done);
    if (status != 0) { [self fail:sender_error(status)]; return; }
    double now = NSProcessInfo.processInfo.systemUptime;
    if (position != self.lastPosition) { self.lastPosition = position; self.lastAdvance = now; }
    // 没收到错误不等于设备还在工作；进度停滞超过两秒也要退出发送状态。
    if (now - self.lastAdvance > 2) { [self fail:@"音频设备没有继续消费数据，已停止。请刷新后重试。"]; return; }
    if (done) {
        cb_session_finish(&_session, _session.generation);
        [self.job cancel];
        self.job = nil;
        if ([self closeSender]) self.status.stringValue = @"本地发送完成。请让对方确认是否完整听到；可继续发送下一句。";
        [self updateControls];
    }
}
- (void)stop:(id)sender {
    // 先让旧任务失效，再停合成/设备，并撤销允许发送，避免停止后自行续播。
    (void)sender;
    cb_session_cancel(&_session);
    [self.job cancel];
    self.job = nil;
    self.armButton.state = NSControlStateValueOff;
    if ([self closeSender]) self.status.stringValue = @"已停止。不会重播旧文字；已提交给通话软件的声音无法撤回。";
    [self updateControls];
}
- (void)buildMenu {
    // 通过系统 responder chain 提供复制、粘贴、撤销等快捷键，不自己重新实现编辑器。
    NSMenu *bar = [[NSMenu alloc] init];
    NSMenuItem *application = [[NSMenuItem alloc] init];
    [bar addItem:application];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"CallBridge"];
    [appMenu addItemWithTitle:@"退出 CallBridge" action:@selector(terminate:) keyEquivalent:@"q"];
    application.submenu = appMenu;
    NSMenuItem *editItem = [[NSMenuItem alloc] init];
    [bar addItem:editItem];
    NSMenu *edit = [[NSMenu alloc] initWithTitle:@"编辑"];
    [edit addItemWithTitle:@"撤销" action:@selector(undo:) keyEquivalent:@"z"];
    [edit addItemWithTitle:@"剪切" action:@selector(cut:) keyEquivalent:@"x"];
    [edit addItemWithTitle:@"复制" action:@selector(copy:) keyEquivalent:@"c"];
    [edit addItemWithTitle:@"粘贴" action:@selector(paste:) keyEquivalent:@"v"];
    [edit addItemWithTitle:@"全选" action:@selector(selectAll:) keyEquivalent:@"a"];
    editItem.submenu = edit;
    NSApp.mainMenu = bar;
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    // 3. 构建普通原生窗口；这里只组装控件，不自动开始合成或音频 IO。
    (void)notification;
    [self buildMenu];
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 660, 580)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"CallBridge · 文字语音演示版";
    self.window.minSize = NSMakeSize(620, 600);
    self.window.releasedWhenClosed = NO;
    // 不让 AppKit 自动恢复这个窗口；这并不等于对操作系统缓存/换页作出保密保证。
    self.window.restorable = NO;
    self.window.delegate = self;
    NSTextField *heading = [NSTextField labelWithString:@"打字，让通话另一端听见"];
    heading.font = [NSFont boldSystemFontOfSize:22];
    NSTextField *instructions = [NSTextField wrappingLabelWithString:@"仅发送合成语音，不打开真实麦克风。\n在 FaceTime / 微信中选择 BlackHole 16ch 作为麦克风，输出仍选耳机。"];
    self.voices = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.voices.accessibilityLabel = @"合成语音";
    self.refreshButton = [NSButton buttonWithTitle:@"刷新设备 / 语音" target:self action:@selector(refresh:)];
    NSStackView *options = [NSStackView stackViewWithViews:@[self.voices, self.refreshButton]];
    options.spacing = 12;
    NSScrollView *scroll = [[NSScrollView alloc] init];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    self.editor = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 600, 140)];
    // 使用系统纯文本编辑器，保留中文输入法、选区与撤销；不解析富文本内容。
    self.editor.richText = NO;
    self.editor.allowsUndo = YES;
    self.editor.font = [NSFont systemFontOfSize:17];
    self.editor.textContainerInset = NSMakeSize(10, 10);
    self.editor.autoresizingMask = NSViewWidthSizable;
    self.editor.textContainer.widthTracksTextView = YES;
    self.editor.horizontallyResizable = NO;
    self.editor.verticallyResizable = YES;
    self.editor.accessibilityLabel = @"待发送文字，最多 280 个字符";
    scroll.documentView = self.editor;
    self.armButton = [NSButton checkboxWithTitle:@"允许向 BlackHole 发送（其他监听它的程序也可能收到）"
        target:self action:@selector(armChanged:)];
    self.armButton.state = NSControlStateValueOff;
    self.sendButton = [NSButton buttonWithTitle:@"发送" target:self action:@selector(send:)];
    self.stopButton = [NSButton buttonWithTitle:@"停止" target:self action:@selector(stop:)];
    NSStackView *actions = [NSStackView stackViewWithViews:@[self.sendButton, self.stopButton]];
    actions.spacing = 12;
    self.status = [NSTextField wrappingLabelWithString:@"正在检查设备…"];
    self.status.accessibilityLabel = @"发送状态";
    NSTextField *limit = [NSTextField wrappingLabelWithString:@"每次最多 280 字符 / 30 秒。不保存文字或音频。Enter 换行，点击按钮发送。"];
    limit.textColor = NSColor.secondaryLabelColor;
    NSStackView *stack = [NSStackView stackViewWithViews:@[heading, instructions, options, scroll, self.armButton, actions, self.status, limit]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 12;
    // 使用 Auto Layout 明确约束，关闭旧式 autoresizing mask 自动生成的约束，避免冲突。
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.window.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.window.contentView.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:self.window.contentView.trailingAnchor constant:-24],
        [stack.topAnchor constraintEqualToAnchor:self.window.contentView.topAnchor constant:24],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:self.window.contentView.bottomAnchor constant:-20],
        [scroll.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [scroll.heightAnchor constraintEqualToConstant:140],
        [instructions.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [self.status.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [limit.widthAnchor constraintEqualToAnchor:stack.widthAnchor]
    ]];
    [self refresh:nil];
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:self.editor];
    [NSApp activateIgnoringOtherApps:YES];
    // 睡眠前走同一停止入口，不在唤醒后悄悄重播旧句。
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(stop:) name:NSWorkspaceWillSleepNotification object:nil];
    if (self.uiSmoke) {
        // 只检查初始布局和安全默认值；不模拟真实用户打字，也不启动音频。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [self.window.contentView layoutSubtreeIfNeeded];
            BOOL fits = YES;
            for (NSView *view in stack.arrangedSubviews) {
                NSRect bounds = [view convertRect:view.bounds toView:self.window.contentView];
                if (!NSContainsRect(self.window.contentView.bounds, bounds)) fits = NO;
            }
            BOOL passed = fits && self.window.visible && self.editor.editable && !self.sendButton.enabled
                && self.armButton.state == NSControlStateValueOff && self->_sender == NULL;
            print_report(@{ @"mode": @"ui-smoke", @"passed": @(passed), @"content_fits": @(fits), @"audio_io_started": @NO }, passed ? 0 : 1);
            [self stop:nil];
            [self.window orderOut:nil];
            exit(passed ? 0 : 1);
        });
    }
}
- (BOOL)windowShouldClose:(NSWindow *)window {
    // 点窗口关闭按钮也必须停发送，不能只隐藏可见界面。
    (void)window;
    [self stop:nil];
    return YES;
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)application {
    (void)application;
    return YES;
}
- (void)applicationWillTerminate:(NSNotification *)notification {
    // 菜单退出等路径最后仍要清理；stop 可以重复调用。
    (void)notification;
    [self stop:nil];
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
}
@end

int main(int argc, const char *argv[]) {
    // 4. 参数路由在启动 GUI 前完成；主动发送必须带 --confirm-virtual-io。
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--tts-smoke") == 0) return smoke_test(NO, NO);
        if (argc == 2 && strcmp(argv[1], "--cancel-smoke") == 0) return smoke_test(NO, YES);
        if (argc == 3 && strcmp(argv[1], "--sender-smoke") == 0 && strcmp(argv[2], "--confirm-virtual-io") == 0) return smoke_test(YES, NO);
        BOOL uiSmoke = argc == 2 && strcmp(argv[1], "--ui-smoke") == 0;
        if (argc != 1 && !uiSmoke) {
            fprintf(stderr, "usage: CallBridge [--tts-smoke | --cancel-smoke | --ui-smoke | --sender-smoke --confirm-virtual-io]\n");
            return 2;
        }
        NSApplication *application = NSApplication.sharedApplication;
        [application setActivationPolicy:NSApplicationActivationPolicyRegular];
        // 明确保持 delegate 活到 run 返回，不能因 ARC 提前结束局部变量寿命而丢失回调对象。
        __attribute__((objc_precise_lifetime)) CallBridgeApp *delegate = [[CallBridgeApp alloc] init];
        delegate.uiSmoke = uiSmoke;
        application.delegate = delegate;
        [application run];
        return 0;
    }
}

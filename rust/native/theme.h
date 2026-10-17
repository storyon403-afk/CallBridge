/*
本文件的目的：集中定义演示面板的字体、间距和尺寸，避免控件各写一套视觉参数。
使用系统颜色适应浅深外观；最小尺寸对应核心操作，不为尚未接入的模块放置假按钮。
*/
#ifndef CALLBRIDGE_THEME_H
#define CALLBRIDGE_THEME_H
#import <AppKit/AppKit.h>

static const CGFloat CBPanelPadding = 20;
static const CGFloat CBPanelSpacing = 12;
static const NSSize CBPanelMinimumSize = {520, 640};
static const NSSize CBPanelDefaultSize = {640, 700};
static const CGFloat CBVolumeLabelWidth = 86;
static inline NSFont *CBHeadingFont(void) { return [NSFont boldSystemFontOfSize:22]; }
static inline NSFont *CBEditorFont(void) { return [NSFont systemFontOfSize:17]; }
static inline NSFont *CBDetailFont(void) { return [NSFont systemFontOfSize:13]; }
static inline NSColor *CBSecondaryColor(void) { return NSColor.secondaryLabelColor; }
#endif

/*
本文件的目的：集中定义模块面板、设置窗和文字浮窗的视觉参数。
使用系统语义颜色适应浅深外观；尺寸只影响布局，不影响音频状态或实时回调。
*/
#ifndef CALLBRIDGE_THEME_H
#define CALLBRIDGE_THEME_H
#import <AppKit/AppKit.h>

static const CGFloat CBPanelPadding = 20;
static const CGFloat CBPanelSpacing = 12;
static const NSSize CBPanelMinimumSize = {280, 258};
static const NSSize CBPanelDefaultSize = {548, 408};
static const NSSize CBTextMinimumSize = {440, 400};
static const NSSize CBTextDefaultSize = {560, 440};
static const NSSize CBAudioSize = {520, 510};
static const NSSize CBMixSize = {520, 380};
static const CGFloat CBTileWidth = 236;
static const CGFloat CBTileHeight = 140;
static const CGFloat CBTileRadius = 18;
static const CGFloat CBVolumeLabelWidth = 86;
static inline NSFont *CBHeadingFont(void) { return [NSFont boldSystemFontOfSize:22]; }
static inline NSFont *CBEditorFont(void) { return [NSFont systemFontOfSize:17]; }
static inline NSFont *CBDetailFont(void) { return [NSFont systemFontOfSize:13]; }
static inline NSFont *CBTileFont(void) { return [NSFont systemFontOfSize:17 weight:NSFontWeightSemibold]; }
static inline NSFont *CBSectionFont(void) { return [NSFont systemFontOfSize:12 weight:NSFontWeightMedium]; }
static inline NSColor *CBSecondaryColor(void) { return NSColor.secondaryLabelColor; }
static inline NSColor *CBSurfaceColor(void) { return NSColor.controlBackgroundColor; }
static inline NSColor *CBWindowColor(void) {
    return [NSColor colorWithName:@"CallBridgeCanvas" dynamicProvider:^NSColor *(NSAppearance *appearance) {
        BOOL dark = [[appearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]]
            isEqual:NSAppearanceNameDarkAqua];
        return [NSColor colorWithCalibratedWhite:dark ? 0.12 : 0.96 alpha:1];
    }];
}
#endif

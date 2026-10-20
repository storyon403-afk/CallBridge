/*
本文件的目的：保存用户明确选择的设备、音色、音量、文件引用和窗口布局。
只序列化白名单，不保存草稿、PCM、播放游标、发送勾选或麦克风运行状态。
读取有界普通文件，逐项校验；写入原子替换，进程中断时不会留下半份 plist。
文件存取由 App 的串行后台队列承担，音频回调和窗口交互不等待磁盘。
*/
#import "settings.h"
#include <math.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>

static BOOL text_value(id value, NSUInteger maximum) {
    return [value isKindOfClass:NSString.class] && [value length] <= maximum
        && [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound;
}
static BOOL number_value(id value, double lower, double upper) {
    return [value isKindOfClass:NSNumber.class] && isfinite([value doubleValue])
        && [value doubleValue] >= lower && [value doubleValue] <= upper;
}
static BOOL local_path(id value) {
    return text_value(value, 4096) && ([value length] == 0 || [value isAbsolutePath]);
}

NSDictionary *CBDefaultSettings(void) {
    return @{
        @"schema_version": @1, @"voice_id": @"", @"prosody_mode": @0,
        @"send_uid": @"CallBridgeLink_UID", @"preview_uid": @"", @"microphone_uid": @"",
        @"speech_gain": @1, @"background_gain": @0.1, @"environment_gain": @0.25,
        @"background_loop": @YES, @"pin_text": @YES,
        @"background_path": @"", @"voice_preset_paths": @[], @"window_frames": @{}
    };
}

NSDictionary *CBNormalizeSettings(id value) {
    NSMutableDictionary *result = [CBDefaultSettings() mutableCopy];
    if (![value isKindOfClass:NSDictionary.class]
        || !number_value(value[@"schema_version"], 1, 1)) return result;
    // 字段允许单独失效；不能让一个坏音量覆盖其他有效选择。
    for (NSString *key in @[@"voice_id", @"preview_uid", @"microphone_uid"])
        if (text_value(value[key], 1024)) result[key] = value[key];
    if ([@[@"CallBridgeLink_UID", @"BlackHole2ch_UID", @"BlackHole16ch_UID"] containsObject:value[@"send_uid"]])
        result[@"send_uid"] = value[@"send_uid"];
    if (number_value(value[@"prosody_mode"], 0, 5)
        && floor([value[@"prosody_mode"] doubleValue]) == [value[@"prosody_mode"] doubleValue])
        result[@"prosody_mode"] = value[@"prosody_mode"];
    for (NSString *key in @[@"speech_gain", @"background_gain", @"environment_gain"])
        if (number_value(value[key], 0, 1)) result[key] = value[key];
    for (NSString *key in @[@"background_loop", @"pin_text"])
        if (number_value(value[key], 0, 1) && floor([value[key] doubleValue]) == [value[key] doubleValue])
            result[key] = @([value[key] boolValue]);
    if (local_path(value[@"background_path"])) result[@"background_path"] = value[@"background_path"];
    id paths = value[@"voice_preset_paths"];
    if ([paths isKindOfClass:NSArray.class] && [paths count] <= 64) {
        NSMutableArray *accepted = [NSMutableArray array];
        for (id path in paths)
            if (local_path(path) && [path length] > 0 && ![accepted containsObject:path]) [accepted addObject:path];
        result[@"voice_preset_paths"] = [accepted copy];
    }
    id frames = value[@"window_frames"];
    if ([frames isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *accepted = [NSMutableDictionary dictionary];
        for (NSString *key in @[@"main", @"text", @"audio", @"mix"]) {
            id frame = frames[key];
            if ([frame isKindOfClass:NSArray.class] && [frame count] == 4
                && number_value(frame[0], -1000000, 1000000) && number_value(frame[1], -1000000, 1000000)
                && number_value(frame[2], 1, 16384) && number_value(frame[3], 1, 16384))
                accepted[key] = frame;
        }
        result[@"window_frames"] = [accepted copy];
    }
    return [result copy];
}

NSURL *CBSettingsURL(void) {
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
        inDomains:NSUserDomainMask].firstObject;
    return [[support URLByAppendingPathComponent:@"CallBridge" isDirectory:YES]
        URLByAppendingPathComponent:@"settings-v1.plist"];
}

NSDictionary *CBReadSettings(NSURL *url, NSString **warning) {
    if (warning != NULL) *warning = nil;
    int descriptor = url.isFileURL ? open(url.fileSystemRepresentation,
        O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) : -1;
    if (descriptor < 0) {
        if (warning != NULL && (!url.isFileURL || errno != ENOENT)) *warning = @"无法读取上次设置，暂用默认值。";
        return CBDefaultSettings();
    }
    struct stat attributes;
    const NSUInteger maximum = 512 * 1024;
    BOOL valid = fstat(descriptor, &attributes) == 0 && S_ISREG(attributes.st_mode)
        && attributes.st_size > 0 && attributes.st_size <= (off_t)maximum;
    NSMutableData *data = [NSMutableData data];
    uint8_t block[4096];
    while (valid) {
        ssize_t count = read(descriptor, block, sizeof(block));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) { valid = NO; break; }
        if (count == 0) break;
        if (data.length + (NSUInteger)count > maximum) { valid = NO; break; }
        [data appendBytes:block length:(NSUInteger)count];
    }
    close(descriptor);
    id value = valid ? [NSPropertyListSerialization propertyListWithData:data
        options:NSPropertyListImmutable format:NULL error:NULL] : nil;
    if (![value isKindOfClass:NSDictionary.class] || !number_value(value[@"schema_version"], 1, 1)) {
        if (warning != NULL) *warning = @"上次设置损坏或版本不支持，暂用默认值；原文件未改动。";
        return CBDefaultSettings();
    }
    return CBNormalizeSettings(value);
}

BOOL CBWriteSettings(NSDictionary *settings, NSURL *url, NSString **error) {
    if (error != NULL) *error = nil;
    NSError *failure = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:CBNormalizeSettings(settings)
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:&failure];
    BOOL saved = url.isFileURL && data != nil && [NSFileManager.defaultManager
        createDirectoryAtURL:url.URLByDeletingLastPathComponent withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions: @0700} error:&failure]
        && [data writeToURL:url options:NSDataWritingAtomic error:&failure];
    if (saved) saved = [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions: @0600}
        ofItemAtPath:url.path error:&failure];
    if (!saved && error != NULL) *error = @"设置保存失败，本次仍可使用；请检查本地目录权限和磁盘空间。";
    return saved;
}

/*
本文件的目的：为内存对照与 A/B 听评共用同一套固定语料校验。
只读取本地 JSON 并调用纯 Rust 规划，不访问音色目录、不合成或播放。
*/
#import "prosody_corpus.h"
#include "prosody.h"

// 先检查整份本地语料，失败时不枚举音色、不启动 TTS；最多读取 64 KiB 加一个溢出字节。
NSDictionary *CBLoadProsodyCorpus(NSString *path) {
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    if (![attributes[NSFileType] isEqual:NSFileTypeRegular]) return nil;
    NSFileHandle *file = [NSFileHandle fileHandleForReadingFromURL:[NSURL fileURLWithPath:path] error:nil];
    NSData *data = [file readDataUpToLength:65537 error:nil];
    [file closeAndReturnError:nil];
    if (data == nil || data.length > 65536) return nil;
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![root isKindOfClass:NSDictionary.class] || ![root[@"version"] isEqual:@1]
        || ![root[@"id"] isEqual:@"callbridge-zh-v1"] || ![root[@"locale"] isEqual:@"zh-CN"]
        || ![root[@"cases"] isKindOfClass:NSArray.class] || [root[@"cases"] count] != 40) return nil;
    NSMutableSet *identifiers = [NSMutableSet set];
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789-"];
    for (id entry in root[@"cases"]) {
        if (![entry isKindOfClass:NSDictionary.class]) return nil;
        for (NSString *key in @[@"id", @"category", @"text", @"focus"]) {
            if (![entry[key] isKindOfClass:NSString.class] || [entry[key] length] == 0) return nil;
        }
        NSString *identifier = entry[@"id"];
        if (identifier.length > 64 || [identifier rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound
            || [identifiers containsObject:identifier]) return nil;
        [identifiers addObject:identifier];
        id segments = entry[@"segments"];
        if (![segments isKindOfClass:NSArray.class] || [segments count] == 0 || [segments count] > 16) return nil;
        for (id segment in segments)
            if (![segment isKindOfClass:NSString.class] || [segment length] == 0) return nil;
        if (![[segments componentsJoinedByString:@""] isEqual:entry[@"text"]]) return nil;
        NSData *text = [entry[@"text"] dataUsingEncoding:NSUTF8StringEncoding];
        if (text == nil || text.length > 4096) return nil;
        // 文字上限与控制字符规则复用 Rust，避免 NSString 的 UTF-16 长度被误当 Unicode 标量数。
        CallBridgeProsodyRequest request = {
            .text = text.bytes, .text_bytes = (uint32_t)text.length, .mode = 1,
            .voice = (const uint8_t *)"fixture.voice", .voice_bytes = 13,
            .locale = (const uint8_t *)"zh-CN", .locale_bytes = 5,
            .generation = 1, .now_ms = 0, .base_rate = 0.5f, .base_pitch = 1.0f
        };
        CallBridgeProsody *plan = cb_prosody_create(&request);
        if (plan == NULL) return nil;
        cb_prosody_destroy(plan);
    }
    return root;
}


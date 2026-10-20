/* 本文件的目的：共享固定语料读取入口；返回 ARC 管理的不可变快照，失败返回 nil。 */
#import <Foundation/Foundation.h>
NSDictionary *CBLoadProsodyCorpus(NSString *path);

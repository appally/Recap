//
//  FileUtils.m
//  SpeechDemo
//
//  Created by fangweiwei on 2020/6/16.
//  Copyright © 2020 fangweiwei. All rights reserved.
//

#import "FileUtils.h"

@implementation FileUtils

+ (NSFileHandle *)openFileForReading:(NSString *)filename inPath:(NSString *)path {
    NSString *filePath = [path stringByAppendingPathComponent:filename];
    return [NSFileHandle fileHandleForReadingAtPath:filePath];
}

+ (NSFileHandle *)openFileForWriting:(NSString *)filename inPath:(NSString *)path {
    NSString *filePath = [path stringByAppendingPathComponent:filename];
    [[NSFileManager defaultManager] createFileAtPath:filePath contents:nil attributes:nil];
    return [NSFileHandle fileHandleForUpdatingAtPath:filePath];
}

+ (BOOL)writeData:(NSData *)data toFileHandel:(NSFileHandle *)fileHandle {
    if (fileHandle && data) {
        @try {
            [fileHandle writeData:data];
        } @catch (NSException *exception) {
            NSLog(@"FileUtils, write data failed: %@", exception.description);
            return FALSE;
        }
        return TRUE;
    }
    return FALSE;
}

+ (BOOL)writeString:(NSString *)data toFileHandel:(NSFileHandle *)fileHandle {
    if (fileHandle && data) {
        @try {
            [fileHandle writeData:[data dataUsingEncoding:NSUTF8StringEncoding]];
        } @catch (NSException *exception) {
            NSLog(@"FileUtils, write data failed: %@", exception.description);
            return FALSE;
        }
        return TRUE;
    }
    return FALSE;
}

+ (BOOL)readData:(NSData **)data length:(NSUInteger)length fromFileHandel:(NSFileHandle *)fileHandle {
    if (fileHandle && data) {
        NSError *err;
        if (@available(iOS 13.0, *)) {
            *data = [fileHandle readDataUpToLength:length error:&err];
            if (err) {
                NSLog(@"FileUtils read data failed: %@.", err);
                return FALSE;
            }
        }
        return TRUE;
    }
    return FALSE;
}

+ (void)closeFile:(NSFileHandle *)filehandle {
    if (filehandle) {
        [filehandle closeFile];
    }
}

@end

//
//  FileUtils.h
//  SpeechDemo
//
//  Created by fangweiwei on 2020/6/16.
//  Copyright © 2020 fangweiwei. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface FileUtils : NSObject

+ (NSFileHandle *)openFileForReading:(NSString *)filename inPath:(NSString *)path;
+ (NSFileHandle *)openFileForWriting:(NSString *)filename inPath:(NSString *)path;
+ (BOOL)writeData:(NSData *)data toFileHandel:(NSFileHandle *)fileHandle;
+ (BOOL)writeString:(NSString *)data toFileHandel:(NSFileHandle *)fileHandle;
+ (BOOL)readData:(NSData *_Nullable*_Nullable)data length:(NSUInteger)length fromFileHandel:(NSFileHandle *)fileHandle;
+ (void)closeFile:(NSFileHandle *)filehandle;

@end

NS_ASSUME_NONNULL_END

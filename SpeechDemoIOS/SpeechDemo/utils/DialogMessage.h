//
//  DialogMessage.h
//  SpeechDemo
//
//  Created by bytedance on 2025/5/15.
//  Copyright © 2025 bytedance. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef enum {
    // 用户提问内容
    ROLE_USER,
    // 助手机器人回复内容
    ROLE_ASSISTANT,
    // 日志信息
    ROLE_LOG,
} Role;

@interface DialogMessage : NSObject
@property (assign, nonatomic) Role role;
@property (strong, nonatomic) NSString* text;
@property (assign, nonatomic) bool confirmed;
@end

NS_ASSUME_NONNULL_END

//
//  SpeechMonitor.h
//  SpeechDemo
//
//  Created by fangweiwei on 2023/3/31.
//  Copyright © 2023 fangweiwei. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SpeechMonitor : NSObject

+ (instancetype)shareInstance;

- (void)UploadDelay:(long)delay withEventName:(NSString *)eventName withServiceName:(NSString *)serviceName;

- (void)UploadMetric:(NSDictionary *)metric withServiceName:(NSString *)serviceName;

@end

NS_ASSUME_NONNULL_END

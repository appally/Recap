//
//  SpeechMonitor.m
//  SpeechDemo
//
//  Created by fangweiwei on 2023/3/31.
//  Copyright © 2023 fangweiwei. All rights reserved.
//

#import "SpeechMonitor.h"

@implementation SpeechMonitor

+ (instancetype)shareInstance {
    static SpeechMonitor* sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (void)UploadDelay:(long)delay withEventName:(NSString *)eventName withServiceName:(NSString *)serviceName {
    NSLog(@"Upload delay: %ld.", delay);
    NSMutableDictionary *metric = [[NSMutableDictionary alloc] init];
    [metric setValue:[NSNumber numberWithLong:delay] forKey:eventName];
    [self UploadMetric:metric withServiceName:serviceName];
}

- (void)UploadMetric:(NSDictionary *)metric withServiceName:(NSString *)serviceName {
    NSLog(@"%@", metric);
}

@end

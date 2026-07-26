//
//  StreamRecorder.h
//  SpeechDemo
//
//  Created by fangweiwei on 2020/9/16.
//  Copyright © 2020 fangweiwei. All rights reserved.
//

#define StreamRecorder_H

#import <Foundation/Foundation.h>
#import "AppDelegate.h"

NS_ASSUME_NONNULL_BEGIN

@interface StreamRecorder : NSObject

- (int)getSampleRate;
- (int)getChannel;
- (void)setSpeechEngine:(SpeechEngine *)engine;
- (void)setSpeechEngine:(NSString *) viewId engine:(SpeechEngine *)engine;
- (BOOL)start;
- (void)stop;

@end

NS_ASSUME_NONNULL_END


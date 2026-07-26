//
//  AppDelegate.h
//  SpeechDemo
//
//  Created by fangweiwei on 2019/12/6.
//  Copyright © 2019 fangweiwei. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "SpeechEngine.h"
#import "SpeechEngineDefines.h"
#import "SpeechResourceManager.h"

@interface AppDelegate : UIResponder <UIApplicationDelegate>

@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, readonly, strong) NSString *deviceID;

@end

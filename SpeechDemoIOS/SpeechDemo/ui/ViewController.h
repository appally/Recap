//
//  ViewController.h
//  SpeechDemo
//
//  Created by fangweiwei on 2019/12/6.
//  Copyright © 2019 fangweiwei. All rights reserved.
//

#import <UIKit/UIKit.h>

#import "AppDelegate.h"
#import "StreamRecorder.h"

@interface ViewController : UIViewController

+(void)setAppDelegate : (AppDelegate*)appDelegate;
+(AppDelegate*)getAppDelegate;

+(StreamRecorder*)getStreamRecorder;
+(NSString*)extractBundleToFilePath:(NSString*)filename;

@end


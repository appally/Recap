//
//  ViewController.m
//  SpeechDemo
//
//  Created by fangweiwei on 2019/12/6.
//  Copyright © 2019 fangweiwei. All rights reserved.
//

#import "ViewController.h"
#import <objc/runtime.h>

static AppDelegate* APP_DELEGATE = nil;
static StreamRecorder *STREAM_RECORDER = nil;

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    STREAM_RECORDER = [[StreamRecorder alloc] init];
}

+(void)setAppDelegate:(AppDelegate *)appDelegate {
    APP_DELEGATE = appDelegate;
}

+(AppDelegate*)getAppDelegate {
    return APP_DELEGATE;
}

+(StreamRecorder*)getStreamRecorder {
    return STREAM_RECORDER;
}

+(NSString*)extractBundleToFilePath:(NSString*)filename {
    NSString *bundlePath = [[NSBundle mainBundle] pathForResource:filename ofType:nil];
    if (bundlePath == nil) {
        return nil;
    }

    NSString *documentsPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    if (documentsPath == nil) {
        return nil;
    }
    
    NSString *targetPath = [documentsPath stringByAppendingPathComponent:filename];
    NSError *error = nil;
    if ([[NSFileManager defaultManager] fileExistsAtPath:targetPath]) {
        // Delete if file exists
        [[NSFileManager defaultManager] removeItemAtPath:targetPath error:&error];
        if (error) {
            NSLog(@"删除文件失败: %@", error.localizedDescription);
            return nil;
        }
    }
    [[NSFileManager defaultManager] copyItemAtPath:bundlePath toPath:targetPath error:&error];
    if (error != nil) {
        return nil;
    }
    
    return targetPath;
}

#pragma mark - Navigation

// In a storyboard-based application, you will often want to do a little preparation before navigation
- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    // Get the new view controller using [segue destinationViewController].
    // Pass the selected object to the new view controller.
    [segue destinationViewController];
}

@end

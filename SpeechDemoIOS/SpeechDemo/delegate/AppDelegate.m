//
//  AppDelegate.m
//  SpeechDemo
//
//  Created by fangweiwei on 2019/12/6.
//  Copyright © 2019 fangweiwei. All rights reserved.
//

#import "AppDelegate.h"
#import "SensitiveDefines.h"



@interface AppDelegate ()

@property(nonatomic, readwrite, strong) NSString *deviceID;

@end

@implementation AppDelegate


- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    UIDevice *device = [UIDevice currentDevice];
    self.deviceID = [[device identifierForVendor] UUIDString];
 
    // 完成网络环境等相关依赖配置，只需要调用一次。
    BOOL status = [SpeechEngine prepareEnvironment];
    if (status) {
        [self setupResourceManager];
    }
    return status;
}


- (void) setupResourceManager {
    NSLog(@"初始化模型资源管理器");
    SpeechResourceManager *speechResourceManager = [SpeechResourceManager shareInstance];
    [speechResourceManager setAppId:SDEF_APPID];
    [speechResourceManager setAppVersion:@"1.0.0"];
    [speechResourceManager setDeviceId:self.deviceID];
    [speechResourceManager setRootPath: [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"models"]];
    [speechResourceManager setOnlineModelEnable:YES];
    [speechResourceManager setup];
}

#pragma mark - UISceneSession lifecycle


- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession options:(UISceneConnectionOptions *)options  API_AVAILABLE(ios(13.0)){
    // Called when a new scene session is being created.
    // Use this method to select a configuration to create the new scene with.
    return [[UISceneConfiguration alloc] initWithName:@"Default Configuration" sessionRole:connectingSceneSession.role];
}


- (void)application:(UIApplication *)application didDiscardSceneSessions:(NSSet<UISceneSession *> *)sceneSessions  API_AVAILABLE(ios(13.0)){
    // Called when the user discards a scene session.
    // If any sessions were discarded while the application was not running, this will be called shortly after application:didFinishLaunchingWithOptions.
    // Use this method to release any resources that were specific to the discarded scenes, as they will not return.
}


@end

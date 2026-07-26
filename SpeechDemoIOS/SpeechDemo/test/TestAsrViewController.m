//
//  TestAsrViewController.m
//  SpeechDemo
//
//  Created by bytedance on 2020/9/8.
//  Copyright © 2020 fengkai.0518. All rights reserved.
//

#import "TestAsrViewController.h"

#import <AVFoundation/AVFoundation.h>

#import "AppDelegate.h"
#import "FileUtils.h"
#import "SettingsHelper.h"
#import "ViewController.h"
#import "SensitiveDefines.h"

@interface TestAsrViewController () <SpeechEngineDelegate, UITextViewDelegate>

// UI
@property (weak, nonatomic) IBOutlet UITextView *resultTextView;
@property (weak, nonatomic) IBOutlet UITextField *statusTextView;
@property (weak, nonatomic) IBOutlet UIButton *startButton;
@property (weak, nonatomic) IBOutlet UIButton *stopButton;

// Device ID: 用于定位线上问题
@property (nonatomic, strong) NSString *deviceID;
// Debug Path: 用于存放一些 SDK 相关的文件，比如模型、日志等
@property (strong, nonatomic) NSString *debugPath;

// SpeechEngine
@property (strong, nonatomic) SpeechEngine *curEngine;

// Settings
@property (strong, nonatomic) Settings *settings;

// APP 层自定义的录音机，在音频来源为 Stream 时使用
@property (weak, nonatomic) StreamRecorder *streamRecorder;

// 一些用于统计的字段
@property (nonatomic, assign) long talkingFinisheTimestamp;

// 压测相关
@property (nonatomic, assign) NSInteger stressSceneId;
@property (assign, nonatomic) BOOL stressStarted;
@property (nonatomic, strong) NSThread *testThread;
@end

@implementation TestAsrViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.startButton.enabled = TRUE;
    self.stopButton.enabled = TRUE;
    self.stressStarted = FALSE;
    self.testThread = nil;
    
    [self decorateTextView:self.resultTextView];
    [self.resultTextView setTextColor:UIColor.blackColor];
    
    [ViewController setAppDelegate:(AppDelegate *)[[UIApplication sharedApplication] delegate]];
    
    self.streamRecorder = [ViewController getStreamRecorder];
    self.settings = [[SettingsHelper shareInstance]getSettings:VIEW_TEST_ASR_STRESS];
}

- (void)viewDidDisappear:(BOOL)animated {
    [self uninitEngine];
    [super viewDidDisappear:animated];
}

- (void)decorateTextView:(UITextView *)textView {
    textView.layer.cornerRadius = 5.0f;
    textView.layer.borderWidth = .25f;
    textView.layer.borderColor = [UIColor grayColor].CGColor;
}

#pragma mark - Config & Init & Uninit Methods

-(void)configInitParams{
    //【必需配置】Engine Name
    [self.curEngine setStringParam:SE_ASR_ENGINE forKey:SE_PARAMS_KEY_ENGINE_NAME_STRING];
    
    //【可选配置】Debug & Log
    [self.curEngine setStringParam:self.debugPath forKey:SE_PARAMS_KEY_DEBUG_PATH_STRING];
    [self.curEngine setStringParam:SE_LOG_LEVEL_DEBUG forKey:SE_PARAMS_KEY_LOG_LEVEL_STRING];

    //【可选配置】UID & deviceID: 用于定位线上问题
    [self.curEngine setStringParam:SDEF_UID forKey:SE_PARAMS_KEY_UID_STRING];
    [self.curEngine setStringParam:self.deviceID forKey:SE_PARAMS_KEY_DEVICE_ID_STRING];
    
    //【必需配置】配置音频来源
    [self.curEngine setStringParam:[self.settings getOptionsValue:SETTING_RECORD_TYPE] forKey:SE_PARAMS_KEY_RECORDER_TYPE_STRING];
    
    if ([self.settings getBool:SETTING_ASR_RECORDER_SAVE]) {
        //【可选配置】录音文件保存路径，如配置，SDK会将录音保存到该路径下，文件格式为 .wav
        [self.curEngine setStringParam:self.debugPath forKey:SE_PARAMS_KEY_ASR_REC_PATH_STRING];
    }
    
    // 当音频来源为 RECORDER_TYPE_STREAM 时，如输入音频采样率不等于 16K，需添加如下配置
    if ([self.settings getOptionsValue:SETTING_RECORD_TYPE] == SE_RECORDER_TYPE_STREAM) {
        if ([self.streamRecorder getSampleRate] != 16000) {
            // 当音频来源为 RECORDER_TYPE_STREAM 时【必需配置】，否则【无需配置】
            // 启用 SDK 内部的重采样
            [self.curEngine setBoolParam:TRUE forKey:SE_PARAMS_KEY_ENABLE_RESAMPLER_BOOL];
            // 将重采样所需的输入采样率设置为 APP 层输入的音频的实际采样率
            [self.curEngine setIntParam:[self.streamRecorder getSampleRate] forKey:SE_PARAMS_KEY_CUSTOM_SAMPLE_RATE_INT];
        }
    }
    
    NSString *address = [self.settings getString:SETTING_ADDRESS];
    if (!address.length) {
        address = SDEF_DEFAULT_ADDRESS;
    }
    NSLog(@"Current address: %@", address);
    //【必需配置】识别服务域名
    [self.curEngine setStringParam:address forKey:SE_PARAMS_KEY_ASR_ADDRESS_STRING];
    
    NSString *uri = [self.settings getString:SETTING_URI];
    if (!uri.length) {
        uri = SDEF_ASR_DEFAULT_URI;
    }
    NSLog(@"Current uri: %@", uri);
    //【必需配置】识别服务Uri
    [self.curEngine setStringParam:uri forKey:SE_PARAMS_KEY_ASR_URI_STRING];
    
    NSString* appID = [self.settings getString:SETTING_APPID];
    //【必需配置】鉴权相关：Appid
    [self.curEngine setStringParam:appID.length <= 0 ? SDEF_APPID : appID forKey:SE_PARAMS_KEY_APP_ID_STRING];
    //【必需配置】鉴权相关：Token
    NSString* token = [self.settings getString:SETTING_TOKEN];
    [self.curEngine setStringParam:token.length <= 0 ? SDEF_TOKEN : token forKey:SE_PARAMS_KEY_APP_TOKEN_STRING];

    NSString* cluster = [self.settings getString:SETTING_CLUSTER];
    NSLog(@"Current cluster: %@", cluster);
    //【必需配置】识别服务所用集群
    [self.curEngine setStringParam:cluster.length <= 0 ? SDEF_ASR_DEFAULT_CLUSTER : cluster forKey:SE_PARAMS_KEY_ASR_CLUSTER_STRING];
    
    //【可选配置】在线请求的建连与接收超时，一般不需配置使用默认值即可
    [self.curEngine setIntParam:3000 forKey:SE_PARAMS_KEY_ASR_CONN_TIMEOUT_INT];
    [self.curEngine setIntParam:5000 forKey:SE_PARAMS_KEY_ASR_RECV_TIMEOUT_INT];
    
    NSString* recPath = @"";
    if ([self.settings getBool:SETTING_RECORD_SAVE]) {
        recPath = self.debugPath;
    }
    [self.curEngine setStringParam:recPath forKey:SE_PARAMS_KEY_REC_PATH_STRING];
    [self.curEngine setIntParam:[self.settings getOptions:SETTING_RECORD_FILE_TYPE].chooseIdx forKey:SE_PARAMS_KEY_REC_FILE_TYPE_INT];
}

-(void)configStartAsrParams{
    //【可选配置】控制识别结果的配置
    [self.curEngine setBoolParam:[self.settings getBool:SETTING_ASR_ENABLE_DDC] forKey:SE_PARAMS_KEY_ASR_ENABLE_DDC_BOOL];
    [self.curEngine setBoolParam:[self.settings getBool:SETTING_ASR_ENABLE_ITN] forKey:SE_PARAMS_KEY_ASR_ENABLE_ITN_BOOL];
    [self.curEngine setBoolParam:[self.settings getBool:SETTING_ASR_ENABLE_NLU_PUNC] forKey:SE_PARAMS_KEY_ASR_SHOW_NLU_PUNC_BOOL];
    
    //【可选配置】控制识别结果返回的形式，全量返回或增量返回，默认为全量
    [self.curEngine setStringParam:[self.settings getOptionsValue:SETTING_ASR_RESULT_TYPE] forKey:SE_PARAMS_KEY_ASR_RESULT_TYPE_STRING];

    //【可选配置】控制 ASR 中的 VAD 模块的阈值的配置
    [self.curEngine setIntParam:[self.settings getInt:SETTING_ASR_VAD_START_SILENCE_TIME] forKey:SE_PARAMS_KEY_ASR_VAD_START_SILENCE_TIME_INT];
    [self.curEngine setIntParam:[self.settings getInt:SETTING_ASR_VAD_END_SILENCE_TIME] forKey:SE_PARAMS_KEY_ASR_VAD_END_SILENCE_TIME_INT];
    [self.curEngine setStringParam:[self.settings getString:SETTING_ASR_VAD_MODE] forKey:SE_PARAMS_KEY_ASR_VAD_MODE_STRING];
    //【可选配置】用户音频输入最大时长，仅一句话识别场景生效，单位毫秒，默认为 150000ms.
    [self.curEngine setIntParam:[self.settings getInt:SETTING_VAD_MAX_SPEECH_DURATION] forKey:SE_PARAMS_KEY_VAD_MAX_SPEECH_DURATION_INT];
    
    //【可选配置】控制是否返回录音音量，在 APP 需要显示音频波形时可以启用
    [self.curEngine setBoolParam:[self.settings getBool:SETTING_GET_VOLUME] forKey:SE_PARAMS_KEY_ENABLE_GET_VOLUME_BOOL];
    
    //【可选配置】更新 ASR 热词
    if ([self.settings getString:SETTING_ASR_HOTWORDS].length != 0) {
        [self setHotWords:[self.settings getString:SETTING_ASR_HOTWORDS]];
    }
    
    if ([self.settings getOptionsValue:SETTING_RECORD_TYPE] == SE_RECORDER_TYPE_STREAM) {
        if (![self.streamRecorder start]) {
            [self speechEngineNoPermission];
        }
    } else if ([self.settings getOptionsValue:SETTING_RECORD_TYPE] == SE_RECORDER_TYPE_FILE) {
        // 使用音频文件识别时，需要设置文件的绝对路径
        NSString* file_path = [NSString stringWithFormat:@"%@/%@", self.debugPath, @"asr_rec_file.pcm"];
        NSLog(@"输入的音频文件路径: %@", file_path);
        // 使用音频文件识别时【必须配置】，否则【无需配置】
        [self.curEngine setStringParam:file_path forKey:SE_PARAMS_KEY_RECORDER_FILE_STRING];
    }
}

- (void)setHotWords:(NSString*) hotWords {
    [self.curEngine sendDirective:SEDirectiveUpdateAsrHotWords data: hotWords];
}

- (void)initEngine {
    NSLog(@"获取设备ID，调试使用");
    AppDelegate *appDelegate = [ViewController getAppDelegate];
    if (appDelegate == nil) {
        appDelegate = (AppDelegate *)[[UIApplication sharedApplication] delegate];
    }
    [ViewController setAppDelegate:appDelegate];
    self.deviceID = appDelegate.deviceID;
    if ([self.deviceID isEqualToString:@""]) {
        self.deviceID = @"speech_test_123";
    }
    NSLog(@"获取设备ID成功: %@", self.deviceID);
    
    
    NSLog(@"创建引擎");
    if (self.curEngine == nil) {
        self.curEngine = [[SpeechEngine alloc] init];
        if (![self.curEngine createEngineWithDelegate:self]) {
            NSLog(@"引擎创建失败.");
            return;
        }
    }
    NSLog(@"SDK 版本号: %@", [self.curEngine getVersion]);
    
    self.debugPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSLog(@"当前调试路径: %@", self.debugPath);
    
    NSLog(@"配置初始化参数");
    [self configInitParams];
    
    NSLog(@"引擎初始化");
    SEEngineErrorCode ret = [self.curEngine initEngine];
    if (ret == SENoError) {
        NSLog(@"初始化成功");
    } else {
        NSLog(@"初始化失败，返回值: %d", ret);
    }
}

- (void)uninitEngine {
    if (self.curEngine != nil) {
        NSLog(@"引擎析构");
        [self.curEngine destroyEngine];
        self.curEngine = nil;
        NSLog(@"引擎析构完成");
    }
}

- (void)startEngine {
    NSLog(@"配置启动参数");
    [self configStartAsrParams];

    //【可选配置】是否启用云端自动判停，仅一句话识别场景生效
    NSLog(@"开启 ASR 云端自动判停");
    [self.curEngine setBoolParam:TRUE forKey:SE_PARAMS_KEY_ASR_AUTO_STOP_BOOL];
    
    NSLog(@"启用引擎.");
    NSLog(@"Directive: SEDirectiveStartEngine");
    SEEngineErrorCode ret = [self.curEngine sendDirective:SEDirectiveStartEngine];
    if (ret == SERecCheckEnvironmentFailed) {
        [self speechEngineNoPermission];
    }
}

- (void)stopEngine {
    NSLog(@"异步关闭引擎");
    NSLog(@"Directive: SEDirectiveStopEngine");
    [self.curEngine sendDirective:SEDirectiveStopEngine];
}

- (void)syncStopEngine {
    NSLog(@"同步关闭引擎");
    NSLog(@"Directive: SEDirectiveStopEngine");
    [self.curEngine sendDirective:SEDirectiveSyncStopEngine];
}

- (void)finishTalking {
    NSLog(@"结束音频输入");
    NSLog(@"Directive: SEDirectiveFinishTalking");
    [self.curEngine sendDirective:SEDirectiveFinishTalking];
}

- (void)speechEngineNoPermission {
    NSLog(@"没有音频权限");
}

- (void)sleep:(NSTimeInterval)ti {
    [NSThread sleepForTimeInterval:ti];
}

- (int)getRandomValue:(int)a andData:(int)b {
    return (arc4random() % (b + 1)) + a;
}

- (void)testScene0 {
    [self initEngine];
    while (self.stressStarted) {
        [self syncStopEngine];
        [self startEngine];
        [self sleep:[self getRandomValue:0 andData:3]];
        if ([self getRandomValue:0 andData:1] == 0) {
            [self finishTalking];
        } else {
            [self stopEngine];
        }
        [self sleep:[self getRandomValue:0 andData:3]];
    }
    [self uninitEngine];
}

- (void)testScene1 {
    while (self.stressStarted) {
        [self initEngine];
        [self syncStopEngine];
        [self startEngine];
        [self sleep:[self getRandomValue:0 andData:3]];
        if ([self getRandomValue:0 andData:1] == 0) {
            [self finishTalking];
        } else {
            [self stopEngine];
        }
        [self sleep:[self getRandomValue:0 andData:3]];
        [self uninitEngine];
    }
}

- (void)testScene2 {
    while (self.stressStarted) {
        [self initEngine];
        [self syncStopEngine];
        [self startEngine];
        [self sleep:1];
        [self finishTalking];
        [self sleep:2];
        [self uninitEngine];
    }
}

- (void)testScene3 {
    [self initEngine];
    while (self.stressStarted) {
        int method = [self getRandomValue:0 andData:4];
        switch (method) {
            case 0:
                [self startEngine];
                break;
            case 1:
                [self syncStopEngine];
                break;
            case 2:
                [self stopEngine];
                break;
            case 3:
                [self finishTalking];
                break;
            case 4:
                [self uninitEngine];
                [self initEngine];
                break;
        }
        [self sleep:[self getRandomValue:0 andData:5]];
    }
    [self uninitEngine];
}

- (void)test {
    NSString* sceneid = [self.settings getOptionsValue:SETTING_ASR_STRESS_SCENEID];
    NSArray* sceneType = @[@"正常场景1", @"正常场景2", @"ERROR回调时析构", @"随机压测"];
    self.stressSceneId = [sceneType indexOfObject:sceneid];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString* str = [@"开始压测 " stringByAppendingString:sceneType[self.stressSceneId]];
        [self setResultText:str];
    });
    switch (self.stressSceneId) {
        case 0:
            [self testScene0];
            break;
        case 1:
            [self testScene1];
            break;
        case 2:
            [self testScene2];
            break;
        case 3:
            [self testScene3];
            break;
        default:
            break;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString* str = [@"压测结束 " stringByAppendingString:sceneType[self.stressSceneId]];
        [self setResultText:str];
    });
}

#pragma mark - UI Actions

- (IBAction)startBtnClicked:(id)sender {
    if (self.testThread) {
        if (self.testThread.executing) {
            NSLog(@"Already start!");
            return;
        }
        [self.testThread cancel];
        self.testThread = nil;
    }
    self.stressStarted = TRUE;
    self.testThread = [[NSThread alloc] initWithTarget:self selector:@selector(test) object:nil];
    [self.testThread start];
    
}

- (IBAction)stopBtnClicked:(id)sender {
    if (!self.testThread) {
        NSLog(@"Not start yet!");
        return;
    }
    self.stressStarted = FALSE;
}

#pragma mark - Message Callback

- (void)onMessageWithType:(SEMessageType)type andData:(NSData *)data {
    NSLog(@"Message Type: %d.", type);
    switch (type) {
        case SEEngineStart:
            // Callback: 引擎启动成功回调
            NSLog(@"Callback: 引擎启动成功");
            break;
        case SEEngineStop:
            // Callback: 引擎关闭回调
            NSLog(@"Callback: 引擎关闭");
            break;
        case SEEngineError:
            // Callback: 错误信息回调
            NSLog(@"Callback: 错误信息: %@", data);
            [self speechEngineError:data];
            break;
        case SEAsrPartialResult:
            // Callback: ASR 当前请求的部分结果回调
            NSLog(@"Callback: ASR 当前请求的部分结果");
            break;
        case SEFinalResult:
            // Callback: ASR 当前请求最终结果回调
            NSLog(@"Callback: ASR 当前请求最终结果");
            [self speechEngineResult:data isFinal:true];
            break;
        case SEVolumeLevel:
            // Callback: 录音音量回调
            NSLog(@"Callback: 录音音量");
            break;
        default:
            break;
    }
}

- (void)speechEngineError:(NSData *)data {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.stressSceneId == 2) {
            if ([self getRandomValue:0 andData:1] == 0) {
                [self stopEngine];
            }
            [self uninitEngine];
        }
    });
}

- (void)speechEngineResult:(NSData *)data isFinal:(BOOL)isFinal {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (isFinal && self.stressSceneId == 2) {
            if ([self getRandomValue:0 andData:1] == 0) {
                [self stopEngine];
            }
            [self uninitEngine];
        }
    });
}

#pragma mark - Helper

- (NSString *)getRecorderType {
    SettingOptions* recorderTypeOptions = [self.settings getOptions:SETTING_RECORD_TYPE];
    switch (recorderTypeOptions.chooseIdx) {
        case 0:
            return SE_RECORDER_TYPE_RECORDER;
        case 1:
            return SE_RECORDER_TYPE_FILE;
        case 2:
            return SE_RECORDER_TYPE_STREAM;
        default:
            break;
    }
    return @"";
}

- (void)setResultText:(NSString *)result {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.resultTextView setText:[result stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
    });
}

- (long)timeDelayFrom:(long)pastTimestamp {
    return [[NSDate date] timeIntervalSince1970] * 1000 - pastTimestamp;
}

#pragma mark - UITextViewDelegate

- (BOOL)textView:(UITextView *)textView shouldChangeTextInRange:(NSRange)range replacementText:(NSString *)text {
    if([text isEqualToString:@"\n"]) {
        [textView resignFirstResponder];
        return NO;
    }
    return YES;
}

#pragma mark - Navigation

// In a storyboard-based application, you will often want to do a little preparation before navigation
- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    // Get the new view controller using [segue destinationViewController].
    // Pass the selected object to the new view controller.
    id nextPage = [segue destinationViewController];
    [nextPage setValue:VIEW_TEST_ASR_STRESS forKey:@"viewId"];
}

@end

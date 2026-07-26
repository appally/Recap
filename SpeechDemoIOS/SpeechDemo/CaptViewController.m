//
//  CaptViewController.m
//  SpeechDemo
//
//  Created by bytedance on 2020/9/8.
//  Copyright © 2020 fengkai.0518. All rights reserved.
//

#import "CaptViewController.h"

#import <AVFoundation/AVFoundation.h>

#import "AppDelegate.h"
#import "FileUtils.h"
#import "SettingsHelper.h"
#import "ViewController.h"
#import "SensitiveDefines.h"

@interface CaptViewController () <SpeechEngineDelegate, UITextViewDelegate>

@property (weak, nonatomic) IBOutlet UITextView *referTextView;
@property (weak, nonatomic) IBOutlet UITextView *resultTextView;
@property (weak, nonatomic) IBOutlet UITextField *statusTextView;
@property (weak, nonatomic) IBOutlet UIButton *engineInitButton;
@property (weak, nonatomic) IBOutlet UIButton *engineUninitButton;
@property (weak, nonatomic) IBOutlet UIButton *startEngineButton;
@property (weak, nonatomic) IBOutlet UIButton *stopEngineButton;
@property (weak, nonatomic) IBOutlet UIButton *longPressButton;

@property (strong, nonatomic) SpeechEngine *curEngine;
@property (assign, nonatomic) BOOL engineStarted;

// Device ID: 用于定位线上问题
@property (nonatomic, strong) NSString *deviceID;
// 一些用于统计的字段
@property (nonatomic, assign) long talkingFinisheTimestamp;
// Debug Path: 用于存放一些 SDK 相关的文件，比如模型、日志等
@property (strong, nonatomic) NSString *debugPath;
// APP 层自定义的录音机，在音频来源为 Stream 时使用
@property (weak, nonatomic) StreamRecorder *streamRecorder;

// settings
@property (strong, nonatomic) Settings *settings;

@end

@implementation CaptViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.engineInitButton.enabled = TRUE;
    self.engineUninitButton.enabled = FALSE;
    self.startEngineButton.enabled = FALSE;
    self.stopEngineButton.enabled = FALSE;
    self.longPressButton.enabled = FALSE;
    
    [self decorateTextView:self.referTextView];
    [self decorateTextView:self.resultTextView];
    [self.referTextView setDelegate:self];
    self.referTextView.editable = TRUE;
    [self.statusTextView setText:@"Waiting for init."];
    
    [ViewController setAppDelegate:(AppDelegate *)[[UIApplication sharedApplication] delegate]];
    UILongPressGestureRecognizer *longPgr = [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                                                          action:@selector(recordTriggered:)];
    longPgr.minimumPressDuration = 0.5;
    [self.longPressButton addGestureRecognizer:longPgr];
    
    self.streamRecorder = [ViewController getStreamRecorder];
    self.engineStarted = FALSE;
    self.settings = [[SettingsHelper shareInstance]getSettings:VIEW_CAPT];
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
    [self.curEngine setStringParam:SE_CAPT_ENGINE forKey:SE_PARAMS_KEY_ENGINE_NAME_STRING];
    //【可选配置】Debug & Log
    [self.curEngine setStringParam:self.debugPath forKey:SE_PARAMS_KEY_DEBUG_PATH_STRING];
    [self.curEngine setStringParam:SE_LOG_LEVEL_DEBUG forKey:SE_PARAMS_KEY_LOG_LEVEL_STRING];
    //【可选配置】UID: 用于定位线上问题
    [self.curEngine setStringParam:SDEF_UID forKey:SE_PARAMS_KEY_UID_STRING];
    
    //【必需配置】配置音频来源
    [self.curEngine setStringParam:[self getRecorderType] forKey:SE_PARAMS_KEY_RECORDER_TYPE_STRING];
    
    if ([self.settings getBool:SETTING_CAPT_RECORDER_SAVE]) {
        //【可选配置】录音文件保存路径，如配置，SDK会将录音保存到该路径下，文件格式为 .wav
        [self.curEngine setStringParam:self.debugPath forKey:SE_PARAMS_KEY_CAPT_REC_PATH_STRING];
    }
    
    // 当音频来源为 RECORDER_TYPE_STREAM 时，如输入音频采样率不等于 16K，需添加如下配置
    if ([[self getRecorderType] isEqualToString:SE_RECORDER_TYPE_STREAM]) {
        if ([self.streamRecorder getSampleRate] != 16000) {
            // 当音频来源为 RECORDER_TYPE_STREAM 时【必需配置】，否则【无需配置】
            // 启用 SDK 内部的重采样
            [self.curEngine setBoolParam:TRUE forKey:SE_PARAMS_KEY_ENABLE_RESAMPLER_BOOL];
            // 将重采样所需的输入采样率设置为 APP 层输入的音频的实际采样率
            [self.curEngine setIntParam:[self.streamRecorder getSampleRate] forKey:SE_PARAMS_KEY_CUSTOM_SAMPLE_RATE_INT];
        }
    }
    
    //【必需配置】鉴权相关：Appid
    NSString* appID = [self.settings getString:SETTING_APPID];
    [self.curEngine setStringParam:appID.length <= 0 ? SDEF_APPID : appID forKey:SE_PARAMS_KEY_APP_ID_STRING];
    //【必需配置】鉴权相关：Token
    NSString* token = [self.settings getString:SETTING_TOKEN];
    [self.curEngine setStringParam:token.length <= 0 ? SDEF_TOKEN : token forKey:SE_PARAMS_KEY_APP_TOKEN_STRING];

    NSString *address = [self.settings getString:SETTING_ADDRESS];
    if (!address.length) {
        address = SDEF_DEFAULT_ADDRESS;
    }
    NSLog(@"Current address: %@", address);
    //【必需配置】评测服务域名
    [self.curEngine setStringParam:address forKey:SE_PARAMS_KEY_CAPT_ADDRESS_STRING];
    NSString *uri = [self.settings getString:SETTING_URI];
    if (!uri.length) {
        uri = SDEF_CAPT_DEFAULT_MDD_URI;
    }
    NSLog(@"Current uri: %@", uri);
    //【必需配置】评测服务Uri
    [self.curEngine setStringParam:uri forKey:SE_PARAMS_KEY_CAPT_URI_STRING];
    NSString* cluster = [self.settings getString:SETTING_CLUSTER];
    if (!cluster.length) {
        cluster = SDEF_CAPT_DEFAULT_CLUSTER;
    }
    NSLog(@"Current cluster: %@", cluster);
    //【必需配置】评测服务所用集群
    [self.curEngine setStringParam:cluster forKey:SE_PARAMS_KEY_CAPT_CLUSTER_STRING];
    
    //【可选配置】在线请求的建连与接收超时，一般不需配置使用默认值即可
    [self.curEngine setIntParam:12000 forKey:SE_PARAMS_KEY_CAPT_CONN_TIMEOUT_INT];
    [self.curEngine setIntParam:8000 forKey:SE_PARAMS_KEY_CAPT_RECV_TIMEOUT_INT];
}

-(void)configStartParams{
    NSString* text = self.referTextView.text;
    if (text.length < 1) {
        text = @"Write down the reference text here";
    }
    //【必需配置】评测参考文本
    [self.curEngine setStringParam:text forKey:SE_PARAMS_KEY_CAPT_REFER_TEXT_STRING];

    
    //【可选配置】默认为英文打分，如果需要中文需要设置为SE_CAPT_CORE_TYPE_CN_SENT_RAW
    [self.curEngine setStringParam:[self getCoreType] forKey:SE_PARAMS_KEY_CAPT_CORE_TYPE_STRING];
    
    NSInteger difficultyLevel = [self.settings getInt:SETTING_CAPT_DIFFICULTY_LEVEL];
    //【可选配置】评测难度，默认2，1：容易，2：中等，3：困难
    [self.curEngine setIntParam:difficultyLevel forKey:SE_PARAMS_KEY_CAPT_DIFFICULTY_INT];
    
    NSString *responseMode = SE_CAPT_RESPONSE_MODE_ONCE;
    if ([self.settings getBool:SETTING_CAPT_STREAMING_MODE]) {
        responseMode = SE_CAPT_RESPONSE_MODE_STREAMING;
    }
    //【可选配置】控制评测结果返回形式，默认是SE_CAPT_RESPONSE_MODE_ONCE单次返回，如果需要流式返回请设置为SE_CAPT_RESPONSE_MODE_STREAMING
    [self.curEngine setStringParam:responseMode forKey:SE_PARAMS_KEY_CAPT_RESPONSE_MODE_STRING];
    
    //【可选配置】是否启用云端自动判停
    [self.curEngine setBoolParam:TRUE forKey:SE_PARAMS_KEY_CAPT_AUTO_STOP_BOOL];
    
    //【可选配置】控制是否返回录音音量，在 APP 需要显示音频波形时可以启用
    [self.curEngine setBoolParam:[self.settings getBool:SETTING_GET_VOLUME]
                          forKey:SE_PARAMS_KEY_ENABLE_GET_VOLUME_BOOL];
    //【可选配置】用户音频输入最大时长，单位毫秒，默认为 150000ms.
    [self.curEngine setIntParam:[self.settings getInt:SETTING_VAD_MAX_SPEECH_DURATION] forKey:SE_PARAMS_KEY_VAD_MAX_SPEECH_DURATION_INT];
    
    if ([[self getRecorderType] isEqualToString:SE_RECORDER_TYPE_STREAM]) {
        if (![self.streamRecorder start]) {
            [self speechEngineNoPermission];
        }
    } else if ([[self getRecorderType] isEqualToString:SE_RECORDER_TYPE_FILE]) {
        // 使用音频文件评测时，需要设置文件的绝对路径
        NSString* file_path = [NSString stringWithFormat:@"%@/%@", self.debugPath, @"capt_rec_file.pcm"];
        NSLog(@"输入的音频文件路径: %@", file_path);
        // 使用音频文件评测时【必须配置】，否则【无需配置】
        [self.curEngine setStringParam:file_path forKey:SE_PARAMS_KEY_RECORDER_FILE_STRING];
    }
}

#pragma mark - Init Methods

- (void)initEngine {
    NSLog(@"获取设备ID，调试使用");
    AppDelegate *appDelegate = [ViewController getAppDelegate];
    if (appDelegate == nil) {
        appDelegate = (AppDelegate *)[[UIApplication sharedApplication] delegate];
    }
    [ViewController setAppDelegate:appDelegate];
    self.deviceID = appDelegate.deviceID;
    NSLog(@"获取设备ID成功: %@", self.deviceID);
    

    NSLog(@"创建引擎");
    if (self.curEngine == nil) {
        self.curEngine = [[SpeechEngine alloc] init];
    }
    if (![self.curEngine createEngineWithDelegate:self]) {
        NSLog(@"引擎创建失败.");
        return;
    }

    [self.resultTextView setTextColor:UIColor.blackColor];
    NSLog(@"SDK 版本号: %@", [self.curEngine getVersion]);
    
    self.debugPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSLog(@"当前调试路径: %@", self.debugPath);
    
    NSLog(@"配置初始化参数");
    [self configInitParams];
    
    NSLog(@"引擎初始化");
    SEEngineErrorCode ret = [self.curEngine initEngine];
    if (ret == SENoError) {
        NSLog(@"初始化成功");
        [self speechEngineInitSucceeded];
    } else {
        NSLog(@"初始化失败，返回值: %d", ret);
        [self speechEngineInitFailed];
    }
}

- (NSString *)getRecorderType {
    switch ([self.settings getOptions:SETTING_RECORD_TYPE].chooseIdx) {
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

- (NSString *)getCoreType {
    switch ([self.settings getOptions:SETTING_CAPT_CORE_TYPE].chooseIdx) {
        case 0:
            return SE_CAPT_CORE_TYPE_EN_SENT_SCORE;
        case 1:
            return SE_CAPT_CORE_TYPE_EN_WORD_SCORE;
        case 2:
            return SE_CAPT_CORE_TYPE_EN_WORD_PRON;
        case 3:
            return SE_CAPT_CORE_TYPE_CN_SENT_RAW;
        default:
            break;
    }
    return @"";
}

- (void)uninitEngine {
    [self.curEngine destroyEngine];
    self.curEngine = nil;
}

#pragma mark - UI Actions

- (IBAction)initEngineBtnClicked:(id)sender {
    [self initEngine];
}

- (IBAction)uninitEngineBtnClicked:(id)sender {
    if (self.engineStarted) {
        [self.statusTextView setText:@"Engine is busy, stop it first!"];
        return;
    }
    [self uninitEngine];
    [self.statusTextView setText:@"Waiting for init."];
    self.startEngineButton.enabled = FALSE;
    self.stopEngineButton.enabled = FALSE;
    self.longPressButton.enabled = FALSE;
    self.engineInitButton.enabled = TRUE;
    self.engineUninitButton = FALSE;
}

- (IBAction)startEngineBtnClicked:(id)sender {
    [self setResultText:@""];
    
    NSLog(@"配置启动参数");
    [self configStartParams];

    //【可选配置】是否启用云端自动判停
    NSLog(@"开启 CAPT 云端自动判停");
    [self.curEngine setBoolParam:TRUE forKey:SE_PARAMS_KEY_CAPT_AUTO_STOP_BOOL];
    
    // Directive：启动引擎前调用SYNC_STOP指令，保证前一次请求结束。
    NSLog(@"Directive: SEDirectiveSyncStopEngine");
    SEEngineErrorCode ret = [self.curEngine sendDirective:SEDirectiveSyncStopEngine];
    if (ret != SENoError) {
        NSLog(@"Send directive syncstop failed: %d", ret);
    } else {
        NSLog(@"启用引擎.");
        NSLog(@"Directive: SEDirectiveStartEngine");
        SEEngineErrorCode ret = [self.curEngine sendDirective:SEDirectiveStartEngine];
        if (ret == SERecCheckEnvironmentFailed) {
            [self speechEngineNoPermission];
        }
    }
}

- (IBAction)stopEngineBtnClicked:(id)sender {
    NSLog(@"关闭引擎");
    NSLog(@"Directive: SEDirectiveStopEngine");
    [self.curEngine sendDirective:SEDirectiveStopEngine];
}

- (void)recordTriggered:(UILongPressGestureRecognizer *)longPgr {
    if (longPgr.state == UIGestureRecognizerStateBegan) {
        [self setResultText:@""];
        
        NSLog(@"配置启动参数");
        [self configStartParams];
        
        //【可选配置】是否启用云端自动判停
        NSLog(@"关闭 CAPT 云端自动判停");
        [self.curEngine setBoolParam:FALSE forKey:SE_PARAMS_KEY_CAPT_AUTO_STOP_BOOL];
        
        // Directive：启动引擎前调用SYNC_STOP指令，保证前一次请求结束。
        NSLog(@"Directive: SEDirectiveSyncStopEngine");
        SEEngineErrorCode ret = [self.curEngine sendDirective:SEDirectiveSyncStopEngine];
        if (ret != SENoError) {
            NSLog(@"Send directive syncstop failed: %d", ret);
        } else {
            // Directive：启动引擎指令。
            NSLog(@"Directive: SEDirectiveStartEngine");
            SEEngineErrorCode ret = [self.curEngine sendDirective:SEDirectiveStartEngine];
            if (ret == SERecCheckEnvironmentFailed) {
                [self speechEngineNoPermission];
            }
        }
    } else if (longPgr.state == UIGestureRecognizerStateEnded) {
        self.talkingFinisheTimestamp = [[NSDate date] timeIntervalSince1970] * 1000;
        // Directive：结束音频输入。
        NSLog(@"Directive: SEDirectiveFinishTalking");
        [self.curEngine sendDirective:SEDirectiveFinishTalking];
        if ([[self getRecorderType] isEqualToString:SE_RECORDER_TYPE_STREAM]) {
            [self.streamRecorder stop];
        }
    }
}

#pragma mark - SpeechEngineDelegate

- (void)onMessageWithType:(SEMessageType)type andData:(NSData *)data {
    NSLog(@"Message Type: %d.", type);
    switch (type) {
        case SEEngineStart:
            // Callback: 引擎启动成功回调
            NSLog(@"Callback: 引擎启动成功");
            [self speechEngineStarted];
            break;
        case SEEngineStop:
            // Callback: 引擎关闭回调
            NSLog(@"Callback: 引擎关闭");
            [self speechEngineStopped];
            break;
        case SEEngineError:
            // Callback: 错误信息回调
            NSLog(@"Callback: 错误信息: %@", data);
            [self speechEngineError:data];
            break;
        case SEAsrPartialResult:
            // Callback: Capt 当前请求的部分结果回调，只有设置SE_PARAMS_KEY_CAPT_RESPONSE_MODE_STRING为SE_CAPT_RESPONSE_MODE_STREAMING时才会回调该消息
            NSLog(@"Callback: Capt 当前请求的部分结果");
            break;
        case SEFinalResult:
            // Callback: Capt 最终评测结果回调
            NSLog(@"Callback: Capt 最终评测结果");
            [self speechEngineResult:data];
            break;
        case SEVolumeLevel:
            // Callback: 录音音量回调
            NSLog(@"Callback: 录音音量");
            break;
        default:
            break;
    }
}

#pragma mark - Engine Callback

- (void)speechEngineNoPermission {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self uninitEngine];
        [self.statusTextView setText:@"No permission!"];
        self.engineUninitButton.enabled = TRUE;
        self.engineInitButton.enabled = FALSE;
        self.startEngineButton.enabled = TRUE;
        self.longPressButton.enabled = TRUE;
        self.referTextView.editable = TRUE;
        self.startEngineButton.enabled = TRUE;
    });
}

- (void)speechEngineInitSucceeded {
    [self.streamRecorder setSpeechEngine:self.curEngine];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.statusTextView setText:@"Ready"];
        [self.resultTextView setText:[NSString stringWithFormat:@"DeviceID: %@", self.deviceID]];
        self.engineUninitButton.enabled = TRUE;
        self.engineInitButton.enabled = FALSE;
        self.startEngineButton.enabled = TRUE;
        self.longPressButton.enabled = TRUE;
        self.referTextView.editable = TRUE;
        self.startEngineButton.enabled = TRUE;
    });
}

- (void)speechEngineInitFailed {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self uninitEngine];
        [self.statusTextView setText:@"Failed to init engine!"];
        self.engineInitButton.enabled = TRUE;
    });
}

- (void)speechEngineStarted {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.engineStarted = true;
        [self.statusTextView setText:@"Engine Started!"];
        self.referTextView.editable = FALSE;
        self.startEngineButton.enabled = FALSE;
        self.stopEngineButton.enabled = TRUE;
        self.longPressButton.enabled = FALSE;
    });
}

- (void)speechEngineStopped {
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self getRecorderType] == SE_RECORDER_TYPE_STREAM) {
            [self.streamRecorder stop];
        }
        self.engineStarted = FALSE;
        [self.statusTextView setText:@"Engine Stopped!"];
        self.referTextView.editable = TRUE;
        self.startEngineButton.enabled = TRUE;
        self.stopEngineButton.enabled = FALSE;
        self.longPressButton.enabled = TRUE;
    });
}

- (void)speechEngineResult:(NSData *)data {
    dispatch_async(dispatch_get_main_queue(), ^{
        long response_delay = 0;
        if (self.talkingFinisheTimestamp > 0) {
            response_delay = [self timeDelayFrom:self.talkingFinisheTimestamp];
            self.talkingFinisheTimestamp = 0;
        }
        NSError *error;
        NSDictionary *jsonResult = [NSJSONSerialization JSONObjectWithData:data
                                                                   options:NSJSONReadingMutableContainers
                                                                     error:&error];
        NSMutableString *text = [[NSMutableString alloc] initWithString:@""];
        NSDictionary *scores = [jsonResult objectForKey:@"scores"];
        NSArray *integrity = [jsonResult objectForKey:@"integrity_details"];
        if (scores && scores != (id)[NSNull null] && integrity && integrity != (id)[NSNull null]) {
            [text appendFormat:@"response_delay: %ld", response_delay];
            [text appendFormat:@"\nreqid: %@", [jsonResult objectForKey:@"reqid"]];
            [text appendFormat:@"\nscores: %@", [scores description]];
            [text appendFormat:@"\nintegrity_details: %@", [integrity description]];
        }
        
        NSString *res_text = [NSString stringWithCString:[text cStringUsingEncoding:NSUTF8StringEncoding] encoding:NSNonLossyASCIIStringEncoding];
        if (res_text.length) {
            [self.resultTextView setText:[res_text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
        }
    });
}

- (void)speechEngineError:(NSData *)data {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 从回调的 json 数据中解析错误码和错误详细信息
        [self.resultTextView setText:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]];
        [self stopEngineBtnClicked:nil];
    });
}

- (void)setResultText:(NSString *)result {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.resultTextView setText:[result stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
    });
}

#pragma mark - Helper

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
    [nextPage setValue:VIEW_CAPT forKey:@"viewId"];
}

@end



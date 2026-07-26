//
//  AsrViewController.m
//  SpeechDemo
//
//  Created by bytedance on 2020/9/8.
//  Copyright © 2020 fengkai.0518. All rights reserved.
//

#import "AsrViewController.h"

#import <AVFoundation/AVFoundation.h>

#import "AppDelegate.h"
#import "FileUtils.h"
#import "SettingsHelper.h"
#import "ViewController.h"
#import "SensitiveDefines.h"

@interface AsrViewController () <SpeechEngineDelegate, UITextViewDelegate>

// UI
@property (weak, nonatomic) IBOutlet UITextView *resultTextView;
@property (weak, nonatomic) IBOutlet UITextField *statusTextView;
@property (weak, nonatomic) IBOutlet UIButton *initialEngineButton;
@property (weak, nonatomic) IBOutlet UIButton *uninitialEngineButton;
@property (weak, nonatomic) IBOutlet UIButton *startEngineButton;
@property (weak, nonatomic) IBOutlet UIButton *stopEngineButton;
@property (weak, nonatomic) IBOutlet UIButton *recordButton;

// Device ID: 用于定位线上问题
@property (nonatomic, strong) NSString *deviceID;
// Debug Path: 用于存放一些 SDK 相关的文件，比如模型、日志等
@property (strong, nonatomic) NSString *debugPath;

// SpeechEngine
@property (strong, nonatomic) SpeechEngine *curEngine;
@property (assign, nonatomic) BOOL engineStarted;

// Settings
@property (strong, nonatomic) Settings *settings;

// APP 层自定义的录音机，在音频来源为 Stream 时使用
@property (weak, nonatomic) StreamRecorder *streamRecorder;

// 一些用于统计的字段
@property (nonatomic, assign) long talkingFinishTimestamp;
@end

@implementation AsrViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.initialEngineButton.enabled = TRUE;
    self.uninitialEngineButton.enabled = FALSE;
    self.startEngineButton.enabled = FALSE;
    self.stopEngineButton.enabled = FALSE;
    self.recordButton.enabled = FALSE;
    
    [self.statusTextView setText:@"Waiting for init."];
    [self decorateTextView:self.resultTextView];
    
    [ViewController setAppDelegate:(AppDelegate *)[[UIApplication sharedApplication] delegate]];
    UILongPressGestureRecognizer *longPgr = [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                                                          action:@selector(recordTriggered:)];
    longPgr.minimumPressDuration = 0.5;
    [self.recordButton addGestureRecognizer:longPgr];
    
    self.streamRecorder = [ViewController getStreamRecorder];
    self.engineStarted = FALSE;
    self.settings = [[SettingsHelper shareInstance]getSettings:VIEW_ASR];
    self.debugPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSLog(@"当前调试路径 %@", self.debugPath);
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
    [self.curEngine setStringParam:[self getRecorderType] forKey:SE_PARAMS_KEY_RECORDER_TYPE_STRING];

    if ([self.settings getBool:SETTING_ASR_RECORDER_SAVE]) {
        //【可选配置】录音文件保存路径，如配置，SDK会将录音保存到该路径下，文件格式为 .wav
        [self.curEngine setStringParam:self.debugPath forKey:SE_PARAMS_KEY_ASR_REC_PATH_STRING];
    }
    
    // 当音频来源为 RECORDER_TYPE_STREAM 时，如输入音频采样率不等于 16K，需添加如下配置
    if ([[self getRecorderType] isEqualToString:SE_RECORDER_TYPE_STREAM]) {
        if ([self.streamRecorder getSampleRate] != 16000 || [self.streamRecorder getChannel] != 1) {
            // 当音频来源为 RECORDER_TYPE_STREAM 时【必需配置】，否则【无需配置】
            // 启用 SDK 内部的重采样
            [self.curEngine setBoolParam:TRUE forKey:SE_PARAMS_KEY_ENABLE_RESAMPLER_BOOL];
            // 将重采样所需的输入采样率设置为 APP 层输入的音频的实际采样率
            [self.curEngine setIntParam:[self.streamRecorder getSampleRate] forKey:SE_PARAMS_KEY_CUSTOM_SAMPLE_RATE_INT];
            [self.curEngine setIntParam:[self.streamRecorder getChannel] forKey:SE_PARAMS_KEY_CUSTOM_CHANNEL_INT];
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
    [self.curEngine setStringParam:token forKey:SE_PARAMS_KEY_APP_TOKEN_STRING];
    //【可需配置】自定义请求头部KV：Headers
    [self.curEngine setStringParam:[self.settings getString:SETTING_REQUEST_HEADERS] forKey:SE_PARAMS_KEY_REQUEST_HEADERS_STRING];

    NSString* cluster = [self.settings getString:SETTING_CLUSTER];
    NSLog(@"Current cluster: %@", cluster);
    //【必需配置】识别服务所用集群
    [self.curEngine setStringParam:cluster.length <= 0 ? SDEF_ASR_DEFAULT_CLUSTER : cluster forKey:SE_PARAMS_KEY_ASR_CLUSTER_STRING];
    
    //【可选配置】在线请求的建连与接收超时，一般不需配置使用默认值即可
    [self.curEngine setIntParam:3000 forKey:SE_PARAMS_KEY_ASR_CONN_TIMEOUT_INT];
    [self.curEngine setIntParam:5000 forKey:SE_PARAMS_KEY_ASR_RECV_TIMEOUT_INT];
    
    //【可选配置】在线请求断连后，重连次数，默认值为0，如果需要开启需要设置大于0的次数
    [self.curEngine setIntParam:[self.settings getInt:SETTING_ASR_MAX_RETRY_TIMES] forKey:SE_PARAMS_KEY_ASR_MAX_RETRY_TIMES_INT];
    
    //【可选配置】音频采样率，默认16000
    [self.curEngine setIntParam:[self.settings getInt:SETTING_SAMPLE_RATE] forKey:SE_PARAMS_KEY_SAMPLE_RATE_INT];
    //【可选配置】音频通道数，默认1，可选1或2
    [self.curEngine setIntParam:[self.settings getInt:SETTING_CHANNEL] forKey:SE_PARAMS_KEY_CHANNEL_NUM_INT];
    //【可选配置】上传给服务的音频通道数，默认1，可选1或2，一般与SE_PARAMS_KEY_SAMPLE_RATE_INT保持一致即可
    [self.curEngine setIntParam:[self.settings getInt:SETTING_CHANNEL] forKey:SE_PARAMS_KEY_UP_CHANNEL_NUM_INT];
}

-(void)configStartAsrParams{
    //【可选配置】是否开启顺滑(DDC)
    [self.curEngine setBoolParam:[self.settings getBool:SETTING_ASR_ENABLE_DDC] forKey:SE_PARAMS_KEY_ASR_ENABLE_DDC_BOOL];
    //【可选配置】是否开启文字转数字(ITN)
    [self.curEngine setBoolParam:[self.settings getBool:SETTING_ASR_ENABLE_ITN] forKey:SE_PARAMS_KEY_ASR_ENABLE_ITN_BOOL];
    //【可选配置】是否开启标点
    [self.curEngine setBoolParam:[self.settings getBool:SETTING_ASR_ENABLE_NLU_PUNC] forKey:SE_PARAMS_KEY_ASR_SHOW_NLU_PUNC_BOOL];
    //【可选配置】是否隐藏句尾标点
    [self.curEngine setBoolParam:[self.settings getBool:SETTING_ASR_DISABLE_END_PUNC] forKey:SE_PARAMS_KEY_ASR_DISABLE_END_PUNC_BOOL];
    // 【可选配置】直接传递自定义的ASR请求JSON，若使用此参数需自行确保JSON格式正确
    [self.curEngine setStringParam:[self.settings getString:SETTING_ASR_REQ_PARAMS] forKey:SE_PARAMS_KEY_ASR_REQ_PARAMS_STRING];

    //【可选配置】设置识别语种
    [self.curEngine setStringParam:[self.settings getString:SETTING_ASR_LANGUAGE] forKey:SE_PARAMS_KEY_ASR_LANGUAGE_STRING];
    //【可选配置】是否返回用户说话的语种
    [self.curEngine setBoolParam:[self.settings getBool:SETTING_ASR_SHOW_LANGUAGE] forKey:SE_PARAMS_KEY_ASR_SHOW_LANG_BOOL];

    //【可选配置】控制识别结果返回的形式，全量返回或增量返回，默认为全量
    [self.curEngine setStringParam:[self.settings getOptionsValue:SETTING_ASR_RESULT_TYPE] forKey:SE_PARAMS_KEY_ASR_RESULT_TYPE_STRING];

    //【可选配置】设置VAD头部静音时长，用户多久没说话视为空音频，即静音检测时长
    [self.curEngine setIntParam:[self.settings getInt:SETTING_ASR_VAD_START_SILENCE_TIME] forKey:SE_PARAMS_KEY_ASR_VAD_START_SILENCE_TIME_INT];
    //【可选配置】设置VAD尾部静音时长，用户说话后停顿多久视为说话结束，即自动判停时长
    [self.curEngine setIntParam:[self.settings getInt:SETTING_ASR_VAD_END_SILENCE_TIME] forKey:SE_PARAMS_KEY_ASR_VAD_END_SILENCE_TIME_INT];
    //【可选配置】用户音频输入最大时长，仅一句话识别场景生效，单位毫秒，默认为 150000ms.
    [self.curEngine setIntParam:[self.settings getInt:SETTING_VAD_MAX_SPEECH_DURATION] forKey:SE_PARAMS_KEY_VAD_MAX_SPEECH_DURATION_INT];
    
    //【可选配置】控制是否返回录音音量，在 APP 需要显示音频波形时可以启用
    [self.curEngine setBoolParam:[self.settings getBool:SETTING_GET_VOLUME] forKey:SE_PARAMS_KEY_ENABLE_GET_VOLUME_BOOL];
    
    //【可选配置】更新 ASR 热词
    if ([self.settings getString:SETTING_ASR_HOTWORDS].length != 0) {
        [self setHotWords:[self.settings getString:SETTING_ASR_HOTWORDS]];
    }
    
    //【可选配置】设置纠错词表，识别结果会根据设置的纠错词纠正结果，例如："{\"古爱玲\":\"谷爱凌\"}"，当识别结果中出现"古爱玲"时会替换为"谷爱凌"
    [self.curEngine setStringParam:[self.settings getString:SETTING_ASR_CORRECTWORDS] forKey:SE_PARAMS_KEY_ASR_CORRECT_WORDS_STRING];
    
    NSString* recorderType = [self getRecorderType];
    NSLog(@"录音模式: %@", recorderType);
    
    if ([recorderType isEqualToString:SE_RECORDER_TYPE_STREAM]) {
        if (![self.streamRecorder start]) {
            [self speechEngineNoPermission];
        }
    } else if ([recorderType isEqualToString:SE_RECORDER_TYPE_FILE]) {
        // 使用音频文件识别时，需要设置文件的绝对路径
        NSString* file_path = [NSString stringWithFormat:@"%@/%@", self.debugPath, @"asr_rec_file.pcm"];
        NSLog(@"输入的音频文件路径: %@", file_path);
        // 使用音频文件识别时【必须配置】，否则【无需配置】
        [self.curEngine setStringParam:file_path forKey:SE_PARAMS_KEY_RECORDER_FILE_STRING];
    }
}

- (void)setHotWords:(NSString*) hotWords {
    // 更新 ASR 热词，例如："{\"hotwords\":[{\"word\":\"过秦论\",\"scale\":2.0}]}"
    // scale为float类型参数，其中叠词的范围为[1.0,2.0]，非叠词的范围为[1.0,50.0]，scale值越大，结果中出现热词的概率越大
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
    NSLog(@"获取设备ID成功: %@", self.deviceID);
    
    
    NSLog(@"创建引擎");
    if (self.curEngine == nil) {
        self.curEngine = [[SpeechEngine alloc] init];
        if (![self.curEngine createEngineWithDelegate:self]) {
            NSLog(@"引擎创建失败.");
            return;
        }
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
        [self speechEngineInitFailed:ret];
    }
}

- (void)uninitEngine {
    if (self.curEngine != nil) {
        NSLog(@"引擎析构");
        [self.curEngine destroyEngine];
        self.curEngine = nil;
        NSLog(@"引擎析构完成");
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        self.initialEngineButton.enabled = TRUE;
        self.uninitialEngineButton.enabled = FALSE;
        self.startEngineButton.enabled = FALSE;
        self.stopEngineButton.enabled = FALSE;
        self.recordButton.enabled = FALSE;
    });
}

- (void)speechEngineInitSucceeded {
    [self.streamRecorder setSpeechEngine:VIEW_ASR engine:self.curEngine];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.statusTextView setText:@"Ready"];
        [self setResultText:[NSString stringWithFormat:@"DeviceID: %@", self.deviceID]];
        self.uninitialEngineButton.enabled = TRUE;
        self.initialEngineButton.enabled = FALSE;
        self.startEngineButton.enabled = TRUE;
        self.recordButton.enabled = TRUE;
    });
}

- (void)speechEngineInitFailed:(int)initStatus {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self uninitEngine];
        [self.statusTextView setText:[[NSString alloc] initWithFormat:@"Failed to init engine, %d!", initStatus]];
        self.initialEngineButton.enabled = TRUE;
        self.uninitialEngineButton.enabled = FALSE;
    });
}

- (void)speechEngineNoPermission {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self uninitEngine];
        [self.statusTextView setText:@"No permission!"];
        self.initialEngineButton.enabled = TRUE;
        self.uninitialEngineButton.enabled = FALSE;
    });
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
    
    [self.resultTextView setTextColor:UIColor.grayColor];
    [self setResultText:@"点击或按住说话后，展示语音识别结果"];
}

- (IBAction)startEngineBtnClicked:(id)sender {
    self.talkingFinishTimestamp = 0;
    [self setResultText:@""];
    
    NSLog(@"配置启动参数");
    [self configStartAsrParams];

    //【可选配置】该按钮为短按模式，预期是按下开始录音，自动判停结束，需要开启云端自动判停功能。
    NSLog(@"开启 ASR 云端自动判停");
    [self.curEngine setBoolParam:TRUE forKey:SE_PARAMS_KEY_ASR_AUTO_STOP_BOOL];

    
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
        self.talkingFinishTimestamp = 0;
        [self setResultText:@""];
        
        NSLog(@"配置启动参数");
        [self configStartAsrParams];

        //【可选配置】是否启用云端自动判停，仅一句话识别场景生效
        NSLog(@"关闭 ASR 云端自动判停");
        [self.curEngine setBoolParam:FALSE forKey:SE_PARAMS_KEY_ASR_AUTO_STOP_BOOL];


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
        self.talkingFinishTimestamp = [[NSDate date] timeIntervalSince1970] * 1000;
        // Directive：结束音频输入。
        NSLog(@"Directive: SEDirectiveFinishTalking");
        [self.curEngine sendDirective:SEDirectiveFinishTalking];
        if ([[self getRecorderType] isEqualToString:SE_RECORDER_TYPE_STREAM]) {
            [self.streamRecorder stop];
        }
    }
}

#pragma mark - Message Callback

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
        case SEConnectionConnected:
            NSLog(@"Callback: 建连成功");
            break;
        case SEAsrPartialResult:
            // Callback: ASR 当前请求的部分结果回调
            NSLog(@"Callback: ASR 当前请求的部分结果");
            [self speechEngineResult:data isFinal:FALSE];
            break;
        case SEFinalResult:
            // Callback: ASR 当前请求最终结果回调
            NSLog(@"Callback: ASR 当前请求最终结果");
            [self speechEngineResult:data isFinal:TRUE];
            break;
        case SEVolumeLevel:
            // Callback: 录音音量回调
            NSLog(@"Callback: 录音音量，%.3f", [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] floatValue]);
            break;
        default:
            break;
    }
}

- (void)speechEngineStarted {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.engineStarted = true;
        [self.statusTextView setText:@"Engine Started!"];
        self.startEngineButton.enabled = FALSE;
        self.stopEngineButton.enabled = TRUE;
        self.recordButton.enabled = FALSE;
    });
}

- (void)speechEngineStopped {
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([[self getRecorderType] isEqualToString:SE_RECORDER_TYPE_STREAM]) {
            [self.streamRecorder stop];
        }
        self.engineStarted = FALSE;
        [self.statusTextView setText:@"Engine Stopped!"];
        self.startEngineButton.enabled = TRUE;
        self.stopEngineButton.enabled = FALSE;
        self.recordButton.enabled = TRUE;
    });
}

- (void)speechEngineResult:(NSData *)data isFinal:(BOOL)isFinal {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 计算由录音结束到 ASR 最终结果之间的延迟
        long response_delay = 0;
        if (isFinal && self.talkingFinishTimestamp > 0) {
            response_delay = [self timeDelayFrom:self.talkingFinishTimestamp];
        }
        
        // 从回调的 json 数据中解析 ASR 结果
        NSError *error;
        NSDictionary *jsonResult = [NSJSONSerialization JSONObjectWithData:data
                                                                   options:NSJSONReadingMutableContainers
                                                                     error:&error];
        if (![jsonResult objectForKey:@"result"]) {
            return;
        }
        
        // 在 UI 显示 ASR 结果和延迟信息
        NSString *result = [[[jsonResult objectForKey:@"result"] firstObject] objectForKey:@"text"];
        if (result.length == 0) {
            return;
        }
        NSMutableString *text = [[NSMutableString alloc] initWithString:@""];
        [text appendFormat:@"result: %@", result];
        [text appendFormat:@"\nreqid: %@", [jsonResult objectForKey:@"reqid"]];
        if (isFinal && response_delay > 0) {
            [text appendFormat:@"\nresponse_delay: %ld", response_delay];
        }
        [self setResultText:[text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
    });
}

- (void)speechEngineError:(NSData *)data {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 从回调的 json 数据中解析错误码和错误详细信息
        id error_json = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
        if ([error_json isKindOfClass:[NSDictionary class]]) {
            NSDictionary *error_info = error_json;
            
            // 在 UI 显示错误信息
            if ([error_info objectForKey:@"name"] != nil) {
                NSString* error_msg = [[error_json objectForKey:@"err_msg"] stringValue];
                NSString* reqid = [[error_json objectForKey:@"reqid"] stringValue];
                [self setResultText:[NSString stringWithFormat:@"reqid: %@, error: %@", reqid, error_msg]];
            } else {
                [self setResultText:[NSString stringWithFormat:@"%@", error_info]];
            }
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
    [nextPage setValue:VIEW_ASR forKey:@"viewId"];
}

@end

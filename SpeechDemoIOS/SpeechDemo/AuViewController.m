//
//  AuViewController.m
//  SpeechDemo
//
//  Created by bytedance on 2023/5/16.
//  Copyright © 2023 chengzihao.ds. All rights reserved.
//

#import "AuViewController.h"

#import <AVFoundation/AVFoundation.h>

#import "AppDelegate.h"
#import "FileUtils.h"
#import "SettingsHelper.h"
#import "ViewController.h"
#import "SensitiveDefines.h"

@interface AuViewController () <SpeechEngineDelegate, UITextViewDelegate>

@property (weak, nonatomic) IBOutlet UITextView *resultTextView;
@property (weak, nonatomic) IBOutlet UITextField *statusTextView;
@property (weak, nonatomic) IBOutlet UIButton *engineInitButton;
@property (weak, nonatomic) IBOutlet UIButton *engineUninitButton;
@property (weak, nonatomic) IBOutlet UIButton *startEngineButton;
@property (weak, nonatomic) IBOutlet UIButton *stopEngineButton;
@property (weak, nonatomic) IBOutlet UIButton *longPressButton;

@property (strong, nonatomic) SpeechEngine *curEngine;
@property (assign, nonatomic) BOOL engineStarted;

@property (nonatomic, strong) NSString *deviceID;
@property (nonatomic, assign) long talkingFinisheTimestamp;
@property (nonatomic, assign) long startEngineTimestamp;
@property (strong, nonatomic) NSString *debugPath;

@property (weak, nonatomic) StreamRecorder *streamRecorder;

// settings
@property (strong, nonatomic) Settings *settings;

@end

static NSString *SLARDAR_AU_SERVICE_NAME = @"au_statistics";
static NSString *SLARDAR_AU_EVENT_RESPONSE_DELAY = @"au_response_delay";

@implementation AuViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.settings = [[SettingsHelper shareInstance]getSettings:VIEW_AU];
    self.debugPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSLog(@"当前调试路径 %@", self.debugPath);
    
    self.engineInitButton.enabled = TRUE;
    self.engineUninitButton.enabled = FALSE;
    self.startEngineButton.enabled = FALSE;
    self.stopEngineButton.enabled = FALSE;
    self.longPressButton.enabled = FALSE;
    [self.statusTextView setText:@"Waiting for init."];
    [self decorateTextView:self.resultTextView];
    [ViewController setAppDelegate:(AppDelegate *)[[UIApplication sharedApplication] delegate]];
    UILongPressGestureRecognizer *longPgr = [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                                                          action:@selector(longPressTriggered:)];
    longPgr.minimumPressDuration = 0.5;
    [self.longPressButton addGestureRecognizer:longPgr];
    self.streamRecorder = [ViewController getStreamRecorder];
    self.engineStarted = FALSE;
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

- (void)configInitAuParams {
    //【必需配置】Engine Name
    [self.curEngine setStringParam:SE_AU_ENGINE forKey:SE_PARAMS_KEY_ENGINE_NAME_STRING];

    //【可选配置】Debug & Log
    [self.curEngine setStringParam:self.debugPath forKey:SE_PARAMS_KEY_DEBUG_PATH_STRING];
    [self.curEngine setStringParam:SE_LOG_LEVEL_DEBUG forKey:SE_PARAMS_KEY_LOG_LEVEL_STRING];
    //【可选配置】UID & deviceID: 用于定位线上问题
    [self.curEngine setStringParam:SDEF_UID forKey:SE_PARAMS_KEY_UID_STRING];
    //【必需配置】配置音频来源
    [self.curEngine setStringParam:[self getRecorderType] forKey:SE_PARAMS_KEY_RECORDER_TYPE_STRING];
    if ([self.settings getBool:SETTING_AU_RECORDER_SAVE]) {
        //【可选配置】录音文件保存路径，如配置，SDK会将录音保存到该路径下，文件格式为 .wav
        [self.curEngine setStringParam:self.debugPath forKey:SE_PARAMS_KEY_AU_REC_PATH_STRING];
    }
    //【必需配置】鉴权相关：Appid
    [self.curEngine setStringParam:[self.settings getString:SETTING_APPID] forKey:SE_PARAMS_KEY_APP_ID_STRING];
    //【必需配置】鉴权相关：Token
    [self.curEngine setStringParam:[self.settings getString:SETTING_TOKEN] forKey:SE_PARAMS_KEY_APP_TOKEN_STRING];
    //【可选配置】使用的AU能力组合，默认只进行ASR识别
    [self.curEngine setIntParam:[self getAuAbility] forKey:SE_PARAMS_KEY_AU_ABILITY_INT];
    //【必需配置】识别服务域名
    [self.curEngine setStringParam:[self.settings getString:SETTING_ADDRESS] forKey:SE_PARAMS_KEY_AU_ADDRESS_STRING];
    //【必需配置】识别服务Uri
    [self.curEngine setStringParam:[self.settings getString:SETTING_URI] forKey:SE_PARAMS_KEY_AU_URI_STRING];
    //【必需配置】识别服务所用集群
    [self.curEngine setStringParam:[self.settings getString:SETTING_CLUSTER] forKey:SE_PARAMS_KEY_AU_CLUSTER_STRING];
    //【可选配置】在线请求的建连与接收超时，一般不需配置使用默认值即可
    [self.curEngine setIntParam:3000 forKey:SE_PARAMS_KEY_AU_CONN_TIMEOUT_INT];
    [self.curEngine setIntParam:5000 forKey:SE_PARAMS_KEY_AU_RECV_TIMEOUT_INT];
    //【可选配置】AU处理超时，音乐流程需要额外处理时间，一般不需配置使用默认值即可
    [self.curEngine setIntParam:[self.settings getInt:SETTING_AU_PROCESS_TIMEOUT] forKey:SE_PARAMS_KEY_AU_PROCESS_TIMEOUT_INT];
    //【可选配置】AU音频包发送间隔，一般不需配置使用默认值即可
    [self.curEngine setIntParam:[self.settings getInt:SETTING_AU_AUDIO_PACKET_DURATION] forKey:SE_PARAMS_KEY_AU_AUDIO_PACKET_DURATION_INT];
    //【可选配置】AU轮询包发送间隔，一般不需配置使用默认值即可
    [self.curEngine setIntParam:[self.settings getInt:SETTING_AU_EMPTY_PACKET_INTERVAL] forKey:SE_PARAMS_KEY_AU_EMPTY_PACKET_INTERVAL_INT];
    
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
}

- (void)configStartAuParams {
    // Au 部分配置
    //【可选配置】用户说话最大时长，单位毫秒，默认为 150000ms.
    [self.curEngine setIntParam:[self.settings getInt:SETTING_VAD_MAX_SPEECH_DURATION] forKey:SE_PARAMS_KEY_VAD_MAX_SPEECH_DURATION_INT];
    //【可选配置】用户歌唱最大时长，单位毫秒，默认为 12000ms.
    [self.curEngine setIntParam:[self.settings getInt:SETTING_VAD_MAX_MUSIC_DURATION] forKey:SE_PARAMS_KEY_VAD_MAX_MUSIC_DURATION_INT];
    if ([[self getRecorderType] isEqualToString:SE_RECORDER_TYPE_STREAM]) {
        if (![self.streamRecorder start]) {
            [self speechEngineNoPermission];
            return;
        }
    } else if ([[self getRecorderType] isEqualToString:SE_RECORDER_TYPE_FILE]) {
        // 使用音频文件识别时，需要设置文件的绝对路径
        NSString* file_path = [NSString stringWithFormat:@"%@/%@", self.debugPath, @"au_rec_file.pcm"];
        NSLog(@"test file path: %@", file_path);
        // 使用音频文件识别时【必须配置】，否则【无需配置】
        [self.curEngine setStringParam:file_path forKey:SE_PARAMS_KEY_RECORDER_FILE_STRING];
    }

    // Asr 部分配置
    //【可选配置】是否开启顺滑(DDC)
    [self.curEngine setBoolParam:[self.settings getBool:SETTING_ASR_ENABLE_DDC] forKey:SE_PARAMS_KEY_ASR_ENABLE_DDC_BOOL];
    //【可选配置】是否开启文字转数字(ITN)
    [self.curEngine setBoolParam:[self.settings getBool:SETTING_ASR_ENABLE_ITN] forKey:SE_PARAMS_KEY_ASR_ENABLE_ITN_BOOL];
    //【可选配置】是否开启标点
    [self.curEngine setBoolParam:[self.settings getBool:SETTING_ASR_ENABLE_NLU_PUNC] forKey:SE_PARAMS_KEY_ASR_SHOW_NLU_PUNC_BOOL];
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
    //【可选配置】设置VAD模式，用于定制VAD场景，默认为空
    [self.curEngine setStringParam:[self.settings getString:SETTING_ASR_VAD_MODE] forKey:SE_PARAMS_KEY_ASR_VAD_MODE_STRING];
    //【可选配置】更新 ASR 热词
    if ([self.settings getString:SETTING_ASR_HOTWORDS].length != 0) {
        [self setHotWords:[self.settings getString:SETTING_ASR_HOTWORDS]];
    }
}

- (void)setHotWords:(NSString*) hotWords {
    [self.curEngine sendDirective:SEDirectiveUpdateAsrHotWords data: hotWords];
}

#pragma mark - SpeechEngineDelegate

- (void)onMessageWithType:(SEMessageType)type andData:(NSData *)data {
    NSLog(@"Message Type: %d.", type);
    switch (type) {
        case SEEngineStart:
            [self speechEngineStarted];
            break;
        case SEEngineStop:
            [self speechEngineStopped];
            break;
        case SEEngineError:
            [self speechEngineError:data];
            break;
        case SEPartialResult:
            [self speechEngineResult:data isFinal:FALSE];
            break;
        case SEFinalResult:
            [self speechEngineResult:data isFinal:TRUE];
            break;
        case SEVolumeLevel:
            NSLog(@"volume level: %s", (char*)data.bytes);
            break;
        case SEEngineLog:
            NSLog(@"engine log: %s", (char*)data.bytes);
            break;
        default:
            break;
    }
}

#pragma mark - UI Actions

- (IBAction)initEngine:(id)sender {
    [self initEngine];
}

- (IBAction)uninitEngine:(id)sender {
    if (self.engineStarted) {
        [self.statusTextView setText:@"Engine is busy, stop it first!"];
        return;
    }
    [self uninitEngine];
    [self.resultTextView setTextColor:UIColor.grayColor];
    [self.resultTextView setText:@"点击或按住说话后，展示语音理解结果"];
}

- (IBAction)startEngine:(id)sender {
    NSLog(@"配置启动参数");
    [self configStartAuParams];
    [self.curEngine setBoolParam:TRUE forKey:SE_PARAMS_KEY_AU_AUTO_STOP_BOOL];
    
    SEEngineErrorCode ret = [self.curEngine sendDirective:SEDirectiveStartEngine];
    if (ret == SERecCheckEnvironmentFailed) {
        [self speechEngineNoPermission];
    }
}

- (IBAction)stopEngine:(id)sender {
    NSLog(@"Stop engine.");
    [self.curEngine sendDirective:SEDirectiveStopEngine];
}

- (void)longPressTriggered:(UILongPressGestureRecognizer *)longPgr {
    if (longPgr.state == UIGestureRecognizerStateBegan) {
        NSLog(@"Long press begin.");
        
        [self setResultText:@""];
        NSLog(@"配置启动参数");
        [self configStartAuParams];
        [self.curEngine setBoolParam:FALSE forKey:SE_PARAMS_KEY_AU_AUTO_STOP_BOOL];
        
        SEEngineErrorCode ret = [self.curEngine sendDirective:SEDirectiveStartEngine];
        if (ret == SERecCheckEnvironmentFailed) {
            [self speechEngineNoPermission];
        }
    } else if (longPgr.state == UIGestureRecognizerStateEnded) {
        NSLog(@"Long press ended.");
        self.talkingFinisheTimestamp = [[NSDate date] timeIntervalSince1970] * 1000;
        [self.curEngine sendDirective:SEDirectiveFinishTalking];
        if ([[self getRecorderType] isEqualToString:SE_RECORDER_TYPE_STREAM]) {
            [self.streamRecorder stop];
        }
    }
}

#pragma mark - Init Methods

- (void)initEngine {
    AppDelegate *appDelegate = [ViewController getAppDelegate];
    if (appDelegate == nil) {
        appDelegate = (AppDelegate *)[[UIApplication sharedApplication] delegate];
    }
    if (appDelegate.deviceID.length < 1) {
        self.engineInitButton.enabled = FALSE;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.statusTextView setText:@"Waiting for get deviceID."];
            sleep(1);
            [self initEngine];
        });
        return;
    }
    [ViewController setAppDelegate:appDelegate];
    self.deviceID = appDelegate.deviceID;
    

    if (self.curEngine == nil) {
        self.curEngine = [[SpeechEngine alloc] init];
    }
    if (![self.curEngine createEngineWithDelegate:self]) {
        NSLog(@"Create speech engine failed.");
        return;
    }

    [self.resultTextView setTextColor:UIColor.blackColor];

    NSLog(@"SDK 版本号: %@", [self.curEngine getVersion]);
    self.debugPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSLog(@"当前调试路径: %@", self.debugPath);

    NSLog(@"配置初始化参数");
    [self configInitAuParams];
    
    NSLog(@"引擎初始化");
    SEEngineErrorCode ret = [self.curEngine initEngine];
    if (ret != SENoError) {
        NSLog(@"初始化失败，返回值: %ld", ret);
    }
    if (ret == SENoError) {
        [self speechEngineInitOk];
    } else {
        [self speechEngineInitFailed];
    }
}

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

- (int)getAuAbility {
    SettingOptions* auAbilityOptions = [self.settings getOptions:SETTING_AU_ABILITY];
    switch (auAbilityOptions.chooseIdx) {
        case 0:
            return SEAuAbilityAsr;
        case 1:
            return SEAuAbilityMusic;
        case 2:
            return SEAuAbilityAsr | SEAuAbilityMusic;
        default:
            return SEAuAbilityAsr;
    }
}

- (void)uninitEngine {
    [self.curEngine destroyEngine];
    self.curEngine = nil;
    self.engineInitButton.enabled = TRUE;
    self.engineUninitButton.enabled = FALSE;
    self.startEngineButton.enabled = FALSE;
    self.stopEngineButton.enabled = FALSE;
    self.longPressButton.enabled = FALSE;
}

#pragma mark - Engine Callback

- (void)speechEngineNoPermission {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self uninitEngine];
        [self.statusTextView setText:@"No permission!"];
        self.engineInitButton.enabled = TRUE;
        self.engineUninitButton.enabled = FALSE;
    });
}

- (void)speechEngineInitOk {
    [self.streamRecorder setSpeechEngine:VIEW_AU engine:self.curEngine];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.statusTextView setText:@"Ready"];
        [self.resultTextView setText:[NSString stringWithFormat:@"DeviceID: %@", self.deviceID]];
        self.engineUninitButton.enabled = TRUE;
        self.engineInitButton.enabled = FALSE;
        self.startEngineButton.enabled = TRUE;
        self.longPressButton.enabled = TRUE;
    });
}

- (void)speechEngineInitFailed {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self uninitEngine];
        [self.statusTextView setText:@"Failed to init engine!"];
        self.engineInitButton.enabled = TRUE;
        self.engineUninitButton.enabled = FALSE;
    });
}

- (void)speechEngineStarted {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.startEngineTimestamp = [[NSDate date] timeIntervalSince1970] * 1000;
        self.engineStarted = true;
        [self.statusTextView setText:@"Engine Started!"];
        self.startEngineButton.enabled = FALSE;
        self.stopEngineButton.enabled = TRUE;
        self.longPressButton.enabled = FALSE;
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
        self.longPressButton.enabled = TRUE;
    });
}

- (void)speechEngineResult:(NSData *)data isFinal:(BOOL)isFinal {
    dispatch_async(dispatch_get_main_queue(), ^{
        long response_delay = 0;
        if (isFinal && self.talkingFinisheTimestamp > 0) {
            response_delay = [self timeDelayFrom:self.talkingFinisheTimestamp];
            self.talkingFinisheTimestamp = 0;
        }
        
        NSMutableString *text = [[NSMutableString alloc] initWithString:@""];
        [text appendFormat:@"result: %@", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]];
        if (isFinal) {
            [text appendFormat:@"\nresponse_delay: %ld", response_delay];
        }
        [self.resultTextView setText:[text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
    });
}

- (void)speechEngineError:(NSData *)data {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.resultTextView setText:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]];
//        [self stopEngine:nil];
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
    [nextPage setValue:VIEW_AU forKey:@"viewId"];
}

@end


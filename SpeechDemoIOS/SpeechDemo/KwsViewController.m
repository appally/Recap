//
//  KwsViewController.m
//  SpeechDemo
//
//  Created by bytedance on 2020/9/8.
//  Copyright © 2020 fengkai.0518. All rights reserved.
//

#import "KwsViewController.h"

#import <AVFoundation/AVFoundation.h>

#import "AppDelegate.h"
#import "FileUtils.h"
#import "SettingsHelper.h"
#import "ViewController.h"
#import "SpeechResourceManager.h"
#import "SensitiveDefines.h"

@interface KwsViewController () <SpeechEngineDelegate, UITextViewDelegate>

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
// Debug Path: 用于存放一些 SDK 相关的文件，比如模型、日志等
@property (strong, nonatomic) NSString *debugPath;

@property (weak, nonatomic) StreamRecorder *streamRecorder;

// settings
@property (strong, nonatomic) Settings *settings;

@end

@implementation KwsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.settings = [[SettingsHelper shareInstance]getSettings:VIEW_KWS];
    
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

#pragma mark - Config & Init & Uninit Methods

-(void)configInitParams{
    //【必需配置】Engine Name
    [self.curEngine setStringParam:SE_KWS_ENGINE forKey:SE_PARAMS_KEY_ENGINE_NAME_STRING];
    
    //【可选配置】Debug & Log
    [self.curEngine setStringParam:self.debugPath forKey:SE_PARAMS_KEY_DEBUG_PATH_STRING];
    [self.curEngine setStringParam:SE_LOG_LEVEL_DEBUG forKey:SE_PARAMS_KEY_LOG_LEVEL_STRING];
    
    //【必需配置】配置音频来源
    [self.curEngine setStringParam:[self.settings getOptionsValue:SETTING_RECORD_TYPE] forKey:SE_PARAMS_KEY_RECORDER_TYPE_STRING];
    
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
    
    NSString* recPath = @"";
    if ([self.settings getBool:SETTING_RECORD_SAVE]) {
        recPath = self.debugPath;
    }
    [self.curEngine setStringParam:recPath forKey:SE_PARAMS_KEY_REC_PATH_STRING];
    [self.curEngine setIntParam:[self.settings getOptions:SETTING_RECORD_FILE_TYPE].chooseIdx forKey:SE_PARAMS_KEY_REC_FILE_TYPE_INT];
    
    [self.curEngine setStringParam:@"{\"array_type\": 0,\"radius\":0.0,\"total_channels\":1,\"mic_offset\":0,\"mic_num\":1,\"ref_offset\":0,\"ref_num\":0,\"vad_speech_active_thresh\":0.5,\"vad_speech_deactive_thresh\":0.5}" forKey:SE_PARAMS_KEY_KWS_USER_PARAM_STRING];
    [self.curEngine setIntParam:600 forKey:SE_PARAMS_KEY_KWS_VAD_END_SILENCE_TIMEOUT_INT];
    [self.curEngine setBoolParam:false forKey:SE_PARAMS_KEY_KWS_ENABLE_VAD_BOOL];

    SpeechResourceManager *resourceManager = [SpeechResourceManager shareInstance];
    NSString* modelsPath = [resourceManager getModelPath:[self getKwsModelName]];
    NSLog(@"Kws model path: %@", modelsPath);
    [self.curEngine setStringParam:modelsPath forKey:SE_PARAMS_KEY_KWS_ROOT_PATH_STRING];
}

-(void)configStartParams{
    //【可选配置】控制是否返回录音音量，在 APP 需要显示音频波形时可以启用
    [self.curEngine setBoolParam:[self.settings getBool:SETTING_GET_VOLUME] forKey:SE_PARAMS_KEY_ENABLE_GET_VOLUME_BOOL];
    
    if ([self.settings getOptionsValue:SETTING_RECORD_TYPE] == SE_RECORDER_TYPE_STREAM) {
        if (![self.streamRecorder start]) {
            [self speechEngineNoPermission];
        }
    } else if ([self.settings getOptionsValue:SETTING_RECORD_TYPE] == SE_RECORDER_TYPE_FILE) {
        // 使用音频文件唤醒时，需要设置文件的绝对路径
        NSString* file_path = [NSString stringWithFormat:@"%@/%@", self.debugPath, @"kws_rec_file.pcm"];
        NSLog(@"输入的音频文件路径: %@", file_path);
        // 使用音频文件唤醒时【必须配置】，否则【无需配置】
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
    
    self.debugPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSLog(@"当前调试路径: %@", self.debugPath);

    SpeechResourceManager *resourceManager = [SpeechResourceManager shareInstance];
    [resourceManager setAppId:SDEF_APPID];
    [resourceManager setAppVersion:@"1.0.0"];
    [resourceManager setDeviceId:self.deviceID];
    [resourceManager setRootPath:self.debugPath];
    [resourceManager setSpeechEngineName:SE_KWS_ENGINE];
    [resourceManager setAddress:@"https://sdk.bytespeech.com"];
    [resourceManager setOnlineModelEnable:NO];
    [resourceManager setup];
    
    if ([resourceManager checkModelExist:[self getKwsModelName]]) {
        [resourceManager checkModelVersion:[self getKwsModelName] completion:^(SEResourceStatus status, BOOL needUpdate, NSData *data) {
            if (status == kSERSuccess) {
                if (needUpdate) {
                    [self fetchResource];
                } else {
                    [self initEngineInternal];
                }
            } else {
                NSLog(@"Model check failed: %@", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
                [self.resultTextView setText:@"Failed to check asr resource"];
                [self speechEngineInitFailed:status];
            }
        }];
    } else {
        [self fetchResource];
    }
}

- (void)fetchResource {
    SpeechResourceManager *resourceManager = [SpeechResourceManager shareInstance];
    [resourceManager fetchModelByName:[self getKwsModelName] completion:^(SEResourceStatus status, NSData* data) {
        if (status == kSERSuccess) {
            [self initEngineInternal];
        } else {
            [self.resultTextView setText:@"Failed to fetch asr resource"];
            [self speechEngineInitFailed:status];
        }
    }];
}

- (void)initEngineInternal {
    
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
    [self.curEngine destroyEngine];
    self.curEngine = nil;
    self.engineInitButton.enabled = TRUE;
    self.engineUninitButton.enabled = FALSE;
    self.startEngineButton.enabled = FALSE;
    self.stopEngineButton.enabled = FALSE;
    self.longPressButton.enabled = FALSE;
}

- (void)speechEngineInitSucceeded {
    [self.streamRecorder setSpeechEngine:self.curEngine];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.statusTextView setText:@"Ready"];
        self.engineUninitButton.enabled = TRUE;
        self.engineInitButton.enabled = FALSE;
        self.startEngineButton.enabled = TRUE;
        self.longPressButton.enabled = TRUE;
    });
}

- (void)speechEngineInitFailed:(int)initStatus {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self uninitEngine];
        [self.statusTextView setText:[[NSString alloc] initWithFormat:@"Failed to init engine, %d!", initStatus]];
        self.engineInitButton.enabled = TRUE;
        self.engineUninitButton.enabled = FALSE;
    });
}

- (void)speechEngineNoPermission {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self uninitEngine];
        [self.statusTextView setText:@"No permission!"];
        self.engineInitButton.enabled = TRUE;
        self.engineUninitButton.enabled = FALSE;
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
    [self.resultTextView setText:@"点击或按住说话后，展示语音唤醒结果"];
}

- (IBAction)startEngineBtnClicked:(id)sender {
    [self setResultText:@""];
    
    NSLog(@"配置启动参数");
    [self configStartParams];
    
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
        // Directive：结束音频输入。
        NSLog(@"Directive: SEDirectiveFinishTalking");
        [self.curEngine sendDirective:SEDirectiveFinishTalking];
        if ([self.settings getOptionsValue:SETTING_RECORD_TYPE] == SE_RECORDER_TYPE_STREAM) {
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
        case SEWakeupResult:
            // Callback: 唤醒结果
            NSLog(@"Callback: 唤醒结果");
            [self speechEngineResult:data];
            break;
        case SEFinalResult:
        case SEVolumeLevel:
            // Callback: 录音音量回调
            NSLog(@"Callback: 录音音量");
            break;
        default:
            break;
    }
}

#pragma mark - Engine Callback

- (void)speechEngineStarted {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.engineStarted = true;
        [self.statusTextView setText:@"Engine Started!"];
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
        self.startEngineButton.enabled = TRUE;
        self.stopEngineButton.enabled = FALSE;
        self.longPressButton.enabled = TRUE;
    });
}

- (void)speechEngineResult:(NSData *)data {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.resultTextView setText:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]];
    });
}

- (void)speechEngineError:(NSData *)data {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 从回调的 json 数据中解析错误码和错误详细信息
        id error_json = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
        if ([error_json isKindOfClass:[NSDictionary class]]) {
            NSDictionary *error_info = error_json;
            NSInteger error_code = [[error_info objectForKey:@"err_code"] intValue];
            switch (error_code) {
                case SEEncodingAudioError:
                    [self stopEngineBtnClicked:nil];
                    break;
                default:
                    break;
            }
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

- (void)updateWakeupWords {
    if (self.curEngine == nil) {
        return;
    }
    NSString* customWords = [self.settings getString:SETTING_KWS_CUSTOM_WORDS];
    if (customWords.length == 0) {
        return;
    }
    [self.curEngine sendDirective:SEDirectiveUpdateWakeupWordsParams data:customWords];
}

- (NSString*)getKwsModelName {
    return [self.settings getString:SETTING_KWS_MODEL_NAME];
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
    [nextPage setValue:VIEW_KWS forKey:@"viewId"];
}

@end


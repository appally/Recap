//
//  AsrOfflineViewController.m
//  SpeechDemo
//
//  Created by bytedance on 2020/9/8.
//  Copyright © 2020 fengkai.0518. All rights reserved.
//

#import "AsrOfflineViewController.h"

#import <AVFoundation/AVFoundation.h>

#import "AppDelegate.h"
#import "FileUtils.h"
#import "SettingsHelper.h"
#import "ViewController.h"
#import "SensitiveDefines.h"

@interface AsrOfflineViewController () <SpeechEngineDelegate, UITextViewDelegate>

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

static NSString *SLARDAR_ASR_SERVICE_NAME = @"asr_statistics";
static NSString *SLARDAR_ASR_EVENT_RESPONSE_DELAY = @"asr_response_delay";

@implementation AsrOfflineViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.settings = [[SettingsHelper shareInstance]getSettings:VIEW_ASR_OFFLINE];
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
        case SEAsrPartialResult:
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
    [self.resultTextView setText:@"点击或按住说话后，展示语音识别结果"];
}

- (IBAction)startEngine:(id)sender {
    NSLog(@"Start engine.");
    [self.curEngine setStringParam:[self.settings getString:SETTING_APPID] forKey:SE_PARAMS_KEY_APP_ID_STRING];
    [self.curEngine setBoolParam:[self.settings getBool:SETTING_ASR_ENABLE_ITN] forKey:SE_PARAMS_KEY_ASR_ENABLE_ITN_BOOL];
    [self.curEngine setBoolParam:TRUE forKey:SE_PARAMS_KEY_ASR_AUTO_STOP_BOOL];
    [self.curEngine setIntParam:[self.settings getInt:SETTING_VAD_MAX_SPEECH_DURATION] forKey:SE_PARAMS_KEY_VAD_MAX_SPEECH_DURATION_INT];
    //【可选配置】控制识别结果返回的形式，全量返回或增量返回，默认为全量
    [self.curEngine setStringParam:[self.settings getOptionsValue:SETTING_ASR_RESULT_TYPE] forKey:SE_PARAMS_KEY_ASR_RESULT_TYPE_STRING];

    if ([[self getRecorderType] isEqualToString:SE_RECORDER_TYPE_STREAM]) {
        [self.curEngine setIntParam:[self.streamRecorder getSampleRate] forKey:SE_PARAMS_KEY_CUSTOM_SAMPLE_RATE_INT];
        [self.curEngine setIntParam:[self.streamRecorder getChannel] forKey:SE_PARAMS_KEY_CUSTOM_CHANNEL_INT];
        if (![self.streamRecorder start]) {
            [self speechEngineNoPermission];
            return;
        }
    } else if ([[self getRecorderType] isEqualToString:SE_RECORDER_TYPE_FILE]) {
        NSString* file_path = [NSString stringWithFormat:@"%@/%@", self.debugPath, @"asr_rec_file.pcm"];
        NSLog(@"test file path: %@", file_path);
        [self.curEngine setStringParam:file_path forKey:SE_PARAMS_KEY_RECORDER_FILE_STRING];
    }
    [self.curEngine sendDirective:SEDirectiveSyncStopEngine];
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
        [self.curEngine setStringParam:[self.settings getString:SETTING_APPID] forKey:SE_PARAMS_KEY_APP_ID_STRING];
        [self.curEngine setBoolParam:[self.settings getBool:SETTING_ASR_ENABLE_ITN] forKey:SE_PARAMS_KEY_ASR_ENABLE_ITN_BOOL];
        [self.curEngine setBoolParam:FALSE forKey:SE_PARAMS_KEY_ASR_AUTO_STOP_BOOL];
        [self.curEngine setIntParam:[self.settings getInt:SETTING_VAD_MAX_SPEECH_DURATION] forKey:SE_PARAMS_KEY_VAD_MAX_SPEECH_DURATION_INT];
        
        if ([[self getRecorderType] isEqualToString:SE_RECORDER_TYPE_STREAM]) {
            [self.curEngine setIntParam:[self.streamRecorder getSampleRate] forKey:SE_PARAMS_KEY_CUSTOM_SAMPLE_RATE_INT];
            [self.curEngine setIntParam:[self.streamRecorder getChannel] forKey:SE_PARAMS_KEY_CUSTOM_CHANNEL_INT];
            if (![self.streamRecorder start]) {
                [self speechEngineNoPermission];
                return;
            }
        } else if ([[self getRecorderType] isEqualToString:SE_RECORDER_TYPE_FILE]) {
            NSString* file_path = [NSString stringWithFormat:@"%@/%@", self.debugPath, @"asr_rec_file.pcm"];
            NSLog(@"test file path: %@", file_path);
            [self.curEngine setStringParam:file_path forKey:SE_PARAMS_KEY_RECORDER_FILE_STRING];
        }
        
        [self.curEngine sendDirective:SEDirectiveSyncStopEngine];
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

    if (![self.settings getBool:SETTING_ASR_ENABLE_RESOURCE_DOWNLOAD]) {
        [self initEngineInternal];
    } else {
        SpeechResourceManager *resourceManager = [SpeechResourceManager shareInstance];
        if ([resourceManager checkModelExist:[self getAsrModelName]]) {
            [resourceManager checkModelVersion:[self getAsrModelName] completion:^(SEResourceStatus status, BOOL needUpdate, NSData *data) {
                if (status == kSERSuccess) {
                    if (needUpdate) {
                        [self fetchAsrResource];
                    } else {
                        [self initEngineInternal];
                    }
                } else {
                    NSLog(@"Model check failed: %@", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
                    [self.resultTextView setText:@"Failed to check asr resource"];
                    [self speechEngineInitFailed];
                }
            }];
        } else {
            [self fetchAsrResource];
        }
    }
}

- (void)fetchAsrResource {
    SpeechResourceManager *resourceManager = [SpeechResourceManager shareInstance];
    
    [resourceManager fetchModelByName:[self getAsrModelName] completion:^(SEResourceStatus status, NSData* data) {
        if (status == kSERSuccess) {
            [self initEngineInternal];
        } else {
            [self.resultTextView setText:@"Failed to fetch asr resource"];
            [self speechEngineInitFailed];
        }
    }];
}

- (void)initEngineInternal {
    if (self.curEngine == nil) {
        self.curEngine = [[SpeechEngine alloc] init];
    }
    if (![self.curEngine createEngineWithDelegate:self]) {
        NSLog(@"Create speech engine failed.");
        return;
    }

    [self.resultTextView setTextColor:UIColor.blackColor];
    NSLog(@"Engine version: %@", [self.curEngine getVersion]);
    self.debugPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSLog(@"Debug path: %@", self.debugPath);
    NSString* modelsPath = [NSString stringWithFormat:@"%@/models", self.debugPath];
    if ([self.settings getBool:SETTING_ASR_ENABLE_RESOURCE_DOWNLOAD]) {
        SpeechResourceManager *resourceManager = [SpeechResourceManager shareInstance];
        modelsPath = [resourceManager getModelPath:[self getAsrModelName]];
    }
    NSLog(@"Asr model path: %@", modelsPath);

    //【必需配置】离线合成鉴权相关：证书文件存放路径
    [self.curEngine setStringParam:self.debugPath forKey:SE_PARAMS_KEY_LICENSE_DIRECTORY_STRING];
    NSString* authenticationType = [self getAuthenticationType];
    //【必需配置】Authenticate Type
    [self.curEngine setStringParam:authenticationType forKey:SE_PARAMS_KEY_AUTHENTICATE_TYPE_STRING];
    if ([authenticationType isEqualToString:SE_AUTHENTICATE_TYPE_PRE_BIND]) {
        // 按包名授权，获取到授权的 APP 可以不限次数、不限设备数的使用离线合成
        NSString *licenseName = [self.settings getString:SETTING_LICENSE_NAME];
        NSString *licenseBusiId = [self.settings getString:SETTING_LICENSE_BUSI_ID];
        // 证书名和业务 ID, 离线合成鉴权相关，使用火山提供的证书下发服务时为【必需配置】, 否则为【无需配置】
        // 证书名，用于下载按报名授权的证书文件
        [self.curEngine setStringParam:licenseName forKey:SE_PARAMS_KEY_LICENSE_NAME_STRING];
        // 业务 ID, 用于下载按报名授权的证书文件
        [self.curEngine setStringParam:licenseBusiId forKey:SE_PARAMS_KEY_LICENSE_BUSI_ID_STRING];
    } else if ([authenticationType isEqualToString:SE_AUTHENTICATE_TYPE_LATE_BIND]) {
        // 按装机量授权，不限制 APP 的包名和使用次数，但是限制使用离线合成的设备数量
        //【必需配置】离线合成鉴权相关：Authenticate Address
        [self.curEngine setStringParam:SDEF_AUTHENTICATE_ADDRESS forKey:SE_PARAMS_KEY_AUTHENTICATE_ADDRESS_STRING];
        //【必需配置】离线合成鉴权相关：Authenticate Uri
        [self.curEngine setStringParam:SDEF_AUTHENTICATE_URI forKey:SE_PARAMS_KEY_AUTHENTICATE_URI_STRING];
        NSString* curBusinessKey = [self.settings getString:SETTING_BUSINESS_KEY];
        NSString* curAuthenticateSecret = [self.settings getString:SETTING_AUTHENTICATE_SECRET];
        //【必需配置】离线合成鉴权相关：Business Key
        [self.curEngine setStringParam:curBusinessKey forKey:SE_PARAMS_KEY_BUSINESS_KEY_STRING];
        //【必需配置】离线合成鉴权相关：Authenticate Secret
        [self.curEngine setStringParam:curAuthenticateSecret forKey:SE_PARAMS_KEY_AUTHENTICATE_SECRET_STRING];
    }

    [self.curEngine setStringParam:self.debugPath forKey:SE_PARAMS_KEY_DEBUG_PATH_STRING];
    [self.curEngine setStringParam:SE_LOG_LEVEL_TRACE forKey:SE_PARAMS_KEY_LOG_LEVEL_STRING];
    [self.curEngine setStringParam:[self.settings getString:SETTING_APPID] forKey:SE_PARAMS_KEY_APP_ID_STRING];
    [self.curEngine setStringParam:@"388808087185088" forKey:SE_PARAMS_KEY_UID_STRING];
    [self.curEngine setIntParam:1 forKey:SE_PARAMS_KEY_CHANNEL_NUM_INT];
    [self.curEngine setStringParam:@"" forKey:SE_PARAMS_KEY_ASR_REC_PATH_STRING];
    if ([self.settings getBool:SETTING_ASR_RECORDER_SAVE]) {
        [self.curEngine setStringParam:self.debugPath forKey:SE_PARAMS_KEY_ASR_REC_PATH_STRING];
    }
    [self.curEngine setStringParam:[self getRecorderType] forKey:SE_PARAMS_KEY_RECORDER_TYPE_STRING];
    [self.curEngine setStringParam:SE_ASR_ENGINE forKey:SE_PARAMS_KEY_ENGINE_NAME_STRING];
    [self.curEngine setIntParam:16000 forKey:SE_PARAMS_KEY_SAMPLE_RATE_INT];
    [self.curEngine setBoolParam:true forKey:SE_PARAMS_KEY_ASR_SHOW_UTTER_BOOL];
    [self.curEngine setBoolParam:[self.settings getBool:SETTING_ASR_SHOW_LANGUAGE] forKey:SE_PARAMS_KEY_ASR_SHOW_LANG_BOOL];
    [self.curEngine setBoolParam:true forKey:SE_PARAMS_KEY_ASR_SHOW_VOLUME_BOOL];
    [self.curEngine setIntParam:SEAsrWorkModeOfflineFlute forKey:SE_PARAMS_KEY_ASR_WORK_MODE_INT];
    [self.curEngine setStringParam:modelsPath forKey:SE_PARAMS_KEY_ASR_OFF_RESOURCE_PATH_STRING];
    
    if ([[self getRecorderType] isEqualToString:SE_RECORDER_TYPE_STREAM]) {
        if ([self.streamRecorder getSampleRate] != 16000 || [self.streamRecorder getChannel] != 1) {
            [self.curEngine setBoolParam:TRUE forKey:SE_PARAMS_KEY_ENABLE_RESAMPLER_BOOL];
        }
    }
    
    SEEngineErrorCode ret = [self.curEngine initEngine];
    if (ret != SENoError) {
        NSLog(@"Init Engine failed: %d", ret);
    }
    if (ret == SENoError) {
        [self speechEngineInitOk];
    } else {
        [self.resultTextView setText:[NSString stringWithFormat:@"Failed to init engine: %d", ret]];
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

- (void)uninitEngine {
    if (self.curEngine != nil) {
        NSLog(@"引擎析构");
        [self.curEngine destroyEngine];
        self.curEngine = nil;
        NSLog(@"引擎析构完成");
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        self.engineInitButton.enabled = TRUE;
        self.engineUninitButton.enabled = FALSE;
        self.startEngineButton.enabled = FALSE;
        self.stopEngineButton.enabled = FALSE;
        self.longPressButton.enabled = FALSE;
    });
}

- (void)setHotWords:(NSString*) hotWords {
    [self.curEngine sendDirective:SEDirectiveUpdateAsrHotWords data: hotWords];
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
    [self.streamRecorder setSpeechEngine:VIEW_ASR_OFFLINE engine:self.curEngine];
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
        
        NSString* dataStr = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        NSMutableString *text = [[NSMutableString alloc] initWithString:@""];
        [text appendFormat:@"result: %@", dataStr];
        if (isFinal) {
            [text appendFormat:@"\nresponse_delay: %ld", response_delay];
        }
        if (text.length) {
            [self.resultTextView setText:[text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
        }
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

- (NSString*)getAsrModelName {
    return [self.settings getString:SETTING_ASR_MODEL_NAME];
}

#pragma mark - Helper

- (NSString*)getAuthenticationType {
    switch ([self.settings getOptions:SETTING_AUTHENTICATION_TYPE].chooseIdx) {
        case 0:
            return SE_AUTHENTICATE_TYPE_PRE_BIND;
        case 1:
            return SE_AUTHENTICATE_TYPE_LATE_BIND;
        default:
            break;
    }
    return SE_AUTHENTICATE_TYPE_PRE_BIND;
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
    [nextPage setValue:VIEW_ASR_OFFLINE forKey:@"viewId"];
}

@end


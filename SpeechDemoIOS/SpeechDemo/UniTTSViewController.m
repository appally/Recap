//
//  UniTTSViewController.m
//  SpeechDemo
//
//  Created by ByteDance on 2025/7/3.
//  Copyright © 2025 ByteDance. All rights reserved.
//

#import "UniTTSViewController.h"
#include <CoreFoundation/CoreFoundation.h>
#include <objc/objc.h>

#import <AVFoundation/AVFoundation.h>

#import "AppDelegate.h"
#import "FileUtils.h"
#import "SettingsHelper.h"
#import "ViewController.h"
#import "SensitiveDefines.h"

@interface UniTTSViewController () <SpeechEngineDelegate, UITextViewDelegate>

@property (weak, nonatomic) IBOutlet UITextView *referTextView;
@property (weak, nonatomic) IBOutlet UITextView *resultTextView;
@property (weak, nonatomic) IBOutlet UITextField *statusTextView;
@property (weak, nonatomic) IBOutlet UIButton *engineSwitchButton;
@property (weak, nonatomic) IBOutlet UIButton *startEngineButton;
@property (weak, nonatomic) IBOutlet UIButton *stopEngineButton;
@property (weak, nonatomic) IBOutlet UIButton *pauseResumeButton;

// Device ID: 用于定位线上问题
@property (nonatomic, strong) NSString *deviceID;
// Debug Path: 用于存放一些 SDK 相关的文件，比如模型、日志等
@property (strong, nonatomic) NSString *debugPath;

// SpeechEngine
@property (strong, nonatomic) SpeechEngine *curEngine;

// Engine State
@property (assign, nonatomic) BOOL engineInited;
@property (assign, nonatomic) BOOL engineStarted;
@property (assign, nonatomic) BOOL playerPaused;
// Settings
@property (strong, nonatomic) Settings *settings;

@end

@implementation UniTTSViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.settings = [[SettingsHelper shareInstance]getSettings:VIEW_UNITTS];
    
    self.engineSwitchButton.enabled = TRUE;
    self.referTextView.editable = TRUE;
    self.engineInited = FALSE;
    self.engineStarted = FALSE;
    self.playerPaused = FALSE;

    [self.referTextView setText:@"愿中国青年都摆脱冷气，只是向上走，不必听自暴自弃者流的话。能做事的做事，能发声的发声。有一分热，发一分光。就令萤火一般，也可以在黑暗里发一点光，不必等候炬火。此后如竟没有炬火：我便是唯一的光。"];
    [self.statusTextView setText:@"Waiting for init."];
    [ViewController setAppDelegate:(AppDelegate *)[[UIApplication sharedApplication] delegate]];
    
    self.debugPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSLog(@"当前调试路径 %@", self.debugPath);
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(audioInterruptionHandler:)
                                                 name:AVAudioSessionInterruptionNotification
                                               object:nil];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
}

#pragma mark - Notifications

-(void)appWillTerminate:(NSNotification*)note {
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:AVAudioSessionInterruptionNotification
                                                  object:nil];
}

- (void)audioInterruptionHandler:(NSNotification*)notification {
    AVAudioSessionInterruptionType interruptionType = (AVAudioSessionInterruptionType)[[notification.userInfo objectForKey:AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
    AVAudioSessionInterruptionOptions intertuptionOptions = [[notification.userInfo objectForKey:AVAudioSessionInterruptionOptionKey] unsignedIntValue];
    NSLog(@"Receive audio interruption notification, type: %lu, options: %lu.", (unsigned long)interruptionType, (unsigned long)intertuptionOptions);
    if (interruptionType == AVAudioSessionInterruptionTypeBegan) {
        NSLog(@"Audio session interruption began");
        @synchronized (self) {
            [self pausePlayback];
        }
    } else if (interruptionType == AVAudioSessionInterruptionTypeEnded) {
        @synchronized (self) {
            NSLog(@"Audio session interruption ended");
            if (intertuptionOptions == AVAudioSessionInterruptionOptionShouldResume) {
                AVAudioSession *session = [AVAudioSession sharedInstance];
                AVAudioSessionCategoryOptions cur_options = session.categoryOptions;
                // AudioQueueStart() will return AVAudioSessionErrorCodeCannotInterruptOthers if options didn't contains AVAudioSessionCategoryOptionMixWithOthers
                if (!(cur_options & AVAudioSessionCategoryOptionMixWithOthers)) {
                    AVAudioSessionCategoryOptions readyOptions = AVAudioSessionCategoryOptionMixWithOthers | cur_options;
                    [session setCategory:AVAudioSessionCategoryPlayback withOptions:readyOptions error:nil];
                }
                [self resumePlayback];
                
                cur_options = session.categoryOptions;
                // Remove AVAudioSessionCategoryOptionMixWithOthers, or the playback will not be interrupted any more
                if (cur_options & AVAudioSessionCategoryOptionMixWithOthers) {
                    [session setCategory:AVAudioSessionCategoryPlayback withOptions:((~AVAudioSessionCategoryOptionMixWithOthers) & cur_options) error:nil];
                }
            }
        }
    }
}

#pragma mark - Config & Init & Uninit Methods

-(void)configInitParams {
    //【必需配置】Engine Name（双向流式TTS Engine 也支持 单向流式TTS 功能）
    [self.curEngine setStringParam:SE_BITTS_ENGINE forKey:SE_PARAMS_KEY_ENGINE_NAME_STRING];

    //【可选配置】Debug & Log
    [self.curEngine setStringParam:self.debugPath forKey:SE_PARAMS_KEY_DEBUG_PATH_STRING];
    [self.curEngine setStringParam:SE_LOG_LEVEL_DEBUG forKey:SE_PARAMS_KEY_LOG_LEVEL_STRING];
    
    //【可选配置】User ID（用以辅助定位线上用户问题）
    [self.curEngine setStringParam:SDEF_UID forKey:SE_PARAMS_KEY_UID_STRING];
    [self.curEngine setStringParam:self.deviceID forKey:SE_PARAMS_KEY_DEVICE_ID_STRING];
    
    //【可选配置】是否将合成出的音频保存到设备上，为 true 时需要正确配置 PARAMS_KEY_TTS_AUDIO_PATH_STRING 才会生效
    [self.curEngine setBoolParam:[self.settings getBool:SETTING_TTS_ENABLE_DUMP]
                          forKey:SE_PARAMS_KEY_TTS_ENABLE_DUMP_BOOL];
    // TTS 音频文件保存目录，必须在合成之前创建好且 APP 具有访问权限，保存的音频文件名格式为 tts_{reqid}.wav, {reqid} 是本次合成的请求 id
    // PARAMS_KEY_TTS_ENABLE_DUMP_BOOL 配置为 true 的音频时为【必需配置】，否则为【可选配置】
    [self.curEngine setStringParam:self.debugPath forKey:SE_PARAMS_KEY_TTS_AUDIO_PATH_STRING];
    //【可选配置】自定义请求Header
    [self.curEngine setStringParam:[self.settings getString:SETTING_REQUEST_HEADERS] forKey:SE_PARAMS_KEY_REQUEST_HEADERS_STRING];
    //【可选配置】是否使用 SDK 内置播放器播放合成出的音频，默认为 true
    [self.curEngine setBoolParam:[self.settings getBool:SETTING_TTS_ENABLE_PLAYER]
                          forKey:SE_PARAMS_KEY_TTS_ENABLE_PLAYER_BOOL];
    //【可选配置】是否令 SDK 通过回调返回合成的音频数据，默认不返回。
    // 开启后，SDK 会流式返回音频，收到 SETtsAudioData 回调表示当次合成所有的音频已经全部返回
    [self.curEngine setBoolParam:[self.settings getBool:SETTING_ENABLE_PLAYER_AUDIO_CALL_BACK] ? SETtsDataCallbackModeAll : SETtsDataCallbackModeNone forKey:SE_PARAMS_KEY_ENABLE_PLAYER_AUDIO_CALLBACK_BOOL];
    
    // ------------------------ 在线合成相关配置 -----------------------
    //【必需配置】在线合成鉴权相关：Appid
    [self.curEngine setStringParam:[self.settings getString:SETTING_APPID] forKey:SE_PARAMS_KEY_APP_ID_STRING];
    //【必需配置】在线合成鉴权相关：Token
    [self.curEngine setStringParam:[self.settings getString:SETTING_TOKEN] forKey:SE_PARAMS_KEY_APP_TOKEN_STRING];
    //【必需配置】语音合成服务域名
    [self.curEngine setStringParam:[self.settings getString:SETTING_ADDRESS] forKey:SE_PARAMS_KEY_TTS_ADDRESS_STRING];
    //【必需配置】语音合成服务Uri
    [self.curEngine setStringParam:[self.settings getString:SETTING_URI] forKey:SE_PARAMS_KEY_TTS_URI_STRING];
    //【必需配置】语音合成服务资源id
    [self.curEngine setStringParam:[self.settings getString:SETTING_RESOURCE_ID] forKey: SE_PARAMS_KEY_RESOURCE_ID_STRING];
    //【可选配置】TTS连接超时时间
    [self.curEngine setIntParam:10000 forKey:SE_PARAMS_KEY_TTS_CONN_TIMEOUT_INT];
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
    NSLog(@"SDK 版本号: %@", [self.curEngine getVersion]);
    [self initEngineInternal];
}

- (void)initEngineInternal {
    NSLog(@"配置初始化参数");
    [self configInitParams];
    
    NSLog(@"引擎初始化");
    SEEngineErrorCode ret = [self.curEngine initEngine];
    self.engineInited = (ret == SENoError);
    if (self.engineInited) {
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
}

#pragma mark - UI Actions

- (IBAction)switchEngine:(id)sender {
    if (self.engineStarted) {
        [self.statusTextView setText:@"Engine is busy, stop it first!"];
        return;
    }
    [self clearResult:nil];
    self.startEngineButton.enabled = FALSE;
    self.pauseResumeButton.enabled = FALSE;
    if (self.engineInited) {
        self.referTextView.editable = TRUE;
        [self uninitEngine];
        self.engineInited = FALSE;
        [self.statusTextView setText:@"Waiting for init."];
        self.engineSwitchButton.enabled = TRUE;
        [self.engineSwitchButton setTitle:@"Init Engine" forState:UIControlStateNormal];
        self.stopEngineButton.enabled = FALSE;
    } else {
        self.referTextView.editable = TRUE;
        [self initEngine];
    }
}

- (IBAction)startEngineBtnClicked:(id)sender {
    NSLog(@"Start engine, current status: %d", self.engineStarted);
    if (!self.engineStarted) {
        [self clearResult:nil];
        
        // Directive：启动引擎前调用SYNC_STOP指令，保证前一次请求结束。
        NSLog(@"关闭引擎（同步）");
        NSLog(@"Directive: SEDirectiveSyncStopEngine");
        SEEngineErrorCode ret = [self.curEngine sendDirective:SEDirectiveSyncStopEngine];
        if (ret != SENoError) {
            NSLog(@"Send directive syncstop failed: %d", ret);
        } else {
            
            NSLog(@"启动引擎.");
            NSLog(@"Directive: SEDirectiveStartEngine");
            NSString* startPayload = [NSString stringWithFormat:@"{\"req_params\":{\"text\":\"%@\",\"speaker\":\"zh_female_roumeinvyou_emo_v2_mars_bigtts\",\"audio_params\":{\"emotion\":\"excited\",\"loudness_rate\":50}}}", self.referTextView.text];
            SEEngineErrorCode ret = [self.curEngine sendDirective:SEDirectiveStartEngine data:startPayload];
            if (SENoError != ret) {
                NSString* message = [NSString stringWithFormat:@"发送启动引擎指令失败: %d", ret];
                [self sendStartEngineDirectiveFailed:message];
                return;
            }
            ret = [self.curEngine sendDirective:SEDirectiveEventStartSession data:@""];
            if (ret != SENoError) {
                NSLog(@"Start Session faile: %d", ret);
            }
        }
    }
}

- (IBAction)stopEngineBtnClicked:(id)sender {
    NSLog(@"关闭引擎");
    NSLog(@"Directive: SEDirectiveStopEngine");
    [self.curEngine sendDirective:SEDirectiveStopEngine];
}

- (void)pausePlayback {
    NSLog(@"暂停播放");
    NSLog(@"Directive: SEDirectivePausePlayer");
    SEEngineErrorCode ret = [self.curEngine sendDirective:SEDirectivePausePlayer];
    if (ret == SENoError) {
        self.playerPaused = TRUE;
        [self.pauseResumeButton setTitle:@"Resume" forState:UIControlStateNormal];
    }
    NSLog(@"Pause playback status: %d", ret);
}

- (void)resumePlayback {
    NSLog(@"继续播放");
    NSLog(@"Directive: SEDirectiveResumePlayer");
    SEEngineErrorCode ret = [self.curEngine sendDirective:SEDirectiveResumePlayer];
    if (ret == SENoError) {
        self.playerPaused = FALSE;
        [self.pauseResumeButton setTitle:@"Pause" forState:UIControlStateNormal];
    }
    NSLog(@"Resume playback status: %d", ret);
}

- (IBAction)controlPlayingStatus:(id)sender {
    NSLog(@"Pause or resume player, current player status: %hhd", self.playerPaused);
    if (self.playerPaused) {
        [self resumePlayback];
    } else {
        [self pausePlayback];
    }
}

- (IBAction)clearResult:(id)sender {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.resultTextView setText:@""];
    });
}

#pragma mark - Message Callback

- (void)onMessageWithType:(SEMessageType)type andData:(NSData *)data {
    NSLog(@"Message Type: %d.", type);
    switch (type) {
        case SEEngineStart:
            NSLog(@"Callback: 引擎启动成功: data: %@", data);
            [self speechEngineStarted];
            break;
        case SEEngineStop:
            NSLog(@"Callback: 引擎关闭: data: %@", data);
            [self speechEngineStopped];
            break;
        case SEEngineError:
            NSLog(@"Callback: 错误信息: %@", data);
            [self speechEngineError:data];
            break;
        case SEEventConnectionStarted:
            NSLog(@"Callback: SEEventConnectionStarted");
            break;
        case SEEventConnectionFailed:
            NSLog(@"Callback: SEEventConnectionFailed");
            break;
        case SEEventConnectionFinished:
            NSLog(@"Callback: SEEventConnectionFinished");
            break;
        case SEEventSessionStarted:
            NSLog(@"Callback: SEEventSessionStarted");
            break;
        case SEEventSessionCanceled:
            NSLog(@"Callback: SEEventSessionCanceled");
            break;
        case SEEventSessionFinished:
            NSLog(@"Callback: SEEventSessionFinished");
            break;
        case SEEventSessionFailed:
            NSLog(@"Callback: SEEventSessionFailed");
            break;
        case SEEventTTSSentenceStart:
            NSLog(@"Callback: 合成开始 SentenceStart: %@", data);
            break;
        case SEEventTTSSentenceEnd:
            NSLog(@"Callback: 合成结束 SentenceEnd: %@", data);
        case SEEventTTSResponse:
            NSLog(@"Callback: 收到合成音频 TTSResponse: %@", data);
        case SEEventTTSEnded:
            NSLog(@"Callback: TTSEnd: %@", data);
        case SEPlayerAudioData:
            NSLog(@"Callback: 接收到播放的pcm音频");
            break;
        case SEPlayerStartPlayAudio:
            NSLog(@"Callback: 开始播放TTS音频");
            [self speechStartPlaying:nil];
            break;
        case SEPlayerFinishPlayAudio:
            NSLog(@"Callback: 结束播放TTS音频");
            [self speechFinishPlaying:nil];
            break;
        default:
            break;
    }
}

- (void)speechEngineInitSucceeded {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.engineSwitchButton.enabled = TRUE;
        [self.engineSwitchButton setTitle:@"UninitEngine" forState:UIControlStateNormal];
        [self.statusTextView setText:@"Ready"];
        [self.resultTextView setText:[NSString stringWithFormat:@"DeviceID: %@.", self.deviceID]];
        self.referTextView.editable = TRUE;
        self.startEngineButton.enabled = TRUE;
    });
}

- (void)speechEngineInitFailed:(int)initStatus {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self uninitEngine];
        [self.statusTextView setText:[[NSString alloc] initWithFormat:@"Failed to init engine, %d!", initStatus]];
        self.engineSwitchButton.enabled = TRUE;
    });
}

- (void)sendSynthesisDirectiveFailed:(NSString*)tipText {
    NSLog(@"%@", tipText);
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.resultTextView setText:tipText];
        [self.curEngine sendDirective:SEDirectiveStopEngine];
    });
}

- (void)sendStartEngineDirectiveFailed:(NSString*)tipText {
    NSLog(@"%@", tipText);
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.resultTextView setText:tipText];
        self.engineStarted = FALSE;
    });
}

- (void)speechEngineStarted {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.referTextView.editable = TRUE;
        self.engineStarted = true;
        [self.statusTextView setText:@"Engine Started!"];
        self.startEngineButton.enabled = FALSE;
        self.stopEngineButton.enabled = TRUE;
    });
}

- (void)speechEngineStopped {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.referTextView.editable = TRUE;
        self.engineStarted = FALSE;
        [self.statusTextView setText:@"Engine Stopped!"];
        self.startEngineButton.enabled = TRUE;
        self.stopEngineButton.enabled = FALSE;
        [self.pauseResumeButton setTitle:@"Pause" forState:UIControlStateNormal];
        self.pauseResumeButton.enabled = FALSE;
        self.playerPaused = FALSE;
    });
}

- (void)speechEngineError:(NSData *)data {
    dispatch_async(dispatch_get_main_queue(), ^{
        id json_obj = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
        if ([json_obj isKindOfClass:[NSDictionary class]]) {
            NSDictionary *error_info = json_obj;
            [self setResultText:[NSString stringWithFormat:@"%@", error_info]];
        }
    });
}

- (void)setResultText:(NSString *)result {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *currentText = self.resultTextView.text ?: @"";
        NSString *newText = [NSString stringWithFormat:@"%@\n%@", currentText, result];
        [self.resultTextView setText:newText];
        if (self.resultTextView.text.length > 0) {
            NSRange bottomRange = NSMakeRange(self.resultTextView.text.length - 1, 1);
            [self.resultTextView scrollRangeToVisible:bottomRange];
            [self.resultTextView layoutIfNeeded];
        }
    });
}

- (void)speechStartPlaying:(NSData *)data {
    NSLog(@"TTS start playing");
    dispatch_async(dispatch_get_main_queue(), ^{
        self.pauseResumeButton.enabled = TRUE;
    });
}

- (void)speechFinishPlaying :(NSData *)data {
    NSLog(@"TTS finish playing");
    [self setResultText:@"playing finished"];
    dispatch_async(dispatch_get_main_queue(), ^{
        // 播放结束，停止引擎
        [self stopEngineBtnClicked:nil];
    });
}

#pragma mark - Navigation

// In a storyboard-based application, you will often want to do a little preparation before navigation
- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    // Get the new view controller using [segue destinationViewController].
    // Pass the selected object to the new view controller.
    id nextPage = [segue destinationViewController];
    [nextPage setValue:VIEW_UNITTS forKey:@"viewId"];
}

@end

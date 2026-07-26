//
//  BiTTSViewController.m
//  SpeechDemo
//
//  Created by ByteDance on 2025/7/3.
//  Copyright © 2025 fangweiwei. All rights reserved.
//

#import "BiTTSViewController.h"
#include <CoreFoundation/CoreFoundation.h>
#include <objc/objc.h>

#import <AVFoundation/AVFoundation.h>

#import "AppDelegate.h"
#import "FileUtils.h"
#import "SettingsHelper.h"
#import "ViewController.h"
#import "SensitiveDefines.h"

static int TTS_MAX_RETRY_COUNT = 3;

@interface BiTTSViewController () <SpeechEngineDelegate, UITextViewDelegate>

@property (weak, nonatomic) IBOutlet UITextView *referTextView;
@property (weak, nonatomic) IBOutlet UITextView *resultTextView;
@property (weak, nonatomic) IBOutlet UITextField *statusTextView;
@property (weak, nonatomic) IBOutlet UIButton *engineSwitchButton;
@property (weak, nonatomic) IBOutlet UIButton *startEngineButton;
@property (weak, nonatomic) IBOutlet UIButton *stopEngineButton;
@property (weak, nonatomic) IBOutlet UIButton *synthesisButton;
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
@property (assign, nonatomic) BOOL engineErrorOccurred;
@property (assign, nonatomic) BOOL playerPaused;
@property (assign, nonatomic) BOOL refTextChanged;
// Settings
@property (strong, nonatomic) Settings *settings;

// 一些在线合成的配置
@property (strong, nonatomic) NSString *ttsAppId;
@property (strong, nonatomic) NSString *ttsVoiceOnline;
@property (strong, nonatomic) NSString *ttsVoiceTypeOnline;


// tts合成文本相关
@property (assign, nonatomic) int ttsSynthesisIndex;
@property (strong, nonatomic) NSMutableArray* ttsSynthesisText;
@property (strong, nonatomic) NSMutableDictionary* ttsSynthesisMap;

@property (assign, nonatomic) int ttsRetryCount;

@end

@implementation BiTTSViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.settings = [[SettingsHelper shareInstance]getSettings:VIEW_BITTS];
    
    self.engineSwitchButton.enabled = TRUE;
    [self decorateTextView:self.referTextView];
    [self decorateTextView:self.resultTextView];
    [self.referTextView setDelegate:self];
    self.referTextView.editable = TRUE;
    self.engineInited = FALSE;
    self.engineStarted = FALSE;
    self.engineErrorOccurred = FALSE;
    self.playerPaused = FALSE;
    
    // 初始化和tts有关的字段
    self.ttsSynthesisIndex = 0;
    self.ttsSynthesisText = [[NSMutableArray alloc] init];
    self.ttsSynthesisMap = [[NSMutableDictionary alloc]init];
    
    self.ttsRetryCount = TTS_MAX_RETRY_COUNT;

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

- (void)decorateTextView:(UITextView *)textView {
    textView.layer.cornerRadius = 5.0f;
    textView.layer.borderWidth = .25f;
    textView.layer.borderColor = [UIColor grayColor].CGColor;
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
    //【必需配置】Engine Name
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
    NSString* headerStr = [self.settings getString:SETTING_REQUEST_HEADERS];
    if ([headerStr isEqualToString:@""]) {
        headerStr = @"{}";
    }
    [self.curEngine setStringParam:headerStr forKey:SE_PARAMS_KEY_REQUEST_HEADERS_STRING];
    
    //【可选配置】是否使用 SDK 内置播放器播放合成出的音频，默认为 true
    [self.curEngine setBoolParam:[self.settings getBool:SETTING_TTS_ENABLE_PLAYER]
                          forKey:SE_PARAMS_KEY_TTS_ENABLE_PLAYER_BOOL];
    //【可选配置】是否令 SDK 通过回调返回合成的音频数据，默认不返回。
    // 开启后，SDK 会流式返回音频，收到 SETtsAudioData 回调表示当次合成所有的音频已经全部返回
    [self.curEngine setBoolParam:[self.settings getBool:SETTING_ENABLE_PLAYER_AUDIO_CALL_BACK] ? SETtsDataCallbackModeAll : SETtsDataCallbackModeNone forKey:SE_PARAMS_KEY_ENABLE_PLAYER_AUDIO_CALLBACK_BOOL];
    
    // ------------------------ 在线合成相关配置 -----------------------
    
    //【必需配置】新版在线合成鉴权相关：api-key
    NSString* api_key = [self.settings getString:SETTING_API_KEY];
    if (api_key.length == 0) {
        api_key = SDEF_API_KEY;
    }
    [self.curEngine setStringParam:api_key forKey:SE_PARAMS_KEY_API_KEY_STRING];
    
    
//    NSString* appid = [self.settings getString:SETTING_APPID];
//    self.ttsAppId = appid.length > 0 ? appid : SDEF_APPID;
//    //【必需配置】旧版在线合成鉴权相关：Appid
//    [self.curEngine setStringParam:self.ttsAppId forKey:SE_PARAMS_KEY_APP_ID_STRING];
//    
//    NSString* token = [self.settings getString:SETTING_TOKEN];
//    NSString* ttsAppToken = token.length > 0 ? token : SDEF_TOKEN;
//    //【必需配置】旧版在线合成鉴权相关：Token
//    [self.curEngine setStringParam:ttsAppToken forKey:SE_PARAMS_KEY_APP_TOKEN_STRING];
    
    
    NSString *address = [self.settings getString:SETTING_ADDRESS];
    NSString *ttsAddress = address.length > 0 ? address : SDEF_DEFAULT_ADDRESS;
    //【必需配置】语音合成服务域名
    [self.curEngine setStringParam:ttsAddress forKey:SE_PARAMS_KEY_TTS_ADDRESS_STRING];
    
    NSString *uri = [self.settings getString:SETTING_URI];
    NSString *ttsUri = uri.length > 0 ? uri : SDEF_BITTS_DEFAULT_URI;
    //【必需配置】语音合成服务Uri
    [self.curEngine setStringParam:ttsUri forKey:SE_PARAMS_KEY_TTS_URI_STRING];
    
    NSString *resourceId = [self.settings getString:SETTING_RESOURCE_ID];
    //【必需配置】语音合成服务资源id
    [self.curEngine setStringParam:resourceId forKey: SE_PARAMS_KEY_RESOURCE_ID_STRING];
    //【可选配置】TTS连接超时时间
    [self.curEngine setIntParam:10000 forKey:SE_PARAMS_KEY_TTS_CONN_TIMEOUT_INT];
}

-(void)configStartTtsParams {
    // 准备待合成的文本
    if(![self prepareBiTTSText]) {
        char fake_error_info[] = "{err_code:3006, err_msg:\"Invalid input text.\"}";
        [self speechEngineError:[NSData dataWithBytes:fake_error_info length:sizeof(fake_error_info)]];
        return;
    }
}

- (NSString*)getSynthesisText {
    if(self.refTextChanged){ //如果文本有变更重新追加进去
        self.refTextChanged = FALSE;
        
        __block NSString* refText = nil;
        if (![NSThread isMainThread]) {
            dispatch_sync(dispatch_get_main_queue(), ^{
                refText = self.referTextView.text;
            });
        } else {
            refText = self.referTextView.text; // 已经在主线程，直接赋值
        }
        
        if (refText.length > 0) {
            NSError *error = nil;
            NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"[^;!?。！？；…]+[;!?。！？；…]?" options:0 error:&error];
            
            if (!error) {
                NSArray<NSTextCheckingResult *> *matches = [regex matchesInString:refText options:0 range:NSMakeRange(0, refText.length)];
                
                for (NSTextCheckingResult *match in matches) {
                    NSString *sentence = [refText substringWithRange:match.range];
                    [self addSentence:sentence];
                }
            }
        }
    }
    
    if(self.ttsSynthesisIndex == [self.ttsSynthesisText count]){
        NSLog(@"no more tts conttent to synthesis");
        [self updateTtsResultText:@"No More Text to Synthesis"];
        return nil;
    }
    
    NSString* text = self.ttsSynthesisText[self.ttsSynthesisIndex];
    NSLog(@"Synthesis: %d, text: %@", self.ttsSynthesisIndex, text);
    self.ttsSynthesisIndex = (self.ttsSynthesisIndex + 1);
    return text;
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
    self.synthesisButton.enabled = FALSE;
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

- (IBAction)Synthesis:(id)sender {
    [self triggerSynthesis];
}

- (IBAction)startEngineBtnClicked:(id)sender {
    NSLog(@"Start engine, current status: %d", self.engineStarted);
    if (!self.engineStarted) {
        [self clearResult:nil];
        self.engineErrorOccurred = FALSE;
        
        // Directive：启动引擎前调用SYNC_STOP指令，保证前一次请求结束。
        NSLog(@"关闭引擎（同步）");
        NSLog(@"Directive: SEDirectiveSyncStopEngine");
        SEEngineErrorCode ret = [self.curEngine sendDirective:SEDirectiveSyncStopEngine];
        if (ret != SENoError) {
            NSLog(@"Send directive syncstop failed: %d", ret);
        } else {
            [self configStartTtsParams];
            
            NSLog(@"启动引擎.");
            NSLog(@"Directive: SEDirectiveStartEngine");
            NSString* startPayload = @"{\"req_params\":{\"speaker\":\"zh_female_vv_uranus_bigtts\",\"audio_params\":{\"enable_subtitle\":true,\"emotion\":\"excited\",\"loudness_rate\":50}}}";
            SEEngineErrorCode ret = [self.curEngine sendDirective:SEDirectiveStartEngine data:startPayload];
            if (SENoError != ret) {
                NSString* message = [NSString stringWithFormat:@"发送启动引擎指令失败: %d", ret];
                [self sendStartEngineDirectiveFailed:message];
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
            [self speechStartSynthesis:data];
            NSLog(@"Callback: 合成开始 SentenceStart: %@", data);
            break;
        case SEEventTTSSentenceEnd:
            [self speechFinishSynthesis:data];
            NSLog(@"Callback: 合成结束 SentenceEnd: %@", data);
            break;
        case SEEventTTSResponse:
            NSLog(@"Callback: 收到合成音频 TTSResponse: %@", data);
            break;
        case SEEventTTSSubtitle:
            NSLog(@"Callback: 收到 TTSSubtitle: %@", data);
            break;
        case SEEventTTSEnded:
            NSLog(@"Callback: TTSEnd: %@", data);
            break;
        case SEPlayerAudioData:
//            NSLog(@"Callback: 播放的pcm音频: %@", data);
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

- (void)onSpeechLogid:(NSString *)logid {
    NSLog(@"Callback: logid: %@", logid);
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
    self.ttsRetryCount = TTS_MAX_RETRY_COUNT;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.referTextView.editable = TRUE;
        self.engineStarted = true;
        [self.statusTextView setText:@"Engine Started!"];
        self.startEngineButton.enabled = FALSE;
        self.synthesisButton.enabled = TRUE;
        self.stopEngineButton.enabled = TRUE;
    });
}

- (void)speechEngineStopped {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.referTextView.editable = TRUE;
        self.engineStarted = FALSE;
        [self.statusTextView setText:@"Engine Stopped!"];
        self.startEngineButton.enabled = TRUE;
        self.synthesisButton.enabled = FALSE;
        self.stopEngineButton.enabled = FALSE;
        [self.pauseResumeButton setTitle:@"Pause" forState:UIControlStateNormal];
        self.pauseResumeButton.enabled = FALSE;
        self.playerPaused = FALSE;
    });
}

- (void)speechEngineError:(NSData *)data {
    dispatch_async(dispatch_get_main_queue(), ^{
        
        BOOL needStop = NO;
        id json_obj = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
        if ([json_obj isKindOfClass:[NSDictionary class]]) {
            NSDictionary *error_info = json_obj;
            NSInteger code = [[error_info objectForKey:@"err_code"] intValue];
            switch (code) {
                case SETTSLimitQps:
                case SETTSLimitCount:
                case SETTSServerBusy:
                case SETTSLongText:
                case SETTSInvalidText:
                case SETTSSynthesisTimeout:
                case SETTSSynthesisError:
                case SETTSSynthesisWaitingTimeout:
                case SETTSErrorUnknown:
                    NSLog(@"When meeting this kind of error, continue to synthesize.");
                    [self triggerSynthesis];
                    break;
                case SEConnectTimeout:
                case SEReceiveTimeout:
                case SENetLibError:
                    // 遇到网络错误时建议重试，重试次数不超过 3 次
                    needStop = ![self retrySynthesis];
                    if (needStop) {
                        self.engineErrorOccurred = TRUE;
                    }
                    break;
                default:
                    needStop = YES;
                    self.engineErrorOccurred = TRUE;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self.resultTextView
                         setText:[[NSString alloc]
                                  initWithData:data
                                  encoding:NSUTF8StringEncoding]];
                    });
                    break;
            }
        } else {
            needStop = YES;
        }
        if (needStop) {
            [self.curEngine sendDirective:SEDirectiveStopEngine];
        }
    });
}

- (void)scrollTextViewToBottom {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.resultTextView.text.length > 0) {
            NSRange bottomRange = NSMakeRange(self.resultTextView.text.length - 1, 1);
            [self.resultTextView scrollRangeToVisible:bottomRange];
            [self.resultTextView layoutIfNeeded];
        }
    });
}

-(void)updateTtsResultText:(NSString*) playingId {
    if (self.engineErrorOccurred) {
        NSLog(@"When a fatal error occurs, prevent the playback text from being displayed.");
        return;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *currentText = self.resultTextView.text ?: @"";
        NSString *newText = [NSString stringWithFormat:@"%@\n%@", currentText, playingId];
        [self.resultTextView setText:newText];
    });
    
    [self scrollTextViewToBottom];
}

- (void)speechStartSynthesis:(NSData *)data {
    if (self.ttsSynthesisIndex < [self.ttsSynthesisText count]) {
        NSString* req_id = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        [self.ttsSynthesisMap setValue:[NSNumber numberWithInt:self.ttsSynthesisIndex] forKey:req_id];
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        self.synthesisButton.enabled = FALSE;
    });
}

- (void)speechFinishSynthesis:(NSData *)data {
    if (self.ttsRetryCount < TTS_MAX_RETRY_COUNT) {
        self.ttsRetryCount = TTS_MAX_RETRY_COUNT;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        self.synthesisButton.enabled = TRUE;
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
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateTtsResultText:@"playing finished"];
    });
    [self triggerSynthesis];
 
}

- (void)speechTtsAudioData:(NSData *)data {
}

- (BOOL)retrySynthesis {
    BOOL ret = FALSE;
    if (self.engineStarted && self.ttsRetryCount > 0) {
        NSLog(@"Retry synthesis for text: %@", self.ttsSynthesisText[self.ttsSynthesisIndex]);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [self triggerSynthesis];
        });
        self.ttsRetryCount -= 1;
        ret = TRUE;
    }
    return ret;
}

-(void)triggerSynthesis {
    NSString *text = [self getSynthesisText];
    if(text == nil){
        return;
    }
    
    SEEngineErrorCode ret = [self.curEngine sendDirective:SEDirectiveEventStartSession data:@""];
    if (ret != SENoError) {
        NSLog(@"Start Session faile: %d", ret);
    }
    
    NSString* taskRequestJson = [NSString stringWithFormat: @"{\"req_params\":{\"text\":\"%@\"}}", text];
    // SEDirectiveTaskRequest 是可以连续发送的，服务端会缓存每一句文本，然后按顺序通过sentence_start 、 task respnse...  sentence_end返回当前处理句的结果
    ret = [self.curEngine sendDirective:SEDirectiveEventTaskRequest data:taskRequestJson];
    [self updateTtsResultText:text];
    NSLog(@"触发合成");
    NSLog(@"Directive: SEDirectiveTaskRequest");
    if (ret != SENoError) {
        NSLog(@"Synthesis faile: %d", ret);
    }
    
    ret = [self.curEngine sendDirective:SEDirectiveEventFinishSession data:@""];
    if (ret != SENoError) {
        NSLog(@"Finish Session faile: %d", ret);
    }
}

-(void)addSentence:(NSString*) text {
    NSCharacterSet* blankChar = [NSCharacterSet characterSetWithCharactersInString:@" "];
    NSString* tmp = [text stringByTrimmingCharactersInSet:blankChar];
    if (tmp.length > 0) {
        [self.ttsSynthesisText addObject:tmp];
    }
}

-(void)resetTtsContext {
    self.ttsSynthesisIndex = 0;
    [self.ttsSynthesisText removeAllObjects];
    [self.ttsSynthesisMap removeAllObjects];
}

-(BOOL)prepareBiTTSText {
    [self resetTtsContext];
    __block NSString* text = nil;
    if (![NSThread isMainThread]) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            text = self.referTextView.text;
        });
    } else {
        text = self.referTextView.text; // 已经在主线程，直接赋值
    }
    if (text.length <= 0) {
        text = @"愿中国青年都摆脱冷气，只是向上走，不必听自暴自弃者流的话。能做事的做事，能发声的发声。有一分热，发一分光。就令萤火一般，也可以在黑暗里发一点光，不必等候炬火。此后如竟没有炬火：我便是唯一的光。";
    }
    if (self.ttsSynthesisText == nil || [self.ttsSynthesisText count] <= 0) {
        // 使用下面几个标点符号来分句，会让通过 MESSAGE_TYPE_TTS_PLAYBACK_PROGRESS 返回的播放进度更加准确
        NSArray* temp = [text componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@";!?。！？；…"]];
        if (text.length > 0) {
            NSError *error = nil;
            NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"[^;!?。！？；…]+[;!?。！？；…]?" options:0 error:&error];
            
            if (!error) {
                NSArray<NSTextCheckingResult *> *matches = [regex matchesInString:text options:0 range:NSMakeRange(0, text.length)];
                
                for (NSTextCheckingResult *match in matches) {
                    NSString *sentence = [text substringWithRange:match.range];
                    [self addSentence:sentence];
                }
            }
        }
    }
    NSLog(@"Synthesis text item num: %ld.", [self.ttsSynthesisText count]);
    return [self.ttsSynthesisText count] > 0;
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
- (void)textViewDidChange:(UITextView *)textView {
    if(textView == _referTextView){
        self.refTextChanged = TRUE;
    }
}
#pragma mark - Navigation

// In a storyboard-based application, you will often want to do a little preparation before navigation
- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    // Get the new view controller using [segue destinationViewController].
    // Pass the selected object to the new view controller.
    id nextPage = [segue destinationViewController];
    [nextPage setValue:VIEW_BITTS forKey:@"viewId"];
}

@end

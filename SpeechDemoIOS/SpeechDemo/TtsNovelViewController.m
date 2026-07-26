//
//  TtsNovelViewController.m
//  SpeechDemo
//
//  Created by bytedance on 2020/9/8.
//  Copyright © 2020 fengkai.0518. All rights reserved.
//

#import "TtsNovelViewController.h"
#include <CoreFoundation/CoreFoundation.h>
#include <objc/objc.h>

#import <AVFoundation/AVFoundation.h>

#import "AppDelegate.h"
#import "FileUtils.h"
#import "SettingsHelper.h"
#import "ViewController.h"
#import "SensitiveDefines.h"

static int TTS_MAX_RETRY_COUNT = 3;

@interface TtsNovelViewController () <SpeechEngineDelegate, UITextViewDelegate>

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

// Settings
@property (strong, nonatomic) Settings *settings;

// 一些在线合成的配置
@property (strong, nonatomic) NSString *ttsAppId;
@property (strong, nonatomic) NSString *ttsVoiceOnline;
@property (strong, nonatomic) NSString *ttsVoiceTypeOnline;

// 一些离线合成的配置
@property (strong, nonatomic) NSString *ttsVoiceOffline;
@property (strong, nonatomic) NSString *ttsVoiceTypeOffline;

// 小说模式相关
@property (assign, nonatomic) BOOL ttsSynthesisFromPlayer;
@property (assign, nonatomic) int ttsSynthesisIndex;
@property (assign, nonatomic) int ttsPlayingIndex;
@property (assign, nonatomic) double ttsPlayingProgress;
@property (strong, nonatomic) NSMutableArray* ttsSynthesisText;
@property (strong, nonatomic) NSMutableDictionary* ttsSynthesisMap;

@property (assign, nonatomic) int ttsRetryCount;

@end

@implementation TtsNovelViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.settings = [[SettingsHelper shareInstance]getSettings:VIEW_TTS];
    
    self.engineSwitchButton.enabled = TRUE;
    [self decorateTextView:self.referTextView];
    [self decorateTextView:self.resultTextView];
    [self.referTextView setDelegate:self];
    self.referTextView.editable = TRUE;
    self.engineInited = FALSE;
    self.engineStarted = FALSE;
    self.engineErrorOccurred = FALSE;
    self.playerPaused = FALSE;
    
    // 初始化和小说模式有关的字段
    self.ttsSynthesisFromPlayer = FALSE;
    self.ttsSynthesisIndex = 0;
    self.ttsPlayingIndex = -1;
    self.ttsPlayingProgress = 0.0;
    self.ttsSynthesisText = [[NSMutableArray alloc] init];
    self.ttsSynthesisMap = [[NSMutableDictionary alloc]init];

    self.ttsRetryCount = TTS_MAX_RETRY_COUNT;

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
    [self.curEngine setStringParam:SE_TTS_ENGINE forKey:SE_PARAMS_KEY_ENGINE_NAME_STRING];

    //【必需配置】Work Mode, 可选值如下
    // SETtsWorkModeOnline, 只进行在线合成，不需要配置离线合成相关参数；
    // SETtsWorkModeOffline, 只进行离线合成，不需要配置在线合成相关参数；
    // SETtsWorkModeAlternate, 先发起在线合成，失败后（网络超时），启动离线合成引擎开始合成；
    [self.curEngine setIntParam:[self getTtsWorkMode] forKey:SE_PARAMS_KEY_TTS_WORK_MODE_INT];

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

    //【可选配置】合成出的音频的采样率，默认为 24000
    [self.curEngine setIntParam:[self.settings getInt:SETTING_TTS_SAMPLE_RATE] forKey:SE_PARAMS_KEY_TTS_SAMPLE_RATE_INT];
    //【可选配置】打断播放时使用多长时间淡出停止，单位：毫秒。默认值 0 表示不淡出
    [self.curEngine setIntParam:[self.settings getInt:SETTING_AUDIO_FADEOUT_DURATION] forKey:SE_PARAMS_KEY_AUDIO_FADEOUT_DURATION_INT];

    // ------------------------ 在线合成相关配置 -----------------------

    NSString* appid = [self.settings getString:SETTING_APPID];
    self.ttsAppId = appid.length > 0 ? appid : SDEF_APPID;
    //【必需配置】在线合成鉴权相关：Appid
    [self.curEngine setStringParam:self.ttsAppId forKey:SE_PARAMS_KEY_APP_ID_STRING];

    NSString* token = [self.settings getString:SETTING_TOKEN];
    NSString* ttsAppToken = token.length > 0 ? token : SDEF_TOKEN;
    //【必需配置】在线合成鉴权相关：Token
    [self.curEngine setStringParam:ttsAppToken forKey:SE_PARAMS_KEY_APP_TOKEN_STRING];

    //【必需配置】语音合成服务域名
    NSString *address = [self.settings getString:SETTING_ADDRESS];
    NSString *ttsAddress = address.length > 0 ? address : SDEF_DEFAULT_ADDRESS;
    [self.curEngine setStringParam:ttsAddress forKey:SE_PARAMS_KEY_TTS_ADDRESS_STRING];

    //【必需配置】语音合成服务Uri
    NSString *uri = [self.settings getString:SETTING_URI];
    NSString *ttsUri = uri.length > 0 ? uri : SDEF_TTS_DEFAULT_URI;
    [self.curEngine setStringParam:ttsUri forKey:SE_PARAMS_KEY_TTS_URI_STRING];

    // 【可选配置】是否允许在 websocket 建连失败时自动重连
    [self.curEngine setBoolParam:![self.settings getBool:SETTING_DISABLE_WS_RECONNECT] forKey:SE_PARAMS_KEY_ENABLE_WS_RECONNECT_BOOL];

    //【可选配置】在线合成下发的 opus-ogg 音频的压缩倍率
    [self.curEngine setIntParam:10 forKey:SE_PARAMS_KEY_TTS_COMPRESSION_RATE_INT];

    // ------------------------ 离线合成相关配置 -----------------------

    if ([self getTtsWorkMode] != SETtsWorkModeOnline && [self getTtsWorkMode] != SETtsWorkModeFile) {
        NSString* resourcePath = @"";
        if ([[self.settings getOptionsValue:SETTING_TTS_OFFLINE_RESOURCE_FORMAT] isEqual: @"SingleVoice"]) {
            resourcePath = [[SpeechResourceManager shareInstance] getModelPath];
        } else if ([[self.settings getOptionsValue:SETTING_TTS_OFFLINE_RESOURCE_FORMAT] isEqual: @"MultipleVoice"]) {
            NSString *model_name = [self.settings getString:SETTING_TTS_MODEL_NAME];
            resourcePath = [[SpeechResourceManager shareInstance] getModelPath:model_name];
        }
        NSLog(@"TTS resource root path: %@", resourcePath);
        //【必需配置】离线合成所需资源存放路径
        [self.curEngine setStringParam:resourcePath forKey:SE_PARAMS_KEY_TTS_OFF_RESOURCE_PATH_STRING];
    }

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
}

-(void)configStartTtsParams {
    //【必需配置】TTS 使用场景
    [self.curEngine setStringParam:SE_TTS_SCENARIO_TYPE_NOVEL forKey:SE_PARAMS_KEY_TTS_SCENARIO_STRING];

    // 准备待合成的小说文本
    if(![self prepareNovelText]) {
        char fake_error_info[] = "{err_code:3006, err_msg:\"Invalid input text.\"}";
        [self speechEngineError:[NSData dataWithBytes:fake_error_info length:sizeof(fake_error_info)]];
        return;
    }

    //【可选配置】是否使用 SDK 内置播放器播放合成出的音频，默认为 true
    [self.curEngine setBoolParam:[self.settings getBool:SETTING_TTS_ENABLE_PLAYER]
                          forKey:SE_PARAMS_KEY_TTS_ENABLE_PLAYER_BOOL];
    //【可选配置】是否令 SDK 通过回调返回合成的音频数据，默认不返回。
    // 开启后，SDK 会流式返回音频，收到 SETtsAudioData 回调表示当次合成所有的音频已经全部返回
    [self.curEngine setIntParam:[self.settings getBool:SETTING_TTS_ENABLE_DATA_CALLBACK] ? SETtsDataCallbackModeAll : SETtsDataCallbackModeNone forKey:SE_PARAMS_KEY_TTS_DATA_CALLBACK_MODE_INT];
}

- (void)configSynthesisParams {
    NSString* text = self.ttsSynthesisText[self.ttsSynthesisIndex];
    NSLog(@"Synthesis: %d, text: %@", self.ttsSynthesisIndex, text);
    //【必需配置】需合成的文本，不可超过 80 字
    [self.curEngine setStringParam:text forKey:SE_PARAMS_KEY_TTS_TEXT_STRING];
    //【可选配置】需合成的文本的类型，支持直接传文本(TTS_TEXT_TYPE_PLAIN)和传 SSML 形式(TTS_TEXT_TYPE_SSML)的文本
    [self.curEngine setStringParam:[self getTtsTextType] forKey:SE_PARAMS_KEY_TTS_TEXT_TYPE_STRING];
    //【可选配置】用于控制 TTS 音频的语速，支持的配置范围参考火山官网 语音技术/语音合成/离在线语音合成SDK/参数说明 文档
    [self.curEngine setDoubleParam:[self.settings getDouble:SETTING_TTS_SPEAK_SPEED] forKey:SE_PARAMS_KEY_TTS_SPEED_RATIO_DOUBLE];
    //【可选配置】用于控制 TTS 音频的音量，支持的配置范围参考火山官网 语音技术/语音合成/离在线语音合成SDK/参数说明 文档
    [self.curEngine setDoubleParam:[self.settings getDouble:SETTING_TTS_AUDIO_VOLUME] forKey:SE_PARAMS_KEY_TTS_VOLUME_RATIO_DOUBLE];
    //【可选配置】用于控制 TTS 音频的音高，支持的配置范围参考火山官网 语音技术/语音合成/离在线语音合成SDK/参数说明 文档
    [self.curEngine setDoubleParam:[self.settings getDouble:SETTING_TTS_AUDIO_PITCH] forKey:SE_PARAMS_KEY_TTS_PITCH_RATIO_DOUBLE];
    //【可选配置】是否在文本的每句结尾处添加静音段，单位：毫秒，默认为 0ms
    [self.curEngine setIntParam:[self.settings getInt:SETTING_TTS_SILENCE_DURATION] forKey:SE_PARAMS_KEY_TTS_SILENCE_DURATION_INT];

    // ------------------------ 在线合成相关配置 -----------------------

    //【必需配置】语音合成服务所用集群
    NSString *cluster = [self.settings getString:SETTING_CLUSTER];
    [self.curEngine setStringParam:cluster forKey:SE_PARAMS_KEY_TTS_CLUSTER_STRING];

    NSString *voiceOnline = [self.settings getString:SETTING_ONLINE_VOICE];
    if (voiceOnline.length <= 0) {
        voiceOnline = [self.settings getOptionsValue:SETTING_ONLINE_VOICE];
    }
    self.ttsVoiceOnline = voiceOnline;
    //【必需配置】在线合成使用的发音人代号
    [self.curEngine setStringParam:self.ttsVoiceOnline forKey:SE_PARAMS_KEY_TTS_VOICE_ONLINE_STRING];
    NSString *voiceTypeOnline = [self.settings getString:SETTING_ONLINE_VOICE_TYPE];
    if (voiceTypeOnline.length <= 0) {
        voiceTypeOnline = [self.settings getOptionsValue:SETTING_ONLINE_VOICE_TYPE];
    }
    self.ttsVoiceTypeOnline = voiceTypeOnline;
    //【必需配置】在线合成使用的音色代号
    [self.curEngine setStringParam:self.ttsVoiceTypeOnline forKey:SE_PARAMS_KEY_TTS_VOICE_TYPE_ONLINE_STRING];
    //【可选配置】是否打开在线合成的服务端缓存，默认关闭
    [self.curEngine setBoolParam:[self.settings getBool:SETTING_TTS_ENABLE_CACHE] forKey:SE_PARAMS_KEY_TTS_ENABLE_CACHE_BOOL];
    //【可选配置】指定在线合成的语种，默认为空，即不指定
    [self.curEngine setStringParam:[self.settings getString:SETTING_TTS_ONLINE_LANGUAGE] forKey:SE_PARAMS_KEY_TTS_LANGUAGE_ONLINE_STRING];
    //【可选配置】是否启用在线合成的情感预测功能
    [self.curEngine setBoolParam:[self.settings getBool:SETTING_TTS_WITH_INTENT] forKey:SE_PARAMS_KEY_TTS_WITH_INTENT_BOOL];
    //【可选配置】指定在线合成的情感，例如 happy, sad 等
    [self.curEngine setStringParam:[self.settings getString:SETTING_TTS_EMOTION] forKey:SE_PARAMS_KEY_TTS_EMOTION_STRING];
    //【可选配置】需要返回详细的播放进度或需要启用断点续播功能时应配置为 1, 否则配置为 0 或不配置
    [self.curEngine setIntParam:1 forKey:SE_PARAMS_KEY_TTS_WITH_FRONTEND_INT];
    //【可选配置】需要返回字粒度的播放进度时应配置为 simple, 同时要求 PARAMS_KEY_TTS_WITH_FRONTEND_INT 也配置为 1; 默认为空
    [self.curEngine setStringParam:[self.settings getBool:SETTING_TTS_ENABLE_WORD_LEVEL_PROGRESS_UPDATE] ? @"simple" : @"" forKey:SE_PARAMS_KEY_TTS_FRONTEND_TYPE_STRING];
    //【可选配置】使用复刻音色
    [self.curEngine setBoolParam:[self.settings getBool:SETTING_TTS_USE_VOICECLONE_VOICE] forKey:SE_PARAMS_KEY_TTS_USE_VOICECLONE_BOOL];
    //【可选配置】在开启前述使用复刻音色的开关后，制定复刻音色所用的后端集群
    [self.curEngine setStringParam:[self.settings getString:SETTING_TTS_BACKEND_CLUSTER] forKey:SE_PARAMS_KEY_TTS_BACKEND_CLUSTER_STRING];
    
    //【可选配置】在线合成的请求参数，JSON 格式。当服务端新增参数但是 SDK 还未新增对应的配置项时，开发者可自行构造请求参数由此传入
    [self.curEngine setStringParam:[self.settings getString:SETTING_TTS_REQUEST_PARAMS] forKey:SE_PARAMS_KEY_TTS_REQ_PARAMS_STRING];

    // ------------------------ 离线合成相关配置 -----------------------

    NSString *voiceOffline = [self.settings getString:SETTING_OFFLINE_VOICE];
    if (voiceOffline.length <= 0) {
        voiceOffline = [self.settings getOptionsValue:SETTING_OFFLINE_VOICE];
    }
    self.ttsVoiceOffline = voiceOffline;
    //【必需配置】离线合成使用的发音人代号
    [self.curEngine setStringParam:self.ttsVoiceOffline forKey:SE_PARAMS_KEY_TTS_VOICE_OFFLINE_STRING];
    NSString *voiceTypeOffline = [self.settings getString:SETTING_OFFLINE_VOICE_TYPE];
    if (voiceTypeOffline.length <= 0) {
        voiceTypeOffline = [self.settings getOptionsValue:SETTING_OFFLINE_VOICE_TYPE];
    }
    self.ttsVoiceTypeOffline = voiceTypeOffline;
    //【必需配置】离线合成使用的音色代号
    [self.curEngine setStringParam:self.ttsVoiceTypeOffline forKey:SE_PARAMS_KEY_TTS_VOICE_TYPE_OFFLINE_STRING];

    //【可选配置】是否降低离线合成的 CPU 利用率，默认关闭
    // 打开该配置会使离线合成的实时率变大，仅当必要（例如为避免系统主动杀死CPU占用持续过高的进程）时才应开启
    [self.curEngine setBoolParam:[self.settings getBool:SETTING_TTS_LIMIT_CPU_USAGE] forKey:SE_PARAMS_KEY_TTS_LIMIT_CPU_USAGE_BOOL];
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

    if ([self getTtsWorkMode] == SETtsWorkModeOnline || [self getTtsWorkMode] == SETtsWorkModeFile) {
        // 当使用纯在线模式时，不需要下载离线合成所需资源
        [self initEngineInternal];
    } else {
        [self.statusTextView setText:@"Waiting for loading model."];
        // 下载离线合成所需资源需要区分多音色资源和单音色资源，下载这两种资源所调用的方法略有不同
        if ([[self.settings getOptionsValue:SETTING_TTS_OFFLINE_RESOURCE_FORMAT] isEqual: @"MultipleVoice"]) {
            // 多音色资源是指一个资源文件中包含了多个离线音色，这种资源一般是旧版(V2)离线合成所用资源
            NSLog(@"当前所用资源类别为多音色资源，开始准备多音色资源");
            [self prepareMultipleVoiceResource];
        } else if ([[self.settings getOptionsValue:SETTING_TTS_OFFLINE_RESOURCE_FORMAT] isEqual: @"SingleVoice"]) {
            // 单音色资源是指一个资源文件仅包含一个离线音色，新版(V4 及以上)离线合成用的就是单音色资源
            NSLog(@"当前所用资源类别为单音色资源，开始准备单音色资源");
            [self prepareSingleVoiceResource];
        }
    }
}

- (void)prepareMultipleVoiceResource {
    // 因为多音色资源的一个文件包含了多个音色，导致资源的名字和音色的名字无法一一对应
    // 所以下载资源需要显式指定资源名字
    NSString *model_name = [self.settings getString:SETTING_TTS_MODEL_NAME];
    SpeechResourceManager *speechResourceManager = [SpeechResourceManager shareInstance];
    NSLog(@"检查本地是否存在可用模型");
    if (![speechResourceManager checkModelExist:model_name]) {
        NSLog(@"本地没有模型，开始下载");
        [self fetchMultipleVoiceResource:model_name];
    } else {
        NSLog(@"模型存在，检查是否需要更新模型");
        [speechResourceManager checkModelVersion:model_name completion:^(SEResourceStatus status, BOOL needUpdate, NSData *data) {
            if (status != kSERSuccess || needUpdate == NO) {
                NSLog(@"无需更新，直接使用本地已有模型。");
                [self initEngineInternal];
            } else {
                NSLog(@"存在更新，开始下载模型");
                [self fetchMultipleVoiceResource:model_name];
            }
        }];
    }
}

- (void) fetchMultipleVoiceResource:(NSString*)model_name {
    NSLog(@"需要下载的模型名为 %@", model_name);
    SpeechResourceManager *speechResourceManager = [SpeechResourceManager shareInstance];
    [speechResourceManager fetchModelByName:model_name completion:^(SEResourceStatus status, NSData* data) {
        if (status == kSERSuccess) {
            NSLog(@"下载成功");
            [self initEngineInternal];
        } else {
            NSLog(@"下载失败，错误码: %d", status);
            [self speechEngineInitFailed:kSERDownloadFailed];
        }
    }];
}

- (void) prepareSingleVoiceResource {
    SpeechResourceManager *speechResourceManager = [SpeechResourceManager shareInstance];
    NSString* offlineLanguage = [self.settings getString:SETTING_TTS_OFFLINE_LANGUAGE];
    if (offlineLanguage.length <= 0) {
        offlineLanguage = SDEF_TTS_DEFAULT_OFFLINE_LANGUAGE;
    }
    NSArray* ttsLanguageArray = @[offlineLanguage];
    NSLog(@"需要下载的离线合成语种资源有： %@", ttsLanguageArray);
    [speechResourceManager setTtsLanguage:ttsLanguageArray];
    NSArray* needDownloadVoiceType = (NSArray *)SDEF_TTS_DEFAULT_DOWNLOAD_OFFLINE_VOICES();
    NSArray* voiceTypeArray = [self.settings getOptions:SETTING_OFFLINE_VOICE_TYPE].optionsArray;
    if (voiceTypeArray != nil && voiceTypeArray.count > 0) {
        needDownloadVoiceType = voiceTypeArray;
    }
    NSLog(@"需要下载的离线合成音色资源有： %@", needDownloadVoiceType);
    [speechResourceManager setTtsVoiceType:needDownloadVoiceType];

    NSLog(@"检查本地是否存在可用模型");
    if ([speechResourceManager checkModelExist]) {
        NSLog(@"本地没有模型，开始下载");
        [self fetchSingleVoiceResource];
    } else {
        NSLog(@"模型存在，检查是否需要更新模型");
        [speechResourceManager checkModelVersion:^(SEResourceStatus status, BOOL needUpdate, NSData *data) {
            if (status != kSERSuccess || needUpdate == NO) {
                NSLog(@"无需更新，直接使用本地已有模型。");
                [self initEngineInternal];
            } else {
                NSLog(@"存在更新，开始下载模型");
                [self fetchSingleVoiceResource];
            }
        }];
    }
}

- (void)fetchSingleVoiceResource {
    SpeechResourceManager *speechResourceManager = [SpeechResourceManager shareInstance];
    [speechResourceManager fetchModel:^(SEResourceStatus status, NSData* data) {
        if (status == kSERSuccess) {
            NSLog(@"下载成功");
            [self initEngineInternal];
        } else {
            NSLog(@"下载失败，错误码: %d", status);
            [self speechEngineInitFailed:kSERDownloadFailed];
        }
    }];
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
        self.referTextView.editable = FALSE;
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
            SEEngineErrorCode ret = [self.curEngine sendDirective:SEDirectiveStartEngine];
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

- (void) pausePlayback {
    NSLog(@"暂停播放");
    NSLog(@"Directive: SEDirectivePausePlayer");
    SEEngineErrorCode ret = [self.curEngine sendDirective:SEDirectivePausePlayer];
    if (ret == SENoError) {
        self.playerPaused = TRUE;
        [self.pauseResumeButton setTitle:@"Resume" forState:UIControlStateNormal];
    }
    NSLog(@"Pause playback status: %d", ret);
}

- (void) resumePlayback {
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
    [self.resultTextView setText:@""];
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
        case SETtsSynthesisBegin:
            NSLog(@"Callback: 合成开始: %@", data);
            [self speechStartSynthesis:data];
            break;
        case SETtsSynthesisEnd:
            NSLog(@"Callback: 合成结束: %@", data);
            [self speechFinishSynthesis:data];
            break;
        case SETtsStartPlaying:
            NSLog(@"Callback: 播放开始: %@", data);
            [self speechStartPlaying:data];
            break;
        case SETtsPlaybackProgress:
            NSLog(@"Callback: 播放进度");
            [self updatePlayingProgress:data];
            break;
        case SETtsFinishPlaying:
            NSLog(@"Callback: 播放结束: %@", data);
            [self speechFinishPlaying:data];
            break;
        case SETtsAudioData:
            NSLog(@"Callback: 音频数据，长度 %lu 字节", (unsigned long)data.length);
            [self speechTtsAudioData:data];
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
    self.ttsRetryCount = TTS_MAX_RETRY_COUNT;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.referTextView.editable = FALSE;
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
                    [self synthesisNextSentence];
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
                    [self.resultTextView
                        setText:[[NSString alloc]
                                    initWithData:data
                                        encoding:NSUTF8StringEncoding]];
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

// 根据 SDK 返回的播放进度高亮正在播放的文本，用红色表示
// 根据 SDK 返回的合成开始和合成结束回调高亮正在合成的文本，用蓝色表示
-(void)updateTtsResultText:(NSString*) playingId {
    if (self.engineErrorOccurred) {
        NSLog(@"When a fatal error occurs, prevent the playback text from being displayed.");
        return;
    }
    
    NSNumber* val = [self.ttsSynthesisMap objectForKey:playingId];
    if (val != nil) {
        self.ttsPlayingIndex = [val intValue];
    }
    
    int beginIndex = MAX(self.ttsPlayingIndex, 0);
    int maxSentencesDisplayed = MIN((int)[self.ttsSynthesisText count], 16);
    NSMutableAttributedString *resultStr = [[NSMutableAttributedString alloc] initWithString:@""];
    for (int cnt = 0; cnt < maxSentencesDisplayed; ++cnt) {
        int index = (beginIndex + cnt) % [self.ttsSynthesisText count];
        NSString* current_sentence = self.ttsSynthesisText[index];
        NSInteger playedPosition = 0;
        if (index == self.ttsPlayingIndex) {
            playedPosition = MIN(ceil((double)(self.ttsPlayingProgress) * (double)([current_sentence length])), [current_sentence length]);
            NSLog(@"played position: %ld", (long)playedPosition);
            NSString* playedString = [current_sentence substringToIndex:playedPosition];
            NSAttributedString* playedSpan = [[NSAttributedString alloc] initWithString:playedString attributes:[NSDictionary dictionaryWithObject:[UIColor redColor] forKey:NSForegroundColorAttributeName]];
            [resultStr appendAttributedString:playedSpan];
        }
        NSString* remainString = [current_sentence substringFromIndex:playedPosition];
        NSAttributedString* span = [[NSAttributedString alloc] initWithString:remainString attributes:[NSDictionary dictionaryWithObject:[UIColor blackColor] forKey:NSForegroundColorAttributeName]];
        [resultStr appendAttributedString:span];
    }
    [self.resultTextView setAttributedText:resultStr];
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
    [self synthesisNextSentence];
}

- (void)speechStartPlaying:(NSData *)data {
    NSString* playingId = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSLog(@"TTS start playing: %@", playingId);
    dispatch_async(dispatch_get_main_queue(), ^{
        self.pauseResumeButton.enabled = TRUE;
        self.ttsPlayingProgress = 0.0;
        [self updateTtsResultText:playingId];
    });
}

- (void)updatePlayingProgress :(NSData *)data {
    if (data != nil) {
        NSError *error = nil;
        id object = [NSJSONSerialization
                     JSONObjectWithData:data
                     options:0
                     error:&error];
        if(error) {
            NSLog(@"Parse data as json error!");
            return ;
        }
        if([object isKindOfClass:[NSDictionary class]]) {
            NSDictionary *results = object;
            float percentage = [[results valueForKey:@"progress"] floatValue];
            NSString *reqid = [results valueForKey:@"reqid"];
            NSLog(@"playing id: %@, progress in percent: %.2f", reqid, percentage);
            dispatch_async(dispatch_get_main_queue(), ^{
                self.ttsPlayingProgress = percentage;
                [self updateTtsResultText:reqid];
            });
        }
    }
}

- (void)speechFinishPlaying :(NSData *)data {
    NSString* playingId = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSLog(@"TTS finish playing: %@", playingId);
    dispatch_async(dispatch_get_main_queue(), ^{
        self.ttsPlayingProgress = 1.0;
        [self updateTtsResultText:playingId];
    });
    if (self.ttsSynthesisFromPlayer) {
        [self triggerSynthesis];
        self.ttsSynthesisFromPlayer = FALSE;
    }
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

- (void)synthesisNextSentence {
    self.ttsSynthesisIndex = (self.ttsSynthesisIndex + 1) % [self.ttsSynthesisText count];
    if (!self.ttsSynthesisFromPlayer) {
        [self triggerSynthesis];
    }
}

-(void)triggerSynthesis {
    [self configSynthesisParams];
    // DIRECTIVE_SYNTHESIS 是连续合成必需的一个指令，在成功调用 DIRECTIVE_START_ENGINE 之后，每次合成新的文本需要再调用 DIRECTIVE_SYNTHESIS 指令
    // DIRECTIVE_SYNTHESIS 需要在当前没有正在合成的文本时才可以成功调用，否则就会报错 -901，可以在收到 MESSAGE_TYPE_TTS_SYNTHESIS_END 之后调用
    // 当使用 SDK 内置的播放器时，为了避免缓存过多的音频导致内存占用过高，SDK 内部限制缓存的音频数量不超过 5 次合成的结果，
    // 如果 DIRECTIVE_SYNTHESIS 后返回 -902, 就需要在下一次收到 MESSAGE_TYPE_TTS_FINISH_PLAYING 再去调用 MESSAGE_TYPE_TTS_FINISH_PLAYING
    NSLog(@"触发合成");
    NSLog(@"Directive: DIRECTIVE_SYNTHESIS");
    SEEngineErrorCode ret = [self.curEngine sendDirective:SEDirectiveSynthesis];
    if (ret != SENoError) {
        NSLog(@"Synthesis faile: %d", ret);
        if (ret == SESynthesisPlayerIsBusy) {
            self.ttsSynthesisFromPlayer = TRUE;
        } else {
            NSString* message = [NSString stringWithFormat:@"发送合成指令失败: %d", ret];
            [self sendSynthesisDirectiveFailed:message];
        }
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
    self.ttsPlayingIndex = -1;
    self.ttsSynthesisFromPlayer = FALSE;
    [self.ttsSynthesisText removeAllObjects];
    [self.ttsSynthesisMap removeAllObjects];
}

-(BOOL)prepareNovelText {
    [self resetTtsContext];
    NSString* text = self.referTextView.text;
    if (text.length <= 0) {
        text = @"愿中国青年都摆脱冷气，只是向上走，不必听自暴自弃者流的话。能做事的做事，能发声的发声。有一分热，发一分光。就令萤火一般，也可以在黑暗里发一点光，不必等候炬火。此后如竟没有炬火：我便是唯一的光。";
    }
    if (self.ttsSynthesisText == nil || [self.ttsSynthesisText count] <= 0) {
        // 使用下面几个标点符号来分句，会让通过 MESSAGE_TYPE_TTS_PLAYBACK_PROGRESS 返回的播放进度更加准确
        NSArray* temp = [text componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@";!?。！？；…"]];
        for (int j = 0; j < temp.count; ++j) {
            [self addSentence:temp[j]];
        }
    }
    NSLog(@"Synthesis text item num: %ld.", [self.ttsSynthesisText count]);
    return [self.ttsSynthesisText count] > 0;
}

#pragma mark - Helper

- (NSString*)getTtsTextType {
    switch ([self.settings getOptions:SETTING_TTS_TEXT_TYPE].chooseIdx) {
        case 0:
            return SE_TTS_TEXT_TYPE_PLAIN;
        case 1:
            return SE_TTS_TEXT_TYPE_SSML;
        default:
            break;
    }
    return SE_TTS_TEXT_TYPE_PLAIN;;
}

- (int)getTtsWorkMode {
    switch ([self.settings getOptions:SETTING_TTS_WORK_MODE].chooseIdx) {
        case 0:
            return SETtsWorkModeOnline;
        case 1:
            return SETtsWorkModeOffline;
        case 2:
            return SETtsWorkModeAlternate;
        default:
            break;
    }
    return SETtsWorkModeOnline;;
}

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
    [nextPage setValue:VIEW_TTS forKey:@"viewId"];
}

@end

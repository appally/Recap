//
//  TtsNormalViewController.m
//  SpeechDemo
//
//  Created by bytedance on 2020/9/8.
//  Copyright © 2020 fengkai.0518. All rights reserved.
//

#import "TtsNormalViewController.h"
#include <Foundation/Foundation.h>

#import <AVFoundation/AVFoundation.h>

#import "AppDelegate.h"
#import "FileUtils.h"
#import "SettingsHelper.h"
#import "ViewController.h"
#import "SensitiveDefines.h"

@interface TtsNormalViewController () <SpeechEngineDelegate, UITextViewDelegate>

@property (weak, nonatomic) IBOutlet UITextView *referTextView;
@property (weak, nonatomic) IBOutlet UITextView *resultTextView;
@property (weak, nonatomic) IBOutlet UITextField *statusTextView;
@property (weak, nonatomic) IBOutlet UIButton *engineSwitchButton;
@property (weak, nonatomic) IBOutlet UIButton *createConnectionButton;
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
@property (assign, nonatomic) BOOL connectionCreated;
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

// 用于合成的文本
@property (strong, nonatomic) NSString *ttsText;


@end

@implementation TtsNormalViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.settings = [[SettingsHelper shareInstance]getSettings:VIEW_TTS];
    
    self.engineSwitchButton.enabled = TRUE;
    [self decorateTextView:self.referTextView];
    [self decorateTextView:self.resultTextView];
    [self.referTextView setDelegate:self];
    self.referTextView.editable = TRUE;
    self.engineInited = FALSE;
    self.connectionCreated = FALSE;
    self.engineStarted = FALSE;
    self.engineErrorOccurred = FALSE;
    self.playerPaused = FALSE;


    [self.statusTextView setText:@"Waiting for init."];
    [ViewController setAppDelegate:(AppDelegate *)[[UIApplication sharedApplication] delegate]];

    self.debugPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSLog(@"当前调试路径 %@", self.debugPath);
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appDidEnterBackground:)
                                                 name:UIApplicationDidEnterBackgroundNotification
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

- (void)appDidEnterBackground:(UIApplication *)application; {
    NSLog(@"app enter background.");
    [self.curEngine sendDirective:SEDirectiveStopEngine];
}

-(void)appWillTerminate:(NSNotification*)note {
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:UIApplicationDidEnterBackgroundNotification
                                                  object:nil];
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
    //【可选配置】是否禁止创建播放器对象，不使用 SDK 内置播放器时可开启，默认为 false. 开启后将 SE_PARAMS_KEY_TTS_ENABLE_PLAYER_BOOL 设置为 true 不起作用。 
    [self.curEngine setBoolParam:[self.settings getBool:SETTING_PREVENT_PLAYER_CREATION] forKey:SE_PARAMS_KEY_PREVENT_PLAYER_CREATION_BOOL];
    
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

    // ------------------------ 在离线切换相关配置 -----------------------
    if ([self getTtsWorkMode] == SETtsWorkModeAlternate) {
        // 断点续播功能在断点处会发生由在线合成音频切换到离线合成音频，为了提升用户体验，SDK 支持
        // 淡出地停止播放在线音频然后再淡入地开始播放离线音频，下面两个参数可以控制淡出淡入的长度
        
        //【可选配置】断点续播专用，切换到离线合成时淡入的音频长度，单位：毫秒
        [self.curEngine setIntParam:30 forKey:SE_PARAMS_KEY_TTS_FADEIN_DURATION_INT];
        //【可选配置】断点续播专用，在线合成停止播放时淡出的音频长度，单位：毫秒
        [self.curEngine setIntParam:30 forKey:SE_PARAMS_KEY_TTS_FADEOUT_DURATION_INT];
    }
}

-(void)configStartTtsParams {
    //【必需配置】TTS 使用场景
    [self.curEngine setStringParam:SE_TTS_SCENARIO_TYPE_NORMAL forKey:SE_PARAMS_KEY_TTS_SCENARIO_STRING];

    NSString* curText = self.referTextView.text;
    if (curText.length > 0) {
        self.ttsText = curText;
    } else {
        self.ttsText = @"愿中国青年都摆脱冷气，只是向上走，不必听自暴自弃者流的话。能做事的做事，能发声的发声。有一分热，发一分光。就令萤火一般，也可以在黑暗里发一点光，不必等候炬火。此后如竟没有炬火：我便是唯一的光。";
    }

    //【必需配置】需合成的文本，不可超过 80 字
    [self.curEngine setStringParam:self.ttsText forKey:SE_PARAMS_KEY_TTS_TEXT_STRING];
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

    //【可选配置】是否使用 SDK 内置播放器播放合成出的音频，默认为 true
    [self.curEngine setBoolParam:![self.settings getBool:SETTING_PREVENT_PLAYER_CREATION] && [self.settings getBool:SETTING_TTS_ENABLE_PLAYER]
                          forKey:SE_PARAMS_KEY_TTS_ENABLE_PLAYER_BOOL];
    //【可选配置】是否令 SDK 通过回调返回合成的音频数据，默认不返回。
    // 开启后，SDK 会流式返回音频，收到 SETtsAudioData 回调表示当次合成所有的音频已经全部返回
    [self.curEngine setIntParam:[self.settings getBool:SETTING_TTS_ENABLE_DATA_CALLBACK] ? SETtsDataCallbackModeAll : SETtsDataCallbackModeNone forKey:SE_PARAMS_KEY_TTS_DATA_CALLBACK_MODE_INT];

    // SDK 支持使用传入的 reqid 作为合成的唯一标识
    NSString* ttsReqId = [self.settings getString:SETTING_TTS_REQUEST_ID];
    if (ttsReqId.length > 0) {
        NSLog(@"Tts req id: %@", ttsReqId);
        //【可选配置】唯一标识一次合成的 reqid, 不传则自动生成并伴随 MESSAGE_TYPE_TTS_SYNTHESIS_BEGIN 返回
        [self.curEngine setStringParam:ttsReqId forKey:SE_PARAMS_KEY_TTS_REQUEST_ID_STRING];
    }
    
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
    [self.curEngine setIntParam:[self.settings getBool:SETTING_TTS_ENABLE_RESUME_FROM_BREAKPOINT] forKey:SE_PARAMS_KEY_TTS_WITH_FRONTEND_INT];
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

- (void)fetchMultipleVoiceResource:(NSString*)model_name {
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

- (void)prepareSingleVoiceResource {
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
    self.pauseResumeButton.enabled = FALSE;
    if (self.engineInited) {
        self.referTextView.editable = FALSE;
        [self uninitEngine];
        self.engineInited = FALSE;
        self.connectionCreated = FALSE;
        [self.statusTextView setText:@"Waiting for init."];
        self.engineSwitchButton.enabled = TRUE;
        [self.engineSwitchButton setTitle:@"Init Engine" forState:UIControlStateNormal];
        
        self.stopEngineButton.enabled = FALSE;
        self.createConnectionButton.enabled = FALSE;
    } else {
        self.referTextView.editable = TRUE;
        [self initEngine];
    }
}

- (IBAction)createConnection:(id)sender {
    if (self.connectionCreated) {
        NSLog(@"Connection is created.");
        return;
    }

    // SEDirectiveCreateConnection 指令，可减小在线合成的端到端播放延时，主要应用在能够提前预知要使用语音合成的情况下，例如语音交互场景
    // SEDirectiveCreateConnection 指令是一个同步指令，调用返回之后可以根据返回值判断连接是否建立成功
    // 如果不使用 SEDirectiveCreateConnection 指令，建连实际发生在调用 DIRECTIVE_START_ENGINE 后
    NSLog(@"触发提前建连");
    NSLog(@"Directive: SEDirectiveCreateConnection");
    SEEngineErrorCode ret = [self.curEngine sendDirective:SEDirectiveCreateConnection];
    if(ret != SENoError) {
        NSString* error_message = [NSString stringWithFormat:@"在线合成提前建连失败: %d", ret];
        NSLog(@"%@", error_message);
        [self createConnectionFailed:error_message];
    } else {
        NSString* message = [NSString stringWithFormat:@"在线合成提前建连成功: %d", ret];
        NSLog(@"%@", message);
        [self createConnectionSucceeded:message];
    }
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
        self.createConnectionButton.enabled = [self getTtsWorkMode] != SETtsWorkModeOffline;    });
}

- (void)speechEngineInitFailed:(int)initStatus {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self uninitEngine];
        [self.statusTextView setText:[[NSString alloc] initWithFormat:@"Failed to init engine, %d!", initStatus]];
        self.engineSwitchButton.enabled = TRUE;
    });
}

- (void)createConnectionSucceeded:(NSString*)tipText {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.createConnectionButton.enabled = FALSE;
        [self.resultTextView setText:tipText];
        self.connectionCreated = TRUE;
    });
}

- (void)createConnectionFailed:(NSString*)tipText {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.resultTextView setText:tipText];
        self.connectionCreated = FALSE;
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
        self.referTextView.editable = FALSE;
        self.engineStarted = true;
        [self.statusTextView setText:@"Engine Started!"];
        [self.resultTextView setText:self.ttsText];
        self.startEngineButton.enabled = FALSE;
        self.stopEngineButton.enabled = TRUE;
        self.createConnectionButton.enabled = FALSE;
    });
}

- (void)speechEngineStopped {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.referTextView.editable = TRUE;
        self.engineStarted = FALSE;
        self.connectionCreated = FALSE;
        [self.statusTextView setText:@"Engine Stopped!"];
        self.startEngineButton.enabled = TRUE;
        self.stopEngineButton.enabled = FALSE;
        self.createConnectionButton.enabled = [self getTtsWorkMode] != SETtsWorkModeOffline;
        [self.pauseResumeButton setTitle:@"Pause" forState:UIControlStateNormal];
        self.pauseResumeButton.enabled = FALSE;
        self.playerPaused = FALSE;
    });
}

- (void)speechEngineError:(NSData *)data {
    self.engineErrorOccurred = TRUE;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.resultTextView setTextColor:[UIColor blackColor]];
        [self.resultTextView setText:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]];
    });
}

- (void)speechStartSynthesis:(NSData *)data {
}

- (void)speechFinishSynthesis:(NSData *)data {
}

- (void)speechStartPlaying:(NSData *)data {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.pauseResumeButton.enabled = TRUE;
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
            NSLog(@"当前播放的文本对应的 reqid: %@，播放进度：%.3f", reqid, percentage);
        }
    }
}

- (void)speechFinishPlaying :(NSData *)data {
}

- (void)speechTtsAudioData:(NSData *)data {
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

//
//  DialogDuplexViewController.m
//  SpeechDemo
//
//  Created by bytedance on 2026/6/18.
//  Copyright © 2026 bytedance. All rights reserved.
//

#import "DialogDuplexViewController.h"

#import <AVFoundation/AVFoundation.h>

#import "AppDelegate.h"
#import "SensitiveDefines.h"
#import "SettingsHelper.h"
#import "SettingsViewController.h"
#import "ViewController.h"
#import "utils/DialogMessage.h"

#pragma mark - DialogDuplexViewController
@interface DialogDuplexViewController () <SpeechEngineDelegate, UITextViewDelegate>

// UI
@property (strong, nonatomic) UIButton *initialEngineButton;
@property (strong, nonatomic) UIButton *uninitialEngineButton;
@property (strong, nonatomic) UIButton *startEngineButton;
@property (strong, nonatomic) UIButton *stopEngineButton;
@property (strong, nonatomic) UIButton *speechTextAppendButton;
@property (strong, nonatomic) UIButton *pausePlayerButton;
@property (strong, nonatomic) UIButton *pauseRecorderButton;
@property (strong, nonatomic) UIButton *clientInterruptButton;
@property (strong, nonatomic) UITextField *statusTextView;
@property (strong, nonatomic) UITextView *resultTextView;
@property (strong, nonatomic) UITextView *helloTextView;
@property (strong, nonatomic) UITextView *speechTextAppendTextView;
@property (strong, nonatomic) NSMutableArray *dialogMessages;

// Debug
@property (nonatomic, strong) NSString *deviceID;
@property (strong, nonatomic) NSString *debugPath;

// Speech Engine
@property (strong, nonatomic) SpeechEngine *speechEngine;
@property (assign, nonatomic) BOOL engineStarted;
@property (assign, nonatomic) BOOL isPlayerPaused;
@property (assign, nonatomic) BOOL isRecorderPaused;
@property (strong, nonatomic) NSString *dialogId;
@property (strong, nonatomic) NSString *speechTextAppendSpeechId;

// Settings
@property (strong, nonatomic) Settings *settings;

@end

@implementation DialogDuplexViewController

static NSString *const DUPLEX_AEC_MODEL_NAME = @"aec.model";
static const int MAX_DUPLEX_DIALOG_MESSAGE_COUNT = 20;
static NSString *const DUPLEX_TTS_PROMPT = @"用非常快且亲密的语气打招呼";

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"对话双工";
    self.view.backgroundColor = [UIColor whiteColor];
    self.dialogMessages = [[NSMutableArray alloc] init];
    self.engineStarted = FALSE;
    self.isPlayerPaused = NO;
    self.isRecorderPaused = NO;
    self.dialogId = @"";
    self.speechTextAppendSpeechId = @"";
    self.settings = [[SettingsHelper shareInstance] getSettings:VIEW_DIALOG_DUPLEX];

    [ViewController setAppDelegate:(AppDelegate *)[[UIApplication sharedApplication] delegate]];
    [self setupViews];
    [self updateButtonsForWaitingInit];
}

- (void)viewDidDisappear:(BOOL)animated {
    [self uninitEngine];
    [super viewDidDisappear:animated];
}

- (void)setupViews {
    UIScrollView *scrollView = [[UIScrollView alloc] init];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scrollView];

    UIView *contentView = [[UIView alloc] init];
    contentView.translatesAutoresizingMaskIntoConstraints = NO;
    [scrollView addSubview:contentView];

    UILabel *helloLabel = [self makeLabel:@"开场白"];
    self.helloTextView = [self makeTextView:@"我是你的AI助手，请问有什么可以帮你。"];

    UILabel *speechTextAppendLabel = [self makeLabel:@"speech_text_buffer.replacement.append"];
    self.speechTextAppendTextView = [self makeTextView:@""];
    self.speechTextAppendTextView.editable = NO;
    self.speechTextAppendTextView.backgroundColor = [UIColor colorWithWhite:0.94 alpha:1.0];

    self.resultTextView = [self makeTextView:@""];
    self.resultTextView.editable = NO;
    self.resultTextView.backgroundColor = [UIColor colorWithWhite:0.94 alpha:1.0];

    self.statusTextView = [[UITextField alloc] init];
    self.statusTextView.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusTextView.borderStyle = UITextBorderStyleRoundedRect;
    self.statusTextView.enabled = NO;
    self.statusTextView.textAlignment = NSTextAlignmentCenter;
    self.statusTextView.font = [UIFont systemFontOfSize:14];
    self.statusTextView.text = @"Waiting for init.";

    self.initialEngineButton = [self makeButton:@"Init Engine" action:@selector(initEngineBtnClicked:)];
    self.uninitialEngineButton = [self makeButton:@"Uninit Engine" action:@selector(uninitEngineBtnClicked:)];
    self.startEngineButton = [self makeButton:@"Start Engine" action:@selector(startEngineBtnClicked:)];
    self.stopEngineButton = [self makeButton:@"Stop Engine" action:@selector(stopEngineBtnClicked:)];
    self.speechTextAppendButton = [self makeButton:@"SpeechTextReplacement" action:@selector(speechTextAppendBtnClicked:)];
    UIButton *settingsButton = [self makeButton:@"Settings" action:@selector(settingsBtnClicked:)];
    self.pauseRecorderButton = [self makeButton:@"暂停录音" action:@selector(pauseRecorderBtnClicked:)];
    self.pausePlayerButton = [self makeButton:@"暂停播放" action:@selector(pausePlayerBtnClicked:)];
    self.clientInterruptButton = [self makeButton:@"打断播放" action:@selector(clientInterruptBtnClicked:)];

    UIStackView *initStack = [self makeHorizontalStack:@[self.initialEngineButton, self.uninitialEngineButton]];
    UIStackView *engineStack = [self makeHorizontalStack:@[self.startEngineButton, self.stopEngineButton]];
    UIStackView *actionStack = [self makeHorizontalStack:@[self.speechTextAppendButton, settingsButton]];
    UIStackView *controlStack = [self makeHorizontalStack:@[self.pauseRecorderButton, self.pausePlayerButton, self.clientInterruptButton]];

    NSArray *views = @[helloLabel, self.helloTextView, speechTextAppendLabel, self.speechTextAppendTextView,
                       self.resultTextView, self.statusTextView, initStack, engineStack, actionStack, controlStack];
    for (UIView *view in views) {
        [contentView addSubview:view];
    }

    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scrollView.topAnchor constraintEqualToAnchor:guide.topAnchor],
        [scrollView.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor],
        [scrollView.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor],

        [contentView.topAnchor constraintEqualToAnchor:scrollView.topAnchor],
        [contentView.leadingAnchor constraintEqualToAnchor:scrollView.leadingAnchor],
        [contentView.trailingAnchor constraintEqualToAnchor:scrollView.trailingAnchor],
        [contentView.bottomAnchor constraintEqualToAnchor:scrollView.bottomAnchor],
        [contentView.widthAnchor constraintEqualToAnchor:scrollView.widthAnchor],

        [helloLabel.topAnchor constraintEqualToAnchor:contentView.topAnchor constant:10],
        [helloLabel.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:20],
        [helloLabel.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-20],
        [helloLabel.heightAnchor constraintEqualToConstant:24],

        [self.helloTextView.topAnchor constraintEqualToAnchor:helloLabel.bottomAnchor constant:4],
        [self.helloTextView.leadingAnchor constraintEqualToAnchor:helloLabel.leadingAnchor],
        [self.helloTextView.trailingAnchor constraintEqualToAnchor:helloLabel.trailingAnchor],
        [self.helloTextView.heightAnchor constraintEqualToConstant:58],

        [speechTextAppendLabel.topAnchor constraintEqualToAnchor:self.helloTextView.bottomAnchor constant:8],
        [speechTextAppendLabel.leadingAnchor constraintEqualToAnchor:helloLabel.leadingAnchor],
        [speechTextAppendLabel.trailingAnchor constraintEqualToAnchor:helloLabel.trailingAnchor],
        [speechTextAppendLabel.heightAnchor constraintEqualToConstant:24],

        [self.speechTextAppendTextView.topAnchor constraintEqualToAnchor:speechTextAppendLabel.bottomAnchor constant:4],
        [self.speechTextAppendTextView.leadingAnchor constraintEqualToAnchor:helloLabel.leadingAnchor],
        [self.speechTextAppendTextView.trailingAnchor constraintEqualToAnchor:helloLabel.trailingAnchor],
        [self.speechTextAppendTextView.heightAnchor constraintEqualToConstant:70],

        [self.resultTextView.topAnchor constraintEqualToAnchor:self.speechTextAppendTextView.bottomAnchor constant:8],
        [self.resultTextView.leadingAnchor constraintEqualToAnchor:helloLabel.leadingAnchor],
        [self.resultTextView.trailingAnchor constraintEqualToAnchor:helloLabel.trailingAnchor],
        [self.resultTextView.heightAnchor constraintEqualToConstant:170],

        [self.statusTextView.topAnchor constraintEqualToAnchor:self.resultTextView.bottomAnchor constant:14],
        [self.statusTextView.leadingAnchor constraintEqualToAnchor:helloLabel.leadingAnchor],
        [self.statusTextView.trailingAnchor constraintEqualToAnchor:helloLabel.trailingAnchor],
        [self.statusTextView.heightAnchor constraintEqualToConstant:34],

        [initStack.topAnchor constraintEqualToAnchor:self.statusTextView.bottomAnchor constant:20],
        [initStack.leadingAnchor constraintEqualToAnchor:helloLabel.leadingAnchor],
        [initStack.trailingAnchor constraintEqualToAnchor:helloLabel.trailingAnchor],
        [initStack.heightAnchor constraintEqualToConstant:45],

        [engineStack.topAnchor constraintEqualToAnchor:initStack.bottomAnchor constant:10],
        [engineStack.leadingAnchor constraintEqualToAnchor:helloLabel.leadingAnchor],
        [engineStack.trailingAnchor constraintEqualToAnchor:helloLabel.trailingAnchor],
        [engineStack.heightAnchor constraintEqualToConstant:45],

        [actionStack.topAnchor constraintEqualToAnchor:engineStack.bottomAnchor constant:10],
        [actionStack.leadingAnchor constraintEqualToAnchor:helloLabel.leadingAnchor],
        [actionStack.trailingAnchor constraintEqualToAnchor:helloLabel.trailingAnchor],
        [actionStack.heightAnchor constraintEqualToConstant:45],

        [controlStack.topAnchor constraintEqualToAnchor:actionStack.bottomAnchor constant:10],
        [controlStack.leadingAnchor constraintEqualToAnchor:helloLabel.leadingAnchor],
        [controlStack.trailingAnchor constraintEqualToAnchor:helloLabel.trailingAnchor],
        [controlStack.heightAnchor constraintEqualToConstant:34],
        [controlStack.bottomAnchor constraintEqualToAnchor:contentView.bottomAnchor constant:-20],
    ]];
}

- (UILabel *)makeLabel:(NSString *)text {
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = text;
    label.textColor = [UIColor darkGrayColor];
    label.font = [UIFont systemFontOfSize:14];
    return label;
}

- (UITextView *)makeTextView:(NSString *)text {
    UITextView *textView = [[UITextView alloc] init];
    textView.translatesAutoresizingMaskIntoConstraints = NO;
    textView.text = text;
    textView.font = [UIFont systemFontOfSize:14];
    textView.delegate = self;
    [self decorateTextView:textView];
    return textView;
}

- (UIButton *)makeButton:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.titleLabel.font = [UIFont systemFontOfSize:15];
    button.backgroundColor = [UIColor colorWithWhite:0.92 alpha:1.0];
    [button setTitle:title forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (UIStackView *)makeHorizontalStack:(NSArray<UIView *> *)views {
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:views];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.distribution = UIStackViewDistributionFillEqually;
    stack.spacing = 10;
    return stack;
}

- (void)decorateTextView:(UITextView *)textView {
    textView.layer.cornerRadius = 5.0f;
    textView.layer.borderWidth = .25f;
    textView.layer.borderColor = [UIColor grayColor].CGColor;
}

- (void)setButton:(UIButton *)button enabled:(BOOL)enabled {
    button.enabled = enabled;
    button.alpha = enabled ? 1.0 : 0.45;
}

#pragma mark - Config & Init & Uninit Methods

- (void)configInitParams {
    //【必需配置】Engine Name
    [self.speechEngine setStringParam:SE_DIALOG_ENGINE forKey:SE_PARAMS_KEY_ENGINE_NAME_STRING];
    //【必需配置】双工 JSON 协议
    [self.speechEngine setIntParam:SEProtocolTypeSeedDuplex forKey:SE_PARAMS_KEY_PROTOCOL_TYPE_INT];

    //【可选配置】Debug & Log
    self.debugPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSLog(@"Debug path: %@", self.debugPath);
    [self.speechEngine setStringParam:self.debugPath forKey:SE_PARAMS_KEY_DEBUG_PATH_STRING];
    [self.speechEngine setStringParam:SE_LOG_LEVEL_TRACE forKey:SE_PARAMS_KEY_LOG_LEVEL_STRING];

    //【必需配置】新版 Authentication：ApiKey
    [self.speechEngine setStringParam:[self.settings getString:SETTING_API_KEY] forKey:SE_PARAMS_KEY_API_KEY_STRING];
    //【必需配置】Authentication：AppKey
    [self.speechEngine setStringParam:[self.settings getString:SETTING_APPKEY] forKey:SE_PARAMS_KEY_APP_KEY_STRING];

    //【必需配置】对话服务资源信息 ResourceId
    NSString *resourceId = [self.settings getString:SETTING_RESOURCE_ID];
    if (resourceId.length == 0 || [resourceId isEqualToString:SDEF_DIALOG_DEFAULT_RESOURCE_ID]) {
        resourceId = SDEF_DIALOG_DUPLEX_DEFAULT_RESOURCE_ID;
    }
    [self.speechEngine setStringParam:resourceId forKey:SE_PARAMS_KEY_RESOURCE_ID_STRING];

    //【必需配置】User ID（用以辅助定位线上用户问题，如无法提供可提供固定字符串）
    [self.speechEngine setStringParam:SDEF_UID forKey:SE_PARAMS_KEY_UID_STRING];
    //【必需配置】Dialog Address，对话服务域名
    [self.speechEngine setStringParam:[self.settings getString:SETTING_ADDRESS] forKey:SE_PARAMS_KEY_DIALOG_ADDRESS_STRING];

    //【必需配置】Dialog Uri，对话服务 Uri
    NSString *uri = [self.settings getString:SETTING_URI];
    if (uri.length == 0 || [uri isEqualToString:SDEF_DIALOG_DEFAULT_URI]) {
        uri = SDEF_DIALOG_DUPLEX_DEFAULT_URI;
    }
    [self.speechEngine setStringParam:uri forKey:SE_PARAMS_KEY_DIALOG_URI_STRING];

    //【可选配置】是否开启 AEC，默认不开启，同时启用设备录音和播放时必须开启
    [self.speechEngine setBoolParam:TRUE forKey:SE_PARAMS_KEY_ENABLE_AEC_BOOL];
    //【可选配置】AEC 模型路径，开启 AEC 时必填
    [self.speechEngine setStringParam:[ViewController extractBundleToFilePath:DUPLEX_AEC_MODEL_NAME] forKey:SE_PARAMS_KEY_AEC_MODEL_PATH_STRING];
    //【可选配置】配置音频来源，默认使用设备麦克风录音（Dialog 仅支持 RECORDER 和 STREAM 模式，RECORDER 表示设备麦克风录音，STREAM 表示自定义音频输入）
    [self.speechEngine setStringParam:SE_RECORDER_TYPE_RECORDER forKey:SE_PARAMS_KEY_RECORDER_TYPE_STRING];
    //【可选配置】是否开启播放器，默认开启
    [self.speechEngine setBoolParam:TRUE forKey:SE_PARAMS_KEY_DIALOG_ENABLE_PLAYER_BOOL];
    //【可选配置】启用录音机音频回调，默认不启用
    [self.speechEngine setBoolParam:FALSE forKey:SE_PARAMS_KEY_DIALOG_ENABLE_RECORDER_AUDIO_CALLBACK_BOOL];
    //【可选配置】启用播放器音频回调，默认不启用（为当前正在播放的音频数据，会随着播放进度回调）
    [self.speechEngine setBoolParam:FALSE forKey:SE_PARAMS_KEY_DIALOG_ENABLE_PLAYER_AUDIO_CALLBACK_BOOL];
    //【可选配置】启用解码后原始音频回调，默认不启用（为解码后的需要播报的数据，会在解码完成后立刻回调，不等待播放进度）
    [self.speechEngine setBoolParam:FALSE forKey:SE_PARAMS_KEY_DIALOG_ENABLE_DECODER_AUDIO_CALLBACK_BOOL];

    //【可选配置】录音文件保存路径，如不为空，则 SDK 会将录音机音频保存到该路径下，文件格式为 .wav
    if ([self.settings getBool:SETTING_DIALOG_ENABLE_RECORDER_DUMP]) {
        [self.speechEngine setStringParam:self.debugPath forKey:SE_PARAMS_KEY_DIALOG_RECORDER_PATH_STRING];
    } else {
        [self.speechEngine setStringParam:@"" forKey:SE_PARAMS_KEY_DIALOG_RECORDER_PATH_STRING];
    }
    //【可选配置】播放文件保存路径，如不为空，则 SDK 会将播放器音频保存到该路径下，文件格式为 .wav
    if ([self.settings getBool:SETTING_DIALOG_ENABLE_PLAYER_DUMP]) {
        [self.speechEngine setStringParam:self.debugPath forKey:SE_PARAMS_KEY_DIALOG_PLAYER_PATH_STRING];
    } else {
        [self.speechEngine setStringParam:@"" forKey:SE_PARAMS_KEY_DIALOG_PLAYER_PATH_STRING];
    }
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

    NSLog(@"创建双工协议对话引擎");
    if (self.speechEngine == nil) {
        self.speechEngine = [[SpeechEngine alloc] init];
        if (![self.speechEngine createEngineWithDelegate:self]) {
            NSLog(@"Create speech engine failed.");
            return;
        }
    }
    NSLog(@"Engine version: %@", [self.speechEngine getVersion]);

    [self configInitParams];

    SEEngineErrorCode ret = [self.speechEngine initEngine];
    if (ret != SENoError) {
        NSLog(@"Init Engine failed: %d", ret);
        [self speechEngineInitFailed:[NSString stringWithFormat:@"Failed to init engine: %d", ret]];
        return;
    }

    [self speechEngineInitOk];
}

- (void)uninitEngine {
    if (self.speechEngine) {
        NSLog(@"引擎析构");
        [self.speechEngine destroyEngine];
        self.speechEngine = nil;
        NSLog(@"引擎析构完成");
    }
    [self.statusTextView setText:@"Engine uninited!"];
}

#pragma mark - Build Event Methods

- (NSString *)buildSessionCreate {
    self.dialogId = [[NSUUID UUID] UUIDString];
    return [self buildSessionEvent:@"session.create" dialogId:self.dialogId];
}

- (NSString *)buildSessionUpdate {
    if (self.dialogId.length == 0) {
        self.dialogId = [[NSUUID UUID] UUIDString];
    }
    return [self buildSessionEvent:@"session.update" dialogId:self.dialogId];
}

- (NSString *)buildSessionEvent:(NSString *)type dialogId:(NSString *)dialogId {
    NSDictionary *event = @{
        @"type": type,
        @"event_id": [self randomEventId],
        @"session": @{
            @"id": dialogId,
            @"model": @"1.2.6.0",
            @"instructions": @"You are a creative assistant that helps with design tasks.",
            @"output_modalities": @[@"text", @"audio"],
            @"audio": @{
                @"input": @{
                    @"format": @{@"type": @"speech_opus", @"rate": @16000},
                    @"transcription": @{@"language": @"zh"},
                },
                @"output": @{
                    @"format": @{@"type": @"ogg_opus", @"rate": @24000},
                    @"voice": @"zh_male_yunzhou_jupiter_bigtts",
                },
            },
        },
        @"extension": @{
            @"asr": @{@"extra": @{}},
            @"tts": @{},
            @"dialog": @{
                @"dialog_id": @"",
                @"bot_name": @"",
                @"system_role": @"",
                @"speaking_style": @"",
                @"location": @{
                    @"longitude": @114.305556,
                    @"latitude": @22.62,
                    @"city": @"深圳",
                    @"country": @"中国",
                    @"province": @"广东省",
                    @"district": @"南山区",
                    @"town": @"深圳",
                    @"country_code": @"CN",
                    @"address": @"中国深圳市南山区",
                },
                @"extra": @{
                    @"audit_response": @"抱歉，这个问题我无法回答，你可以换个其他话题，我会尽力为你提供帮助。",
                    @"enable_auto_conversation_truncate": @YES,
                    @"enable_conversation_truncate": @YES,
                    @"enable_denoise": @NO,
                    @"enable_loudness_norm": @YES,
                    @"enable_music": @YES,
                    @"enable_user_query_exit": @YES,
                    @"enable_volc_websearch": @YES,
                    @"input_mod": @"keep_alive",
                    @"model": @"O2.6",
                    @"strict_audit": @NO,
                    @"volc_websearch_api_key": @"oXwyShLTxx9oNxVQD54z51m4xRk78OV4",
                    @"volc_websearch_bot_id": @"7574703519819679295",
                    @"volc_websearch_type": @"web_agent",
                },
            },
        },
    };
    return [self jsonStringFromObject:event fallback:[NSString stringWithFormat:@"{\"type\":\"%@\",\"session\":{}}", type]];
}

- (NSString *)buildSessionClose {
    return [self jsonStringFromObject:@{@"event_id": @"event_close", @"type": @"session.close"}
                             fallback:@"{\"event_id\":\"event_close\",\"type\":\"session.close\"}"];
}

- (NSString *)buildSessionCancel {
    return [self jsonStringFromObject:@{@"event_id": @"event_cancel", @"type": @"session.cancel"}
                             fallback:@"{\"event_id\":\"event_cancel\",\"type\":\"session.cancel\"}"];
}

- (NSString *)buildSpeechTextAppend:(NSString *)speechId text:(NSString *)text {
    return [self jsonStringFromObject:@{@"type": @"speech_text_buffer.append",
                                        @"event_id": [self randomEventId],
                                        @"speech_id": speechId,
                                        @"text": text,
                                        @"tts_prompt": DUPLEX_TTS_PROMPT}
                             fallback:@"{\"type\":\"speech_text_buffer.append\"}"];
}

- (NSString *)buildSpeechTextCommit:(NSString *)speechId text:(NSString *)text {
    NSMutableDictionary *event = [@{@"type": @"speech_text_buffer.commit",
                                    @"event_id": [self randomEventId],
                                    @"speech_id": speechId,
                                    @"tts_prompt": DUPLEX_TTS_PROMPT} mutableCopy];
    if (text.length > 0) {
        event[@"text"] = text;
    }
    return [self jsonStringFromObject:event fallback:@"{\"type\":\"speech_text_buffer.commit\"}"];
}

- (NSString *)buildSpeechTextReplacementAppend:(NSString *)speechId text:(NSString *)text {
    return [self jsonStringFromObject:@{@"type": @"speech_text_buffer.replacement.append",
                                        @"event_id": [self randomEventId],
                                        @"speech_id": speechId,
                                        @"text": text}
                             fallback:@"{\"type\":\"speech_text_buffer.replacement.append\"}"];
}

- (NSString *)buildSpeechTextReplacementCommit:(NSString *)speechId text:(NSString *)text {
    NSMutableDictionary *event = [@{@"type": @"speech_text_buffer.replacement.commit",
                                    @"event_id": [self randomEventId],
                                    @"speech_id": speechId} mutableCopy];
    if (text.length > 0) {
        event[@"text"] = text;
    }
    return [self jsonStringFromObject:event fallback:@"{\"type\":\"speech_text_buffer.replacement.commit\"}"];
}

- (NSDictionary *)buildConversationTextItem:(NSString *)text {
    return @{@"type": @"message",
             @"role": @"user",
             @"content": @[@{@"type": @"input_text", @"text": text}]};
}

- (NSString *)buildConversationItemCreate:(NSArray *)items {
    return [self buildConversationItemsEvent:@"conversation.item.create" items:items];
}

- (NSString *)buildConversationItemUpdate:(NSArray *)items {
    return [self buildConversationItemsEvent:@"conversation.item.update" items:items];
}

- (NSString *)buildConversationItemRetrieve:(NSArray *)items {
    return [self buildConversationItemsEvent:@"conversation.item.retrieve" items:items];
}

- (NSString *)buildConversationItemDelete:(NSArray *)items {
    return [self buildConversationItemsEvent:@"conversation.item.delete" items:items];
}

- (NSString *)buildConversationItemsEvent:(NSString *)type items:(NSArray *)items {
    return [self jsonStringFromObject:@{@"type": type,
                                        @"event_id": [self randomEventId],
                                        @"items": items}
                             fallback:[NSString stringWithFormat:@"{\"type\":\"%@\"}", type]];
}

- (NSString *)buildConversationItemTruncate:(NSString *)itemId contentIndex:(NSInteger)contentIndex audioEndMs:(NSInteger)audioEndMs {
    return [self jsonStringFromObject:@{@"type": @"conversation.item.truncate",
                                        @"event_id": [self randomEventId],
                                        @"item_id": itemId,
                                        @"content_index": @(contentIndex),
                                        @"audio_end_ms": @(audioEndMs)}
                             fallback:@"{\"type\":\"conversation.item.truncate\"}"];
}

- (NSString *)buildResponseCreate:(NSString *)instructions {
    NSMutableDictionary *response = [@{@"modalities": @[@"text", @"audio"]} mutableCopy];
    if (instructions.length > 0) {
        response[@"instructions"] = instructions;
    }
    return [self jsonStringFromObject:@{@"type": @"response.create", @"response": response}
                             fallback:@"{\"type\":\"response.create\"}"];
}

- (NSString *)buildResponseCancel {
    return @"{\"type\":\"response.cancel\"}";
}

#pragma mark - Event Send Methods

- (SEEngineErrorCode)sendSessionUpdate {
    return [self sendUplinkEvent:[self buildSessionUpdate]];
}

- (SEEngineErrorCode)sendSessionCancel {
    return [self sendUplinkEvent:[self buildSessionCancel]];
}

- (SEEngineErrorCode)sendSpeechTextCommit:(NSString *)text {
    return [self sendSpeechTextCommit:[[NSUUID UUID] UUIDString] text:text];
}

- (SEEngineErrorCode)sendSpeechTextCommit:(NSString *)speechId text:(NSString *)text {
    return [self sendUplinkEvent:[self buildSpeechTextCommit:speechId text:text]];
}

- (SEEngineErrorCode)sendSpeechTextAppend:(NSString *)speechId text:(NSString *)text {
    return [self sendUplinkEvent:[self buildSpeechTextAppend:speechId text:text]];
}

- (SEEngineErrorCode)sendSpeechTextReplacementAppend:(NSString *)speechId text:(NSString *)text {
    return [self sendUplinkEvent:[self buildSpeechTextReplacementAppend:speechId text:text]];
}

- (SEEngineErrorCode)sendSpeechTextReplacementCommit:(NSString *)speechId text:(NSString *)text {
    return [self sendUplinkEvent:[self buildSpeechTextReplacementCommit:speechId text:text]];
}

- (SEEngineErrorCode)sendConversationItemCreate:(NSArray *)items {
    return [self sendUplinkEvent:[self buildConversationItemCreate:items]];
}

- (SEEngineErrorCode)sendConversationItemUpdate:(NSArray *)items {
    return [self sendUplinkEvent:[self buildConversationItemUpdate:items]];
}

- (SEEngineErrorCode)sendConversationItemRetrieve:(NSArray *)items {
    return [self sendUplinkEvent:[self buildConversationItemRetrieve:items]];
}

- (SEEngineErrorCode)sendConversationItemTruncate:(NSString *)itemId contentIndex:(NSInteger)contentIndex audioEndMs:(NSInteger)audioEndMs {
    return [self sendUplinkEvent:[self buildConversationItemTruncate:itemId contentIndex:contentIndex audioEndMs:audioEndMs]];
}

- (SEEngineErrorCode)sendConversationItemDelete:(NSArray *)items {
    return [self sendUplinkEvent:[self buildConversationItemDelete:items]];
}

- (SEEngineErrorCode)sendResponseCancel {
    return [self sendUplinkEvent:[self buildResponseCancel]];
}

- (SEEngineErrorCode)sendUplinkEvent:(NSString *)payload {
    NSLog(@"Directive: SEDirectiveSendUplinkEvent: %@", payload);
    return [self.speechEngine sendDirective:SEDirectiveSendUplinkEvent data:payload];
}

#pragma mark - Duplex Actions

- (void)startEngine {
    if (self.speechEngine == nil) {
        [self.statusTextView setText:@"Engine is not initialized!"];
        return;
    }

    NSLog(@"Directive: SEDirectiveSyncStopEngine");
    [self.speechEngine sendDirective:SEDirectiveSyncStopEngine data:[self buildSessionClose]];

    NSLog(@"Directive: SEDirectiveStartEngine");
    NSString *sessionCreate = [self buildSessionCreate];
    NSLog(@"session.create: %@", sessionCreate);
    SEEngineErrorCode ret = [self.speechEngine sendDirective:SEDirectiveStartEngine data:sessionCreate];
    if (ret == SERecCheckEnvironmentFailed) {
        [self speechEngineNoPermission];
    } else if (ret == SENoError) {
        self.dialogMessages = [[NSMutableArray alloc] init];
        self.speechTextAppendSpeechId = @"";
        self.resultTextView.text = @"";
        if (self.helloTextView.text.length != 0) {
            [self sayHello];
        }
    } else {
        [self.statusTextView setText:[NSString stringWithFormat:@"Fail to start engine: %d", ret]];
    }
}

- (void)stopEngine {
    if (self.speechEngine == nil) {
        [self.statusTextView setText:@"Engine is not initialized!"];
        return;
    }
    NSLog(@"Directive: SEDirectiveSyncStopEngine");
    [self.speechEngine sendDirective:SEDirectiveSyncStopEngine data:[self buildSessionClose]];
}

- (void)sayHello {
    NSString *text = self.helloTextView.text;
    if (text.length == 0) {
        return;
    }
    SEEngineErrorCode ret = [self sendSpeechTextCommit:text];
    if (ret != SENoError) {
        NSString *tips = [NSString stringWithFormat:@"Send duplex say hello failed: %d", ret];
        NSLog(@"%@", tips);
        self.statusTextView.text = tips;
        [self stopEngine];
    } else {
        [self showHelloMessage:text];
    }
}

- (void)speechTextAppend {
    NSString *text = self.speechTextAppendTextView.text;
    if (text.length == 0) {
        return;
    }
    if (self.speechTextAppendSpeechId.length == 0) {
        self.speechTextAppendSpeechId = [[NSUUID UUID] UUIDString];
    }
    SEEngineErrorCode ret = [self sendSpeechTextAppend:self.speechTextAppendSpeechId text:text];
    if (ret != SENoError) {
        [self handleSendFailed:@"speech_text_buffer.append" error:ret];
        return;
    }
    ret = [self sendSpeechTextCommit:self.speechTextAppendSpeechId text:@""];
    if (ret != SENoError) {
        [self handleSendFailed:@"speech_text_buffer.commit" error:ret];
        return;
    }
    [self showAssistantMessageText:text append:YES];
}

- (void)speechTextReplacement {
    NSString *text = self.speechTextAppendTextView.text;
    if (text.length == 0) {
        return;
    }
    NSString *speechId = [[NSUUID UUID] UUIDString];
    SEEngineErrorCode ret = [self sendSpeechTextReplacementAppend:speechId text:text];
    if (ret != SENoError) {
        [self handleSendFailed:@"speech_text_buffer.replacement.append" error:ret];
        return;
    }
    ret = [self sendSpeechTextReplacementCommit:speechId text:@""];
    if (ret != SENoError) {
        [self handleSendFailed:@"speech_text_buffer.replacement.commit" error:ret];
        return;
    }
    [self showAssistantMessageText:text append:YES];
}

- (void)clientInterrupt {
    SEEngineErrorCode ret = [self sendResponseCancel];
    if (ret != SENoError) {
        [self handleSendFailed:@"response.cancel" error:ret];
    } else {
        NSLog(@"send response.cancel succeed");
    }
}

- (void)handleSendFailed:(NSString *)event error:(SEEngineErrorCode)ret {
    NSString *tips = [NSString stringWithFormat:@"Send duplex %@ failed: %d", event, ret];
    NSLog(@"%@", tips);
    self.statusTextView.text = tips;
    [self stopEngine];
}

- (void)pausePlayer {
    SEEngineErrorCode ret = [self.speechEngine sendDirective:SEDirectivePausePlayer];
    if (ret != SENoError) {
        [self handleSendFailed:@"pause player" error:ret];
    } else {
        NSLog(@"Send directive pause player succeed");
    }
}

- (void)resumePlayer {
    SEEngineErrorCode ret = [self.speechEngine sendDirective:SEDirectiveResumePlayer];
    if (ret != SENoError) {
        [self handleSendFailed:@"resume player" error:ret];
    } else {
        NSLog(@"Send directive resume player succeed");
    }
}

- (void)pauseRecorder {
    SEEngineErrorCode ret = [self.speechEngine sendDirective:SEDirectivePauseRecorder];
    if (ret != SENoError) {
        [self handleSendFailed:@"pause recorder" error:ret];
    } else {
        NSLog(@"Send directive pause recorder succeed");
    }
}

- (void)resumeRecorder {
    SEEngineErrorCode ret = [self.speechEngine sendDirective:SEDirectiveResumeRecorder];
    if (ret != SENoError) {
        [self handleSendFailed:@"resume recorder" error:ret];
    } else {
        NSLog(@"Send directive resume recorder succeed");
    }
}

#pragma mark - UI Actions

- (IBAction)initEngineBtnClicked:(id)sender {
    if (self.engineStarted) {
        [self.statusTextView setText:@"Engine is busy, stop it first!"];
        return;
    }
    [self updateButtonsForInitializing];
    [self initEngine];
}

- (IBAction)uninitEngineBtnClicked:(id)sender {
    if (self.engineStarted) {
        [self.statusTextView setText:@"Engine is busy, stop it first!"];
        return;
    }
    [self uninitEngine];
    [self.dialogMessages removeAllObjects];
    self.resultTextView.text = @"";
    [self updateButtonsForWaitingInit];
}

- (IBAction)startEngineBtnClicked:(id)sender {
    [self startEngine];
}

- (IBAction)stopEngineBtnClicked:(id)sender {
    [self stopEngine];
}

- (IBAction)speechTextAppendBtnClicked:(id)sender {
}

- (IBAction)pausePlayerBtnClicked:(id)sender {
    if (self.speechEngine == nil) {
        [self.statusTextView setText:@"Engine is not initialized!"];
        return;
    }
    if (self.isPlayerPaused) {
        [self resumePlayer];
        self.isPlayerPaused = NO;
        [self.pausePlayerButton setTitle:@"暂停播放" forState:UIControlStateNormal];
    } else {
        [self pausePlayer];
        self.isPlayerPaused = YES;
        [self.pausePlayerButton setTitle:@"恢复播放" forState:UIControlStateNormal];
    }
}

- (IBAction)pauseRecorderBtnClicked:(id)sender {
    if (self.speechEngine == nil) {
        [self.statusTextView setText:@"Engine is not initialized!"];
        return;
    }
    if (self.isRecorderPaused) {
        [self resumeRecorder];
        self.isRecorderPaused = NO;
        [self.pauseRecorderButton setTitle:@"暂停录音" forState:UIControlStateNormal];
    } else {
        [self pauseRecorder];
        self.isRecorderPaused = YES;
        [self.pauseRecorderButton setTitle:@"恢复录音" forState:UIControlStateNormal];
    }
}

- (IBAction)clientInterruptBtnClicked:(id)sender {
    if (self.speechEngine == nil) {
        [self.statusTextView setText:@"Engine is not initialized!"];
        return;
    }
    [self clientInterrupt];
}

- (IBAction)settingsBtnClicked:(id)sender {
    SettingsViewController *nextPage = [[SettingsViewController alloc] initWithStyle:UITableViewStyleGrouped];
    nextPage.viewId = VIEW_DIALOG_DUPLEX;
    [self.navigationController pushViewController:nextPage animated:YES];
}

#pragma mark - SpeechEngineDelegate

- (void)onMessageWithType:(SEMessageType)type andData:(NSData *)data {
    NSLog(@"Message Type: %d.", type);
    NSString *strData = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    switch (type) {
        case SEEngineStart:
            NSLog(@"Callback: 引擎启动成功: %d", type);
            [self speechEngineStarted:strData];
            break;
        case SEEngineStop:
            NSLog(@"Callback: 引擎关闭: %d", type);
            [self speechEngineStopped:strData];
            break;
        case SEEngineError:
            NSLog(@"Callback: 错误信息: %d, data: %@", type, strData);
            [self showLogMessage:strData];
            break;
        case SEDialogDownlinkEvent:
            [self handleDialogDownlinkEvent:strData];
            break;
        default:
            NSLog(@"Callback: ignored message: %d, data: %@", type, strData);
            break;
    }
}

- (void)onSpeechLogid:(NSString *)logid {
    NSLog(@"Callback: logid: %@", logid);
}

- (void)handleDialogDownlinkEvent:(NSString *)payload {
    NSData *data = [payload dataUsingEncoding:NSUTF8StringEncoding];
    NSError *error;
    NSDictionary *event = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (error || ![event isKindOfClass:[NSDictionary class]]) {
        NSLog(@"Parse dialog downlink event failed: %@", payload);
        [self showLogMessage:payload];
        return;
    }

    NSString *eventType = event[@"type"];
    if ([eventType isEqualToString:@"session.created"]) {
        NSLog(@"session.created -> SessionStarted");
    } else if ([eventType isEqualToString:@"session.updated"]) {
        NSLog(@"session.updated -> SessionUpdated");
    } else if ([eventType isEqualToString:@"session.closed"]) {
        NSLog(@"session.closed -> SessionFinished");
    } else if ([eventType isEqualToString:@"conversation.item.input_audio_transcription.started"]) {
        NSLog(@"conversation.item.input_audio_transcription.started -> ASRInfo");
    } else if ([eventType isEqualToString:@"conversation.item.input_audio_transcription.delta"]) {
        NSLog(@"conversation.item.input_audio_transcription.delta -> ASRResponse");
        [self showUserMessageText:[self stringValue:event[@"delta"]]];
    } else if ([eventType isEqualToString:@"conversation.item.input_audio_transcription.completed"]) {
        NSLog(@"conversation.item.input_audio_transcription.completed -> ASREnded");
        [self confirmUserMessage];
    } else if ([eventType isEqualToString:@"response.output_text.delta"]) {
        NSLog(@"response.output_text.delta -> ChatResponse");
        [self showAssistantMessageText:[self stringValue:event[@"delta"]] append:YES];
    } else if ([eventType isEqualToString:@"response.output_text.done"]) {
        NSLog(@"response.output_text.done -> ChatEnded");
        [self confirmAssistantMessage];
    } else if ([eventType isEqualToString:@"response.output_audio.started"]) {
        NSLog(@"response.output_audio.started -> TTSSentenceStart");
    } else if ([eventType isEqualToString:@"response.output_audio.done"]) {
        NSLog(@"response.output_audio.done -> TTSEnded");
    } else if ([eventType isEqualToString:@"response.function_call_arguments.done"]) {
        NSLog(@"response.function_call_arguments.done -> FunctionCallResponse");
    } else if ([eventType isEqualToString:@"conversation.item.added"]) {
        NSLog(@"conversation.item.added -> ConversationCreated");
    } else if ([eventType isEqualToString:@"conversation.item.retrieved"]) {
        NSLog(@"conversation.item.retrieved -> ConversationRetrieved");
    } else if ([eventType isEqualToString:@"conversation.item.truncated"]) {
        NSLog(@"conversation.item.truncated -> ConversationTruncated");
    } else if ([eventType isEqualToString:@"conversation.item.deleted"]) {
        NSLog(@"conversation.item.deleted -> ConversationDeleted");
    } else if ([eventType isEqualToString:@"response.canceled"]) {
        NSLog(@"response.canceled -> ClientInterrupted");
    } else if ([eventType isEqualToString:@"response.done"]) {
        NSLog(@"response.done -> UsageResponse");
    } else {
        NSLog(@"handleDialogDownlinkEvent: %@", payload);
        if ([self shouldShowLog:eventType]) {
            [self showLogMessage:[NSString stringWithFormat:@"Event: %@", eventType ?: @""]];
        }
    }
}

- (BOOL)shouldShowLog:(NSString *)eventType {
    if (eventType.length == 0) {
        return YES;
    }
    return ![eventType hasPrefix:@"response.audio.delta"] &&
           ![eventType hasPrefix:@"response.output_audio.delta"] &&
           ![eventType hasPrefix:@"input_audio_buffer"] &&
           ![eventType hasPrefix:@"rate_limits.updated"];
}

#pragma mark - SpeechEngine Callback

- (void)speechEngineNoPermission {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self uninitEngine];
        [self.statusTextView setText:@"No permission!"];
        [self setButton:self.initialEngineButton enabled:YES];
        [self setButton:self.uninitialEngineButton enabled:NO];
    });
}

- (void)speechEngineInitOk {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.statusTextView setText:[NSString stringWithFormat:@"DeviceID: %@", self.deviceID]];
        [self setButton:self.initialEngineButton enabled:NO];
        [self setButton:self.uninitialEngineButton enabled:YES];
        [self setButton:self.startEngineButton enabled:YES];
    });
}

- (void)speechEngineInitFailed:(NSString *)tipText {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self uninitEngine];
        [self.statusTextView setText:tipText];
        [self setButton:self.initialEngineButton enabled:YES];
        [self setButton:self.uninitialEngineButton enabled:NO];
    });
}

- (void)speechEngineStarted:(NSString *)sessionId {
    [self showLogMessage:[NSString stringWithFormat:@"Engine start: %@", sessionId]];
    dispatch_async(dispatch_get_main_queue(), ^{
        self.engineStarted = TRUE;
        self.isPlayerPaused = NO;
        self.isRecorderPaused = NO;
        [self setButton:self.startEngineButton enabled:NO];
        [self setButton:self.stopEngineButton enabled:YES];
        [self setButton:self.speechTextAppendButton enabled:NO];
        [self setButton:self.pausePlayerButton enabled:YES];
        [self setButton:self.pauseRecorderButton enabled:YES];
        [self setButton:self.clientInterruptButton enabled:YES];
        [self.pausePlayerButton setTitle:@"暂停播放" forState:UIControlStateNormal];
        [self.pauseRecorderButton setTitle:@"暂停录音" forState:UIControlStateNormal];
        [self.statusTextView setText:@"Engine Started!"];
    });
}

- (void)speechEngineStopped:(NSString *)sessionId {
    [self showLogMessage:[NSString stringWithFormat:@"Engine stop: %@", sessionId]];
    dispatch_async(dispatch_get_main_queue(), ^{
        self.engineStarted = FALSE;
        self.isPlayerPaused = NO;
        self.isRecorderPaused = NO;
        self.speechTextAppendSpeechId = @"";
        [self setButton:self.startEngineButton enabled:YES];
        [self setButton:self.stopEngineButton enabled:NO];
        [self setButton:self.speechTextAppendButton enabled:NO];
        [self setButton:self.pausePlayerButton enabled:NO];
        [self setButton:self.pauseRecorderButton enabled:NO];
        [self setButton:self.clientInterruptButton enabled:NO];
        [self.pausePlayerButton setTitle:@"暂停播放" forState:UIControlStateNormal];
        [self.pauseRecorderButton setTitle:@"暂停录音" forState:UIControlStateNormal];
        [self.statusTextView setText:@"Engine Stopped!"];
    });
}

- (void)updateButtonsForWaitingInit {
    [self setButton:self.initialEngineButton enabled:YES];
    [self setButton:self.uninitialEngineButton enabled:NO];
    [self setButton:self.startEngineButton enabled:NO];
    [self setButton:self.stopEngineButton enabled:NO];
    [self setButton:self.speechTextAppendButton enabled:NO];
    [self setButton:self.pausePlayerButton enabled:NO];
    [self setButton:self.pauseRecorderButton enabled:NO];
    [self setButton:self.clientInterruptButton enabled:NO];
}

- (void)updateButtonsForInitializing {
    [self setButton:self.startEngineButton enabled:NO];
    [self setButton:self.stopEngineButton enabled:NO];
    [self setButton:self.speechTextAppendButton enabled:NO];
    [self setButton:self.pausePlayerButton enabled:NO];
    [self setButton:self.pauseRecorderButton enabled:NO];
    [self setButton:self.clientInterruptButton enabled:NO];
}

#pragma mark - Helper

- (void)showLogMessage:(NSString *)text {
    dispatch_async(dispatch_get_main_queue(), ^{
        DialogMessage *message = [[DialogMessage alloc] init];
        message.role = ROLE_LOG;
        message.text = text ?: @"";
        message.confirmed = true;
        [self.dialogMessages addObject:message];
        [self updateMessageUI];
    });
}

- (void)showHelloMessage:(NSString *)helloMessage {
    dispatch_async(dispatch_get_main_queue(), ^{
        DialogMessage *message = [[DialogMessage alloc] init];
        message.role = ROLE_ASSISTANT;
        message.text = helloMessage ?: @"";
        message.confirmed = true;
        [self.dialogMessages addObject:message];
        [self updateMessageUI];
    });
}

- (void)showUserMessageText:(NSString *)text {
    dispatch_async(dispatch_get_main_queue(), ^{
        DialogMessage *message = [self lastUnconfirmedMessage:ROLE_USER];
        if (message == nil) {
            message = [[DialogMessage alloc] init];
            message.role = ROLE_USER;
            message.text = @"";
            message.confirmed = false;
            [self.dialogMessages addObject:message];
        }
        message.text = text ?: @"";
        [self updateMessageUI];
    });
}

- (void)confirmUserMessage {
    dispatch_async(dispatch_get_main_queue(), ^{
        DialogMessage *message = [self lastUnconfirmedMessage:ROLE_USER];
        if (message) {
            message.confirmed = true;
        }
    });
}

- (void)showAssistantMessageText:(NSString *)text append:(BOOL)append {
    dispatch_async(dispatch_get_main_queue(), ^{
        DialogMessage *message = [self lastUnconfirmedMessage:ROLE_ASSISTANT];
        if (message == nil) {
            message = [[DialogMessage alloc] init];
            message.role = ROLE_ASSISTANT;
            message.text = @"";
            message.confirmed = false;
            [self.dialogMessages addObject:message];
        }
        if (append) {
            NSString *safeText = text ?: @"";
            message.text = [message.text stringByAppendingString:safeText];
        } else {
            message.text = text ?: @"";
        }
        [self updateMessageUI];
    });
}

- (void)confirmAssistantMessage {
    dispatch_async(dispatch_get_main_queue(), ^{
        DialogMessage *message = [self lastUnconfirmedMessage:ROLE_ASSISTANT];
        if (message) {
            message.confirmed = true;
        }
    });
}

- (DialogMessage *)lastUnconfirmedMessage:(Role)role {
    for (DialogMessage *message in [self.dialogMessages reverseObjectEnumerator]) {
        if (message.role == role) {
            if (!message.confirmed) {
                return message;
            }
            break;
        }
    }
    return nil;
}

- (void)updateMessageUI {
    if (self.dialogMessages.count > MAX_DUPLEX_DIALOG_MESSAGE_COUNT) {
        [self.dialogMessages removeObjectAtIndex:0];
    }
    NSMutableString *results = [[NSMutableString alloc] init];
    for (DialogMessage *message in self.dialogMessages) {
        NSString *role = @"";
        switch (message.role) {
            case ROLE_USER:
                role = @"[USER]:";
                break;
            case ROLE_ASSISTANT:
                role = @"[ASSISTANT]:";
                break;
            case ROLE_LOG:
                role = @"[LOG]:";
                break;
        }
        [results appendFormat:@"%@%@\n", role, message.text ?: @""];
    }
    [self.resultTextView setText:results];
    if (self.resultTextView.text.length > 0) {
        NSRange bottom = NSMakeRange(self.resultTextView.text.length - 1, 1);
        [self.resultTextView scrollRangeToVisible:bottom];
    }
}

- (NSString *)jsonStringFromObject:(id)object fallback:(NSString *)fallback {
    NSError *error;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:&error];
    if (error || data == nil) {
        NSLog(@"Build json failed: %@", error);
        return fallback;
    }
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

- (NSString *)randomEventId {
    return [NSString stringWithFormat:@"event_%@", [[NSUUID UUID] UUIDString]];
}

- (NSString *)stringValue:(id)value {
    if ([value isKindOfClass:[NSString class]]) {
        return value;
    }
    if (value == nil || value == [NSNull null]) {
        return @"";
    }
    return [value description];
}

#pragma mark - UITextViewDelegate

- (BOOL)textView:(UITextView *)textView shouldChangeTextInRange:(NSRange)range replacementText:(NSString *)text {
    if ([text isEqualToString:@"\n"]) {
        [textView resignFirstResponder];
        return NO;
    }
    return YES;
}

@end

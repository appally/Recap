//
//  DialogDelegateViewController.m
//  SpeechDemo
//
//  Created by bytedance on 2025/3/27.
//  Copyright © 2025 bytedance. All rights reserved.
//

#import "DialogDelegateViewController.h"

#import <AVFoundation/AVFoundation.h>

#import "AppDelegate.h"
#import "FileUtils.h"
#import "SettingsHelper.h"
#import "ViewController.h"
#import "SensitiveDefines.h"
#import "utils/DialogMessage.h"

#pragma mark - DialogDelegateViewController
@interface DialogDelegateViewController () <SpeechEngineDelegate, UITextViewDelegate>

// UI
@property (weak, nonatomic) IBOutlet UIButton *initialEngineButton;
@property (weak, nonatomic) IBOutlet UIButton *uninitialEngineButton;
@property (weak, nonatomic) IBOutlet UIButton *startEngineButton;
@property (weak, nonatomic) IBOutlet UIButton *stopEngineButton;
@property (weak, nonatomic) IBOutlet UIButton *chatTtsTextButton;
@property (weak, nonatomic) IBOutlet UIButton *useServerTriggerTtsButton;
@property (weak, nonatomic) IBOutlet UITextField *statusTextView;
@property (weak, nonatomic) IBOutlet UITextView *resultTextView;
@property (weak, nonatomic) IBOutlet UITextView *referTextView;
@property (strong, nonatomic) NSMutableArray *dialogMessages;

// Debug
@property (nonatomic, strong) NSString *deviceID;
@property (strong, nonatomic) NSString *debugPath;

// Speech Engine
@property (strong, nonatomic) SpeechEngine *speechEngine;
@property (assign, nonatomic) BOOL engineStarted;

// Settings
@property (strong, nonatomic) Settings *settings;

@end

@implementation DialogDelegateViewController

static const int MAX_DIALOG_MESSAGE_COUNT = 20;

- (void)viewDidLoad {
    [super viewDidLoad];

    self.initialEngineButton.enabled = TRUE;
    self.uninitialEngineButton.enabled = FALSE;
    self.startEngineButton.enabled = FALSE;
    self.stopEngineButton.enabled = FALSE;
    self.chatTtsTextButton.enabled = FALSE;
    self.useServerTriggerTtsButton.enabled = FALSE;

    [self.statusTextView setText:@"Waiting for init."];
    [self decorateTextView:self.resultTextView];

    [ViewController setAppDelegate:(AppDelegate *)[[UIApplication sharedApplication] delegate]];

    self.engineStarted = FALSE;
    self.settings = [[SettingsHelper shareInstance]getSettings:VIEW_DIALOG_DELEGATE];
}

- (void)viewDidDisappear:(BOOL)animated {
    [self uninitEngine];
    [super viewDidDisappear:animated];
}

- (void)decorateView:(UIView *)view {
    view.layer.cornerRadius = 5.0f;
    view.layer.borderWidth = .25f;
    view.layer.borderColor = [UIColor grayColor].CGColor;
}

- (void)decorateTextView:(UITextView *)textView {
    textView.layer.cornerRadius = 5.0f;
    textView.layer.borderWidth = .25f;
    textView.layer.borderColor = [UIColor grayColor].CGColor;
}

#pragma mark - Config & Init & Uninit Methods

- (void)configInitParams {
    //【必需配置】Engine Name
    [self.speechEngine setStringParam:SE_DIALOG_ENGINE forKey:SE_PARAMS_KEY_ENGINE_NAME_STRING];

    //【可选配置】Debug & Log
    self.debugPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSLog(@"Debug path: %@", self.debugPath);
    [self.speechEngine setStringParam:self.debugPath forKey:SE_PARAMS_KEY_DEBUG_PATH_STRING];
    [self.speechEngine setStringParam:SE_LOG_LEVEL_TRACE forKey:SE_PARAMS_KEY_LOG_LEVEL_STRING];

    //【必需配置】Authentication：AppId
    [self.speechEngine setStringParam:[self.settings getString:SETTING_APPID] forKey:SE_PARAMS_KEY_APP_ID_STRING];
    //【必需配置】Authentication：AppKey
    [self.speechEngine setStringParam:[self.settings getString:SETTING_APPKEY] forKey:SE_PARAMS_KEY_APP_KEY_STRING];
    //【必需配置】Authentication：Token
    [self.speechEngine setStringParam:[self.settings getString:SETTING_TOKEN] forKey:SE_PARAMS_KEY_APP_TOKEN_STRING];
    //【必需配置】对话服务资源信息ResourceId
    [self.speechEngine setStringParam:[self.settings getString:SETTING_RESOURCE_ID] forKey:SE_PARAMS_KEY_RESOURCE_ID_STRING];
    //【必需配置】User ID（用以辅助定位线上用户问题，如无法提供可提供固定字符串）
    [self.speechEngine setStringParam:SDEF_UID forKey:SE_PARAMS_KEY_UID_STRING];
    //【必需配置】Dialog Address，对话服务域名
    [self.speechEngine setStringParam:[self.settings getString:SETTING_ADDRESS] forKey:SE_PARAMS_KEY_DIALOG_ADDRESS_STRING];
    //【必需配置】Dialog Uri，对话服务Uri
    [self.speechEngine setStringParam:[self.settings getString:SETTING_URI] forKey:SE_PARAMS_KEY_DIALOG_URI_STRING];
    //【可选配置】是否开启AEC，默认不开启，同时启用设备录音和播放时必须开启
    [self.speechEngine setBoolParam:TRUE forKey:SE_PARAMS_KEY_ENABLE_AEC_BOOL];
    //【可选配置】AEC模型路径，开启AEC时必填
    NSString* aecModelPath = [NSString stringWithFormat:@"%@/aec.model", self.debugPath];
    [self.speechEngine setStringParam:aecModelPath forKey:SE_PARAMS_KEY_AEC_MODEL_PATH_STRING];
    //【可选配置】配置音频来源，默认使用设备麦克风录音（Dialog 仅支持 RECORDER 和 STREAM 模式，RECORDER表示设备麦克风录音，STREAM表示自定义音频输入）
    [self.speechEngine setStringParam:SE_RECORDER_TYPE_RECORDER forKey:SE_PARAMS_KEY_RECORDER_TYPE_STRING];
    //【可选配置】是否开启播放器，默认开启
    [self.speechEngine setBoolParam:TRUE forKey:SE_PARAMS_KEY_DIALOG_ENABLE_PLAYER_BOOL];
    //【可选配置】启用录音机音频回调，默认不启用
    [self.speechEngine setBoolParam:FALSE forKey:SE_PARAMS_KEY_DIALOG_ENABLE_RECORDER_AUDIO_CALLBACK_BOOL];
    //【可选配置】启用播放器音频回调，默认不启用（为当前正在播放的音频数据，会随着播放进度回调）
    [self.speechEngine setBoolParam:FALSE forKey:SE_PARAMS_KEY_DIALOG_ENABLE_PLAYER_AUDIO_CALLBACK_BOOL];
    //【可选配置】启用解码后原始音频回调，默认不启用（为解码后的需要播报的数据，会在解码完成后立刻回调，不等待播放进度）
    [self.speechEngine setBoolParam:FALSE forKey:SE_PARAMS_KEY_DIALOG_ENABLE_DECODER_AUDIO_CALLBACK_BOOL];
    //【可选配置】自定义请求Header
    [self.speechEngine setStringParam:[self.settings getString:SETTING_REQUEST_HEADERS] forKey:SE_PARAMS_KEY_REQUEST_HEADERS_STRING];
    //【可选配置】录音文件保存路径，如不为空，则SDK会将录音机音频保存到该路径下，文件格式为 .wav
    if ([self.settings getBool:SETTING_DIALOG_ENABLE_RECORDER_DUMP]) {
        [self.speechEngine setStringParam:self.debugPath forKey:SE_PARAMS_KEY_DIALOG_RECORDER_PATH_STRING];
    } else {
        [self.speechEngine setStringParam:@"" forKey:SE_PARAMS_KEY_DIALOG_RECORDER_PATH_STRING];
    }
    //【可选配置】播放文件保存路径，如不为空，则SDK会将播放器音频保存到该路径下，文件格式为 .wav
    if ([self.settings getBool:SETTING_DIALOG_ENABLE_PLAYER_DUMP]) {
        [self.speechEngine setStringParam:self.debugPath forKey:SE_PARAMS_KEY_DIALOG_PLAYER_PATH_STRING];
    } else {
        [self.speechEngine setStringParam:@"" forKey:SE_PARAMS_KEY_DIALOG_PLAYER_PATH_STRING];
    }
    // 【可选配置】启用TTS文本委托，默认不启用
    [self.speechEngine setIntParam:SEDialogWorkModeDelegateChatTtsText forKey:SE_PARAMS_KEY_DIALOG_WORK_MODE_INT];
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
    if (self.speechEngine == nil) {
        self.speechEngine = [[SpeechEngine alloc] init];
        if (![self.speechEngine createEngineWithDelegate:self]) {
            NSLog(@"Create speech engine failed.");
            return;
        }
    }
    NSLog(@"Engine version: %@", [self.speechEngine getVersion]);
    
    NSLog(@"配置初始化参数");
    [self configInitParams];

    NSLog(@"引擎初始化");
    SEEngineErrorCode ret = [self.speechEngine initEngine];
    if (ret != SENoError) {
        NSLog(@"Init Engine failed: %d", ret);
        [self speechEngineInitFailed];
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

- (void)sayHello {
    // Directive：发送say_hello指令以播放开场白。
    NSString* sayHelloJson = [NSString stringWithFormat: @"{\"content\": \"%@\"}", self.referTextView.text];
    SEEngineErrorCode ret = [self.speechEngine sendDirective:SEDirectiveEventSayHello data:sayHelloJson];
    if (ret != SENoError) {
        [self.statusTextView setText:[NSString stringWithFormat: @"开场白触发失败: %d", ret]];
    } else {
        // Directive：发送UseClientTriggerTts指令以播放客户端指定的TTS回复。
        ret = [self.speechEngine sendDirective:SEDirectiveDialogUseClientTriggerTts];
        if (ret != SENoError) {
            [self.statusTextView setText:[NSString stringWithFormat: @"播放客户端指定的TTS回复失败: %d", ret]];
        } else {
            [self showHelloMessage:self.referTextView.text];
        }
    }
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

    self.initialEngineButton.enabled = TRUE;
    self.uninitialEngineButton.enabled = FALSE;
    self.startEngineButton.enabled = FALSE;
    self.stopEngineButton.enabled = FALSE;
    self.chatTtsTextButton.enabled = FALSE;
    self.useServerTriggerTtsButton.enabled = FALSE;
}

- (IBAction)startEngineBtnClicked:(id)sender {
    if (self.speechEngine == nil) {
        [self.statusTextView setText:@"Engine is not initialized!"];
        return;
    }
    // Directive：启动引擎指令。
    NSLog(@"Directive: SEDirectiveStartEngine");
    NSString* startJson = [NSString stringWithFormat: @"{\"dialog\":{\"bot_name\":\"%@\"}}", [self.settings getString:SETTING_DIALOG_BOT_NAME]];
    SEEngineErrorCode ret = [self.speechEngine sendDirective:SEDirectiveStartEngine data:startJson];
    if (ret == SERecCheckEnvironmentFailed) {
        [self speechEngineNoPermission];
    } else if (ret == SENoError) {
        self.dialogMessages = [[NSMutableArray alloc] init];
        self.resultTextView.text = @"";
        // 开场白
        if (self.referTextView.text.length != 0) {
            [self sayHello];
        }
    } else {
        [self.statusTextView setText:[NSString stringWithFormat: @"Fail to start engine: %d", ret]];
    }
}

- (IBAction)stopEngineBtnClicked:(id)sender {
    if (self.speechEngine == nil) {
        [self.statusTextView setText:@"Engine is not initialized!"];
        return;
    }
    // Directive：关闭引擎，停止对话功能。
    NSLog(@"Directive: SEDirectiveStopEngine");
    [self.speechEngine sendDirective:SEDirectiveStopEngine];
}

- (IBAction)chatTtsTextBtnClicked:(id)sender {
    if (self.speechEngine == nil) {
        [self.statusTextView setText:@"Engine is not initialized!"];
        return;
    }
    NSString* chatTtsText = self.referTextView.text;
    // Directive：发送ChatTtsText指令以播放自定义回复文本，可以流式不断补充文本内容。首包需要包含start:true，end:false 。
    NSString* chatTtsTextJson = [NSString stringWithFormat: @"{\"start\": true, \"content\": \"%@\", \"end\": false}", chatTtsText];
    SEEngineErrorCode ret = [self.speechEngine sendDirective:SEDirectiveEventChatTtsText data:chatTtsTextJson];
    if (ret != SENoError) {
        [self.statusTextView setText:[NSString stringWithFormat: @"自定义TTS回复失败: %d", ret]];
        return;
    }
    // Directive：发送ChatTtsText指令以播放自定义回复文本，可以流式不断补充文本内容。尾包需要包含start:false，end:true 。
    chatTtsTextJson = @"{\"start\": false, \"content\": \"\", \"end\": true}";
    ret = [self.speechEngine sendDirective:SEDirectiveEventChatTtsText data:chatTtsTextJson];
    if (ret != SENoError) {
        [self.statusTextView setText:[NSString stringWithFormat: @"自定义TTS回复失败: %d", ret]];
        return;
    }
    // Directive：发送UseClientTriggerTts指令以播放客户端指定的TTS回复。
    ret = [self.speechEngine sendDirective:SEDirectiveDialogUseClientTriggerTts];
    if (ret != SENoError) {
        [self.statusTextView setText:[NSString stringWithFormat: @"播放客户端指定的TTS回复失败: %d", ret]];
        return;
    }
    [self updateChatTtsTextMessage:chatTtsText];
}

- (IBAction)useServerTriggerTtsBtnClicked:(id)sender {
    if (self.speechEngine == nil) {
        [self.statusTextView setText:@"Engine is not initialized!"];
        return;
    }
    // Directive：发送UseServerTriggerTts指令以播放服务端自动生成的TTS回复。
    int ret = [self.speechEngine sendDirective:SEDirectiveDialogUseServerTriggerTts];
    if (ret != SENoError) {
        [self.statusTextView setText:[NSString stringWithFormat: @"播放服务端自动生成的TTS回复失败: %d", ret]];
        return;
    }
}

#pragma mark - SpeechEngineDelegate

- (void)onMessageWithType:(SEMessageType)type andData:(NSData *)data {
    NSLog(@"Message Type: %d.", type);
    NSString *strData = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    switch (type) {
        case SEEngineStart:
            // Callback: 引擎启动成功回调
            NSLog(@"Callback: 引擎启动成功: %d", type);
            [self speechEngineStarted:strData];
            break;
        case SEEngineStop:
            // Callback: 引擎关闭回调
            NSLog(@"Callback: 引擎关闭: %d", type);
            [self speechEngineStopped:strData];
            break;
        case SEEngineError:
            // Callback: 错误信息回调
            NSLog(@"Callback: 错误信息: %d, data: %@", type, strData);
            [self showLogMessage:strData];
            break;
        case SEEventASRResponse:
            [self showUserMessage: data];
            break;
        case SEEventASREnded:
            [self confirmUserMessage];
            break;
        case SEEventChatResponse:
            [self showAssistantMessage: data];
            break;
        case SEEventASRInfo:
        case SEEventChatEnded:
        case SEEventChatTextQueryConfirmed:
            [self confirmAssistantMessage];
            break;
        case SEEventConversationCreated:
        case SEEventConversationUpdated:
        case SEEventConversationRetrieved:
        case SEEventConversationTruncated:
        case SEEventConversationDeleted:
            NSLog(@"Callback: 会话管理事件: %d, data: %@", type, strData);
            [self showLogMessage:strData];
            break;
        default:
            break;
    }
}

#pragma mark - SpeechEngine Callback

- (void)speechEngineNoPermission {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self uninitEngine];
        [self.statusTextView setText:@"No permission!"];
        self.initialEngineButton.enabled = TRUE;
        self.uninitialEngineButton.enabled = FALSE;
    });
}

- (void)speechEngineInitOk {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.statusTextView setText:[NSString stringWithFormat:@"DeviceID: %@", self.deviceID]];
        self.initialEngineButton.enabled = FALSE;
        self.uninitialEngineButton.enabled = TRUE;
        self.startEngineButton.enabled = TRUE;
    });
}

- (void)speechEngineInitFailed {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self uninitEngine];
        [self.statusTextView setText:@"Failed to init engine!"];
        self.initialEngineButton.enabled = TRUE;
        self.uninitialEngineButton.enabled = FALSE;
    });
}

- (void)speechEngineStarted:(NSString *)sessionId {
    [self showLogMessage: [NSString stringWithFormat:@"Engine start: %@", sessionId]];
    dispatch_async(dispatch_get_main_queue(), ^{
        self.engineStarted = true;
        self.startEngineButton.enabled = FALSE;
        self.stopEngineButton.enabled = TRUE;
        self.chatTtsTextButton.enabled = TRUE;
        self.useServerTriggerTtsButton.enabled = TRUE;
        [self.statusTextView setText:@"Engine Started!"];
    });
}

- (void)speechEngineStopped:(NSString *)sessionId {
    [self showLogMessage: [NSString stringWithFormat:@"Engine stop: %@", sessionId]];
    dispatch_async(dispatch_get_main_queue(), ^{
        self.engineStarted = FALSE;
        self.startEngineButton.enabled = TRUE;
        self.stopEngineButton.enabled = FALSE;
        self.chatTtsTextButton.enabled = FALSE;
        self.useServerTriggerTtsButton.enabled = FALSE;
        [self.statusTextView setText:@"Engine Stopped!"];
    });
}


# pragma mark - Helper

- (void)showLogMessage:(NSString *)text {
    dispatch_async(dispatch_get_main_queue(), ^{
        DialogMessage* message = [[DialogMessage alloc] init];
        message.role = ROLE_LOG;
        message.text = text;
        message.confirmed = true;
        [self.dialogMessages addObject:message];
        [self updateMessageUI];
    });
}

- (void)showHelloMessage:(NSString *)helloMessage {
    dispatch_async(dispatch_get_main_queue(), ^{
        DialogMessage* message = [[DialogMessage alloc] init];
        message.role = ROLE_ASSISTANT;
        message.text = helloMessage;
        message.confirmed = true;
        [self.dialogMessages addObject:message];
        [self updateMessageUI];
    });
}

- (void)showUserMessage:(NSData *)data {
    dispatch_async(dispatch_get_main_queue(), ^{
        DialogMessage* message = [self lastUnconfirmedMessage:ROLE_USER];
        if (message == nil) {
            message = [[DialogMessage alloc] init];
            message.role = ROLE_USER;
            message.confirmed = false;
            [self.dialogMessages addObject:message];
        }
        // 从回调的 json 数据中解析用户说的消息内容
        NSError *error;
        NSDictionary *jsonResult = [NSJSONSerialization JSONObjectWithData:data
                                                                    options:NSJSONReadingMutableContainers
                                                                        error:&error];
        message.text = [[[jsonResult objectForKey:@"results"] firstObject] objectForKey:@"text"];
        [self updateMessageUI];
    });
}

- (void)confirmUserMessage {
    dispatch_async(dispatch_get_main_queue(), ^{
        DialogMessage* message = [self lastUnconfirmedMessage:ROLE_USER];
        if (message) {
            message.confirmed = true;
        }
    });
}

- (void)showAssistantMessage:(NSData *)data {
    dispatch_async(dispatch_get_main_queue(), ^{
        DialogMessage* message = [self lastUnconfirmedMessage:ROLE_ASSISTANT];
        if (message == nil) {
            message = [[DialogMessage alloc] init];
            message.role = ROLE_ASSISTANT;
            message.text = @"";
            message.confirmed = false;
            [self.dialogMessages addObject:message];
        }
        // 从回调的 json 数据中解析用户说的消息内容
        NSError *error;
        NSDictionary *jsonResult = [NSJSONSerialization JSONObjectWithData:data
                                                                    options:NSJSONReadingMutableContainers
                                                                        error:&error];
        message.text = [message.text stringByAppendingString:[jsonResult objectForKey:@"content"]];
        [self updateMessageUI];
    });
}

- (void)confirmAssistantMessage {
    dispatch_async(dispatch_get_main_queue(), ^{
        DialogMessage* message = [self lastUnconfirmedMessage:ROLE_ASSISTANT];
        if (message) {
            message.confirmed = true;
        }
    });
}

- (void)updateChatTtsTextMessage:(NSString *)text {
    dispatch_async(dispatch_get_main_queue(), ^{
        DialogMessage* message = [self.dialogMessages lastObject];
        if (message == nil || message.role != ROLE_ASSISTANT) {
            message = [[DialogMessage alloc] init];
            message.role = ROLE_ASSISTANT;
            [self.dialogMessages addObject:message];
        }
        message.text = text;
        message.confirmed = true;
        [self updateMessageUI];
    });
}

- (DialogMessage*)lastUnconfirmedMessage:(Role)role {
    for (DialogMessage* message in [self.dialogMessages reverseObjectEnumerator]) {
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
    if (self.dialogMessages.count > MAX_DIALOG_MESSAGE_COUNT) {
        [self.dialogMessages removeObjectAtIndex:0];
    }
    NSString* results = @"";
    for (DialogMessage* message in self.dialogMessages) {
        NSString* role = @"";
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
        results = [results stringByAppendingFormat:@"%@%@\n", role, message.text];
    }
    [self.resultTextView setText:results];
    NSRange bottom = NSMakeRange(self.resultTextView.text.length -1, 1);
    [self.resultTextView scrollRangeToVisible:bottom];
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
    [nextPage setValue:VIEW_DIALOG_DELEGATE forKey:@"viewId"];
}

@end

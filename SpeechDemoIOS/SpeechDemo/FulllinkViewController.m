//
//  FulllinkViewController.m
//  SpeechDemo
//
//  Created by bytedance on 2020/9/8.
//  Copyright © 2020 fengkai.0518. All rights reserved.
//

#import "FulllinkViewController.h"

#import <AVFoundation/AVFoundation.h>

#import "AppDelegate.h"
#import "FileUtils.h"
#import "SettingsHelper.h"
#import "ViewController.h"
#import "SensitiveDefines.h"

@interface FulllinkViewController () <SpeechEngineDelegate, UITextViewDelegate>

@property (weak, nonatomic) IBOutlet UITextView *resultTextView;
@property (weak, nonatomic) IBOutlet UITextView *referTextView;
@property (weak, nonatomic) IBOutlet UITextField *statusTextView;
@property (weak, nonatomic) IBOutlet UIButton *engineInitButton;
@property (weak, nonatomic) IBOutlet UIButton *engineUninitButton;
@property (weak, nonatomic) IBOutlet UIButton *startEngineButton;
@property (weak, nonatomic) IBOutlet UIButton *stopEngineButton;
@property (weak, nonatomic) IBOutlet UIButton *longPressButton;
@property (weak, nonatomic) IBOutlet UIButton *forceWakeupButton;
@property (weak, nonatomic) IBOutlet UIButton *cancelDialogButton;

@property (strong, nonatomic) SpeechEngine *curEngine;
@property (assign, nonatomic) BOOL engineStarted;

@property (nonatomic, strong) NSString *deviceID;
@property (nonatomic, assign) long talkingFinisheTimestamp;
@property (nonatomic, assign) long startEngineTimestamp;
@property (strong, nonatomic) NSString *debugPath;

@property (strong, nonatomic) NSArray *engineNameArray;
@property (assign, nonatomic) NSInteger engineNameType;

@property (weak, nonatomic) StreamRecorder *streamRecorder;

// settings
@property (strong, nonatomic) Settings *settings;
@end

@implementation FulllinkViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.settings = [[SettingsHelper shareInstance]getSettings:VIEW_FULLLINK];
    
    self.engineInitButton.enabled = TRUE;
    self.engineUninitButton.enabled = FALSE;
    self.startEngineButton.enabled = FALSE;
    self.stopEngineButton.enabled = FALSE;
    self.longPressButton.enabled = FALSE;
    self.forceWakeupButton.enabled = FALSE;
    self.cancelDialogButton.enabled = FALSE;
    [self.statusTextView setText:@"Waiting for init."];
    [self decorateTextView:self.resultTextView];
    [self decorateTextView:self.referTextView];
    [self.referTextView setDelegate:self];
    self.referTextView.editable = TRUE;
    self.referTextView.text = @"高兴的反义词";
    [ViewController setAppDelegate:(AppDelegate *)[[UIApplication sharedApplication] delegate]];
    UILongPressGestureRecognizer *longPgr = [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                                                          action:@selector(longPressTriggered:)];
    longPgr.minimumPressDuration = 0.5;
    [self.longPressButton addGestureRecognizer:longPgr];
    self.streamRecorder = [ViewController getStreamRecorder];
    self.engineStarted = FALSE;
    self.engineNameArray = @[SE_FULLLINK_LITE_ENGINE, SE_FULLLINK_ENGINE];
    self.engineNameType = 0;
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
        case SEWakeupResult:
            [self speechEngineWakeUp:data];
            break;
        case SEAsrPartialResult:
            [self speechEngineResult:data isFinal:FALSE];
            break;
        case SEFinalResult:
            [self speechEngineResult:data isFinal:TRUE];
            break;
        case SENluResult:
            [self speechEngineNluResult:data];
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

- (IBAction)InitEngine:(id)sender {
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
    [self.curEngine setBoolParam:[self.settings getBool:SETTING_GET_VOLUME]
                          forKey:SE_PARAMS_KEY_ENABLE_GET_VOLUME_BOOL];
    NSString* engine_name = [self.engineNameArray objectAtIndex:self.engineNameType];
    if (engine_name == SE_FULLLINK_LITE_ENGINE) {
        [self.curEngine setBoolParam:[self.settings getBool:SETTING_FULLLINK_ONLY_ASR] forKey:SE_PARAMS_KEY_FULLLINK_ASR_ONLY_BOOL];
        [self.curEngine setBoolParam:TRUE forKey:SE_PARAMS_KEY_FULLLINK_ASR_AUTO_STOP_BOOL];
    }
    [self configUserParams];

    if ([[self getRecorderType] isEqualToString:SE_RECORDER_TYPE_STREAM]) {
        [self.curEngine setIntParam:[self.streamRecorder getSampleRate] forKey:SE_PARAMS_KEY_CUSTOM_SAMPLE_RATE_INT];
        if (![self.streamRecorder start]) {
            [self speechEngineNoPermission];
            return;
        }
    } else if ([[self getRecorderType] isEqualToString:SE_RECORDER_TYPE_FILE]) {
        NSString* file_path = [NSString stringWithFormat:@"%@/%@", self.debugPath, @"recorder.pcm"];
        NSLog(@"test file path: %@", file_path);
        [self.curEngine setStringParam:file_path forKey:SE_PARAMS_KEY_RECORDER_FILE_STRING];
    }

    NSInteger ret = [self.curEngine sendDirective:SEDirectiveStartEngine];
    if (ret == SERecCheckEnvironmentFailed) {
        [self speechEngineNoPermission];
    }
}

- (IBAction)stopEngine:(id)sender {
    NSLog(@"Stop engine.");
    [self.curEngine sendDirective:SEDirectiveStopEngine];
}

- (IBAction)forceWakeup:(id)sender {
    NSLog(@"Force wakeup.");
    NSString* engine_name = [self.engineNameArray objectAtIndex:self.engineNameType];
    if (engine_name == SE_FULLLINK_ENGINE) {
        [self.curEngine sendDirective:SEDirectiveTriggerWakeup];
    }
}

- (IBAction)cancelDialog:(id)sender {
    NSLog(@"Force wakeup.");
    [self.curEngine sendDirective:SEDirectiveCancelCurrentDialog];
}

- (IBAction)longPressTriggered:(UILongPressGestureRecognizer *)longPgr {
    [self configUserParams];
    if (longPgr.state == UIGestureRecognizerStateBegan) {
        NSLog(@"Long press begin.");
        [self setResultText:@""];
        [self.curEngine setBoolParam:[self.settings getBool:SETTING_GET_VOLUME]
                              forKey:SE_PARAMS_KEY_ENABLE_GET_VOLUME_BOOL];
        NSString* engine_name = [self.engineNameArray objectAtIndex:self.engineNameType];
        if (engine_name == SE_FULLLINK_LITE_ENGINE) {
            [self.curEngine setBoolParam:[self.settings getBool:SETTING_FULLLINK_ONLY_ASR] forKey:SE_PARAMS_KEY_FULLLINK_ASR_ONLY_BOOL];
        }

        if ([[self getRecorderType] isEqualToString:SE_RECORDER_TYPE_STREAM]) {
            [self.curEngine setIntParam:[self.streamRecorder getSampleRate] forKey:SE_PARAMS_KEY_CUSTOM_SAMPLE_RATE_INT];
            if (![self.streamRecorder start]) {
                [self speechEngineNoPermission];
                return;
            }
        } else if ([[self getRecorderType] isEqualToString:SE_RECORDER_TYPE_FILE]) {
            NSString* file_path = [NSString stringWithFormat:@"%@/%@", self.debugPath, @"recorder.pcm"];
            NSLog(@"test file path: %@", file_path);
            [self.curEngine setStringParam:file_path forKey:SE_PARAMS_KEY_RECORDER_FILE_STRING];
        }

        NSInteger ret = [self.curEngine sendDirective:SEDirectiveStartEngine];
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
    NSLog(@"Engine version: %@", [self.curEngine getVersion]);
    self.debugPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSLog(@"Debug path: %@", self.debugPath);
    [self.curEngine setStringParam:self.debugPath forKey:SE_PARAMS_KEY_DEBUG_PATH_STRING];
    [self.curEngine setStringParam:[NSString stringWithFormat:@"%@/%@", self.debugPath, @"kws"] forKey:SE_PARAMS_KEY_KWS_ROOT_PATH_STRING];
    [self.curEngine setStringParam:[NSString stringWithFormat:@"%@/%@", self.debugPath, @"signal"] forKey:SE_PARAMS_KEY_SIGNAL_ROOT_PATH_STRING];

    [self.curEngine setStringParam:SE_LOG_LEVEL_TRACE forKey:SE_PARAMS_KEY_LOG_LEVEL_STRING];
    [self.curEngine setStringParam:@"robot_ios" forKey:SE_PARAMS_KEY_APP_ID_STRING];
    [self.curEngine setStringParam:SDEF_UID forKey:SE_PARAMS_KEY_UID_STRING];
    [self.curEngine setIntParam:1 forKey:SE_PARAMS_KEY_CHANNEL_NUM_INT];
    [self.curEngine setBoolParam:[self.settings getBool:SETTING_GET_VOLUME]
                          forKey:SE_PARAMS_KEY_ENABLE_GET_VOLUME_BOOL];
    NSString *address = [self.settings getString:SETTING_ADDRESS];
    if (!address.length) {
        address = SDEF_DEFAULT_ADDRESS;
    }
    NSLog(@"Current address: %@", address);
    [self.curEngine setStringParam:address forKey:SE_PARAMS_KEY_FULLLINK_ADDRESS_STRING];
    NSString *uri = [self.settings getString:SETTING_URI];
    if (!uri.length) {
        uri = SDEF_FULLLINK_DEFAULT_URI;
    }
    NSLog(@"Current uri: %@", uri);
    [self.curEngine setStringParam:uri forKey:SE_PARAMS_KEY_FULLLINK_URI_STRING];
    [self.curEngine setStringParam:@"" forKey:SE_PARAMS_KEY_FULLLINK_QUERY_STRING_STRING];
    [self.curEngine setStringParam:[self getRecorderType] forKey:SE_PARAMS_KEY_RECORDER_TYPE_STRING];
    self.engineNameType = [self.settings getOptions:SETTING_FULLLINK_ENGINE_TYPE].chooseIdx;
    [self.curEngine setStringParam:[self.engineNameArray objectAtIndex:self.engineNameType] forKey:SE_PARAMS_KEY_ENGINE_NAME_STRING];
    [self.curEngine setBoolParam:[self.settings getBool:SETTING_FULLLINK_ENABLE_RECORDER_DUMP] forKey:@"enable_dump"];
    

    if ([[self getRecorderType] isEqualToString:SE_RECORDER_TYPE_STREAM]) {
        if ([self.streamRecorder getSampleRate] != 16000) {
            [self.curEngine setBoolParam:TRUE forKey:SE_PARAMS_KEY_ENABLE_RESAMPLER_BOOL];
        }
    }

    NSInteger ret = [self.curEngine initEngine];
    if (ret != SENoError) {
        NSLog(@"Init Engine failed: %ld", ret);
    }
    if (ret == SENoError) {
        [self speechEngineInitOk];
    } else {
        [self speechEngineInitFailed];
    }
}

- (void)configUserParams {
    NSString *param = @"{\"auth_key\":\"\",\"product_info\":{\"product_id\":2001},\"nlg_request\":{\"nlg_type\":\"\",\"nlg_content\":\"";
    param = [param stringByAppendingString:self.referTextView.text];
    param = [param stringByAppendingString:@"\"},\"session_info\":{},\"client_info\":{\"client_user_id\":\"123456\",\"client_device_id\":\"123456\",\"client_app_id\":\"111\",\"client_device_unique_code\":\"111\",\"sdk_version\":0,\"client_app_version\":\"\"}}"];
    [self.curEngine setStringParam:param forKey:SE_PARAMS_KEY_FULLLINK_USER_PARAM_STRING];
}

- (NSString *)getRecorderType {
    switch ([self.settings getOptions:SETTING_RECORD_TYPE].chooseIdx) {
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
    [self.curEngine destroyEngine];
    self.curEngine = nil;
    self.engineInitButton.enabled = TRUE;
    self.engineUninitButton.enabled = FALSE;
    self.startEngineButton.enabled = FALSE;
    self.stopEngineButton.enabled = FALSE;
    self.longPressButton.enabled = FALSE;
    self.forceWakeupButton.enabled = FALSE;
    self.cancelDialogButton.enabled = FALSE;
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
    [self.streamRecorder setSpeechEngine:self.curEngine];
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
        [self setResultText:@""];
        self.startEngineButton.enabled = FALSE;
        self.stopEngineButton.enabled = TRUE;
        self.longPressButton.enabled = FALSE;
        self.forceWakeupButton.enabled = TRUE;
        self.cancelDialogButton.enabled = TRUE;
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
        self.forceWakeupButton.enabled = FALSE;
        self.cancelDialogButton.enabled = FALSE;
    });
}

- (void)speechEngineResult:(NSData *)data isFinal:(BOOL)isFinal {
    long response_delay = 0;
    if (isFinal && self.talkingFinisheTimestamp > 0) {
        response_delay = [self timeDelayFrom:self.talkingFinisheTimestamp];
        self.talkingFinisheTimestamp = 0;
    }
    
    NSError *error;
    NSDictionary *jsonResult = [NSJSONSerialization JSONObjectWithData:data
                                                               options:NSJSONReadingMutableContainers
                                                                 error:&error];
    NSMutableString *text = [[NSMutableString alloc] initWithString:@""];
    if (![jsonResult objectForKey:@"messageData"]) {
        return;
    }
    [text appendFormat:@"%@", [[[jsonResult objectForKey:@"messageData"] objectForKey:@"inputText"] objectForKey:@"text"]];
    if (text.length) {
        [self setResultText:text];
    }
}

- (void)speechEngineNluResult:(NSData *)data {
    NSError *error;
    NSDictionary *jsonResult = [NSJSONSerialization JSONObjectWithData:data
                                                               options:NSJSONReadingMutableContainers
                                                                 error:&error];
    NSMutableString *text = [[NSMutableString alloc] initWithString:@""];
    if (![jsonResult objectForKey:@"messageData"]) {
        return;
    }
    [text appendFormat:@"%@\n%@", [[jsonResult objectForKey:@"messageData"] objectForKey:@"inputText"], [[jsonResult objectForKey:@"messageData"] objectForKey:@"outputText"]];
    if (text.length) {
        [self setResultText:text];
    }
    bool disableTts = [self.settings getBool:SETTING_FULLLINK_DISABLE_TTS];
    [self.curEngine sendDirective:SEDirectivePlayingDecision data:disableTts ? @"false" : @"true"];
}

- (void)speechEngineError:(NSData *)data {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.resultTextView setText:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]];
//        [self stopEngine:nil];
    });
}

- (void)speechEngineWakeUp:(NSData *)data {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.resultTextView setText:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]];
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
    [nextPage setValue:VIEW_FULLLINK forKey:@"viewId"];
}

@end



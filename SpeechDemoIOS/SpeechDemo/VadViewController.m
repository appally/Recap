//
//  VadViewController.m
//  SpeechDemo
//
//  Created by bytedance on 2023/1/30.
//  Copyright © 2023 tianlei.richard. All rights reserved.
//

#import "VadViewController.h"

#import <AVFoundation/AVFoundation.h>

#import "AppDelegate.h"
#import "FileUtils.h"
#import "SettingsHelper.h"
#import "ViewController.h"
#import "SensitiveDefines.h"

@interface VadViewController () <SpeechEngineDelegate, UITextViewDelegate>

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
@property (nonatomic, assign) long vadDuration;
@property (nonatomic, assign) long vadBeginPosition;
@property (nonatomic, assign) long vadEndPosition;
@property (strong, nonatomic) NSString *debugPath;

@property (weak, nonatomic) StreamRecorder *streamRecorder;

// settings
@property (strong, nonatomic) Settings *settings;

@end

@implementation VadViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.settings = [[SettingsHelper shareInstance]getSettings:VIEW_VAD];
    
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
        case SEVadSilence:
            break;
        case SEVadSil2Speech:
            [self messageVadBegin:data];
            break;
        case SEVadSpeech:
            [self messasgeVadSpeech:data];
            break;
        case SEVadSpeech2Sil:
            [self messageVadEnd:data];
            break;
        case SEVadAudioData:
            self.vadDuration += data.length;
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
    [self.resultTextView setText:@"点击或按住说话后，展示音频活性检测结果"];
}

- (IBAction)startEngine:(id)sender {
    NSLog(@"Start engine.");
    NSString* appID = [self.settings getString:SETTING_APPID];
    [self.curEngine setStringParam:appID.length <= 0 ? SDEF_APPID : appID forKey:SE_PARAMS_KEY_APP_ID_STRING];
    [self.curEngine setBoolParam:[self.settings getBool:SETTING_RESTART_AUDIO_SESSION_ENABLE]
                          forKey:SE_PARAMS_KEY_RESTART_AUDIOSESSION_BOOL];
    [self.curEngine setBoolParam:[self.settings getBool:SETTING_RESUME_OTHERS_INTERRUPTED_PLAYBACK_ENABLE]
                          forKey:SE_PARAMS_KEY_RESUME_OTHERS_INTERRUPTED_PLAYBACK_BOOL];
    [self.curEngine setBoolParam:[self.settings getBool:SETTING_GET_VOLUME] forKey:SE_PARAMS_KEY_ENABLE_GET_VOLUME_BOOL];
    [self.curEngine setIntParam:[self.settings getInt:SETTING_VAD_HEAD_SILENCE_THRESHOLD] forKey:SE_PARAMS_KEY_VAD_HEAD_SILENCE_THRESHOLD_INT];
    [self.curEngine setIntParam:[self.settings getInt:SETTING_VAD_TAIL_SILENCE_THRESHOLD] forKey:SE_PARAMS_KEY_VAD_TAIL_SILENCE_THRESHOLD_INT];
    
    if ([[self getRecorderType] isEqualToString:SE_RECORDER_TYPE_STREAM]) {
        [self.curEngine setIntParam:[self.streamRecorder getSampleRate] forKey:SE_PARAMS_KEY_CUSTOM_SAMPLE_RATE_INT];
        if (![self.streamRecorder start]) {
            [self speechEngineNoPermission];
            return;
        }
    } else if ([[self getRecorderType] isEqualToString:SE_RECORDER_TYPE_FILE]) {
        NSString* file_path = [NSString stringWithFormat:@"%@/%@", self.debugPath, @"vad_rec_file.pcm"];
        NSLog(@"test file path: %@", file_path);
        [self.curEngine setStringParam:file_path forKey:SE_PARAMS_KEY_RECORDER_FILE_STRING];
    }
    
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
        NSString* appID = [self.settings getString:SETTING_APPID];
        [self.curEngine setStringParam:appID.length <= 0 ? SDEF_APPID : appID forKey:SE_PARAMS_KEY_APP_ID_STRING];
        [self.curEngine setBoolParam:[self.settings getBool:SETTING_RESTART_AUDIO_SESSION_ENABLE]
                              forKey:SE_PARAMS_KEY_RESTART_AUDIOSESSION_BOOL];
        [self.curEngine setBoolParam:[self.settings getBool:SETTING_RESUME_OTHERS_INTERRUPTED_PLAYBACK_ENABLE]
                              forKey:SE_PARAMS_KEY_RESUME_OTHERS_INTERRUPTED_PLAYBACK_BOOL];
        [self.curEngine setBoolParam:[self.settings getBool:SETTING_GET_VOLUME]
                              forKey:SE_PARAMS_KEY_ENABLE_GET_VOLUME_BOOL];
        [self.curEngine setIntParam:[self.settings getInt:SETTING_VAD_HEAD_SILENCE_THRESHOLD] forKey:SE_PARAMS_KEY_VAD_HEAD_SILENCE_THRESHOLD_INT];
        [self.curEngine setIntParam:[self.settings getInt:SETTING_VAD_TAIL_SILENCE_THRESHOLD] forKey:SE_PARAMS_KEY_VAD_TAIL_SILENCE_THRESHOLD_INT];

        if ([[self getRecorderType] isEqualToString:SE_RECORDER_TYPE_STREAM]) {
            [self.curEngine setIntParam:[self.streamRecorder getSampleRate] forKey:SE_PARAMS_KEY_CUSTOM_SAMPLE_RATE_INT];
            if (![self.streamRecorder start]) {
                [self speechEngineNoPermission];
                return;
            }
        } else if ([[self getRecorderType] isEqualToString:SE_RECORDER_TYPE_FILE]) {
            NSString* file_path = [NSString stringWithFormat:@"%@/%@", self.debugPath, @"vad_rec_file.pcm"];
            NSLog(@"test file path: %@", file_path);
            [self.curEngine setStringParam:file_path forKey:SE_PARAMS_KEY_RECORDER_FILE_STRING];
        }
        
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
    NSLog(@"Engine version: %@", [self.curEngine getVersion]);
    [self initOfflineModel:^() {
        self.debugPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSLog(@"Debug path: %@", self.debugPath);
        [self.curEngine setStringParam:self.debugPath forKey:SE_PARAMS_KEY_DEBUG_PATH_STRING];
        [self.curEngine setStringParam:SE_LOG_LEVEL_TRACE forKey:SE_PARAMS_KEY_LOG_LEVEL_STRING];
        [self.curEngine setStringParam:SDEF_APPID forKey:SE_PARAMS_KEY_APP_ID_STRING];
        [self.curEngine setStringParam:self.deviceID forKey:SE_PARAMS_KEY_DEVICE_ID_STRING];
        [self.curEngine setIntParam:1 forKey:SE_PARAMS_KEY_CHANNEL_NUM_INT];
        [self.curEngine setBoolParam:[self.settings getBool:SETTING_GET_VOLUME]
                            forKey:SE_PARAMS_KEY_ENABLE_GET_VOLUME_BOOL];
        [self.curEngine setStringParam:@"" forKey:SE_PARAMS_KEY_VAD_REC_PATH_STRING];
        if ([self.settings getBool:SETTING_VAD_RECORDER_SAVE]) {
            [self.curEngine setStringParam:self.debugPath forKey:SE_PARAMS_KEY_VAD_REC_PATH_STRING];
        }
        [self.curEngine setIntParam:4000 forKey:SE_PARAMS_KEY_VAD_HEAD_SILENCE_THRESHOLD_INT];
        [self.curEngine setIntParam:2000 forKey:SE_PARAMS_KEY_VAD_TAIL_SILENCE_THRESHOLD_INT];
        [self.curEngine setStringParam:[self getRecorderType] forKey:SE_PARAMS_KEY_RECORDER_TYPE_STRING];
        [self.curEngine setStringParam:SE_VAD_ENGINE forKey:SE_PARAMS_KEY_ENGINE_NAME_STRING];
        [self.curEngine setIntParam:16000 forKey:SE_PARAMS_KEY_SAMPLE_RATE_INT];

        NSString* aedResourcePath = [[SpeechResourceManager shareInstance] getModelPath:SE_AED_MODEL];
        NSLog(@"petrel aed resource path: %@", aedResourcePath);
        [self.curEngine setStringParam:aedResourcePath forKey:SE_PARAMS_KEY_AED_RESOURCE_PATH_STRING];
        
        if ([[self getRecorderType] isEqualToString:SE_RECORDER_TYPE_STREAM]) {
            if ([self.streamRecorder getSampleRate] != 16000) {
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
            [self speechEngineInitFailed:ret];
        }
    } fail:^{
        [self speechEngineInitFailed:kSERDownloadFailed];
    }];
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

- (void)initOfflineModel:(void(^)(void))succ fail:(void(^)(void))fail {
    NSString *model = SE_AED_MODEL;
    SpeechResourceManager *speechResourceManager = [SpeechResourceManager shareInstance];
    [speechResourceManager checkModelVersion:model completion:^(SEResourceStatus status, BOOL needUpdate, NSData *data) {
        NSLog(@"Need update: %@", needUpdate ? @"YES" : @"NO");
        if (status != kSERSuccess || needUpdate == NO) {
            if ([speechResourceManager checkModelExist:model]) {
                NSLog(@"Model exist!");
                succ();
            } else {
                NSLog(@"Model not exist!");
                fail();
            }
            return;
        }
        
        // need to update model
        [speechResourceManager fetchModelByName:model completion:^(SEResourceStatus status, NSData* data) {
            NSLog(@"Completion: %@", status == kSERSuccess ? @"success" : @"fail");
            if (status == kSERSuccess) {
                succ();
            } else {
                NSLog(@"Failed: %d", status);
                fail();
            }
        }];
    }];
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

- (void)speechEngineInitFailed:(int)initStatus {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self uninitEngine];
        [self.statusTextView setText:[[NSString alloc] initWithFormat:@"Failed to init engine, %d!", initStatus]];
        self.engineInitButton.enabled = TRUE;
        self.engineUninitButton.enabled = FALSE;
    });
}

- (void)speechEngineStarted {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.engineStarted = true;
        self.vadDuration = 0;
        self.vadBeginPosition = 0;
        self.vadEndPosition = 0;
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

- (void)speechEngineError:(NSData *)data {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.resultTextView setText:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]];
        [self stopEngine:nil];
    });
}

- (void)messageVadBegin:(NSData *)data {
    id json_obj = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
    if ([json_obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *vad_info = json_obj;
        self.vadBeginPosition = [[vad_info objectForKey:@"start"] doubleValue];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.resultTextView setText:[NSString stringWithFormat:@"Vad begin, bos: %ld", self.vadBeginPosition]];
    });
}

- (void)messasgeVadSpeech:(NSData *)data {
    id json_obj = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
    if ([json_obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *vad_info = json_obj;
        double currentSegEnd = [[vad_info objectForKey:@"end"] doubleValue];
        if (currentSegEnd > self.vadEndPosition) {
            self.vadEndPosition = currentSegEnd;
        }
    }
}

- (void)messageVadEnd:(NSData *)data {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.resultTextView setText:[NSString stringWithFormat:@"Vad end, eos: %ld, speech duration: %ldms.", self.vadEndPosition, self.vadDuration/(2*16000/1000)]];
        [self stopEngine:nil];
    });
}

- (void)setResultText:(NSString *)result {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.resultTextView setText:[result stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
    });
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
    [nextPage setValue:VIEW_VAD forKey:@"viewId"];
}

@end

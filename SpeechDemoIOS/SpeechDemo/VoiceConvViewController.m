//
//  VoiceConvViewController.m
//  SpeechDemo
//
//  Created by chengzihao.ds on 2021/4/1.
//  Copyright © 2021 chengzihao.ds. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "VoiceConvViewController.h"

#import "AppDelegate.h"
#import "FileUtils.h"
#import "SettingsHelper.h"
#import "ViewController.h"
#import "SensitiveDefines.h"

@interface VoiceConvViewController () <SpeechEngineDelegate, UITextViewDelegate>

@property (weak, nonatomic) IBOutlet UITextView *referTextView;
@property (weak, nonatomic) IBOutlet UITextView *resultTextView;
@property (weak, nonatomic) IBOutlet UITextField *statusTextView;
@property (weak, nonatomic) IBOutlet UIButton *engineSwitchButton;
@property (weak, nonatomic) IBOutlet UIButton *startEngineButton;
@property (weak, nonatomic) IBOutlet UIButton *finishTalkingButton;

@property (strong, nonatomic) SpeechEngine *curEngine;
@property (assign, nonatomic) BOOL signalEnabled;
@property (assign, nonatomic) BOOL engineInited;
@property (assign, nonatomic) BOOL engineStarted;

@property (nonatomic, strong) NSString *deviceID;
@property (nonatomic, assign) long talkingFinisheTimestamp;
@property (nonatomic, assign) long startEngineTimestamp;
@property (strong, nonatomic) NSString *debugPath;

// ViewStatus
typedef enum ViewStatus : NSUInteger {
    BEFORE_INIT,
    INITING,
    BEFORE_START,
    RECORDING,
    WAITING_RESULT,
} ViewStatus;

// Recorder
@property (weak, nonatomic) StreamRecorder *streamRecorder;
@property (strong, nonatomic) NSString *recFilePath;
@property (nonatomic, assign) long curResLength;
@property (nonatomic, assign) long recFileLength;

// settings
@property (strong, nonatomic) Settings *settings;

@end

@implementation VoiceConvViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.settings = [[SettingsHelper shareInstance]getSettings:VIEW_VOICECONV];
    
    [self switchViewStatus:BEFORE_INIT];
    [self decorateTextView:self.referTextView];
    [self decorateTextView:self.resultTextView];
    [self.referTextView setDelegate:self];
    self.referTextView.editable = FALSE;
    
    self.engineInited = FALSE;
    self.engineStarted = FALSE;
    self.streamRecorder = [ViewController getStreamRecorder];
    [self.statusTextView setText:@"Waiting for init."];
    [ViewController setAppDelegate:(AppDelegate *)[[UIApplication sharedApplication] delegate]];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appDidEnterBackground:)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appWillTerminate:)
                                                 name:UIApplicationWillTerminateNotification
                                               object:nil];
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

- (void)switchViewStatus:(ViewStatus) status {
    switch (status) {
        case BEFORE_INIT:
            [self.engineSwitchButton setTitle:@"InitEngine" forState:UIControlStateNormal];
            self.engineSwitchButton.enabled = TRUE;
            self.startEngineButton.enabled = FALSE;
            self.finishTalkingButton.enabled = FALSE;
            break;
        case INITING:
            [self.engineSwitchButton setTitle:@"InitEngine" forState:UIControlStateNormal];
            self.engineSwitchButton.enabled = FALSE;
            self.startEngineButton.enabled = FALSE;
            self.finishTalkingButton.enabled = FALSE;
            break;
        case BEFORE_START:
            [self.engineSwitchButton setTitle:@"UninitEngine" forState:UIControlStateNormal];
            self.engineSwitchButton.enabled = TRUE;
            self.startEngineButton.enabled = TRUE;
            self.finishTalkingButton.enabled = FALSE;
            break;
        case RECORDING:
            [self.engineSwitchButton setTitle:@"UninitEngine" forState:UIControlStateNormal];
            self.engineSwitchButton.enabled = TRUE;
            self.startEngineButton.enabled = FALSE;
            self.finishTalkingButton.enabled = TRUE;
            break;
        case WAITING_RESULT:
            [self.engineSwitchButton setTitle:@"UninitEngine" forState:UIControlStateNormal];
            self.engineSwitchButton.enabled = TRUE;
            self.startEngineButton.enabled = FALSE;
            self.finishTalkingButton.enabled = FALSE;
            break;
        default:
            break;
    }
}

#pragma mark - Notifications

- (void)appDidEnterBackground:(UIApplication *)application; {
//    if (self.engineStarted) {
//        [self stopEngine:nil];
//    }
}

-(void)appWillTerminate:(NSNotification*)note {
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:UIApplicationWillResignActiveNotification
                                                  object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:UIApplicationWillTerminateNotification
                                                  object:nil];
}

#pragma mark - SpeechEngineDelegate

- (void)onMessageWithType:(SEMessageType)type andData:(NSData *)data {
    NSLog(@"Message Type: %d.", type);
    switch (type) {
        case SEEngineStart:
            [self speechEngineStarted];
            break;
        case SEEngineStop:
            [self speechEngineStopped:data];
            break;
        case SEEngineError:
            [self speechEngineError:data];
            break;
        case SEVoiceConvResultAudio:
            [self speechResultAudio:data];
            break;
        case SEEngineLog:
            NSLog(@"engine log: %s", data.bytes);
            break;
        default:
            break;
    }
}

#pragma mark - UI Actions
- (IBAction)switchEngine:(id)sender {
    if (self.engineStarted) {
        [self.statusTextView setText:@"Engine is busy, stop it first!"];
        return;
    }
    
    if (self.engineInited) {
        [self switchViewStatus:BEFORE_INIT];
        [self uninitEngine];
        self.engineInited = FALSE;
        [self.statusTextView setText:@"Waiting for init."];
        [self.engineSwitchButton setTitle:@"InitEngine" forState:UIControlStateNormal];
    } else {
        [self switchViewStatus:INITING];
        [self initEngine];
    }
}

- (IBAction)startEngine:(id)sender {
    if ([[self getRecorderType] isEqualToString:SE_RECORDER_TYPE_STREAM]) {
        [self.curEngine setIntParam:[self.streamRecorder getSampleRate] forKey:SE_PARAMS_KEY_CUSTOM_SAMPLE_RATE_INT];
        if (![self.streamRecorder start]) {
            [self speechEngineNoPermission];
            return;
        }
    } else if ([[self getRecorderType] isEqualToString:SE_RECORDER_TYPE_FILE]) {
        // get file length
        NSFileManager* manager = [NSFileManager defaultManager];
        if ([manager fileExistsAtPath:self.recFilePath]){
            self.recFileLength = [[manager attributesOfItemAtPath:self.recFilePath error:nil] fileSize];
        }
        NSLog(@"Open record file: %@, length: %ld", self.recFilePath, self.recFileLength);
        self.curResLength = 0;
        [self.curEngine setStringParam:self.recFilePath forKey:SE_PARAMS_KEY_RECORDER_FILE_STRING];
    }
        
    [self.curEngine setStringParam:SDEF_UID forKey:SE_PARAMS_KEY_UID_STRING];
    [self.curEngine setStringParam:[self.settings getString:SETTING_VOICE] forKey:SE_PARAMS_KEY_VOICECONV_VOICE_STRING];
    [self.curEngine setStringParam:[self.settings getString:SETTING_VOICE_TYPE] forKey:SE_PARAMS_KEY_VOICECONV_VOICE_TYPE_STRING];
    [self.curEngine setIntParam:[self.settings getInt:SETTING_VOICECONV_RESULT_SAMPLE_RATE] forKey:SE_PARAMS_KEY_VOICECONV_RESULT_SAMPLE_RATE_INT];
    [self.curEngine setIntParam:[self.settings getInt:SETTING_VOICECONV_REQUEST_INTERVAL] forKey:SE_PARAMS_KEY_VOICECONV_REQUEST_INTERVAL_INT];
    SEEngineErrorCode ret = [self.curEngine sendDirective:SEDirectiveStartEngine];
    
    if (ret == SENoError) {
        [self switchViewStatus:RECORDING];
    } else {
        [self.resultTextView setText:[NSString stringWithFormat:@"Start engine failed! ret: %d", ret]];
    }
}

- (IBAction)stopEngine:(id)sender {
    [self.curEngine sendDirective:SEDirectiveStopEngine];
    if ([[self getRecorderType] isEqualToString:SE_RECORDER_TYPE_STREAM]) {
        [self.streamRecorder stop];
    }
}

- (IBAction)finishTalking:(id)sender {
    [self.curEngine sendDirective:SEDirectiveFinishTalking];
    if ([[self getRecorderType] isEqualToString:SE_RECORDER_TYPE_STREAM]) {
        [self.streamRecorder stop];
    }
    [self switchViewStatus:WAITING_RESULT];
}

#pragma mark - Init Methods

- (void)initEngine {
    AppDelegate *appDelegate = [ViewController getAppDelegate];
    if (appDelegate == nil) {
        appDelegate = (AppDelegate *)[[UIApplication sharedApplication] delegate];
    }
    if (appDelegate.deviceID.length < 1) {
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

    self.debugPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    self.recFilePath = [NSString stringWithFormat:@"%@/%@", self.debugPath, @"voiceconv_rec_file.pcm"];
    NSLog(@"Engine version: %@", [self.curEngine getVersion]);
    NSLog(@"Debug path: %@", self.debugPath);
    
    // recorder
    SettingOptions *options = [self.settings getOptions:SETTING_RECORD_TYPE];
    
    [self.curEngine setStringParam:self.debugPath forKey:SE_PARAMS_KEY_DEBUG_PATH_STRING];
    [self.curEngine setStringParam:SE_LOG_LEVEL_TRACE forKey:SE_PARAMS_KEY_LOG_LEVEL_STRING];
    [self.curEngine setStringParam:@"test" forKey:SE_PARAMS_KEY_APP_ID_STRING];
    [self.curEngine setIntParam:1 forKey:SE_PARAMS_KEY_CHANNEL_NUM_INT];
    [self.curEngine setIntParam:16000 forKey:SE_PARAMS_KEY_SAMPLE_RATE_INT];
    [self.curEngine setStringParam:[self getRecorderType] forKey:SE_PARAMS_KEY_RECORDER_TYPE_STRING];
    [self.curEngine setStringParam:SE_VOICECONV_ENGINE forKey:SE_PARAMS_KEY_ENGINE_NAME_STRING];
    
    [self.curEngine setStringParam:@"wss://speech-test.bytedance.com" forKey:SE_PARAMS_KEY_VOICECONV_ADDRESS_STRING];
    [self.curEngine setStringParam:@"/api/v1/voice_conv/ws" forKey:SE_PARAMS_KEY_VOICECONV_URI_STRING];
    [self.curEngine setStringParam:@"default" forKey:SE_PARAMS_KEY_VOICECONV_CLUSTER_STRING];
    [self.curEngine setBoolParam:[self.settings getBool:SETTING_VOICECONV_ENABLE_RECORD_DUMP] forKey:SE_PARAMS_KEY_VOICECONV_ENABLE_RECORD_DUMP_BOOL];
    [self.curEngine setBoolParam:[self.settings getBool:SETTING_VOICECONV_ENABLE_RESULT_DUMP] forKey:SE_PARAMS_KEY_VOICECONV_ENABLE_RESULT_DUMP_BOOL];
    [self.curEngine setStringParam:self.debugPath forKey:SE_PARAMS_KEY_VOICECONV_AUDIO_PATH_STRING];
    
    if ([[self getRecorderType] isEqualToString:SE_RECORDER_TYPE_STREAM]) {
        if ([self.streamRecorder getSampleRate] != 16000) {
            [self.curEngine setBoolParam:TRUE forKey:SE_PARAMS_KEY_ENABLE_RESAMPLER_BOOL];
        }
    }

    SEEngineErrorCode ret = [self.curEngine initEngine];
    if (ret != SENoError) {
        NSLog(@"Init Engine failed: %d", ret);
    }
    self.engineInited = (ret == SENoError);
    if (self.engineInited) {
        [self speechEngineInitOk];
    } else {
        [self speechEngineInitFailed];
    }
}

- (void)uninitEngine {
    [self.curEngine destroyEngine];
    self.curEngine = nil;
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

#pragma mark - Engine Callback

- (void)speechEngineNoPermission {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self uninitEngine];
        [self.statusTextView setText:@"No permission!"];
    });
}

- (void)speechEngineInitOk {
    [self.streamRecorder setSpeechEngine:self.curEngine];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self switchViewStatus:BEFORE_START];
        [self.statusTextView setText:@"Ready"];
        [self.resultTextView setText:[NSString stringWithFormat:@"DeviceID: %@", self.deviceID]];
    });
}

- (void)speechEngineInitFailed {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self switchViewStatus:BEFORE_INIT];
        [self uninitEngine];
        [self.statusTextView setText:@"Failed to init engine!"];
    });
}

- (void)speechEngineStarted {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.startEngineTimestamp = [[NSDate date] timeIntervalSince1970] * 1000;
        self.engineStarted = true;
        [self.statusTextView setText:@"Engine Started!"];
    });
}

- (void)speechEngineStopped:(NSData *)data {
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([[self getRecorderType] isEqualToString:SE_RECORDER_TYPE_STREAM]) {
            [self.streamRecorder stop];
        }
        // record result file
        NSString* reqId = [[NSString alloc] initWithData:data encoding:NSASCIIStringEncoding];
        NSString* resultFile = [NSString stringWithFormat:@"voiceconv_%@.wav", reqId];
        
        self.engineStarted = FALSE;
        [self.statusTextView setText:@"Engine Stopped!"];
        if (self.startEngineTimestamp > 0) {
            long response_delay = [self timeDelayFrom:self.startEngineTimestamp];
            self.startEngineTimestamp = 0;
            [self.resultTextView setText:[NSString stringWithFormat:@"%@\nVoiceConv cost: %ld\nResult File: %@", self.resultTextView.text, response_delay, resultFile]];
        }
        [self switchViewStatus:BEFORE_START];
    });
}

- (void)speechEngineError:(NSData *)data {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.resultTextView setText:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]];
        [self stopEngine:nil];
    });
}

- (void)speechResultAudio:(NSData *)data {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.resultTextView setText:[NSString stringWithFormat:@"Get audio data, size: %ld", data.length]];
        
        // calculate progress
        if ([[self getRecorderType] isEqualToString:SE_RECORDER_TYPE_FILE] && self.recFileLength != 0) {
            self.curResLength += data.length;
            long inputSampleRate = 16000;
            long outputSampleRate = [self.settings getInt:SETTING_VOICECONV_RESULT_SAMPLE_RATE];
            double progress = (double) self.curResLength / self.recFileLength * inputSampleRate / outputSampleRate;
            [self.resultTextView setText:[NSString stringWithFormat:@"%@\nCurrent result length: %ld, total file length: %ld, progress: %lf", self.resultTextView.text, self.curResLength, self.recFileLength, progress]];
            
        }
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
    [nextPage setValue:VIEW_VOICECONV forKey:@"viewId"];
}

@end


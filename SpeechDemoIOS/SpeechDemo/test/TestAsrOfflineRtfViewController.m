//
//  TestAsrOfflineRtfViewController.m
//  SpeechDemo
//
//  Created by bytedance on 2023/6/6.
//  Copyright © 2023 chengzihao.ds. All rights reserved.
//

#import "TestAsrOfflineRtfViewController.h"

#import <AVFoundation/AVFoundation.h>

#import "AppDelegate.h"
#import "FileUtils.h"
#import "SettingsHelper.h"
#import "ViewController.h"

@interface TestAsrOfflineRtfViewController () <SpeechEngineDelegate, UITextViewDelegate>

@property (weak, nonatomic) IBOutlet UITextView *resultTextView;
@property (weak, nonatomic) IBOutlet UITextField *statusTextView;
@property (weak, nonatomic) IBOutlet UIButton *engineInitButton;
@property (weak, nonatomic) IBOutlet UIButton *engineUninitButton;
@property (weak, nonatomic) IBOutlet UIButton *startEngineButton;
@property (weak, nonatomic) IBOutlet UIButton *stopEngineButton;

@property (strong, nonatomic) SpeechEngine *curEngine;
@property (assign, nonatomic) BOOL engineStarted;

@property (nonatomic, strong) NSString *deviceID;
@property (nonatomic, assign) long feedTimestamp;
@property (nonatomic, assign) int audioLength;
@property (strong, nonatomic) NSString *debugPath;

// settings
@property (strong, nonatomic) Settings *settings;

@end

@implementation TestAsrOfflineRtfViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.settings = [[SettingsHelper shareInstance]getSettings:VIEW_TEST_ASR_OFFLINE_RTF];
    
    self.engineInitButton.enabled = TRUE;
    self.engineUninitButton.enabled = FALSE;
    self.startEngineButton.enabled = FALSE;
    self.stopEngineButton.enabled = FALSE;
    [self.statusTextView setText:@"Waiting for init."];
    [self decorateTextView:self.resultTextView];
    [ViewController setAppDelegate:(AppDelegate *)[[UIApplication sharedApplication] delegate]];
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
    [self.curEngine setBoolParam:FALSE forKey:SE_PARAMS_KEY_ASR_AUTO_STOP_BOOL];
    
    SEEngineErrorCode ret = [self.curEngine sendDirective:SEDirectiveStartEngine];
    if (ret == SERecCheckEnvironmentFailed) {
        [self speechEngineNoPermission];
        return;
    }
}

- (IBAction)stopEngine:(id)sender {
    NSLog(@"Stop engine.");
    [self.curEngine sendDirective:SEDirectiveStopEngine];
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
    [self.curEngine setStringParam:SE_LOG_LEVEL_TRACE forKey:SE_PARAMS_KEY_LOG_LEVEL_STRING];
    [self.curEngine setStringParam:[self.settings getString:SETTING_APPID] forKey:SE_PARAMS_KEY_APP_ID_STRING];
    [self.curEngine setStringParam:@"388808087185088" forKey:SE_PARAMS_KEY_UID_STRING];
    [self.curEngine setIntParam:1 forKey:SE_PARAMS_KEY_CHANNEL_NUM_INT];
    [self.curEngine setBoolParam:FALSE forKey:SE_PARAMS_KEY_ASR_AUTO_STOP_BOOL];
    [self.curEngine setStringParam:@"" forKey:SE_PARAMS_KEY_ASR_REC_PATH_STRING];
    if ([self.settings getBool:SETTING_ASR_RECORDER_SAVE]) {
        [self.curEngine setStringParam:self.debugPath forKey:SE_PARAMS_KEY_ASR_REC_PATH_STRING];
    }
    [self.curEngine setStringParam:SE_RECORDER_TYPE_STREAM forKey:SE_PARAMS_KEY_RECORDER_TYPE_STRING];
    [self.curEngine setStringParam:SE_ASR_ENGINE forKey:SE_PARAMS_KEY_ENGINE_NAME_STRING];
    [self.curEngine setIntParam:16000 forKey:SE_PARAMS_KEY_SAMPLE_RATE_INT];
    [self.curEngine setBoolParam:true forKey:SE_PARAMS_KEY_ASR_SHOW_UTTER_BOOL];
    [self.curEngine setBoolParam:[self.settings getBool:SETTING_ASR_SHOW_LANGUAGE] forKey:SE_PARAMS_KEY_ASR_SHOW_LANG_BOOL];
    [self.curEngine setBoolParam:true forKey:SE_PARAMS_KEY_ASR_SHOW_VOLUME_BOOL];
    [self.curEngine setIntParam:SEAsrWorkModeOfflineFlute forKey:SE_PARAMS_KEY_ASR_WORK_MODE_INT];
    NSString* modelsPath = [NSString stringWithFormat:@"%@/models", self.debugPath];
    [self.curEngine setStringParam:modelsPath forKey:SE_PARAMS_KEY_ASR_OFF_RESOURCE_PATH_STRING];
    NSLog(@"Models path: %@", modelsPath);
    
    SEEngineErrorCode ret = [self.curEngine initEngine];
    if (ret != SENoError) {
        NSLog(@"Init Engine failed: %ld", ret);
    }
    if (ret == SENoError) {
        [self speechEngineInitOk];
    } else {
        [self speechEngineInitFailed];
    }
}

- (void)uninitEngine {
    [self.curEngine destroyEngine];
    self.curEngine = nil;
    self.engineInitButton.enabled = TRUE;
    self.engineUninitButton.enabled = FALSE;
    self.startEngineButton.enabled = FALSE;
    self.stopEngineButton.enabled = FALSE;
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
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.statusTextView setText:@"Ready"];
        [self.resultTextView setText:[NSString stringWithFormat:@"DeviceID: %@", self.deviceID]];
        self.engineUninitButton.enabled = TRUE;
        self.engineInitButton.enabled = FALSE;
        self.startEngineButton.enabled = TRUE;
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
        self.engineStarted = true;
        [self.statusTextView setText:@"Engine Started!"];
        self.startEngineButton.enabled = FALSE;
        self.stopEngineButton.enabled = TRUE;
        
        // Read whole file into nsdata.
        NSString* filePath = [NSString stringWithFormat:@"%@/%@", self.debugPath, @"asr_rec_file.pcm"];
        NSData *fileData = [NSData dataWithContentsOfFile:filePath];
        if (!fileData) {
            [self.resultTextView setText:@"ERROR: File asr_rec_file.pcm not found!"];
            [self stopEngine:NULL];
            return;
        }

        int maxLength = [self.settings getInt:SETTING_STREAM_PACKAGE_DURATION] * 16 * 2;
        int16_t* feedData = (int16_t*) malloc(maxLength * sizeof(int16_t));
        self.audioLength = MIN(maxLength, [fileData length]);
        memcpy(feedData, [fileData bytes], self.audioLength);
        self.feedTimestamp = [[NSDate date] timeIntervalSince1970] * 1000;
        [self.curEngine feedAudio:feedData length:self.audioLength / 2];
        [self.curEngine sendDirective:SEDirectiveFinishTalking];

        free(feedData);
        feedData = NULL;
    });
}

- (void)speechEngineStopped {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.engineStarted = FALSE;
        [self.statusTextView setText:@"Engine Stopped!"];
        self.startEngineButton.enabled = TRUE;
        self.stopEngineButton.enabled = FALSE;
    });
}

- (void)speechEngineResult:(NSData *)data isFinal:(BOOL)isFinal {
    dispatch_async(dispatch_get_main_queue(), ^{
        long delay = 0;
        if (isFinal) {
            long current = [[NSDate date] timeIntervalSince1970] * 1000;
            delay = current - self.feedTimestamp;
        }
        
        NSError *error;
        NSDictionary *jsonResult = [NSJSONSerialization JSONObjectWithData:data
                                                                   options:NSJSONReadingMutableContainers
                                                                     error:&error];
        NSMutableString *text = [[NSMutableString alloc] initWithString:@""];
        if (![jsonResult objectForKey:@"result"]) {
            return;
        }
        [text appendFormat:@"result: %@", [[[jsonResult objectForKey:@"result"] firstObject] objectForKey:@"text"]];
        if (isFinal) {
            [text appendFormat:@"\naudio_length: %ld", self.audioLength];
            [text appendFormat:@"\nresponse_delay: %ld", delay];
            [text appendFormat:@"\nrtf: %f", (float) delay / (self.audioLength / 16 / 2)];
        }
        if (text.length) {
            [self.resultTextView setText:[text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
            NSLog(@"asr test result: %@", text);
        }
    });
}

- (void)speechEngineError:(NSData *)data {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.resultTextView setText:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]];
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
    [nextPage setValue:VIEW_TEST_ASR_OFFLINE_RTF forKey:@"viewId"];
}

@end


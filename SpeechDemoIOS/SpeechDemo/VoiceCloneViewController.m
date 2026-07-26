//
//  VoiceCloneViewController.m
//  SpeechDemo
//
//  Created by bytedance on 2021/2/20.
//  Copyright © 2021 chengzihao.ds. All rights reserved.
//

#import "VoiceCloneViewController.h"

#import <AVFoundation/AVFoundation.h>

#import "AppDelegate.h"
#import "FileUtils.h"
#import "SettingsHelper.h"
#import "ViewController.h"

@interface VoiceCloneViewController () <SpeechEngineDelegate, UITextViewDelegate>

@property (weak, nonatomic) IBOutlet UITextView *referTextView;
@property (weak, nonatomic) IBOutlet UITextView *resultTextView;
@property (weak, nonatomic) IBOutlet UITextField *statusTextView;
@property (weak, nonatomic) IBOutlet UIButton *engineSwitchButton;
@property (weak, nonatomic) IBOutlet UIButton *getTaskButton;
@property (weak, nonatomic) IBOutlet UIButton *checkEnvButton;
@property (weak, nonatomic) IBOutlet UIButton *voiceRecordButton;
@property (weak, nonatomic) IBOutlet UIButton *finishTalkingButton;
@property (weak, nonatomic) IBOutlet UIButton *getTrainStatusButton;
@property (weak, nonatomic) IBOutlet UIButton *submitTaskButton;
@property (weak, nonatomic) IBOutlet UIButton *delTrainDataButton;
@property (weak, nonatomic) IBOutlet UIButton *nextRecordTaskButton;

@property (strong, nonatomic) SpeechEngine *curEngine;
@property (assign, nonatomic) BOOL engineInited;
@property (assign, nonatomic) BOOL engineStarted;

@property (nonatomic, strong) NSString *deviceID;
@property (nonatomic, assign) long talkingFinisheTimestamp;
@property (nonatomic, assign) long startEngineTimestamp;
@property (strong, nonatomic) NSString *debugPath;

@property (weak, nonatomic) StreamRecorder *streamRecorder;

// voiceclone json param
@property (strong, nonatomic) NSString *voiceCloneCurText;
@property (assign, nonatomic) NSInteger voiceCloneCurTextSeq;
@property (assign, nonatomic) NSInteger voiceCloneCurTaskId;
// voiceclone last get-task-info result
@property (strong, nonatomic) NSMutableDictionary *voiceCloneTaskInfo;
// ViewStatus
typedef enum ViewStatus : NSUInteger {
    BEFORE_INIT,
    INITING,
    BEFORE_GET_TASK,
    BEFORE_CHECK_ENV,
    BEFORE_RECORD,
    RECORDING,
    BEFORE_SUBMIT,
    AFTER_SUBMIT,
} ViewStatus;
// prev ViewStatus
@property (assign, nonatomic) ViewStatus preViewStatus;
// current ViewStatus
@property (assign, nonatomic) ViewStatus curViewStatus;

// settings
@property (strong, nonatomic) Settings *settings;

@end

@implementation VoiceCloneViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.settings = [[SettingsHelper shareInstance]getSettings:VIEW_VOICECLONE];

    self.voiceCloneTaskInfo = NULL;
    [self updateParamJsonObj];
    
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

- (void)updateParamJsonObj {
    if (self.voiceCloneTaskInfo != NULL) {
        [[self.voiceCloneTaskInfo objectForKey:@"progress"]intValue];
    } else {
        [self updateParamJsonObj:0];
    }
}

- (void)updateParamJsonObj:(int)text_seq {
    if (self.voiceCloneTaskInfo == NULL) {
        self.voiceCloneCurText = @"";
        self.voiceCloneCurTextSeq = 0;
        self.voiceCloneCurTaskId = [self.settings getInt:SETTING_VOICECLONE_TASKID];
    } else {
        NSArray *text_arr = [self.voiceCloneTaskInfo objectForKey:@"texts"];
        self.voiceCloneCurText = [text_arr objectAtIndex:text_seq];
        self.voiceCloneCurTextSeq = text_seq;
        self.voiceCloneCurTaskId =[[self.voiceCloneTaskInfo objectForKey:@"task_id"]intValue];
    }
    // update refer text
    [self.referTextView setText:[NSString stringWithFormat:@"Current task: %d\nCurrent task sequence: %d\nCurrent text: %@", (int)self.voiceCloneCurTaskId, (int)self.voiceCloneCurTextSeq, self.voiceCloneCurText]];
}

- (void)decorateTextView:(UITextView *)textView {
    textView.layer.cornerRadius = 5.0f;
    textView.layer.borderWidth = .25f;
    textView.layer.borderColor = [UIColor grayColor].CGColor;
}

- (void)switchViewStatus:(ViewStatus) status {
    self.preViewStatus = self.curViewStatus;
    self.curViewStatus = status;
    switch (status) {
        case BEFORE_INIT:
            [self.engineSwitchButton setTitle:@"InitEngine" forState:UIControlStateNormal];
            self.engineSwitchButton.enabled = TRUE;
            self.getTaskButton.enabled = FALSE;
            self.checkEnvButton.enabled = FALSE;
            self.voiceRecordButton.enabled = FALSE;
            self.finishTalkingButton.enabled = FALSE;
            self.getTrainStatusButton.enabled = FALSE;
            self.submitTaskButton.enabled = FALSE;
            self.delTrainDataButton.enabled = FALSE;
            self.nextRecordTaskButton.enabled = FALSE;
            break;
        case INITING:
            [self.engineSwitchButton setTitle:@"InitEngine" forState:UIControlStateNormal];
            self.engineSwitchButton.enabled = FALSE;
            self.getTaskButton.enabled = FALSE;
            self.checkEnvButton.enabled = FALSE;
            self.voiceRecordButton.enabled = FALSE;
            self.finishTalkingButton.enabled = FALSE;
            self.getTrainStatusButton.enabled = FALSE;
            self.submitTaskButton.enabled = FALSE;
            self.delTrainDataButton.enabled = FALSE;
            self.nextRecordTaskButton.enabled = FALSE;
            break;
        case RECORDING:
            [self.engineSwitchButton setTitle:@"UninitEngine" forState:UIControlStateNormal];
            self.engineSwitchButton.enabled = FALSE;
            self.getTaskButton.enabled = FALSE;
            self.checkEnvButton.enabled = FALSE;
            self.voiceRecordButton.enabled = FALSE;
            self.finishTalkingButton.enabled = TRUE;
            self.getTrainStatusButton.enabled = FALSE;
            self.submitTaskButton.enabled = FALSE;
            self.delTrainDataButton.enabled = FALSE;
            self.nextRecordTaskButton.enabled = FALSE;
            break;
        case BEFORE_GET_TASK:
        case BEFORE_CHECK_ENV:
        case BEFORE_RECORD:
        case BEFORE_SUBMIT:
        case AFTER_SUBMIT:
            [self.engineSwitchButton setTitle:@"UninitEngine" forState:UIControlStateNormal];
            self.engineSwitchButton.enabled = TRUE;
            self.getTaskButton.enabled = TRUE;
            self.checkEnvButton.enabled = TRUE;
            self.voiceRecordButton.enabled = TRUE;
            self.finishTalkingButton.enabled = FALSE;
            self.getTrainStatusButton.enabled = TRUE;
            self.submitTaskButton.enabled = TRUE;
            self.delTrainDataButton.enabled = TRUE;
            self.nextRecordTaskButton.enabled = TRUE;
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
            [self speechEngineStopped];
            break;
        case SEEngineError:
            [self speechEngineError:data];
            break;
        case SEVoiceCloneGetTaskResult:
            [self speechVoiceCloneGetTaskResult:data];
            break;
        case SEVoiceCloneCheckEnvResult:
            [self speechVoiceCloneCheckEnvResult:data];
            break;
        case SEVoiceCloneRecordVoiceResult:
            [self speechVoiceCloneRecordVoiceResult:data];
            break;
        case SEVoiceCloneQueryStatusResult:
            [self speechVoiceCloneQueryStatusResult:data];
            break;
        case SEVoiceCloneSubmitTaskResult:
            [self speechVoiceCloneSubmitTaskResult:data];
            break;
        case SEVoiceCloneDeleteDataResult:
            [self speechVoiceCloneDeleteDataResult:data];
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
    [self.referTextView setText:@""];
    self.voiceCloneTaskInfo = NULL;
    [self updateParamJsonObj];
    if (self.engineInited) {
        [self uninitEngine];
        self.engineInited = FALSE;
        [self.statusTextView setText:@"Waiting for init."];
        [self switchViewStatus:BEFORE_INIT];
    } else {
        [self switchViewStatus:INITING];
        [self initEngine];
    }
}

- (IBAction)stopEngine:(id)sender {
    [self.curEngine sendDirective:SEDirectiveStopEngine];
}

- (IBAction)getTask:(id)sender {
    [self.curEngine setStringParam:[self.settings getString:SETTING_VOICECLONE_UID] forKey:SE_PARAMS_KEY_UID_STRING];
    [self.curEngine setBoolParam:[self.settings getBool:SETTING_VOICECLONE_GENDER] forKey:SE_PARAMS_KEY_VOICECLONE_GENDER_BOOL];
    [self.curEngine sendDirective:SEDirectiveVoiceCloneGetTask];
}

- (IBAction)checkEnv:(id)sender {
    if (![self checkRecorder]) {
        return;
    }
    [self.curEngine setStringParam:[self.settings getString:SETTING_VOICECLONE_UID] forKey:SE_PARAMS_KEY_UID_STRING];
    [self.curEngine setIntParam:self.voiceCloneCurTaskId forKey:SE_PARAMS_KEY_VOICECLONE_TASKID_INT];
    SEEngineErrorCode ret = [self.curEngine sendDirective:SEDirectiveVoiceCloneCheckEnv];
    if (ret != SENoError) {
        [self.resultTextView setText:[NSString stringWithFormat:@"checkEnv failed: %d", ret]];
    } else {
        [self switchViewStatus:RECORDING];
    }
}

- (IBAction)voiceRecord:(id)sender {
    if (![self checkRecorder]) {
        return;
    }
    [self.curEngine setStringParam:[self.settings getString:SETTING_VOICECLONE_UID] forKey:SE_PARAMS_KEY_UID_STRING];
    [self.curEngine setIntParam:self.voiceCloneCurTaskId forKey:SE_PARAMS_KEY_VOICECLONE_TASKID_INT];
    [self.curEngine setStringParam:self.voiceCloneCurText forKey:SE_PARAMS_KEY_VOICECLONE_TEXT_STRING];
    [self.curEngine setIntParam:self.voiceCloneCurTextSeq forKey:SE_PARAMS_KEY_VOICECLONE_TEXT_SEQ_INT];
    SEEngineErrorCode ret = [self.curEngine sendDirective:SEDirectiveVoiceCloneRecordVoice];
    if (ret != SENoError) {
        [self.resultTextView setText:[NSString stringWithFormat:@"voiceRecord failed: %d", ret]];
    } else {
        [self switchViewStatus:RECORDING];
    }
}

- (IBAction)finishTalking:(id)sender {
    [self.curEngine sendDirective:SEDirectiveFinishTalking];
    if ([[self getRecorderType] isEqualToString:SE_RECORDER_TYPE_STREAM]) {
        [self.streamRecorder stop];
    }
}

- (IBAction)getTrainStatus:(id)sender {
    [self.curEngine setStringParam:[self.settings getString:SETTING_VOICECLONE_UID] forKey:SE_PARAMS_KEY_UID_STRING];
    [self.curEngine setStringParam:[self.settings getString:SETTING_VOICECLONE_QUERY_UIDS] forKey:SE_PARAMS_KEY_VOICECLONE_QUERY_UIDS_STRING];
    [self.curEngine sendDirective:SEDirectiveVoiceCloneQueryStatus];
}

- (IBAction)submitTask:(id)sender {
    [self.curEngine setStringParam:[self.settings getString:SETTING_VOICECLONE_UID] forKey:SE_PARAMS_KEY_UID_STRING];
    [self.curEngine setIntParam:self.voiceCloneCurTaskId forKey:SE_PARAMS_KEY_VOICECLONE_TASKID_INT];
    [self.curEngine setStringParam:[self.settings getString:SETTING_VOICECLONE_VOICE_TYPE] forKey:SE_PARAMS_KEY_VOICECLONE_VOICE_TYPE_STRING];
    [self.curEngine sendDirective:SEDirectiveVoiceCloneSubmitTask];
}

- (IBAction)delTrainData:(id)sender {
    [self.curEngine setStringParam:[self.settings getString:SETTING_VOICECLONE_UID] forKey:SE_PARAMS_KEY_UID_STRING];
    [self.curEngine setIntParam:self.voiceCloneCurTaskId forKey:SE_PARAMS_KEY_VOICECLONE_TASKID_INT];
    [self.curEngine sendDirective:SEDirectiveVoiceCloneDeleteData];
}

- (IBAction)goToNextTaskInfo:(id)sender {
    if (self.voiceCloneTaskInfo != NULL) {
        NSArray *text_arr = [self.voiceCloneTaskInfo objectForKey:@"texts"];
        if (text_arr.count != 0) {
            [self updateParamJsonObj:((int)self.voiceCloneCurTextSeq + 1) % text_arr.count];
            [self.resultTextView setText:@""];
            return;
        }
    }
    [self.resultTextView setText:@"You should get task info sucessfully first!"];
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

    NSLog(@"Engine version: %@", [self.curEngine getVersion]);
    self.debugPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSLog(@"Debug path: %@", self.debugPath);
    [self.curEngine setStringParam:self.debugPath forKey:SE_PARAMS_KEY_DEBUG_PATH_STRING];
    [self.curEngine setStringParam:[self.settings getString:SETTING_APPID] forKey:SE_PARAMS_KEY_APP_ID_STRING];
    [self.curEngine setStringParam:[self.settings getString:SETTING_TOKEN] forKey:SE_PARAMS_KEY_APP_TOKEN_STRING];
    [self.curEngine setStringParam:SE_LOG_LEVEL_TRACE forKey:SE_PARAMS_KEY_LOG_LEVEL_STRING];
    [self.curEngine setIntParam:1 forKey:SE_PARAMS_KEY_CHANNEL_NUM_INT];
    [self.curEngine setStringParam:[self.settings getString:SETTING_VOICECLONE_ADDRESS] forKey:SE_PARAMS_KEY_VOICECLONE_ADDRESS_STRING];
    [self.curEngine setStringParam:[self.settings getString:SETTING_VOICECLONE_STREAM_ADDRESS] forKey:SE_PARAMS_KEY_VOICECLONE_STREAM_ADDRESS_STRING];
    [self.curEngine setStringParam:[self getRecorderType] forKey:SE_PARAMS_KEY_RECORDER_TYPE_STRING];
    [self.curEngine setBoolParam:TRUE forKey:SE_PARAMS_KEY_VOICECLONE_ENABLE_DUMP_BOOL];
    [self.curEngine setStringParam:self.debugPath forKey:SE_PARAMS_KEY_VOICECLONE_REC_PATH_STRING];
    [self.curEngine setStringParam:SE_VOICECLONE_ENGINE forKey:SE_PARAMS_KEY_ENGINE_NAME_STRING];
    [self.curEngine setIntParam:[self.settings getInt:SETTING_SAMPLE_RATE] forKey:SE_PARAMS_KEY_SAMPLE_RATE_INT];
    if ([[self getRecorderType] isEqualToString:SE_RECORDER_TYPE_STREAM]) {
        if ([self.streamRecorder getSampleRate] != [self.settings getInt:SETTING_SAMPLE_RATE]) {
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

- (bool)checkRecorder {
    if ([[self getRecorderType] isEqualToString:SE_RECORDER_TYPE_STREAM]) {
        [self.curEngine setIntParam:[self.streamRecorder getSampleRate] forKey:SE_PARAMS_KEY_CUSTOM_SAMPLE_RATE_INT];
        if (![self.streamRecorder start]) {
            [self speechEngineNoPermission];
            return false;
        }
    } else if ([[self getRecorderType] isEqualToString:SE_RECORDER_TYPE_FILE]) {
        NSString* file_path = [NSString stringWithFormat:@"%@/%@", self.debugPath, @"voiceclone_rec_file.pcm"];
        NSLog(@"test file path: %@", file_path);
        [self.curEngine setStringParam:file_path forKey:SE_PARAMS_KEY_RECORDER_FILE_STRING];
    }
    return true;
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
        [self switchViewStatus:BEFORE_GET_TASK];
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

- (void)speechEngineStopped {
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([[self getRecorderType] isEqualToString:SE_RECORDER_TYPE_STREAM]) {
            [self.streamRecorder stop];
        }
        self.engineStarted = FALSE;
        [self.statusTextView setText:@"Engine Stopped!"];
        if (self.startEngineTimestamp > 0) {
            long response_delay = [self timeDelayFrom:self.startEngineTimestamp];
            self.startEngineTimestamp = 0;
            [self.resultTextView setText:[NSString stringWithFormat:@"%@\nVoiceClone cost: %ld\n", self.resultTextView.text, response_delay]];
        }
    });
}

- (void)
speechEngineError:(NSData *)data {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.resultTextView setText:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]];
        [self stopEngine:nil];
        if (self.curViewStatus == RECORDING) {
            [self switchViewStatus:self.preViewStatus];
        }
    });
}

- (void)
speechEngineResult:(NSString *)text {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.resultTextView setText:text];
    });
}

- (void)speechVoiceCloneGetTaskResult:(NSData *)data {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSError *error;
        NSArray *task_arr = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&error];
        if (task_arr.count <= 0) {
            [self.resultTextView setText:@"No task data!"];
            return;
        }
        [self.resultTextView setText:@""];
        self.voiceCloneCurTaskId = [self.settings getInt:SETTING_VOICECLONE_TASKID];
        for (int i = 0; i < task_arr.count; ++i) {
            NSDictionary *task_info = [task_arr objectAtIndex:i];
            int task_id = [[task_info objectForKey:@"task_id"] intValue];
            if ((int)self.voiceCloneCurTaskId == task_id) {
                self.voiceCloneTaskInfo = [NSMutableDictionary dictionaryWithDictionary:task_info];
                break;
            }
        }
        // no match task_id
        if (self.voiceCloneTaskInfo == NULL) {
            self.voiceCloneTaskInfo = [task_arr objectAtIndex:0];
            [self.resultTextView setText:[NSString stringWithFormat:@"Find task %d failed! Choose task: %d", (int)self.voiceCloneCurTaskId, [[self.voiceCloneTaskInfo objectForKey:@"task_id"] intValue]]];
        }
        // update task progress
        int prog = [[self.voiceCloneTaskInfo objectForKey:@"progress"] intValue];
        NSArray *texts_arr = [self.voiceCloneTaskInfo objectForKey:@"texts"];
        [self updateParamJsonObj:(prog % texts_arr.count)];
        if (prog < texts_arr.count && prog >= 0) {
            [self.resultTextView setText:[NSString stringWithFormat:@"%@\nGet task info success!\nRecord task unfinished.\nGo to check environment", self.resultTextView.text]];
            [self switchViewStatus:BEFORE_CHECK_ENV];
        } else {
            [self.resultTextView setText:[NSString stringWithFormat:@"%@\nGet task info success!\nRecord task finished!\nGo to submit task or query train status.", self.resultTextView.text]];
            [self switchViewStatus:AFTER_SUBMIT];
        }
    });
}

- (void)speechVoiceCloneCheckEnvResult:(NSData *)data {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSError *error;
        NSDictionary *env_info = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&error];
        int status = [[env_info objectForKey:@"status"] intValue];
        if (status > 0) {
            [self.resultTextView setText:[NSString stringWithFormat:@"Checking...\nCurrent status: %d\nCurrent noise: %lf", status, [[env_info objectForKey:@"noise"] doubleValue]]];
        } else if (status < 0) {
            [self.resultTextView setText:[NSString stringWithFormat:@"Check failed! status: %d", status]];
            [self switchViewStatus:BEFORE_CHECK_ENV];
        } else {
            [self.resultTextView setText:[NSString stringWithFormat:@"Check success! status: %d", status]];
            [self switchViewStatus:BEFORE_RECORD];
        }
        
    });
}

- (void)speechVoiceCloneRecordVoiceResult:(NSData *)data {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSError *error;
        NSDictionary *record_res = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&error];
        int status = [[record_res objectForKey:@"status"] intValue];
        if (status > 0) {
        } else if (status < 0) {
            [self.resultTextView setText:[NSString stringWithFormat:@"Check failed! status: %d, wrong_index: %@", status, [record_res objectForKey:@"wrong_index"]]];
            [self switchViewStatus:BEFORE_RECORD];
        } else {
            [self.resultTextView setText:[NSString stringWithFormat:@"Check success! status: %d", status]];
            NSArray* text_arr = [self.voiceCloneTaskInfo objectForKey:@"texts"];
            if (text_arr.count > 0 && self.voiceCloneCurTextSeq + 1 < text_arr.count) {
                [self.resultTextView setText:[NSString stringWithFormat:@"Text %d success! status: %d", (int)self.voiceCloneCurTextSeq, status]];
                [self switchViewStatus:BEFORE_RECORD];
            } else {
                [self.resultTextView setText:[NSString stringWithFormat:@"Voice record task: %d finished!\nGo to submit task!", (int)self.voiceCloneCurTaskId]];
                [self switchViewStatus:BEFORE_SUBMIT];
            }
        }
    });
}

- (void)speechVoiceCloneQueryStatusResult:(NSData *)data {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSError *error;
        NSArray *train_status_arr = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&error];
        [self.resultTextView setText:@""];
        for (int i = 0; i < train_status_arr.count; ++i) {
            NSDictionary *item = [train_status_arr objectAtIndex:i];
            NSString *uid = [item objectForKey:@"uid"];
            int status = [[item objectForKey:@"status"] intValue];
            int task_id = [[item objectForKey:@"task_id"] intValue];
            NSString *extra = [item objectForKey:@"extra"];
            [self.resultTextView setText:[NSString stringWithFormat:@"%@%@: status: %d; task_id: %d; extra: %@\n\n", self.resultTextView.text, uid, status, task_id, extra]];
        }
    });
}

- (void)speechVoiceCloneSubmitTaskResult:(NSData *)data {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSError *error;
        NSDictionary *result = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&error];
        NSString *voiceType = [result objectForKey:@"voice_type"];
        [self.resultTextView setText:[NSString stringWithFormat:@"Task submit success, voice type: %@", voiceType]];
        [self switchViewStatus:AFTER_SUBMIT];
    });
}

- (void)speechVoiceCloneDeleteDataResult:(NSData *)data {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.resultTextView setText:@"Task data del success"];
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
    [nextPage setValue:VIEW_VOICECLONE forKey:@"viewId"];
}

@end


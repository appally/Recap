//
//  AfpViewController.m
//  SpeechDemo
//
//  Created by fangweiwei on 2021/8/31.
//  Copyright © 2021 fangweiwei. All rights reserved.
//

#import "AfpViewController.h"

#import <AVFoundation/AVFoundation.h>

#import "AppDelegate.h"
#import "FileUtils.h"
#import "SettingsHelper.h"
#import "ViewController.h"

@interface AfpViewController () <SpeechEngineDelegate, UITextViewDelegate>

@property (weak, nonatomic) IBOutlet UITextView *resultTextView;
@property (weak, nonatomic) IBOutlet UITextField *statusTextView;
@property (weak, nonatomic) IBOutlet UIButton *engineInitButton;
@property (weak, nonatomic) IBOutlet UIButton *engineUninitButton;
@property (weak, nonatomic) IBOutlet UIButton *startEngineButton;
@property (weak, nonatomic) IBOutlet UIButton *stopEngineButton;
@property (weak, nonatomic) IBOutlet UIButton *fetchResultButton;

@property (strong, nonatomic) SpeechEngine *curEngine;
@property (assign, nonatomic) BOOL engineStarted;

@property (nonatomic, strong) NSString *deviceID;
@property (strong, nonatomic) NSString *debugPath;

// Settings
@property (strong, nonatomic) Settings *settings;
@end

@implementation AfpViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.engineInitButton.enabled = TRUE;
    self.engineUninitButton.enabled = FALSE;
    self.startEngineButton.enabled = FALSE;
    self.stopEngineButton.enabled = FALSE;
    self.fetchResultButton.enabled = FALSE;
    [self.statusTextView setText:@"Waiting for init."];
    [self decorateTextView:self.resultTextView];
    [ViewController setAppDelegate:(AppDelegate *)[[UIApplication sharedApplication] delegate]];
    self.curEngine = nil;
    self.engineStarted = FALSE;
    self.settings = [[SettingsHelper shareInstance]getSettings:VIEW_AFP];
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
    SEEngineErrorCode ret = [self.curEngine ResetEngine];
    NSString *result = [NSString stringWithFormat:@"Reset engine: %d.", ret];
    NSLog(@"%@", result);

    NSString *path = [self.debugPath stringByAppendingPathComponent:@"test_afp.pcm"];
    NSError *error;
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:&error];
    if (data) {
        // Read success.
        SEErrorCode ret = [self.curEngine ProcessAudio:(int16_t *)data.bytes length:(int32_t)(data.length / 2) isFinal:TRUE];
        if (ret != SENoError) {
            [self setResultText:[NSString stringWithFormat:@"Feed audio data failed: %d, lenght: %lu.", ret, (unsigned long)(data.length / 2)]];
        }
    }

    self.engineStarted = true;
    [self.statusTextView setText:@"Engine Started!"];
    [self setResultText:result];
    self.startEngineButton.enabled = FALSE;
    self.stopEngineButton.enabled = TRUE;
    self.fetchResultButton.enabled = TRUE;
}

- (IBAction)stopEngine:(id)sender {
    NSLog(@"Stop engine.");
    SEEngineErrorCode ret = [self.curEngine ResetEngine];
    NSString *result = [NSString stringWithFormat:@"Reset engine: %d.", ret];
    NSLog(@"%@", result);

    self.engineStarted = FALSE;
    [self.statusTextView setText:@"Engine Stopped!"];
    [self setResultText:result];
    self.startEngineButton.enabled = TRUE;
    self.stopEngineButton.enabled = FALSE;
    self.fetchResultButton.enabled = FALSE;
}

- (IBAction)fetchResult:(id)sender {
    SEResultType resultType = [self getResultType];
    int resultTypeIdx = [self.settings getOptions:SETTING_AFP_RESULT_TYPE].chooseIdx;

    if (resultTypeIdx == 0) {
        // Bytes result.
        NSData *result;
        SEEngineErrorCode ret = [self.curEngine FetchResult:resultType result:&result];
        if (ret != SENoError) {
            [self setResultText:[NSString stringWithFormat:@"Fetch result failed! Err code: %d.", ret]];
        } else {
            [self setResultText:@"Fetch result succeed!"];
        }
        NSLog(@"Fetch result: %d.", ret);
        
        NSString *fileName = [NSString stringWithFormat:@"test_%@_out.bytes", [self getEngineName]];
        NSFileHandle *file = [FileUtils openFileForWriting:fileName inPath:self.debugPath];
        [FileUtils writeData:result toFileHandel:file];
        [FileUtils closeFile:file];
    } else {
        // Json result.
        NSString* result = [self.curEngine FetchStringResult:resultType];
        // 提取err_code的值
        NSError *error;
        NSDictionary *jsonResult = [NSJSONSerialization JSONObjectWithData:[result dataUsingEncoding:NSUTF8StringEncoding] options:0 error:&error];
        int errCode = [jsonResult[@"err_code"] intValue];
        if (errCode != SENoError) {
            [self setResultText:[NSString stringWithFormat:@"Fetch result failed! Err code: %d.", errCode]];
        } else {
            [self setResultText:@"Fetch result succeed!"];
        }
        NSLog(@"Fetch result: %d.", errCode);

        NSString *fileName = [NSString stringWithFormat:@"test_%@_out.json", [self getEngineName]];
        NSFileHandle *file = [FileUtils openFileForWriting:fileName inPath:self.debugPath];
        [FileUtils writeString:result toFileHandel:file];
        [FileUtils closeFile:file];
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
    if (![self.curEngine createEngineWithDelegate:nil]) {
        NSLog(@"Create speech engine failed.");
        return;
    }
    [self.resultTextView setTextColor:UIColor.blackColor];
    NSLog(@"Engine version: %@", [self.curEngine getVersion]);
    self.debugPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSLog(@"Debug path: %@", self.debugPath);
    [self.curEngine setStringParam:self.debugPath forKey:SE_PARAMS_KEY_DEBUG_PATH_STRING];
    [self.curEngine setStringParam:SE_LOG_LEVEL_TRACE forKey:SE_PARAMS_KEY_LOG_LEVEL_STRING];
    [self.curEngine setStringParam:[self getEngineName] forKey:SE_PARAMS_KEY_ENGINE_NAME_STRING];

    SEEngineErrorCode ret = [self.curEngine initEngine];
    if (ret != SENoError) {
        NSLog(@"Init Engine failed: %d", ret);
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
    self.fetchResultButton.enabled = FALSE;
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
        self.fetchResultButton.enabled = TRUE;
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

- (void)setResultText:(NSString *)result {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.resultTextView setText:[result stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
    });
}

#pragma mark - Helper

- (long)timeDelayFrom:(long)pastTimestamp {
    return [[NSDate date] timeIntervalSince1970] * 1000 - pastTimestamp;
}

- (NSString* )getEngineName {
    SettingOptions* engineNameOptions = [self.settings getOptions:SETTING_MUSIC_ENGINE_NAME];
    switch (engineNameOptions.chooseIdx) {
        case 1:
            return SE_COVERSONG_ENGINE;
        case 2:
            return SE_HUMMING_ENGINE;
        case 0:
        default:
            return SE_AFP_ENGINE;
    }
}

- (SEResultType)getResultType {
    NSString* engineName = [self getEngineName];
    int resultTypeIdx = [self.settings getOptions:SETTING_AFP_RESULT_TYPE].chooseIdx;

    // AFP
    if ([engineName isEqualToString:SE_AFP_ENGINE]) {
        switch (resultTypeIdx) {
            case 0:
                return SEAfpResult;
            case 1:
            default:
                return SEAfpSliceResult;
        }
    }
    // CoverSong
    if ([engineName isEqualToString:SE_COVERSONG_ENGINE]) {
        switch (resultTypeIdx) {
            case 0:
                return SECoversongResult;
            case 1:
            default:
                return SECoverSongSliceResult;
        }
    }
    // Humming
    if ([engineName isEqualToString:SE_HUMMING_ENGINE]) {
        switch (resultTypeIdx) {
            case 0:
                return SEHummingResult;
            case 1:
            default:
                return SEHummingSliceResult;
        }
    }

    // Return afp result as default.
    return SEAfpResult;
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
    [nextPage setValue:VIEW_AFP forKey:@"viewId"];
}

@end



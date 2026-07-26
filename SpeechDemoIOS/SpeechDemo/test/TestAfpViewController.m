//
//  TestAfpViewController.m
//  SpeechDemo
//
//  Created by chengzihao.ds on 2024/7/10.
//  Copyright © 2024 chengzihao.ds. All rights reserved.
//

#import "TestAfpViewController.h"

#import <AVFoundation/AVFoundation.h>

#import "AppDelegate.h"
#import "FileUtils.h"
#import "SettingsHelper.h"
#import "ViewController.h"

@interface AfpPressureTask : NSObject

@property (nonatomic, strong) NSThread *thread;
@property (nonatomic, strong) SpeechEngine *engine;
@property (nonatomic, weak) NSString *debugPath;
@property (nonatomic, assign) int resultType;
@property (nonatomic, assign) int taskId;
@property (nonatomic, assign) BOOL running;

- (instancetype)initWithTaskId:(int)taskId;
- (void)startTask;
- (void)stopTask;
- (void)taskLoop;
- (int)fetchResult;

@end

@implementation AfpPressureTask

- (instancetype)initWithTaskId:(int)taskId {
    self = [super init];
    if (self) {
        _taskId = taskId;
        _running = YES;
        _engine = NULL;
        _debugPath = NULL;
        _thread = [[NSThread alloc] initWithTarget:self selector:@selector(taskLoop) object:nil];
    }
    return self;
}

- (void)startTask {
    [self.thread start];
}

- (void)stopTask {
    self.running = NO;
}

- (void)taskLoop {
    @autoreleasepool {
        NSString *path = [self.debugPath stringByAppendingPathComponent:@"test_afp.pcm"];
        while (self.running) {
            @autoreleasepool {
                // Init
                self.engine = [[SpeechEngine alloc] init];
                [self.engine createEngineWithDelegate:nil];
                [self.engine setStringParam:SE_AFP_ENGINE forKey:SE_PARAMS_KEY_ENGINE_NAME_STRING];
                SEEngineErrorCode ret = [self.engine initEngine];
                if (ret != SENoError) {
                    NSLog(@"Init Engine failed: %d", ret);
                }

                // Process
                NSError *error;
                NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:&error];
                if (data) {
                    // Read success.
                    ret = [self.engine ProcessAudio:(int16_t *)data.bytes length:(int32_t)(data.length / 2) isFinal:TRUE];
                    if (ret != SENoError) {
                        NSLog(@"Process Audio failed: %d", ret);
                    }
                }

                // FetchResult
                ret = [self fetchResult];
                if (ret != SENoError) {
                    NSLog(@"Fetch Result failed: %d", ret);
                }

                // Reset
                ret = [self.engine ResetEngine];
                if (ret != SENoError) {
                    NSLog(@"Reset Engine failed: %d", ret);
                }

                // Destroy
                [self.engine destroyEngine];
                self.engine = nil;
            }
        }
        NSLog(@"Task %d has stopped", self.taskId);
    }
}

- (int) fetchResult {
    @autoreleasepool {
        NSString *filename;
        if (self.resultType == SEAfpResult) {
            filename = [NSString stringWithFormat:@"test_afp_out_%d.bytes", self.taskId];
        } else {
            filename = [NSString stringWithFormat:@"test_afp_out_%d.json", self.taskId];
        }

        if (self.resultType == SEAfpResult) {
            NSData *result;
            SEEngineErrorCode ret = [self.engine FetchResult:&result];
            if (ret != SENoError) {
                NSLog(@"Fetch Result failed: %d", ret);
                return ret;
            }

            NSFileHandle *file = [FileUtils openFileForWriting:filename inPath:self.debugPath];
            [FileUtils writeData:result toFileHandel:file];
            [FileUtils closeFile:file];
        } else if (self.resultType == SEAfpSliceResult) {
            NSString* result = [self.engine FetchStringResult:SEAfpSliceResult];
            // 提取err_code的值
            NSError *error;
            NSDictionary *jsonResult = [NSJSONSerialization JSONObjectWithData:[result dataUsingEncoding:NSUTF8StringEncoding] options:0 error:&error];
            int errCode = [jsonResult[@"err_code"] intValue];
            if (errCode != SENoError) {
                NSLog(@"Fetch Result failed: %d", errCode);
                return errCode;
            }

            NSFileHandle *file = [FileUtils openFileForWriting:filename inPath:self.debugPath];
            [FileUtils writeString:result toFileHandel:file];
            [FileUtils closeFile:file];
        }
    }
    return 0;
}

@end

@interface TestAfpViewController () <SpeechEngineDelegate, UITextViewDelegate>

@property (weak, nonatomic) IBOutlet UITextView *resultTextView;
@property (weak, nonatomic) IBOutlet UITextField *statusTextView;

@property (strong, nonatomic) NSMutableArray<AfpPressureTask *> *tasks;

@property (nonatomic, strong) NSString *deviceID;
@property (strong, nonatomic) NSString *debugPath;

// Settings
@property (strong, nonatomic) Settings *settings;
@end

@implementation TestAfpViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    [self.statusTextView setText:@"Waiting for init."];
    [self decorateTextView:self.resultTextView];
    [ViewController setAppDelegate:(AppDelegate *)[[UIApplication sharedApplication] delegate]];
    self.debugPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;

    self.settings = [[SettingsHelper shareInstance]getSettings:VIEW_TEST_AFP];
}

- (void)viewDidDisappear:(BOOL)animated {
    [self stopPressureTest];
    [super viewDidDisappear:animated];
}

- (void)decorateTextView:(UITextView *)textView {
    textView.layer.cornerRadius = 5.0f;
    textView.layer.borderWidth = .25f;
    textView.layer.borderColor = [UIColor grayColor].CGColor;
}


#pragma mark - UI Actions

- (IBAction)startStopPressureTest:(id)sender {
    if (self.tasks == NULL) {
        [self startPressureTest];
        [self.resultTextView setText: [NSString stringWithFormat:@"压测开始: %d个实例", [self.settings getInt: SETTING_AFP_INSTANCE_NUMBER]]];
    } else {
        [self stopPressureTest];
        [self.resultTextView setText: @"压测结束"];
    }
}

#pragma mark - Init Methods

- (void)startPressureTest {
    if (self.tasks != NULL) {
        return;
    }
    
    self.tasks = [NSMutableArray array];
    for (int i = 0; i < [self.settings getInt: SETTING_AFP_INSTANCE_NUMBER]; i++) {
        AfpPressureTask *task = [[AfpPressureTask alloc] initWithTaskId:i];
        task.resultType = [self getResultType];
        task.debugPath = self.debugPath;
        [self.tasks addObject:task];
        [task startTask];
    }
}

- (void)stopPressureTest {
    if (self.tasks == NULL) {
        return;
    }

    // 停止所有任务
    for (AfpPressureTask *task in self.tasks) {
        [task stopTask];
    }
    
    // 保证全部任务执行完毕
    for (AfpPressureTask *task in self.tasks) {
        while (![task.thread isFinished]) {
            [NSThread sleepForTimeInterval:0.1];
        }
    }

    self.tasks = NULL;
}

#pragma mark - Helper
- (SEResultType)getResultType {
    SettingOptions* resultTypeOptions = [self.settings getOptions:SETTING_AFP_RESULT_TYPE];
    switch (resultTypeOptions.chooseIdx) {
        case 0:
            return SEAfpResult;
        case 1:
        default:
            return SEAfpSliceResult;
    }
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
    [nextPage setValue:VIEW_TEST_AFP forKey:@"viewId"];
}

@end



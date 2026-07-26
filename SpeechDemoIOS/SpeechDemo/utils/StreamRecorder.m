//
//  StreamRecorder.m
//  SpeechDemo
//
//  Created by fangweiwei on 2020/9/16.
//  Copyright © 2020 fangweiwei. All rights reserved.
//

#import "StreamRecorder.h"
#import "SettingsHelper.h"
#import <AVFoundation/AVFoundation.h>

#define INPUT_BUS 1
#define OUTPUT_BUS 0
#define REC_SAMPLE_RATE 44100
#define REC_CHANNEL 1
#define DEFAULT_PACKAGE_DURATION 100

@interface StreamRecorder ()

@property (assign, nonatomic) BOOL initted;
@property (weak, nonatomic) SpeechEngine *curEngine;
@property (weak, nonatomic) NSString *curViewId;
@property (assign, atomic) int16_t* packageData;
@property (assign, nonatomic) int packageSize; // Size in int16_t
@property (assign, nonatomic) int packageTotalSize; // Size in int16_t
@property (assign, nonatomic) int packageDuration; // Unit: milliseconds
@property (strong, nonatomic) dispatch_semaphore_t waitAudioPermission;

@end

AudioUnit audioUnit;

@implementation StreamRecorder

- (instancetype)init
{
    self = [super init];
    if (self) {
        _initted = FALSE;
        _waitAudioPermission = dispatch_semaphore_create(0);
    }
    return self;
}

- (int)getSampleRate {
    return REC_SAMPLE_RATE;
}

- (int)getChannel {
    return REC_CHANNEL;
}

- (void)setSpeechEngine:(SpeechEngine *)engine {
    [self setSpeechEngine: @"" engine: engine];
}

- (void)setSpeechEngine:(NSString *) viewId engine:(SpeechEngine *)engine {
    self.curViewId = viewId;
    self.curEngine = engine;
}

- (BOOL)start {
    if (![self initRemoteIO]) {
        return FALSE;
    }
    @synchronized (self) {
        Settings *settings = [[SettingsHelper shareInstance]getSettings:self.curViewId];
        self.packageDuration = [settings getInt:SETTING_STREAM_PACKAGE_DURATION def:DEFAULT_PACKAGE_DURATION];
        self.packageTotalSize = (int)((long) REC_SAMPLE_RATE * REC_CHANNEL * 16 / 8 * self.packageDuration / 1000 / sizeof(int16_t));
        self.packageData = (int16_t*) malloc(self.packageTotalSize * sizeof(int16_t));
        self.packageSize = 0;
    }
    AudioOutputUnitStart(audioUnit);
    return TRUE;
}

- (void)stop {
    AudioOutputUnitStop(audioUnit);

    @synchronized (self) {
        if (self.packageData != NULL) {
            free(self.packageData);
            self.packageData = NULL;
        }
        self.packageSize = 0;
    }
}

- (BOOL)initRemoteIO {
    if (self.initted) {
        return TRUE;
    }

    if (!([self checkRecEnvironment] &&
          [self initAudioComponent] &&
          [self initFormat] &&
          [self initAudioProperty] &&
          [self initRecordCallback])) {
        NSLog(@"Fail to initialize remoteIO!");
        AudioComponentInstanceDispose(audioUnit);
        return FALSE;
    }
    AudioUnitInitialize(audioUnit);
    self.initted = TRUE;
    return TRUE;
}

#pragma mark - callback function

static OSStatus RecordCallback(void *inRefCon,
                               AudioUnitRenderActionFlags *ioActionFlags,
                               const AudioTimeStamp *inTimeStamp,
                               UInt32 inBusNumber,
                               UInt32 inNumberFrames,
                               AudioBufferList *ioData) {
    AudioBufferList bufferList;
    bufferList.mNumberBuffers = 1;
    bufferList.mBuffers[0].mData = NULL;
    bufferList.mBuffers[0].mDataByteSize = 0;
    OSStatus status = AudioUnitRender(audioUnit, ioActionFlags, inTimeStamp, 1, inNumberFrames, &bufferList);
    if (status != noErr) {
        NSLog(@"RecordCallback AudioUnitRender error: %d", (int)status);
    } else {
        StreamRecorder *recorder = (__bridge StreamRecorder *)(inRefCon);
        @synchronized (recorder) {
            if (recorder.packageData == NULL) {
                return noErr;
            }
            
            int16_t *data = (int16_t *)bufferList.mBuffers[0].mData;
            int32_t data_size = bufferList.mBuffers[0].mDataByteSize / 2;
            while (data_size + recorder.packageSize >= recorder.packageTotalSize) {
                // Package buffer is full, feed audio.
                int cut_size = recorder.packageTotalSize - recorder.packageSize;
                memcpy(recorder.packageData + recorder.packageSize, data, cut_size * sizeof(int16_t));
                
                NSLog(@"Current package size: %d, total package size: %d", recorder.packageSize, recorder.packageTotalSize);
                
                if ([recorder.curEngine feedAudio:recorder.packageData length:recorder.packageTotalSize]) {
                    NSLog(@"Fail to feed data to engine!");
                    return -1;
                }
                recorder.packageSize = 0;
                
                
                data = data + cut_size;
                data_size = data_size - cut_size;
            }
            memcpy(recorder.packageData + recorder.packageSize, data, data_size * sizeof(int16_t));
            recorder.packageSize += data_size;
            NSLog(@"Current package size: %d, total package size: %d", recorder.packageSize, recorder.packageTotalSize);
        }
    }

    return noErr;
}

#pragma mark - helper

- (BOOL)checkRecEnvironment {
    NSLog(@"check rec environment");
    BOOL ret = NO;
    __block BOOL hasPermission = YES;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    if ([session respondsToSelector:@selector(requestRecordPermission:)]) {
        [session requestRecordPermission:^(BOOL granted) {
            hasPermission = granted;
            dispatch_semaphore_signal(self.waitAudioPermission);
        }];
        dispatch_semaphore_wait(self.waitAudioPermission, DISPATCH_TIME_FOREVER);
    }
    if (!hasPermission) {
        NSLog(@"No permission for recorder.");
        return ret;
    }
    
    if (!session.isInputAvailable) {
        NSLog(@"Input device is not available");
        return ret;
    }

    [session setCategory:AVAudioSessionCategoryPlayAndRecord
             withOptions:AVAudioSessionCategoryOptionDefaultToSpeaker | AVAudioSessionCategoryOptionAllowBluetooth
                   error:nil];

    ret = YES;
    NSLog(@"rec environment is OK");

    return ret;
}

- (BOOL)initAudioComponent {
    AudioComponentDescription audioDesc;
    audioDesc.componentType = kAudioUnitType_Output;
    audioDesc.componentSubType = kAudioUnitSubType_RemoteIO;
    audioDesc.componentManufacturer = kAudioUnitManufacturer_Apple;
    audioDesc.componentFlags = 0;
    audioDesc.componentFlagsMask = 0;

    AudioComponent inputComponent = AudioComponentFindNext(NULL, &audioDesc);
    AudioComponentInstanceNew(inputComponent, &audioUnit);
    return TRUE;
}

- (BOOL)initFormat {
    AudioStreamBasicDescription audioFormat;
    audioFormat.mSampleRate = REC_SAMPLE_RATE;
    audioFormat.mFormatID = kAudioFormatLinearPCM;
    audioFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    audioFormat.mFramesPerPacket = 1;
    audioFormat.mChannelsPerFrame = 1;
    audioFormat.mBitsPerChannel = 16;
    audioFormat.mBytesPerPacket = 2;
    audioFormat.mBytesPerFrame = 2;

    OSStatus status = noErr;
    status = AudioUnitSetProperty(audioUnit,
                                  kAudioUnitProperty_StreamFormat,
                                  kAudioUnitScope_Output,
                                  INPUT_BUS,
                                  &audioFormat,
                                  sizeof(audioFormat));
    if (status != noErr) {
        NSLog(@"initFormat SetOutput Error with status: %d", (int)status);
        return FALSE;
    }
    return TRUE;
}

- (BOOL)initRecordCallback {
    AURenderCallbackStruct recordCallback;
    recordCallback.inputProc = RecordCallback;
    recordCallback.inputProcRefCon = (__bridge void *)self;
    OSStatus status = noErr;
    status = AudioUnitSetProperty(audioUnit,
                                  kAudioOutputUnitProperty_SetInputCallback,
                                  kAudioUnitScope_Global,
                                  INPUT_BUS,
                                  &recordCallback,
                                  sizeof(recordCallback));
    if (status != noErr) {
        NSLog(@"initRecordCallback SetRenderCallBack error with status: %d", (int)status);
        return FALSE;
    }
    return TRUE;
}

- (BOOL)initAudioProperty {
    UInt32 flag = 1;
    OSStatus status = noErr;
    status = AudioUnitSetProperty(audioUnit,
                                  kAudioOutputUnitProperty_EnableIO,
                                  kAudioUnitScope_Input,
                                  INPUT_BUS,
                                  &flag,
                                  sizeof(flag));
    if (status != noErr) {
        NSLog(@"initAudioProperty SetInputIO error with status: %d", (int)status);
        return FALSE;
    }
    return TRUE;
}

@end

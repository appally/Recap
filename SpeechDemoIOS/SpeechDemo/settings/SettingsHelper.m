//
//  SettingsHelper.m
//  SpeechDemo
//
//  Created by bytedance on 2020/9/9.
//  Copyright © 2020 fengkai.0518. All rights reserved.
//

#import <Foundation/Foundation.h>

#import "SettingsHelper.h"
#import "ViewController.h"
#import "SensitiveDefines.h"


@interface SettingsHelper()
@property (strong, nonatomic) Settings* asrSettings;
@property (strong, nonatomic) Settings* asrOfflineSettings;
@property (strong, nonatomic) Settings* bigAsrSettings;
@property (strong, nonatomic) Settings* captSettings;
@property (strong, nonatomic) Settings* fulllinkSettings;
@property (strong, nonatomic) Settings* ttsSettings;
@property (strong, nonatomic) Settings* voiceCloneSettings;
@property (strong, nonatomic) Settings* voiceConvSettings;
@property (strong, nonatomic) Settings* dialogSettings;
@property (strong, nonatomic) Settings* dialogDuplexSettings;
@property (strong, nonatomic) Settings* bittsSettings;
@property (strong, nonatomic) Settings* uniTtsSettings;
@property (strong, nonatomic) Settings* dialogDelegateSettings;
@property (strong, nonatomic) Settings* vadSettings;
@property (strong, nonatomic) Settings* auSettings;
@property (strong, nonatomic) Settings* afpSettings;
@property (strong, nonatomic) Settings* kwsSettings;
@property (strong, nonatomic) Settings* testAfpSettings;
@property (strong, nonatomic) Settings* testAsrOfflineRtfSettings;
@property (strong, nonatomic) Settings* testAsrStressSettings;
@end

@implementation SettingsHelper

#pragma mark - SETTING_KEY

// view id
NSString *const VIEW_ASR = @"ASR";
NSString *const VIEW_ASR_OFFLINE = @"ASR_OFFLINE";
NSString *const VIEW_AU = @"AU";
NSString *const VIEW_BIGASR = @"BIGASR";
NSString *const VIEW_AFP = @"AFP";
NSString *const VIEW_CAPT = @"CAPT";
NSString *const VIEW_FULLLINK = @"FULLLINK";
NSString *const VIEW_TTS = @"TTS";
NSString *const VIEW_BITTS = @"BITTS";
NSString *const VIEW_UNITTS = @"UNITTS";
NSString *const VIEW_VOICECLONE = @"VOICECLONE";
NSString *const VIEW_VOICECONV = @"VOICECONV";
NSString *const VIEW_DIALOG = @"DIALOG";
NSString *const VIEW_DIALOG_DELEGATE = @"DIALOG_DELEGATE";
NSString *const VIEW_DIALOG_DUPLEX = @"DIALOG_DUPLEX";
NSString *const VIEW_VAD = @"VAD";
NSString *const VIEW_KWS = @"KWS";
NSString *const VIEW_TEST_AFP = @"AFP_TEST";
NSString *const VIEW_TEST_ASR_OFFLINE_RTF = @"TEST_ASR_OFFLINE_RTF";
NSString *const VIEW_TEST_ASR_STRESS = @"TEST_ASR_STRESS";

// common
NSString *const SETTING_COMMON = @"Common";
NSString *const SETTING_API_KEY = @"ApiKey";
NSString *const SETTING_APPID = @"AppID";
NSString *const SETTING_APPKEY = @"AppKey";
NSString *const SETTING_TOKEN = @"Token";
NSString *const SETTING_CLUSTER = @"Cluster";
NSString *const SETTING_RESOURCE_ID = @"ResourceId";
NSString *const SETTING_ADDRESS = @"Address";
NSString *const SETTING_URI = @"Uri";
NSString *const SETTING_VOICE = @"Voice";
NSString *const SETTING_VOICE_TYPE = @"Voice Type";
NSString *const SETTING_ONLINE_VOICE = @"Online Voice";
NSString *const SETTING_ONLINE_VOICE_TYPE = @"Online Voice Type";
NSString *const SETTING_OFFLINE_VOICE = @"Offline Voice";
NSString *const SETTING_OFFLINE_VOICE_TYPE = @"Offline Voice Type";
NSString *const SETTING_GET_VOLUME = @"Get Volume";
NSString *const SETTING_RECORD_TYPE = @"Record Type";
NSString *const SETTING_RECORD_SAVE = @"Record Save";
NSString *const SETTING_RECORD_FILE_TYPE = @"Record File Type";
NSString *const SETTING_SAMPLE_RATE = @"Sample Rate";
NSString *const SETTING_CHANNEL = @"Channel";
NSString *const SETTING_ENABLE_AEC = @"Enable Aec";
NSString *const SETTING_RESTART_AUDIO_SESSION_ENABLE = @"Restart AudioSession";
NSString *const SETTING_RESUME_OTHERS_INTERRUPTED_PLAYBACK_ENABLE = @"Resume Others Interrupted Playback";
NSString *const SETTING_AUTHENTICATION_TYPE = @"Authentication Type";
NSString *const SETTING_BUSINESS_KEY = @"Business Key";
NSString *const SETTING_AUTHENTICATE_SECRET = @"Authenticate Secret";
NSString *const SETTING_DISABLE_WS_RECONNECT = @"Disable Ws Reconnect";
NSString *const SETTING_AUDIO_FADEOUT_DURATION = @"Audio Fade Out Duration";
NSString *const SETTING_VAD_MAX_SPEECH_DURATION = @"Vad Max Speech Duration";
NSString *const SETTING_VAD_MAX_MUSIC_DURATION = @"Vad Max Music Duration";
NSString *const SETTING_STREAM_PACKAGE_DURATION = @"Stream Package Duration";
NSString *const SETTING_REQUEST_HEADERS = @"Request headers";
NSString *const SETTING_ENABLE_PLAYER_AUDIO_CALL_BACK = @"Enable player audio callback";
// asr
NSString *const SETTING_ASR = @"Asr";
NSString *const SETTING_ASR_RECORDER_SAVE = @"Asr Recorder Save";
NSString *const SETTING_ASR_ENABLE_DDC = @"Asr Enable Ddc";
NSString *const SETTING_ASR_ENABLE_ITN = @"Asr Enable Itn";
NSString *const SETTING_ASR_ENABLE_NLU_PUNC = @"Asr Enable nlu punctuation";
NSString *const SETTING_ASR_DISABLE_END_PUNC = @"asr_disable_end_punc";
NSString *const SETTING_ASR_KEEP_RECORDING = @"Asr Enable Keep Recording";
NSString *const SETTING_ASR_HOTWORDS = @"Asr HotWords";
NSString *const SETTING_ASR_CORRECTWORDS = @"Asr CorrectWords";
NSString *const SETTING_ASR_VAD_START_SILENCE_TIME = @"Asr Vad Start Silence Time";
NSString *const SETTING_ASR_VAD_END_SILENCE_TIME = @"Asr Vad End Silence Time";
NSString *const SETTING_ASR_VAD_MODE = @"Asr VAD Mode";
NSString *const SETTING_ASR_RESULT_TYPE = @"Asr Result Type";
NSString *const SETTING_ASR_MAX_RETRY_TIMES = @"Asr Max Retry Times";
NSString *const SETTING_ASR_SHOW_LANGUAGE = @"Asr Show Language";
NSString *const SETTING_ASR_LANGUAGE = @"Asr Language";
NSString *const SETTING_ASR_AUTO_STOP = @"Asr Auto Stop";
NSString *const SETTING_ASR_MODEL_NAME = @"Asr Model Name";
NSString *const SETTING_ASR_REQ_PARAMS = @"Asr Request Params";
NSString *const SETTING_ASR_ENABLE_RESOURCE_DOWNLOAD = @"Enable Asr Resource Download";

// capt
NSString *const SETTING_CAPT = @"Capt";
NSString *const SETTING_CAPT_RECORDER_SAVE = @"Capt Recorder Save";
NSString *const SETTING_CAPT_STREAMING_MODE = @"Capt Streaming Mode";
NSString *const SETTING_CAPT_CORE_TYPE = @"Capt Core Type";
NSString *const SETTING_CAPT_DIFFICULTY_LEVEL = @"Capt Difficulty Level";

// fulllink
NSString *const SETTING_FULLLINK = @"Fulllink";
NSString *const SETTING_FULLLINK_ENGINE_TYPE = @"Fulllink Engine Type";
NSString *const SETTING_FULLLINK_WAKEUP_WORDS = @"Fulllink Wakeup Words";
NSString *const SETTING_FULLLINK_ENABLE_RECORDER_DUMP = @"Fulllink Enable Recorder Dump";
NSString *const SETTING_FULLLINK_ENABLE_KWS_DUMP = @"Fulllink Enable Kws Dump";
NSString *const SETTING_FULLLINK_WAKEUP_MODE = @"Fulllink Wakeup Mode";
NSString *const SETTING_FULLLINK_ONLY_ASR = @"Fulllink Only Asr";
NSString *const SETTING_FULLLINK_DISABLE_TTS = @"Fulllink Disable Tts";
NSString *const SETTING_FULLLINK_DISABLE_SIGNAL = @"Fulllink Disable Signal";
NSString *const SETTING_FULLLINK_DISABLE_DEVICE_TYPE = @"Fulllink Device Type";
NSString *const SETTING_FULLLINK_DISABLE_SIGTHREAD_PRI = @"Fulllink Disable SigThread Pri";
NSString *const SETTING_FULLLINK_DISABLE_FILE_OR_DIRECTORY_NAME = @"Fulllink Disable File Or Directory Name";

// tts
NSString *const SETTING_TTS = @"Tts";
NSString *const SETTING_TTS_ONLINE_LANGUAGE = @"Tts online Language";
NSString *const SETTING_TTS_EMOTION = @"Tts emotion";
NSString *const SETTING_TTS_OFFLINE_LANGUAGE = @"Tts offline Language";
NSString *const SETTING_PREVENT_PLAYER_CREATION = @"Prevent Player Creation";
NSString *const SETTING_TTS_ENABLE_RESUME_FROM_BREAKPOINT = @"Tts Enable Resume From Breakpoint";
NSString *const SETTING_TTS_ENABLE_PLAYER = @"Tts Enable Player";
NSString *const SETTING_TTS_ENABLE_DUMP = @"Tts Enable Dump";
NSString *const SETTING_TTS_ENABLE_DATA_CALLBACK = @"Tts Enable Data Callback";
NSString *const SETTING_TTS_ENABLE_WORD_LEVEL_PROGRESS_UPDATE = @"Tts Enable Word level Progress Update";
NSString *const SETTING_TTS_ENABLE_CACHE = @"Tts Enable Cache";
NSString *const SETTING_TTS_WITH_INTENT = @"Tts With Intent Predication";
NSString *const SETTING_TTS_LIMIT_CPU_USAGE = @"Tts Limit Cpu Usage";
NSString *const SETTING_TTS_TEXT_TYPE = @"Tts Text Type";
NSString *const SETTING_TTS_WORK_MODE = @"Tts Synthesis Mode";
NSString *const SETTING_TTS_SPEAK_SPEED = @"Tts Speak Speed";
NSString *const SETTING_TTS_AUDIO_VOLUME = @"Tts Audio Volume";
NSString *const SETTING_TTS_AUDIO_PITCH = @"Tts Audio Pitch";
NSString *const SETTING_TTS_SAMPLE_RATE = @"Tts Sample Rate";
NSString *const SETTING_TTS_MODEL_NAME = @"Tts Model Name";
NSString *const SETTING_LICENSE_NAME = @"License Name";
NSString *const SETTING_LICENSE_BUSI_ID = @"Busi Id";
NSString *const SETTING_TTS_BACKEND_CLUSTER = @"Backend Cluster";
NSString *const SETTING_TTS_REQUEST_ID = @"Tts Request ID";
NSString *const SETTING_TTS_REQUEST_PARAMS = @"Tts Request Parameters";
NSString *const SETTING_TTS_USE_VOICECLONE_VOICE = @"Tts Use VoiceClone Voice";
NSString *const SETTING_TTS_SILENCE_DURATION = @"Tts Silence Duration";
NSString *const SETTING_TTS_OFFLINE_RESOURCE_FORMAT = @"TTS Offline Model Format";

// voiceclone
NSString *const SETTING_VOICECLONE = @"VoiceClone";
NSString *const SETTING_VOICECLONE_ADDRESS = @"VoiceClone Address";
NSString *const SETTING_VOICECLONE_STREAM_ADDRESS = @"VoiceClone Stream Address";
NSString *const SETTING_VOICECLONE_UID = @"VoiceClone Uid";
NSString *const SETTING_VOICECLONE_QUERY_UIDS = @"VoiceClone Query Uids";
NSString *const SETTING_VOICECLONE_VOICE_TYPE = @"VoiceClone Voice Type";
NSString *const SETTING_VOICECLONE_GENDER = @"VoiceClone Gender (Is Female)";
NSString *const SETTING_VOICECLONE_TASKID = @"VoiceClone Taskid";

// voiceconv
NSString *const SETTING_VOICECONV = @"VoiceConv";
NSString *const SETTING_VOICECONV_RESULT_SAMPLE_RATE = @"VoiceConv Result Sample Rate";
NSString *const SETTING_VOICECONV_ENABLE_RECORD_DUMP = @"VoiceConv Enable Record Dump";
NSString *const SETTING_VOICECONV_ENABLE_RESULT_DUMP = @"VoiceConv Enable Result Dump";
NSString *const SETTING_VOICECONV_REQUEST_INTERVAL = @"VoiceConv Request Interval (Unit: ms)";

// dialog
NSString *const SETTING_DIALOG = @"Dialog";
NSString *const SETTING_DIALOG_ENABLE_RECORDER_DUMP = @"Dialog Recorder Dump";
NSString *const SETTING_DIALOG_ENABLE_PLAYER_DUMP = @"Dialog Player Dump";
NSString *const SETTING_DIALOG_BOT_NAME = @"Dialog Bot Name";

// bitts
NSString *const SETTING_BITTS = @"BiTTS";

// unitts
NSString *const SETTING_UNITTS = @"UniTTS";

// vad
NSString *const SETTING_VAD = @"Vad";
NSString *const SETTING_VAD_RECORDER_SAVE = @"Vad Recorder Save";
NSString *const SETTING_VAD_HEAD_SILENCE_THRESHOLD = @"Vad Head silence Threshold";
NSString *const SETTING_VAD_TAIL_SILENCE_THRESHOLD = @"Vad Tail silence Threshold";

// au
NSString *const SETTING_AU = @"Au";
NSString *const SETTING_AU_ABILITY = @"Au Ability";
NSString *const SETTING_AU_RECORDER_SAVE = @"Au Recorder Save";
NSString *const SETTING_AU_PROCESS_TIMEOUT = @"Au Process Timeout";
NSString *const SETTING_AU_AUDIO_PACKET_DURATION = @"Au Audio Packet Duration";
NSString *const SETTING_AU_EMPTY_PACKET_INTERVAL = @"Au Empty Packet Interval";

// afp
NSString *const SETTING_AFP = @"Afp";
NSString *const SETTING_MUSIC_ENGINE_NAME = @"Music engine name";
NSString *const SETTING_AFP_RESULT_TYPE = @"Afp result type";
NSString *const SETTING_AFP_INSTANCE_NUMBER = @"Afp instance number";

// kws
NSString *const SETTING_KWS = @"Kws";
NSString *const SETTING_KWS_CUSTOM_WORDS = @"Kws Custom Words";
NSString *const SETTING_KWS_MODEL_NAME = @"Kws Model Name";

// asr test
NSString *const SETTING_ASR_STRESS = @"Asr Stress";
NSString *const SETTING_ASR_STRESS_SCENEID = @"Asr Stress Sceneid";

#pragma mark - SETTING_HINT
static NSString *const SETTING_HINT_CLUSTER = @"Cluster";
static NSString *const SETTING_HINT_BACKEND_CLUSTER = @"Backend Cluster";
static NSString *const SETTING_HINT_ADDRESS = @"Address";
static NSString *const SETTING_HINT_URI = @"Uri";
static NSString *const SETTING_HINT_VOICE = @"Voice";
static NSString *const SETTING_HINT_VOICE_TYPE = @"Voice Type";
static NSString *const SETTING_HINT_ONLINE_VOICE = @"Online Voice";
static NSString *const SETTING_HINT_ONLINE_VOICE_TYPE = @"Online Voice Type";
static NSString *const SETTING_HINT_OFFLINE_VOICE = @"Offline Voice";
static NSString *const SETTING_HINT_OFFLINE_VOICE_TYPE = @"Offline Voice Type";
static NSString *const SETTING_HINT_TTS_ONLINE_LANGUAGE = @"Tts online Language";
static NSString *const SETTING_HINT_TTS_EMOTION = @"Tts emotion";
static NSString *const SETTING_HINT_TTS_OFFLINE_LANGUAGE = @"Tts offline Language";
static NSString *const SETTING_HINT_DIFFICULTY_LEVEL = @"Support 1,2,3";
static NSString *const SETTING_HINT_VOICECLONE_UID = @"VoiceClone Uid";
static NSString *const SETTING_HINT_VOICECLONE_QUERY_UIDS = @"VoiceClone Query Uids";
static NSString *const SETTING_HINT_VOICECLONE_VOICE_TYPE = @"VoiceClone Voice Type";
static NSString *const SETTING_HINT_BUSINESS_KEY = @"Business Key";
static NSString *const SETTING_HINT_AUTHENTICATE_SECRET = @"Authenticate Secret";
static NSString *const SETTING_HINT_LICENSE_NAME = @"Input license name";
static NSString *const SETTING_HINT_LICENSE_BUSI_ID = @"Input busi id";
static NSString *const SETTING_HINT_TTS_SAMPLE_RATE = @"Input tts sample rate";
static NSString *const SETTING_HINT_TTS_MODEL_NAME = @"Input Tts Model Name";
static NSString *const SETTING_HINT_MAX_CACHE_NUM = @"Input max number of client audio cache, such as 100.";
static NSString *const SETTING_HINT_TTS_CACHE_RENEWAL_DURATION = @"Input cache renewal duration, unit:ms";

#pragma mark - SETTING_OPTIONS
static NSArray* SETTING_OPTIONS_RECORD_TYPE(void) {
    return @[@"Recorder", @"File", @"Stream"];
}
static NSArray* SETTING_OPTIONS_RECORD_FILE_TYPE(void) {
    return @[@"Wav", @"Aac"];
}
static NSArray* SETTING_OPTIONS_ASR_RESULT_TYPE(void) {
    return @[@"full", @"single"];
}
static NSArray* SETTING_OPTIONS_CAPT_CORE_TYPE(void) {
    return @[@"English sentence score", @"English word score", @"English word pronounce", @"Chinese sentence raw"];
}
static NSArray* SETTING_OPTIONS_FULLLINK_ENGINE_TYPE(void) {
    return @[@"FULLLINK LITE", @"FULLLINK"];
}
static NSArray* SETTING_OPTIONS_FULLLINK_WAKEUP_WORDS(void) {
    return @[@"大力大力（only）", @"大力大力（大力同学）", @"大力同学（大力大力）", @"大力同学（only）"];
}
static NSArray* SETTING_OPTIONS_FULLLINK_WAKEUP_MODE(void) {
    return @[@"normal", @"disable wakeup", @"night mode"];
}
static NSArray* SETTING_OPTIONS_TTS_TEXT_TYPE(void) {
    return @[@"Plain", @"SSML", @"Json"];
}
static NSArray* SETTING_OPTIONS_TTS_WORK_MODE(void) {
    return @[@"Online", @"Offline", @"Alternate"];
}
static NSArray* SETTING_OPTIONS_TTS_OFFLINE_RESOURCE_FORMAT(void) {
    return @[@"SingleVoice", @"MultipleVoice"];
}
static NSArray* SETTING_OPTIONS_AUTHENTICATION_TYPE(void) {
    return @[@"Pre Bind", @"Late Bind"];
}
static NSArray* SETTING_OPTIONS_AU_ABILITY(void) {
    return @[@"ASR", @"MUSIC", @"ASR+MUSIC"];
}
static NSArray* SETTING_OPTIONS_MUSIC_ENGINE_NAME(void) {
    return @[@"AFP", @"CoverSong", @"Humming"];
}
static NSArray* SETTING_OPTIONS_AFP_RESULT_TYPE(void) {
    return @[@"Bytes", @"Json"];
}
static NSArray* SETTING_OPTIONS_ASR_STRESS_TYPE(void) {
    return @[@"正常场景1", @"正常场景2", @"ERROR回调时析构", @"随机压测"];
}

#pragma mark - Setting Init
+ (instancetype)shareInstance {
    static SettingsHelper* sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];

        // Asr settings
        sharedInstance.asrSettings = [Settings build];
        [sharedInstance.asrSettings registerItems:@[
            // common
            [SettingItem buildGroup:SETTING_COMMON val:@"" hint:@""],
            [SettingItem buildString:SETTING_APPID val:SDEF_APPID hint:@""],
            [SettingItem buildString:SETTING_TOKEN val:SDEF_TOKEN hint:@""],
            [SettingItem buildString:SETTING_CLUSTER val:SDEF_ASR_DEFAULT_CLUSTER hint:SETTING_HINT_CLUSTER],
            [SettingItem buildString:SETTING_ADDRESS val:SDEF_DEFAULT_ADDRESS hint:SETTING_HINT_ADDRESS],
            [SettingItem buildString:SETTING_URI val:SDEF_ASR_DEFAULT_URI hint:SETTING_HINT_URI],
            [SettingItem buildBool:SETTING_GET_VOLUME val:false hint:@""],
            [SettingItem buildInt:SETTING_SAMPLE_RATE val:16000 hint:@""],
            [SettingItem buildInt:SETTING_CHANNEL val:1 hint:@""],
            [SettingItem buildOptions:SETTING_RECORD_TYPE val:[SettingOptions build:SETTING_OPTIONS_RECORD_TYPE() choose:0] hint:@""],
            [SettingItem buildBool:SETTING_RESTART_AUDIO_SESSION_ENABLE val:false hint:@""],
            [SettingItem buildBool:SETTING_RESUME_OTHERS_INTERRUPTED_PLAYBACK_ENABLE val:false hint:@""],
            [SettingItem buildInt:SETTING_VAD_MAX_SPEECH_DURATION val:60000 hint:@""],
            [SettingItem buildString:SETTING_REQUEST_HEADERS val:@"{\"custom_header_key0\": \"custom_header_value0\",\"custom_header_key1\": \"custom_header_value1\"}" hint:@""],

            // asr
            [SettingItem buildGroup:SETTING_ASR val:@"" hint:@""],
            [SettingItem buildBool:SETTING_ASR_RECORDER_SAVE val:false hint:@""],
            [SettingItem buildBool:SETTING_ASR_ENABLE_DDC val:false hint:@""],
            [SettingItem buildBool:SETTING_ASR_ENABLE_ITN val:false hint:@""],
            [SettingItem buildBool:SETTING_ASR_ENABLE_NLU_PUNC val:true hint:@""],
            [SettingItem buildBool:SETTING_ASR_DISABLE_END_PUNC val:false hint:@""],
            [SettingItem buildBool:SETTING_ASR_KEEP_RECORDING val:false hint:@""],
            [SettingItem buildBool:SETTING_ASR_SHOW_LANGUAGE val:false hint:@""],
            [SettingItem buildString:SETTING_ASR_LANGUAGE val:@"en-US" hint:@""],
            [SettingItem buildString:SETTING_ASR_HOTWORDS val:@"{\"hotwords\":[{\"word\":\"过秦论\",\"scale\":\"2.0\"}]}" hint:@""],
            [SettingItem buildString:SETTING_ASR_CORRECTWORDS val:@"{\"古爱玲\":\"谷爱凌\",\"古埃宁\":\"谷爱凌\",\"谷爱玲\":\"谷爱凌\",\"谷埃宁\":\"谷爱凌\"}" hint:@""],
            [SettingItem buildInt:SETTING_ASR_VAD_START_SILENCE_TIME val:0 hint:@""],
            [SettingItem buildInt:SETTING_ASR_VAD_END_SILENCE_TIME val:0 hint:@""],
            [SettingItem buildString:SETTING_ASR_VAD_MODE val:@"" hint:@""],
            [SettingItem buildOptions:SETTING_ASR_RESULT_TYPE val:[SettingOptions build:SETTING_OPTIONS_ASR_RESULT_TYPE() choose:0] hint:@""],
            [SettingItem buildInt:SETTING_ASR_MAX_RETRY_TIMES val:0 hint:@""],
            [SettingItem buildString:SETTING_ASR_REQ_PARAMS val:@"" hint:@""],
        ]];

        // BigAsr settings
        sharedInstance.bigAsrSettings = [Settings build];
        [sharedInstance.bigAsrSettings registerItems:@[
            // common
            [SettingItem buildGroup:SETTING_COMMON val:@"" hint:@""],
            [SettingItem buildString:SETTING_APPID val:SDEF_BIGASR_DEFAULT_APPID hint:@""],
            [SettingItem buildString:SETTING_TOKEN val:SDEF_BIGASR_DEFAULT_TOKEN hint:@""],
            [SettingItem buildString:SETTING_RESOURCE_ID val:SDEF_BIGASR_DEFAULT_RESOURCE_ID hint:@""],
            [SettingItem buildString:SETTING_ADDRESS val:SDEF_DEFAULT_ADDRESS hint:SETTING_HINT_ADDRESS],
            [SettingItem buildString:SETTING_URI val:SDEF_BIGASR_DEFAULT_URI hint:SETTING_HINT_URI],
            [SettingItem buildBool:SETTING_GET_VOLUME val:false hint:@""],
            [SettingItem buildInt:SETTING_SAMPLE_RATE val:16000 hint:@""],
            [SettingItem buildInt:SETTING_CHANNEL val:1 hint:@""],
            [SettingItem buildOptions:SETTING_RECORD_TYPE val:[SettingOptions build:SETTING_OPTIONS_RECORD_TYPE() choose:0] hint:@""],
            [SettingItem buildBool:SETTING_RESTART_AUDIO_SESSION_ENABLE val:false hint:@""],
            [SettingItem buildBool:SETTING_RESUME_OTHERS_INTERRUPTED_PLAYBACK_ENABLE val:false hint:@""],
            [SettingItem buildInt:SETTING_VAD_MAX_SPEECH_DURATION val:60000 hint:@""],

            // asr
            [SettingItem buildGroup:SETTING_ASR val:@"" hint:@""],
            [SettingItem buildBool:SETTING_ASR_RECORDER_SAVE val:false hint:@""],
            [SettingItem buildBool:SETTING_ASR_ENABLE_DDC val:false hint:@""],
            [SettingItem buildBool:SETTING_ASR_ENABLE_ITN val:false hint:@""],
            [SettingItem buildBool:SETTING_ASR_ENABLE_NLU_PUNC val:true hint:@""],
            [SettingItem buildString:SETTING_ASR_REQ_PARAMS val:@"" hint:@""],
        ]];

        // Asr offline settings
        sharedInstance.asrOfflineSettings = [Settings build];
        [sharedInstance.asrOfflineSettings registerItems:@[
            // common
            [SettingItem buildGroup:SETTING_COMMON val:@"" hint:@""],
            [SettingItem buildString:SETTING_APPID val:SDEF_APPID hint:@""],
            [SettingItem buildOptions:SETTING_RECORD_TYPE val:[SettingOptions build:SETTING_OPTIONS_RECORD_TYPE() choose:0] hint:@""],
            [SettingItem buildInt:SETTING_VAD_MAX_SPEECH_DURATION val:15000 hint:@""],
            [SettingItem buildOptions:SETTING_AUTHENTICATION_TYPE val:[SettingOptions build:SETTING_OPTIONS_AUTHENTICATION_TYPE() choose:1] hint:@""],
            [SettingItem buildString:SETTING_LICENSE_NAME val:SDEF_LICENSE_NAME hint:SETTING_HINT_LICENSE_NAME],
            [SettingItem buildString:SETTING_LICENSE_BUSI_ID val:SDEF_LICENSE_BUSI_ID hint:SETTING_HINT_LICENSE_BUSI_ID],
            [SettingItem buildString:SETTING_BUSINESS_KEY val:SDEF_BUSINESS_KEY hint:SETTING_HINT_BUSINESS_KEY],
            [SettingItem buildString:SETTING_AUTHENTICATE_SECRET val:SDEF_SECRET hint:SETTING_HINT_AUTHENTICATE_SECRET],

            // asr
            [SettingItem buildGroup:SETTING_ASR val:@"" hint:@""],
            [SettingItem buildBool:SETTING_ASR_ENABLE_RESOURCE_DOWNLOAD val:false hint:@""],
            [SettingItem buildString:SETTING_ASR_MODEL_NAME val:SDEF_ASR_DEFAULT_MODEL_NAME hint:@""],
            [SettingItem buildBool:SETTING_ASR_RECORDER_SAVE val:false hint:@""],
            [SettingItem buildBool:SETTING_ASR_ENABLE_ITN val:false hint:@""],
            [SettingItem buildBool:SETTING_ASR_SHOW_LANGUAGE val:false hint:@""],
            [SettingItem buildOptions:SETTING_ASR_RESULT_TYPE val:[SettingOptions build:SETTING_OPTIONS_ASR_RESULT_TYPE() choose:0] hint:@""],
        ]];

        // Capt settings
        sharedInstance.captSettings = [Settings build];
        [sharedInstance.captSettings registerItems:@[
            // common
            [SettingItem buildGroup:SETTING_COMMON val:@"" hint:@""],
            [SettingItem buildString:SETTING_CLUSTER val:SDEF_CAPT_DEFAULT_CLUSTER hint:SETTING_HINT_CLUSTER],
            [SettingItem buildString:SETTING_ADDRESS val:SDEF_DEFAULT_ADDRESS hint:SETTING_HINT_ADDRESS],
            [SettingItem buildString:SETTING_URI val:@"" hint:SETTING_HINT_URI],
            [SettingItem buildString:SETTING_APPID val:SDEF_APPID hint:@""],
            [SettingItem buildString:SETTING_TOKEN val:SDEF_APPID hint:@""],
            [SettingItem buildBool:SETTING_GET_VOLUME val:false hint:@""],
            [SettingItem buildOptions:SETTING_RECORD_TYPE val:[SettingOptions build:SETTING_OPTIONS_RECORD_TYPE() choose:0] hint:@""],
            [SettingItem buildBool:SETTING_ENABLE_AEC val:false hint:@""],
            [SettingItem buildBool:SETTING_RESTART_AUDIO_SESSION_ENABLE val:false hint:@""],
            [SettingItem buildBool:SETTING_RESUME_OTHERS_INTERRUPTED_PLAYBACK_ENABLE val:false hint:@""],
            [SettingItem buildInt:SETTING_VAD_MAX_SPEECH_DURATION val:15000 hint:@""],

            // capt
            [SettingItem buildGroup:SETTING_CAPT val:@"" hint:@""],
            [SettingItem buildBool:SETTING_CAPT_RECORDER_SAVE val:false hint:@""],
            [SettingItem buildBool:SETTING_CAPT_STREAMING_MODE val:false hint:@""],
            [SettingItem buildOptions:SETTING_CAPT_CORE_TYPE val:[SettingOptions build:SETTING_OPTIONS_CAPT_CORE_TYPE() choose:0] hint:@""],
            [SettingItem buildInt:SETTING_CAPT_DIFFICULTY_LEVEL val:2 hint:SETTING_HINT_DIFFICULTY_LEVEL],
        ]];

        // Fulllink settings
        sharedInstance.fulllinkSettings = [Settings build];
        [sharedInstance.fulllinkSettings registerItems:@[
            // common
            [SettingItem buildGroup:SETTING_COMMON val:@"" hint:@""],
            [SettingItem buildString:SETTING_CLUSTER val:@"" hint:SETTING_HINT_CLUSTER],
            [SettingItem buildString:SETTING_ADDRESS val:SDEF_DEFAULT_ADDRESS hint:SETTING_HINT_ADDRESS],
            [SettingItem buildBool:SETTING_GET_VOLUME val:false hint:@""],
            [SettingItem buildInt:SETTING_SAMPLE_RATE val:16000 hint:@""],
            [SettingItem buildOptions:SETTING_RECORD_TYPE val:[SettingOptions build:SETTING_OPTIONS_RECORD_TYPE() choose:0] hint:@""],
            [SettingItem buildBool:SETTING_ENABLE_AEC val:false hint:@""],
            [SettingItem buildBool:SETTING_RESTART_AUDIO_SESSION_ENABLE val:false hint:@""],
            [SettingItem buildBool:SETTING_RESUME_OTHERS_INTERRUPTED_PLAYBACK_ENABLE val:false hint:@""],

            // fulllink
            [SettingItem buildGroup:SETTING_FULLLINK val:@"" hint:@""],
            [SettingItem buildOptions:SETTING_FULLLINK_ENGINE_TYPE val:[SettingOptions build:SETTING_OPTIONS_FULLLINK_ENGINE_TYPE() choose:0] hint:@""],
            [SettingItem buildOptions:SETTING_FULLLINK_WAKEUP_WORDS val:[SettingOptions build:SETTING_OPTIONS_FULLLINK_WAKEUP_WORDS() choose:0] hint:@""],
            [SettingItem buildBool:SETTING_FULLLINK_ENABLE_RECORDER_DUMP val:false hint:@""],
            [SettingItem buildBool:SETTING_FULLLINK_ENABLE_KWS_DUMP val:false hint:@""],
            [SettingItem buildOptions:SETTING_FULLLINK_WAKEUP_MODE val:[SettingOptions build:SETTING_OPTIONS_FULLLINK_WAKEUP_MODE() choose:0] hint:@""],
            [SettingItem buildBool:SETTING_FULLLINK_ONLY_ASR val:false hint:@""],
            [SettingItem buildBool:SETTING_FULLLINK_DISABLE_TTS val:false hint:@""],
            [SettingItem buildBool:SETTING_FULLLINK_DISABLE_SIGNAL val:false hint:@""],
            [SettingItem buildInt:SETTING_FULLLINK_DISABLE_SIGTHREAD_PRI val:-10 hint:@""],
            [SettingItem buildString:SETTING_FULLLINK_DISABLE_FILE_OR_DIRECTORY_NAME val:@"" hint:@""],
        ]];

        // Tts settings
        sharedInstance.ttsSettings = [Settings build];
        [sharedInstance.ttsSettings registerItems:@[
            // common
            [SettingItem buildGroup:SETTING_COMMON val:@"" hint:@""],
            [SettingItem buildString:SETTING_APPID val:SDEF_APPID hint:@""],
            [SettingItem buildString:SETTING_TOKEN val:SDEF_TOKEN hint:@""],
            [SettingItem buildString:SETTING_CLUSTER val:SDEF_TTS_DEFAULT_CLUSTER hint:SETTING_HINT_CLUSTER],
            [SettingItem buildString:SETTING_ADDRESS val:SDEF_DEFAULT_ADDRESS hint:SETTING_HINT_ADDRESS],
            [SettingItem buildString:SETTING_URI val:SDEF_TTS_DEFAULT_URI hint:SETTING_HINT_URI],
            [SettingItem buildString:SETTING_ONLINE_VOICE val:SDEF_TTS_DEFAULT_ONLINE_VOICE hint:SETTING_HINT_ONLINE_VOICE],
            [SettingItem buildString:SETTING_ONLINE_VOICE_TYPE val:SDEF_TTS_DEFAULT_ONLINE_VOICE_TYPE hint:SETTING_HINT_ONLINE_VOICE_TYPE],
            [SettingItem buildString:SETTING_OFFLINE_VOICE val:SDEF_TTS_DEFAULT_OFFLINE_VOICE hint:SETTING_HINT_OFFLINE_VOICE],
            [SettingItem buildString:SETTING_OFFLINE_VOICE_TYPE val:SDEF_TTS_DEFAULT_OFFLINE_VOICE_TYPE hint:SETTING_HINT_OFFLINE_VOICE_TYPE],
            [SettingItem buildOptions:SETTING_AUTHENTICATION_TYPE val:[SettingOptions build:SETTING_OPTIONS_AUTHENTICATION_TYPE() choose:0] hint:@""],
            [SettingItem buildString:SETTING_LICENSE_NAME val:SDEF_LICENSE_NAME hint:SETTING_HINT_LICENSE_NAME],
            [SettingItem buildString:SETTING_LICENSE_BUSI_ID val:SDEF_LICENSE_BUSI_ID hint:SETTING_HINT_LICENSE_BUSI_ID],
            [SettingItem buildString:SETTING_BUSINESS_KEY val:SDEF_BUSINESS_KEY hint:SETTING_HINT_BUSINESS_KEY],
            [SettingItem buildString:SETTING_AUTHENTICATE_SECRET val:SDEF_SECRET hint:SETTING_HINT_AUTHENTICATE_SECRET],
            [SettingItem buildBool:SETTING_DISABLE_WS_RECONNECT val:false hint:@""],
            [SettingItem buildInt:SETTING_AUDIO_FADEOUT_DURATION val:0 hint:@""],

            // tts
            [SettingItem buildGroup:SETTING_TTS val:@"" hint:@""],
            [SettingItem buildOptions:SETTING_TTS_WORK_MODE val:[SettingOptions build:SETTING_OPTIONS_TTS_WORK_MODE() choose:0] hint:@""],
            [SettingItem buildOptions:SETTING_TTS_TEXT_TYPE val:[SettingOptions build:SETTING_OPTIONS_TTS_TEXT_TYPE() choose:0] hint:@""],
            [SettingItem buildBool:SETTING_PREVENT_PLAYER_CREATION val:false hint:@""],
            [SettingItem buildBool:SETTING_TTS_ENABLE_RESUME_FROM_BREAKPOINT val:true hint:@""],
            [SettingItem buildBool:SETTING_TTS_ENABLE_PLAYER val:true hint:@""],
            [SettingItem buildBool:SETTING_TTS_ENABLE_DUMP val:false hint:@""],
            [SettingItem buildBool:SETTING_TTS_ENABLE_DATA_CALLBACK val:false hint:@""],
            [SettingItem buildBool:SETTING_TTS_ENABLE_WORD_LEVEL_PROGRESS_UPDATE val:true hint:@""],
            [SettingItem buildInt:SETTING_TTS_SILENCE_DURATION val:0 hint:@""],
            [SettingItem buildDouble:SETTING_TTS_SPEAK_SPEED val:1.0 hint:@""],
            [SettingItem buildDouble:SETTING_TTS_AUDIO_VOLUME val:1.0 hint:@""],
            [SettingItem buildDouble:SETTING_TTS_AUDIO_PITCH val:1.0 hint:@""],
            [SettingItem buildInt:SETTING_TTS_SAMPLE_RATE val:16000 hint:SETTING_HINT_TTS_SAMPLE_RATE],

            [SettingItem buildBool:SETTING_TTS_ENABLE_CACHE val:false hint:@""],
            [SettingItem buildBool:SETTING_TTS_WITH_INTENT val:false hint:@""],
            [SettingItem buildString:SETTING_TTS_ONLINE_LANGUAGE val:SDEF_TTS_DEFAULT_ONLINE_LANGUAGE hint:SETTING_HINT_TTS_ONLINE_LANGUAGE],
            [SettingItem buildString:SETTING_TTS_EMOTION val:@"" hint:SETTING_HINT_TTS_EMOTION],
            [SettingItem buildBool:SETTING_TTS_USE_VOICECLONE_VOICE val:false hint:@""],
            [SettingItem buildString:SETTING_TTS_BACKEND_CLUSTER val:@"demo_test" hint:SETTING_HINT_BACKEND_CLUSTER],
            [SettingItem buildString:SETTING_TTS_REQUEST_ID val:@"" hint:@""],
            [SettingItem buildString:SETTING_TTS_REQUEST_PARAMS val:@"" hint:@""],

            [SettingItem buildOptions:SETTING_TTS_OFFLINE_RESOURCE_FORMAT val:[SettingOptions build:SETTING_OPTIONS_TTS_OFFLINE_RESOURCE_FORMAT() choose:0] hint:@""],
            [SettingItem buildString:SETTING_TTS_OFFLINE_LANGUAGE val:SDEF_TTS_DEFAULT_OFFLINE_LANGUAGE hint:SETTING_HINT_TTS_OFFLINE_LANGUAGE],
            [SettingItem buildString:SETTING_TTS_MODEL_NAME val:@"aispeech_tts" hint:SETTING_HINT_TTS_MODEL_NAME],
            [SettingItem buildBool:SETTING_TTS_LIMIT_CPU_USAGE val:false hint:@""],
        ]];
        // VoiceClone settings
        sharedInstance.voiceCloneSettings = [Settings build];
        [sharedInstance.voiceCloneSettings registerItems:@[
            // common
            [SettingItem buildGroup:SETTING_COMMON val:@"" hint:@""],
            [SettingItem buildInt:SETTING_SAMPLE_RATE val:44100 hint:@""],
            [SettingItem buildString:SETTING_APPID val:SDEF_APPID hint:@""],
            [SettingItem buildString:SETTING_TOKEN val:SDEF_APPID hint:@""],
            [SettingItem buildOptions:SETTING_RECORD_TYPE val:[SettingOptions build:SETTING_OPTIONS_RECORD_TYPE() choose:0] hint:@""],

            // voiceclone
            [SettingItem buildGroup:SETTING_VOICECLONE val:@"" hint:@""],
            [SettingItem buildString:SETTING_VOICECLONE_ADDRESS val:SDEF_DEFAULT_HTTP_ADDRESS hint:@""],
            [SettingItem buildString:SETTING_VOICECLONE_STREAM_ADDRESS val:SDEF_DEFAULT_ADDRESS hint:@""],
            [SettingItem buildString:SETTING_VOICECLONE_UID val:SDEF_UID hint:SETTING_HINT_VOICECLONE_UID],
            [SettingItem buildString:SETTING_VOICECLONE_QUERY_UIDS val:SDEF_VOICECLONE_DEFAULT_UIDS hint:SETTING_HINT_VOICECLONE_QUERY_UIDS],
            [SettingItem buildString:SETTING_VOICECLONE_VOICE_TYPE val:@"" hint:SETTING_HINT_VOICECLONE_VOICE_TYPE],
            [SettingItem buildBool:SETTING_VOICECLONE_GENDER val:false hint:@""],
            [SettingItem buildInt:SETTING_VOICECLONE_TASKID val:SDEF_VOICECLONE_DEFAULT_TASK_ID hint:@""],
        ]];

        // VoiceConv settings
        sharedInstance.voiceConvSettings = [Settings build];
        [sharedInstance.voiceConvSettings registerItems:@[
            // common
            [SettingItem buildGroup:SETTING_COMMON val:@"" hint:@""],
            [SettingItem buildString:SETTING_VOICE val:SDEF_VOICECONV_DEFAULT_VOICE hint:SETTING_HINT_VOICE],
            [SettingItem buildString:SETTING_VOICE_TYPE val:SDEF_VOICECONV_DEFAULT_VOICE_TYPE hint:SETTING_HINT_VOICE_TYPE],
            [SettingItem buildBool:SETTING_GET_VOLUME val:false hint:@""],
            [SettingItem buildOptions:SETTING_RECORD_TYPE val:[SettingOptions build:SETTING_OPTIONS_RECORD_TYPE() choose:0] hint:@""],

            // voiceconv
            [SettingItem buildGroup:SETTING_VOICECONV val:@"" hint:@""],
            [SettingItem buildInt:SETTING_VOICECONV_RESULT_SAMPLE_RATE val:24000 hint:@""],
            [SettingItem buildBool:SETTING_VOICECONV_ENABLE_RECORD_DUMP val:true hint:@""],
            [SettingItem buildBool:SETTING_VOICECONV_ENABLE_RESULT_DUMP val:true hint:@""],
            [SettingItem buildInt:SETTING_VOICECONV_REQUEST_INTERVAL val:200 hint:@""],
        ]];

        // Dialog settings
        sharedInstance.dialogSettings = [Settings build];
        [sharedInstance.dialogSettings registerItems:@[
            // common
            [SettingItem buildGroup:SETTING_COMMON val:@"" hint:@""],
            [SettingItem buildString:SETTING_API_KEY val:SDEF_API_KEY hint:@""],
            [SettingItem buildString:SETTING_APPID val:SDEF_APPID hint:@""],
            [SettingItem buildString:SETTING_APPKEY val:SDEF_APPKEY hint:@""],
            [SettingItem buildString:SETTING_TOKEN val:SDEF_TOKEN hint:@""],
            [SettingItem buildString:SETTING_RESOURCE_ID val:SDEF_DIALOG_DEFAULT_RESOURCE_ID hint:@""],
            [SettingItem buildString:SETTING_ADDRESS val:SDEF_DEFAULT_ADDRESS hint:SETTING_HINT_ADDRESS],
            [SettingItem buildString:SETTING_URI val:SDEF_DIALOG_DEFAULT_URI hint:SETTING_HINT_URI],
            [SettingItem buildString:SETTING_REQUEST_HEADERS val:@"" hint:@""],

            // dialog
            [SettingItem buildGroup:SETTING_DIALOG val:@"" hint:@""],
            [SettingItem buildBool:SETTING_DIALOG_ENABLE_RECORDER_DUMP val:false hint:@""],
            [SettingItem buildBool:SETTING_DIALOG_ENABLE_PLAYER_DUMP val:false hint:@""],
            [SettingItem buildString:SETTING_DIALOG_BOT_NAME val:@"豆包" hint:@""],
        ]];

        // Dialog duplex settings
        sharedInstance.dialogDuplexSettings = [Settings build];
        [sharedInstance.dialogDuplexSettings registerItems:@[
            // common
            [SettingItem buildGroup:SETTING_COMMON val:@"" hint:@""],
            [SettingItem buildString:SETTING_API_KEY val:SDEF_API_KEY hint:@""],
            [SettingItem buildString:SETTING_APPID val:SDEF_APPID hint:@""],
            [SettingItem buildString:SETTING_APPKEY val:SDEF_APPKEY hint:@""],
            [SettingItem buildString:SETTING_TOKEN val:SDEF_TOKEN hint:@""],
            [SettingItem buildString:SETTING_RESOURCE_ID val:SDEF_DIALOG_DUPLEX_DEFAULT_RESOURCE_ID hint:@""],
            [SettingItem buildString:SETTING_ADDRESS val:SDEF_DEFAULT_ADDRESS hint:SETTING_HINT_ADDRESS],
            [SettingItem buildString:SETTING_URI val:SDEF_DIALOG_DUPLEX_DEFAULT_URI hint:SETTING_HINT_URI],
            [SettingItem buildString:SETTING_REQUEST_HEADERS val:@"" hint:@""],

            // dialog
            [SettingItem buildGroup:SETTING_DIALOG val:@"" hint:@""],
            [SettingItem buildBool:SETTING_DIALOG_ENABLE_RECORDER_DUMP val:false hint:@""],
            [SettingItem buildBool:SETTING_DIALOG_ENABLE_PLAYER_DUMP val:false hint:@""],
            [SettingItem buildString:SETTING_DIALOG_BOT_NAME val:@"豆包" hint:@""],
        ]];

        // Dialog settings
        sharedInstance.dialogDelegateSettings = [Settings build];
        [sharedInstance.dialogDelegateSettings registerItems:@[
            // common
            [SettingItem buildGroup:SETTING_COMMON val:@"" hint:@""],
            [SettingItem buildString:SETTING_API_KEY val:SDEF_API_KEY hint:@""],
            [SettingItem buildString:SETTING_APPID val:SDEF_APPID hint:@""],
            [SettingItem buildString:SETTING_APPKEY val:SDEF_APPKEY hint:@""],
            [SettingItem buildString:SETTING_TOKEN val:SDEF_TOKEN hint:@""],
            [SettingItem buildString:SETTING_RESOURCE_ID val:SDEF_DIALOG_DEFAULT_RESOURCE_ID hint:@""],
            [SettingItem buildString:SETTING_ADDRESS val:SDEF_DEFAULT_ADDRESS hint:SETTING_HINT_ADDRESS],
            [SettingItem buildString:SETTING_URI val:SDEF_DIALOG_DEFAULT_URI hint:SETTING_HINT_URI],
            [SettingItem buildString:SETTING_REQUEST_HEADERS val:@"" hint:@""],

            // dialog
            [SettingItem buildGroup:SETTING_DIALOG val:@"" hint:@""],
            [SettingItem buildBool:SETTING_DIALOG_ENABLE_RECORDER_DUMP val:false hint:@""],
            [SettingItem buildBool:SETTING_DIALOG_ENABLE_PLAYER_DUMP val:false hint:@""],
            [SettingItem buildString:SETTING_DIALOG_BOT_NAME val:@"豆包" hint:@""],
        ]];

        // BiTTS settings
        sharedInstance.bittsSettings = [Settings build];
        [sharedInstance.bittsSettings registerItems:@[
            // common
            [SettingItem buildGroup:SETTING_COMMON val:@"" hint:@""],
            [SettingItem buildString:SETTING_API_KEY val:SDEF_API_KEY hint:@""],
            [SettingItem buildString:SETTING_APPID val:SDEF_BITTS_DEFAULT_APPID hint:@""],
            [SettingItem buildString:SETTING_APPKEY val:SDEF_APPKEY hint:@""],
            [SettingItem buildString:SETTING_TOKEN val:SDEF_BITTS_DEFAULT_TOKEN hint:@""],
            [SettingItem buildString:SETTING_RESOURCE_ID val:SDEF_BITTS_DEFAULT_RESOURCE_ID hint:@""],
            [SettingItem buildString:SETTING_ADDRESS val:SDEF_DEFAULT_ADDRESS hint:SETTING_HINT_ADDRESS],
            [SettingItem buildString:SETTING_URI val:SDEF_BITTS_DEFAULT_URI hint:SETTING_HINT_URI],
            [SettingItem buildString:SETTING_REQUEST_HEADERS val:@"{}" hint:@""],

            // bitts
            [SettingItem buildGroup:SETTING_BITTS val:@"" hint:@""],
            [SettingItem buildBool:SETTING_TTS_ENABLE_PLAYER val:true hint:@""],
            [SettingItem buildBool:SETTING_TTS_ENABLE_DUMP val:false hint:@""],
            [SettingItem buildBool:SETTING_ENABLE_PLAYER_AUDIO_CALL_BACK val:true hint:@""],
        ]];

        // UniTTS settings
        sharedInstance.uniTtsSettings = [Settings build];
        [sharedInstance.uniTtsSettings registerItems:@[
            // common
            [SettingItem buildGroup:SETTING_COMMON val:@"" hint:@""],
            [SettingItem buildString:SETTING_APPID val:SDEF_UNITTS_DEFAULT_APPID hint:@""],
            [SettingItem buildString:SETTING_TOKEN val:SDEF_UNITTS_DEFAULT_TOKEN hint:@""],
            [SettingItem buildString:SETTING_RESOURCE_ID val:SDEF_UNITTS_DEFAULT_RESOURCE_ID hint:@""],
            [SettingItem buildString:SETTING_ADDRESS val:SDEF_DEFAULT_ADDRESS hint:SETTING_HINT_ADDRESS],
            [SettingItem buildString:SETTING_URI val:SDEF_UNITTS_DEFAULT_URI hint:SETTING_HINT_URI],
            [SettingItem buildString:SETTING_REQUEST_HEADERS val:@"{}" hint:@""],

            // unitts
            [SettingItem buildGroup:SETTING_UNITTS val:@"" hint:@""],
            [SettingItem buildBool:SETTING_TTS_ENABLE_PLAYER val:true hint:@""],
            [SettingItem buildBool:SETTING_TTS_ENABLE_DUMP val:false hint:@""],
            [SettingItem buildBool:SETTING_ENABLE_PLAYER_AUDIO_CALL_BACK val:true hint:@""],
        ]];

        // Vad settings
        sharedInstance.vadSettings = [Settings build];
        [sharedInstance.vadSettings registerItems:@[
            // common
            [SettingItem buildGroup:SETTING_COMMON val:@"" hint:@""],
            [SettingItem buildBool:SETTING_GET_VOLUME val:false hint:@""],
            [SettingItem buildOptions:SETTING_RECORD_TYPE val:[SettingOptions build:SETTING_OPTIONS_RECORD_TYPE() choose:0] hint:@""],
            [SettingItem buildBool:SETTING_RESTART_AUDIO_SESSION_ENABLE val:false hint:@""],
            [SettingItem buildBool:SETTING_RESUME_OTHERS_INTERRUPTED_PLAYBACK_ENABLE val:false hint:@""],

            // vad
            [SettingItem buildGroup:SETTING_VAD val:@"" hint:@""],
            [SettingItem buildBool:SETTING_VAD_RECORDER_SAVE val:false hint:@""],
            [SettingItem buildInt:SETTING_VAD_HEAD_SILENCE_THRESHOLD val:4000 hint:@""],
            [SettingItem buildInt:SETTING_VAD_TAIL_SILENCE_THRESHOLD val:2000 hint:@""],
        ]];

        // Au settings
        sharedInstance.auSettings = [Settings build];
        [sharedInstance.auSettings registerItems:@[
            // common
            [SettingItem buildGroup:SETTING_COMMON val:@"" hint:@""],
            [SettingItem buildString:SETTING_APPID val:SDEF_AU_DEFAULT_APP_ID hint:@""],
            [SettingItem buildString:SETTING_TOKEN val:SDEF_TOKEN hint:@""],
            [SettingItem buildString:SETTING_CLUSTER val:SDEF_AU_DEFAULT_CLUSTER hint:SETTING_HINT_CLUSTER],
            [SettingItem buildString:SETTING_ADDRESS val:SDEF_AU_DEFAULT_ADDRESS hint:SETTING_HINT_ADDRESS],
            [SettingItem buildString:SETTING_URI val:SDEF_AU_DEFAULT_URI hint:SETTING_HINT_URI],
            [SettingItem buildOptions:SETTING_RECORD_TYPE val:[SettingOptions build:SETTING_OPTIONS_RECORD_TYPE() choose:0] hint:@""],

            // au
            [SettingItem buildGroup:SETTING_AU val:@"" hint:@""],
            [SettingItem buildOptions:SETTING_AU_ABILITY val:[SettingOptions build:SETTING_OPTIONS_AU_ABILITY() choose:2] hint:@""],
            [SettingItem buildBool:SETTING_AU_RECORDER_SAVE val:false hint:@""],
            [SettingItem buildInt:SETTING_AU_PROCESS_TIMEOUT val:3000 hint:@""],
            [SettingItem buildInt:SETTING_AU_AUDIO_PACKET_DURATION val:80 hint:@""],
            [SettingItem buildInt:SETTING_AU_EMPTY_PACKET_INTERVAL val:500 hint:@""],
            [SettingItem buildInt:SETTING_VAD_MAX_SPEECH_DURATION val:60000 hint:@""],
            [SettingItem buildInt:SETTING_VAD_MAX_MUSIC_DURATION val:12000 hint:@""],

            // asr
            [SettingItem buildGroup:SETTING_ASR val:@"" hint:@""],
            [SettingItem buildBool:SETTING_ASR_ENABLE_DDC val:false hint:@""],
            [SettingItem buildBool:SETTING_ASR_ENABLE_ITN val:false hint:@""],
            [SettingItem buildBool:SETTING_ASR_ENABLE_NLU_PUNC val:false hint:@""],
            [SettingItem buildBool:SETTING_ASR_SHOW_LANGUAGE val:false hint:@""],
            [SettingItem buildString:SETTING_ASR_LANGUAGE val:@"en-US" hint:@""],
            [SettingItem buildString:SETTING_ASR_HOTWORDS val:@"{\"hotwords\":[{\"word\":\"过秦论\",\"scale\":\"2.0\"}]}" hint:@""],
            [SettingItem buildInt:SETTING_ASR_VAD_START_SILENCE_TIME val:0 hint:@""],
            [SettingItem buildInt:SETTING_ASR_VAD_END_SILENCE_TIME val:0 hint:@""],
            [SettingItem buildString:SETTING_ASR_VAD_MODE val:@"" hint:@""],
            [SettingItem buildOptions:SETTING_ASR_RESULT_TYPE val:[SettingOptions build:SETTING_OPTIONS_ASR_RESULT_TYPE() choose:0] hint:@""],
        ]];

        // Afp
        sharedInstance.afpSettings = [Settings build];
        [sharedInstance.afpSettings registerItems:@[
            // afp
            [SettingItem buildGroup:SETTING_AFP val:@"" hint:@""],
            [SettingItem buildOptions:SETTING_MUSIC_ENGINE_NAME val:[SettingOptions build:SETTING_OPTIONS_MUSIC_ENGINE_NAME() choose:0] hint:@""],
            [SettingItem buildOptions:SETTING_AFP_RESULT_TYPE val:[SettingOptions build:SETTING_OPTIONS_AFP_RESULT_TYPE() choose:0] hint:@""],
        ]];

        // Kws settings
        sharedInstance.kwsSettings = [Settings build];
        [sharedInstance.kwsSettings registerItems:@[
                // common
                [SettingItem buildGroup:SETTING_COMMON val:@"" hint:@""],
                [SettingItem buildOptions:SETTING_RECORD_TYPE val:[SettingOptions build:SETTING_OPTIONS_RECORD_TYPE() choose:0] hint:@""],
                // kws
                [SettingItem buildGroup:SETTING_KWS val:@"" hint:@""],
                [SettingItem buildString:SETTING_KWS_MODEL_NAME val:@"aispeech_kws_douyin" hint:@""],
                [SettingItem buildString:SETTING_KWS_CUSTOM_WORDS val:@"{\"word_list\":[{\"name\":\"大力大力\",\"keyword_type\":0,\"min_dur\":0.15,\"max_dur\":3,\"threshold\":-3.6}]}" hint:@""],
        ]];

        // Test Afp
        sharedInstance.testAfpSettings = [Settings build];
        [sharedInstance.testAfpSettings registerItems:@[
            // afp
            [SettingItem buildGroup:SETTING_AFP val:@"" hint:@""],
            [SettingItem buildOptions:SETTING_AFP_RESULT_TYPE val:[SettingOptions build:SETTING_OPTIONS_AFP_RESULT_TYPE() choose:0] hint:@""],
            [SettingItem buildInt:SETTING_AFP_INSTANCE_NUMBER val:10 hint:@""],
        ]];

        // Test: asr offline rtf settins
        sharedInstance.testAsrOfflineRtfSettings = [Settings build];
        [sharedInstance.testAsrOfflineRtfSettings registerItems:@[
                // common
                [SettingItem buildGroup:SETTING_COMMON val:@"" hint:@""],
                [SettingItem buildInt:SETTING_STREAM_PACKAGE_DURATION val:20000 hint:@""],

                // asr
                [SettingItem buildGroup:SETTING_ASR val:@"" hint:@""],
                [SettingItem buildBool:SETTING_ASR_RECORDER_SAVE val:false hint:@""],
                [SettingItem buildBool:SETTING_ASR_ENABLE_ITN val:false hint:@""],
                [SettingItem buildBool:SETTING_ASR_SHOW_LANGUAGE val:false hint:@""],
        ]];

        // Test: asr stress settings
        sharedInstance.testAsrStressSettings = [Settings build];
        [sharedInstance.testAsrStressSettings registerItems:@[
            // stress
            [SettingItem buildGroup:SETTING_ASR_STRESS val:@"" hint:@""],
            [SettingItem buildOptions:SETTING_ASR_STRESS_SCENEID val:[SettingOptions build:SETTING_OPTIONS_ASR_STRESS_TYPE() choose:0] hint:@""],

            // common
            [SettingItem buildGroup:SETTING_COMMON val:@"" hint:@""],
            [SettingItem buildString:SETTING_APPID val:SDEF_APPID hint:@""],
            [SettingItem buildString:SETTING_TOKEN val:SDEF_TOKEN hint:@""],
            [SettingItem buildString:SETTING_CLUSTER val:SDEF_ASR_DEFAULT_CLUSTER hint:SETTING_HINT_CLUSTER],
            [SettingItem buildString:SETTING_ADDRESS val:SDEF_DEFAULT_ADDRESS hint:SETTING_HINT_ADDRESS],
            [SettingItem buildString:SETTING_URI val:SDEF_ASR_DEFAULT_URI hint:SETTING_HINT_URI],
            [SettingItem buildBool:SETTING_GET_VOLUME val:false hint:@""],
            [SettingItem buildOptions:SETTING_RECORD_TYPE val:[SettingOptions build:SETTING_OPTIONS_RECORD_TYPE() choose:0] hint:@""],
            [SettingItem buildBool:SETTING_RESTART_AUDIO_SESSION_ENABLE val:false hint:@""],
            [SettingItem buildBool:SETTING_RESUME_OTHERS_INTERRUPTED_PLAYBACK_ENABLE val:false hint:@""],
            [SettingItem buildInt:SETTING_VAD_MAX_SPEECH_DURATION val:15000 hint:@""],
            [SettingItem buildInt:SETTING_STREAM_PACKAGE_DURATION val:20000 hint:@""],

            // asr
            [SettingItem buildGroup:SETTING_ASR val:@"" hint:@""],
            [SettingItem buildBool:SETTING_ASR_RECORDER_SAVE val:false hint:@""],
            [SettingItem buildBool:SETTING_ASR_ENABLE_DDC val:false hint:@""],
            [SettingItem buildBool:SETTING_ASR_ENABLE_ITN val:false hint:@""],
            [SettingItem buildBool:SETTING_ASR_ENABLE_NLU_PUNC val:true hint:@""],
            [SettingItem buildBool:SETTING_ASR_KEEP_RECORDING val:false hint:@""],
            [SettingItem buildBool:SETTING_ASR_SHOW_LANGUAGE val:false hint:@""],
            [SettingItem buildString:SETTING_ASR_LANGUAGE val:@"en-US" hint:@""],
            [SettingItem buildString:SETTING_ASR_HOTWORDS val:@"{\"hotwords\":[{\"word\":\"过秦论\",\"scale\":\"2.0\"}]}" hint:@""],
            [SettingItem buildInt:SETTING_ASR_VAD_START_SILENCE_TIME val:0 hint:@""],
            [SettingItem buildInt:SETTING_ASR_VAD_END_SILENCE_TIME val:0 hint:@""],
            [SettingItem buildString:SETTING_ASR_VAD_MODE val:@"" hint:@""],
            [SettingItem buildOptions:SETTING_ASR_RESULT_TYPE val:[SettingOptions build:SETTING_OPTIONS_ASR_RESULT_TYPE() choose:0] hint:@""],
        ]];

    });
    return sharedInstance;
}

- (Settings*)getSettings:(NSString*)viewId {
    if ([viewId isEqualToString: VIEW_ASR]) {
        return self.asrSettings;
    } else if ([viewId isEqualToString: VIEW_BIGASR]) {
        return self.bigAsrSettings;
    } else if ([viewId isEqualToString: VIEW_ASR_OFFLINE]) {
        return self.asrOfflineSettings;
    } else if ([viewId isEqualToString: VIEW_CAPT]) {
        return self.captSettings;
    } else if ([viewId isEqualToString: VIEW_FULLLINK]) {
        return self.fulllinkSettings;
    } else if ([viewId isEqualToString: VIEW_TTS]) {
        return self.ttsSettings;
    } else if ([viewId isEqualToString: VIEW_VOICECLONE]) {
        return self.voiceCloneSettings;
    } else if ([viewId isEqualToString: VIEW_VOICECONV]) {
        return self.voiceConvSettings;
    } else if ([viewId isEqualToString: VIEW_DIALOG]) {
        return self.dialogSettings;
    } else if ([viewId isEqualToString: VIEW_DIALOG_DUPLEX]) {
        return self.dialogDuplexSettings;
    } else if ([viewId isEqualToString: VIEW_DIALOG_DELEGATE]) {
        return self.dialogDelegateSettings;
    } else if ([viewId isEqualToString: VIEW_BITTS]) {
        return self.bittsSettings;
    } else if ([viewId isEqualToString: VIEW_UNITTS]) {
        return self.uniTtsSettings;
    } else if ([viewId isEqualToString: VIEW_VAD]) {
        return self.vadSettings;
    } else if ([viewId isEqualToString: VIEW_AU]) {
        return self.auSettings;
    } else if ([viewId isEqualToString: VIEW_AFP]) {
        return self.afpSettings;
    } else if ([viewId isEqualToString: VIEW_KWS]) {
        return self.kwsSettings;
    } else if ([viewId isEqualToString: VIEW_TEST_AFP]) {
        return self.testAfpSettings;
    } else if ([viewId isEqualToString: VIEW_TEST_ASR_OFFLINE_RTF]) {
        return self.testAsrOfflineRtfSettings;
    } else if ([viewId isEqualToString: VIEW_TEST_ASR_STRESS]) {
        return self.testAsrStressSettings;
    } else {
        NSLog( @"View id %@ is not found yet!", viewId);
    }
    return [Settings build];
}

@end

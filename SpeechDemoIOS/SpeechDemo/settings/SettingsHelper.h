//
//  SettingsHelper.h
//  SpeechDemo
//
//  Created by bytedance on 2020/9/9.
//  Copyright © 2020 fengkai.0518. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "Settings.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - SETTING_KEY

// view id
extern NSString *const VIEW_ASR;
extern NSString *const VIEW_ASR_OFFLINE;
extern NSString *const VIEW_AU;
extern NSString *const VIEW_BIGASR;
extern NSString *const VIEW_AFP;
extern NSString *const VIEW_CAPT;
extern NSString *const VIEW_FULLLINK;
extern NSString *const VIEW_TTS;
extern NSString *const VIEW_BITTS;
extern NSString *const VIEW_UNITTS;
extern NSString *const VIEW_VOICECLONE;
extern NSString *const VIEW_VOICECONV;
extern NSString *const VIEW_DIALOG;
extern NSString *const VIEW_DIALOG_DELEGATE;
extern NSString *const VIEW_DIALOG_DUPLEX;
extern NSString *const VIEW_VAD;
extern NSString *const VIEW_KWS;
extern NSString *const VIEW_TEST_AFP;
extern NSString *const VIEW_TEST_ASR_OFFLINE_RTF;
extern NSString *const VIEW_TEST_ASR_STRESS;

// common
extern NSString *const SETTING_COMMON;
extern NSString *const SETTING_API_KEY;
extern NSString *const SETTING_APPID;
extern NSString *const SETTING_APPKEY;
extern NSString *const SETTING_TOKEN;
extern NSString *const SETTING_CLUSTER;
extern NSString *const SETTING_RESOURCE_ID;
extern NSString *const SETTING_ADDRESS;
extern NSString *const SETTING_URI;
extern NSString *const SETTING_VOICE;
extern NSString *const SETTING_VOICE_TYPE;
extern NSString *const SETTING_ONLINE_VOICE;
extern NSString *const SETTING_ONLINE_VOICE_TYPE;
extern NSString *const SETTING_OFFLINE_VOICE;
extern NSString *const SETTING_OFFLINE_VOICE_TYPE;
extern NSString *const SETTING_GET_VOLUME;
extern NSString *const SETTING_RECORD_TYPE;
extern NSString *const SETTING_RECORD_SAVE;
extern NSString *const SETTING_RECORD_FILE_TYPE;
extern NSString *const SETTING_SAMPLE_RATE;
extern NSString *const SETTING_CHANNEL;
extern NSString *const SETTING_ENABLE_AEC;
extern NSString *const SETTING_RESTART_AUDIO_SESSION_ENABLE;
extern NSString *const SETTING_RESUME_OTHERS_INTERRUPTED_PLAYBACK_ENABLE;
extern NSString *const SETTING_LICENSE_NAME;
extern NSString *const SETTING_LICENSE_BUSI_ID;
extern NSString *const SETTING_AUTHENTICATION_TYPE;
extern NSString *const SETTING_BUSINESS_KEY;
extern NSString *const SETTING_AUTHENTICATE_SECRET;
extern NSString *const SETTING_DISABLE_WS_RECONNECT;
extern NSString *const SETTING_AUDIO_FADEOUT_DURATION;
extern NSString *const SETTING_VAD_MAX_SPEECH_DURATION;
extern NSString *const SETTING_VAD_MAX_MUSIC_DURATION;
extern NSString *const SETTING_STREAM_PACKAGE_DURATION;
extern NSString *const SETTING_REQUEST_HEADERS;
extern NSString *const SETTING_ENABLE_PLAYER_AUDIO_CALL_BACK;

// asr
extern NSString *const SETTING_ASR;
extern NSString *const SETTING_ASR_RECORDER_SAVE;
extern NSString *const SETTING_ASR_ENABLE_DDC;
extern NSString *const SETTING_ASR_ENABLE_ITN;
extern NSString *const SETTING_ASR_ENABLE_NLU_PUNC;
extern NSString *const SETTING_ASR_DISABLE_END_PUNC;
extern NSString *const SETTING_ASR_KEEP_RECORDING;
extern NSString *const SETTING_ASR_HOTWORDS;
extern NSString *const SETTING_ASR_CORRECTWORDS;
extern NSString *const SETTING_ASR_VAD_START_SILENCE_TIME;
extern NSString *const SETTING_ASR_VAD_END_SILENCE_TIME;
extern NSString *const SETTING_ASR_VAD_MODE;
extern NSString *const SETTING_ASR_RESULT_TYPE;
extern NSString *const SETTING_ASR_MAX_RETRY_TIMES;
extern NSString *const SETTING_ASR_SHOW_LANGUAGE;
extern NSString *const SETTING_ASR_LANGUAGE;
extern NSString *const SETTING_ASR_AUTO_STOP;
extern NSString *const SETTING_ASR_MODEL_NAME;
extern NSString *const SETTING_ASR_REQ_PARAMS;
extern NSString *const SETTING_ASR_ENABLE_RESOURCE_DOWNLOAD;

// capt
extern NSString *const SETTING_CAPT;
extern NSString *const SETTING_CAPT_RECORDER_SAVE;
extern NSString *const SETTING_CAPT_STREAMING_MODE;
extern NSString *const SETTING_CAPT_CORE_TYPE;
extern NSString *const SETTING_CAPT_DIFFICULTY_LEVEL;

// fulllink
extern NSString *const SETTING_FULLLINK;
extern NSString *const SETTING_FULLLINK_ENGINE_TYPE;
extern NSString *const SETTING_FULLLINK_WAKEUP_WORDS;
extern NSString *const SETTING_FULLLINK_ENABLE_RECORDER_DUMP;
extern NSString *const SETTING_FULLLINK_ENABLE_KWS_DUMP;
extern NSString *const SETTING_FULLLINK_WAKEUP_MODE;
extern NSString *const SETTING_FULLLINK_ONLY_ASR;
extern NSString *const SETTING_FULLLINK_DISABLE_TTS;
extern NSString *const SETTING_FULLLINK_DISABLE_SIGNAL;
extern NSString *const SETTING_FULLLINK_DISABLE_DEVICE_TYPE;
extern NSString *const SETTING_FULLLINK_DISABLE_SIGTHREAD_PRI;
extern NSString *const SETTING_FULLLINK_DISABLE_FILE_OR_DIRECTORY_NAME;

// tts
extern NSString *const SETTING_TTS;
extern NSString *const SETTING_TTS_ONLINE_LANGUAGE;
extern NSString *const SETTING_TTS_OFFLINE_LANGUAGE;
extern NSString *const SETTING_PREVENT_PLAYER_CREATION;
extern NSString *const SETTING_TTS_ENABLE_RESUME_FROM_BREAKPOINT;
extern NSString *const SETTING_TTS_ENABLE_PLAYER;
extern NSString *const SETTING_TTS_ENABLE_DUMP;
extern NSString *const SETTING_TTS_ENABLE_DATA_CALLBACK;
extern NSString *const SETTING_TTS_ENABLE_WORD_LEVEL_PROGRESS_UPDATE;
extern NSString *const SETTING_TTS_ENABLE_CACHE;
extern NSString *const SETTING_TTS_WITH_INTENT;
extern NSString *const SETTING_TTS_LIMIT_CPU_USAGE;
extern NSString *const SETTING_TTS_TEXT_TYPE;
extern NSString *const SETTING_TTS_WORK_MODE;
extern NSString *const SETTING_TTS_SPEAK_SPEED;
extern NSString *const SETTING_TTS_AUDIO_VOLUME;
extern NSString *const SETTING_TTS_AUDIO_PITCH;
extern NSString *const SETTING_TTS_SAMPLE_RATE;
extern NSString *const SETTING_TTS_EMOTION;
extern NSString *const SETTING_TTS_MODEL_NAME;
extern NSString *const SETTING_TTS_SILENCE_DURATION;
extern NSString *const SETTING_TTS_OFFLINE_RESOURCE_FORMAT;
extern NSString *const SETTING_TTS_BACKEND_CLUSTER;
extern NSString *const SETTING_TTS_REQUEST_ID;
extern NSString *const SETTING_TTS_REQUEST_PARAMS;
extern NSString *const SETTING_TTS_SILENCE_DURATION;
extern NSString *const SETTING_TTS_USE_VOICECLONE_VOICE;

// voiceclone
extern NSString *const SETTING_VOICECLONE;
extern NSString *const SETTING_VOICECLONE_ADDRESS;
extern NSString *const SETTING_VOICECLONE_STREAM_ADDRESS;
extern NSString *const SETTING_VOICECLONE_UID;
extern NSString *const SETTING_VOICECLONE_QUERY_UIDS;
extern NSString *const SETTING_VOICECLONE_VOICE_TYPE;
extern NSString *const SETTING_VOICECLONE_GENDER;
extern NSString *const SETTING_VOICECLONE_TASKID;

// voiceconv
extern NSString *const SETTING_VOICECONV;
extern NSString *const SETTING_VOICECONV_RESULT_SAMPLE_RATE;
extern NSString *const SETTING_VOICECONV_ENABLE_RECORD_DUMP;
extern NSString *const SETTING_VOICECONV_ENABLE_RESULT_DUMP;
extern NSString *const SETTING_VOICECONV_REQUEST_INTERVAL;

// dialog
extern NSString *const SETTING_DIALOG;
extern NSString *const SETTING_DIALOG_ENABLE_RECORDER_DUMP;
extern NSString *const SETTING_DIALOG_ENABLE_PLAYER_DUMP;
extern NSString *const SETTING_DIALOG_BOT_NAME;

// vad
extern NSString *const SETTING_VAD;
extern NSString *const SETTING_VAD_RECORDER_SAVE;
extern NSString *const SETTING_VAD_HEAD_SILENCE_THRESHOLD;
extern NSString *const SETTING_VAD_TAIL_SILENCE_THRESHOLD;

// au
extern NSString *const SETTING_AU;
extern NSString *const SETTING_AU_ABILITY;
extern NSString *const SETTING_AU_RECORDER_SAVE;
extern NSString *const SETTING_AU_PROCESS_TIMEOUT;
extern NSString *const SETTING_AU_AUDIO_PACKET_DURATION;
extern NSString *const SETTING_AU_EMPTY_PACKET_INTERVAL;

// afp
extern NSString *const SETTING_AFP;
extern NSString *const SETTING_MUSIC_ENGINE_NAME;
extern NSString *const SETTING_AFP_RESULT_TYPE;
extern NSString *const SETTING_AFP_INSTANCE_NUMBER;

// kws
extern NSString *const SETTING_KWS;
extern NSString *const SETTING_KWS_CUSTOM_WORDS;
extern NSString *const SETTING_KWS_MODEL_NAME;

// asr test
extern NSString *const SETTING_ASR_STRESS;
extern NSString *const SETTING_ASR_STRESS_SCENEID;

#pragma mark - SETTING_HELPER
@interface SettingsHelper : NSObject

+ (instancetype)shareInstance;

- (Settings*)getSettings:(NSString*)engine;

@end

NS_ASSUME_NONNULL_END

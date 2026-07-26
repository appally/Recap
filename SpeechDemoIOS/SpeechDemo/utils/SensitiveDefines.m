//
//  SensitiveDefines.m
//  SpeechDemo
//
//  Created by bytedance on 2022/12/9.
//  Copyright © 2022 tianlei.richard. All rights reserved.
//

#import <Foundation/Foundation.h>

#import "SensitiveDefines.h"


// User Info
const NSString* SDEF_UID = @"YOUR UID";

// Online & Resource Authentication
const NSString* SDEF_API_KEY = @"YOUR API KEY";
const NSString* SDEF_APPID = @"YOUR APPID";
const NSString* SDEF_APPKEY = @"YOUR APPKEY";
const NSString* SDEF_TOKEN = @"YOUR TOKEN";
const NSString* SDEF_APP_VERSION = @"YOUR APP VERSION";

// Offline Authentication
const NSString* SDEF_AUTHENTICATE_ADDRESS = @"AUTHENTICAT ADDRESS";
const NSString* SDEF_AUTHENTICATE_URI = @"AUTHENTICATE URI";
const NSString* SDEF_SECRET = @"YOUR SECRET";
const NSString* SDEF_BUSINESS_KEY = @"YOUR BUSINESS KEY";
const NSString* SDEF_LICENSE_NAME = @"YOUR LICENSE NAME";
const NSString* SDEF_LICENSE_BUSI_ID = @"YOUR LICENSE BUSI_ID";

// Address
const NSString* SDEF_DEFAULT_ADDRESS = @"wss://openspeech.bytedance.com";
const NSString* SDEF_DEFAULT_HTTP_ADDRESS = @"https://openspeech.bytedance.com";

// ASR
const NSString* SDEF_ASR_DEFAULT_CLUSTER = @"YOUR ASR CLUSTER";
const NSString* SDEF_ASR_DEFAULT_URI = @"/api/v2/asr";
const NSString* SDEF_ASR_DEFAULT_MODEL_NAME = @"YOUR ASR MODEL NAME";

// BigASR
const NSString* SDEF_BIGASR_DEFAULT_APPID = @"YOUR APPID";
const NSString* SDEF_BIGASR_DEFAULT_TOKEN = @"YOUR TOKEN";
const NSString* SDEF_BIGASR_DEFAULT_RESOURCE_ID = @"YOUR RESOURCE ID";
const NSString* SDEF_BIGASR_DEFAULT_URI = @"/api/v3/sauc/bigmodel";

// AU
const NSString* SDEF_AU_DEFAULT_APP_ID = @"YOUR APPID";
const NSString* SDEF_AU_DEFAULT_ADDRESS = @"wss://openspeech.bytedance.com";
const NSString* SDEF_AU_DEFAULT_URI = @"/api/v1/sauc";
const NSString* SDEF_AU_DEFAULT_CLUSTER = @"YOUR AU CLUSTER";

// TTS
const NSString* SDEF_TTS_DEFAULT_URI = @"/api/v1/tts/ws_binary";
const NSString* SDEF_TTS_DEFAULT_CLUSTER = @"YOUR TTS CLUSTER";
const NSString* SDEF_TTS_DEFAULT_BACKEND_CLUSTER = @"YOUR TTS BACKEND CLUSTER";
const NSString* SDEF_TTS_DEFAULT_ONLINE_VOICE = @"YOUR TTS ONLINE VOICE";
const NSString* SDEF_TTS_DEFAULT_ONLINE_VOICE_TYPE = @"YOUR TTS ONLINE VOICE TYPE";
const NSString* SDEF_TTS_DEFAULT_OFFLINE_VOICE = @"YOUR TTS OFFLINE VOICE";
const NSString* SDEF_TTS_DEFAULT_OFFLINE_VOICE_TYPE = @"YOUR TTS OFFLINE VOICE TYPE";
const NSString* SDEF_TTS_DEFAULT_ONLINE_LANGUAGE = @"YOUT TTS ONLINE LANGUAGE";
const NSString* SDEF_TTS_DEFAULT_OFFLINE_LANGUAGE = @"YOUT TTS OFFLINE LANGUAGE";
const NSArray* SDEF_TTS_DEFAULT_DOWNLOAD_OFFLINE_VOICES() { return @[]; }

// BITTS
const NSString* SDEF_BITTS_DEFAULT_APPID=@"YOUR BITTS APPID";
const NSString* SDEF_BITTS_DEFAULT_TOKEN = @"YOUR BITTS TOKEN";
const NSString* SDEF_BITTS_DEFAULT_RESOURCE_ID = @"YOUR BITTS RESOURCE ID";
const NSString* SDEF_BITTS_DEFAULT_URI = @"/api/v3/tts/bidirection";

// UNITTS
const NSString* SDEF_UNITTS_DEFAULT_APPID=@"YOUR UNITTS APPID";
const NSString* SDEF_UNITTS_DEFAULT_TOKEN = @"YOUR UNITTS TOKEN";
const NSString* SDEF_UNITTS_DEFAULT_RESOURCE_ID = @"YOUR UNITTS RESOURCE ID";
const NSString* SDEF_UNITTS_DEFAULT_URI = @"/api/v3/tts/unidirectional/stream";

// VoiceClone
const NSString* SDEF_VOICECLONE_DEFAULT_UIDS = @"uid_1;uid_2";
int SDEF_VOICECLONE_DEFAULT_TASK_ID = -1;

// VoiceConv
const NSString* SDEF_VOICECONV_DEFAULT_URI = @"/api/v1/voice_conv/ws";
const NSString* SDEF_VOICECONV_DEFAULT_CLUSTER = @"YOUR VOICECONV CLUSTER";
const NSString* SDEF_VOICECONV_DEFAULT_VOICE = @"VOICECONV VOICE";
const NSString* SDEF_VOICECONV_DEFAULT_VOICE_TYPE = @"VOICECONV VOICE TYPE";

// Fulllink
const NSString* SDEF_FULLLINK_DEFAULT_URI = @"FULLLINK URI";

// Dialog
const NSString* SDEF_DIALOG_DEFAULT_URI = @"/api/v3/realtime/dialogue";
const NSString* SDEF_DIALOG_DEFAULT_RESOURCE_ID = @"DIALOG RESOURCE ID";
const NSString* SDEF_DIALOG_DUPLEX_DEFAULT_URI = @"/api/v3/duplex/realtime/dialogue";
const NSString* SDEF_DIALOG_DUPLEX_DEFAULT_RESOURCE_ID = @"DIALOG DUPLEX RESOURCE ID";

// CAPT
const NSString* SDEF_CAPT_DEFAULT_MDD_URI = @"CAPT MDD URI";
const NSString* SDEF_CAPT_DEFAULT_CLUSTER = @"YOUR CAPT CLUSTER";

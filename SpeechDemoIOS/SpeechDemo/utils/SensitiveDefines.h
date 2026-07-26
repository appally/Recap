//
//  SensitiveDefines.h
//  SpeechDemo
//
//  Created by bytedance on 2022/12/9.
//  Copyright © 2022 tianlei.richard. All rights reserved.
//

#define SensitiveDefines_h

/**
 * SensitiveDefines
 * Defines in this class should be different for different business,
 * please contact with @Bytedance AILab about what value should be set before use it.
 */

// User Info
extern NSString* SDEF_UID;

// Online & Resource Authentication
extern NSString* SDEF_API_KEY;
extern NSString* SDEF_APPID;
extern NSString* SDEF_APPKEY;
extern NSString* SDEF_TOKEN;
extern NSString* SDEF_APP_VERSION;

// Offline Authentication
extern NSString* SDEF_AUTHENTICATE_ADDRESS;
extern NSString* SDEF_AUTHENTICATE_URI;
extern NSString* SDEF_SECRET;
extern NSString* SDEF_BUSINESS_KEY;
extern NSString* SDEF_LICENSE_NAME;
extern NSString* SDEF_LICENSE_BUSI_ID;

// Address
extern NSString* SDEF_DEFAULT_ADDRESS;
extern NSString* SDEF_DEFAULT_HTTP_ADDRESS;

// ASR
extern NSString* SDEF_ASR_DEFAULT_CLUSTER;
extern NSString* SDEF_ASR_DEFAULT_URI;
extern NSString* SDEF_ASR_DEFAULT_MODEL_NAME;

// BigASR
extern NSString* SDEF_BIGASR_DEFAULT_APPID;
extern NSString* SDEF_BIGASR_DEFAULT_TOKEN;
extern NSString* SDEF_BIGASR_DEFAULT_RESOURCE_ID;
extern NSString* SDEF_BIGASR_DEFAULT_URI;

// AU
extern const NSString* SDEF_AU_DEFAULT_APP_ID;
extern const NSString* SDEF_AU_DEFAULT_ADDRESS;
extern const NSString* SDEF_AU_DEFAULT_URI;
extern const NSString* SDEF_AU_DEFAULT_CLUSTER;

// TTS
extern NSString* SDEF_TTS_DEFAULT_URI;
extern NSString* SDEF_TTS_DEFAULT_CLUSTER;
extern NSString* SDEF_TTS_DEFAULT_BACKEND_CLUSTER;
extern NSString* SDEF_TTS_DEFAULT_ONLINE_VOICE;
extern NSString* SDEF_TTS_DEFAULT_ONLINE_VOICE_TYPE;
extern NSString* SDEF_TTS_DEFAULT_OFFLINE_VOICE;
extern NSString* SDEF_TTS_DEFAULT_OFFLINE_VOICE_TYPE;
extern NSString* SDEF_TTS_DEFAULT_ONLINE_LANGUAGE;
extern NSString* SDEF_TTS_DEFAULT_OFFLINE_LANGUAGE;
const NSArray* SDEF_TTS_DEFAULT_DOWNLOAD_OFFLINE_VOICES();

// BITTS
extern NSString* SDEF_BITTS_DEFAULT_APPID;
extern NSString* SDEF_BITTS_DEFAULT_TOKEN;
extern NSString* SDEF_BITTS_DEFAULT_RESOURCE_ID;
extern NSString* SDEF_BITTS_DEFAULT_URI;

// UNITTS
extern NSString* SDEF_UNITTS_DEFAULT_APPID;
extern NSString* SDEF_UNITTS_DEFAULT_TOKEN;
extern NSString* SDEF_UNITTS_DEFAULT_RESOURCE_ID;
extern NSString* SDEF_UNITTS_DEFAULT_URI;

// VoiceClone
extern NSString* SDEF_VOICECLONE_DEFAULT_UIDS;
extern int SDEF_VOICECLONE_DEFAULT_TASK_ID;

// VoiceConv
extern NSString* SDEF_VOICECONV_DEFAULT_URI;
extern NSString* SDEF_VOICECONV_DEFAULT_CLUSTER;
extern NSString* SDEF_VOICECONV_DEFAULT_VOICE;
extern NSString* SDEF_VOICECONV_DEFAULT_VOICE_TYPE;

// Fulllink
extern NSString* SDEF_FULLLINK_DEFAULT_URI;

// Dialog
extern NSString* SDEF_DIALOG_DEFAULT_URI;
extern NSString* SDEF_DIALOG_DEFAULT_RESOURCE_ID;
extern NSString* SDEF_DIALOG_DUPLEX_DEFAULT_URI;
extern NSString* SDEF_DIALOG_DUPLEX_DEFAULT_RESOURCE_ID;

// CAPT
extern NSString* SDEF_CAPT_DEFAULT_MDD_URI;
extern NSString* SDEF_CAPT_DEFAULT_CLUSTER;

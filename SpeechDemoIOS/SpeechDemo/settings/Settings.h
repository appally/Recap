//
//  Settings.h
//  SpeechDemo
//
//  Created by bytedance on 2021/3/26.
//  Copyright © 2021 chengzihao.ds. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
#pragma mark - SettingType
typedef NS_ENUM(NSInteger, SettingType) {
    kSettingGroup = 0,
    kSettingBool = 1,
    kSettingNumber = 2,
    kSettingString = 3,
    kSettingOptions = 4,
};

#pragma mark - SettingOptions
@interface SettingOptions : NSObject
@property (strong, nonatomic) NSArray* optionsArray;
@property (assign, nonatomic) int chooseIdx;

+ (instancetype)build:(NSArray*)ops choose:(int)idx;
@end

#pragma mark - SettingItem
@interface SettingItem : NSObject
@property (assign, nonatomic) SettingType type;
@property (strong, nonatomic) NSString* key;
@property (strong, nonatomic) NSObject* value;
@property (strong, nonatomic) NSString* hint;

+ (instancetype)build:(SettingType)type key:(NSString*)key val:(NSObject*)val hint:(NSString*)hint;

+ (instancetype)buildGroup:(NSString*)key val:(NSString*)val hint:(NSString*)hint;
+ (instancetype)buildBool:(NSString*)key val:(BOOL)val hint:(NSString*)hint;
+ (instancetype)buildInt:(NSString *)key val:(int)val hint:(NSString *)hint;
+ (instancetype)buildDouble:(NSString *)key val:(double)val hint:(NSString *)hint;
+ (instancetype)buildString:(NSString*)key val:(NSString*)val hint:(NSString*)hint;
+ (instancetype)buildOptions:(NSString*)key val:(SettingOptions*)val hint:(NSString*)hint;
@end

#pragma mark - Settings
@interface Settings : NSObject
// kSettingGroup type, use SettingItem 1 dimension array.
@property (strong, nonatomic) NSMutableArray* groups;
// other type, use SettingItem 2 dimension array. 1st dimension for each group, 2nd dimension for detail SettingItem in group.
@property (strong, nonatomic) NSMutableArray* configs;

+ (instancetype)build;

- (void)registerItems:(NSArray*)cfgs;

- (void)setBool:(NSString*)key;
- (void)setBool:(NSString*)key val:(BOOL)val;
- (void)setInt:(NSString*)key;
- (void)setInt:(NSString*)key val:(int)val;
- (void)setDouble:(NSString*)key;
- (void)setDouble:(NSString*)key val:(double)val;
- (void)setString:(NSString*)key;
- (void)setString:(NSString*)key val:(NSString*)val;
- (void)setOptions:(NSString*)key;
- (void)setOptions:(NSString*)key val:(SettingOptions*)val;

- (BOOL)getBool:(NSString*)key;
- (BOOL)getBool:(NSString*)key def:(BOOL)def;
- (int)getInt:(NSString*)key;
- (int)getInt:(NSString*)key def:(int)def;
- (double)getDouble:(NSString*)key;
- (double)getDouble:(NSString*)key def:(double)def;
- (NSString*)getString:(NSString*)key;
- (NSString*)getString:(NSString*)key def:(NSString*)def;
- (SettingOptions*)getOptions:(NSString*)key;
- (SettingOptions*)getOptions:(NSString*)key def:(SettingOptions*)def;
- (NSString*)getOptionsValue:(NSString*)key;

@end

NS_ASSUME_NONNULL_END


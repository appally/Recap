//
//  Settings.m
//  SpeechDemo
//
//  Created by bytedance on 2021/3/26.
//  Copyright © 2021 chengzihao.ds. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "Settings.h"

#pragma mark - SettingOptions
@implementation SettingOptions

+ (instancetype)build:(NSArray*)ops choose:(int)idx {
    SettingOptions* instance = [[self alloc] init];
    instance.optionsArray = ops;
    instance.chooseIdx = idx;
    return instance;
}

@end

#pragma mark - SettingItem
@implementation SettingItem

+ (instancetype)build:(SettingType)type key:(NSString*)key val:(NSObject*)val hint:(NSString*)hint {
    SettingItem* instance = [[self alloc] init];
    instance.key = key;
    instance.type = type;
    instance.value = val;
    instance.hint = hint;
    return instance;
}

+ (instancetype)buildGroup:(NSString*)key val:(NSString*)val hint:(NSString*)hint {
    return [SettingItem build:kSettingGroup key:key val:val hint:hint];
}

+ (instancetype)buildBool:(NSString*)key val:(BOOL)val hint:(NSString*)hint {
    return [SettingItem build:kSettingBool key:key val:val ? @1 : @0 hint:hint];
}

+ (instancetype)buildInt:(NSString*)key val:(int)val hint:(NSString*)hint {
    return [SettingItem build:kSettingNumber key:key val:[NSNumber numberWithInt:val] hint:hint];
}

+ (instancetype)buildDouble:(NSString*)key val:(double)val hint:(NSString*)hint {
    return [SettingItem build:kSettingNumber key:key val:[NSNumber numberWithDouble:val] hint:hint];
}

+ (instancetype)buildString:(NSString*)key val:(NSString*)val hint:(NSString*)hint {
    return [SettingItem build:kSettingString key:key val:val hint:hint];
}

+ (instancetype)buildOptions:(NSString*)key val:(SettingOptions*)val hint:(NSString*)hint {
    return [SettingItem build:kSettingOptions key:key val:val hint:hint];
}

@end

#pragma mark - Settings
@implementation Settings

+ (instancetype)build {
    Settings* instance = [[self alloc] init];
    instance.groups = [[NSMutableArray alloc]init];
    instance.configs = [[NSMutableArray alloc]init];
    // configs has at least one group
    [instance.configs addObject:[[NSMutableArray alloc] init]];
    return instance;
}

- (void)setItem:(SettingItem*)item {
    if (item.type == kSettingGroup) {
        // group type
        for (int i = 0; i < _groups.count; ++i) {
            SettingItem* groupItem = _groups[i];
            if ([groupItem.key isEqualToString:item.key]) {
                // same group exist, do nothing
                return;
            }
        }
        
        [_groups addObject:item];
        
        NSMutableArray* group = _configs[0];
        if (_configs.count == 1 && group.count == 0) {
            // first group has no items yet, means this is first group
            return;
        }
        // append new group
        [_configs addObject:[[NSMutableArray alloc] init]];
        return;
    } else {
        // other type
        NSMutableArray* group = NULL;
        for (int i = 0; i < _configs.count; ++i) {
            group = _configs[i];
            for (int j = 0; j < group.count; ++j) {
                SettingItem* cur = group[j];
                if ([cur.key isEqualToString:item.key]) {
                    _configs[i][j] = item;
                    return;
                }
            }
        }
        // default add to last group
        [group addObject:item];
    }
}

- (SettingItem*)getItem:(NSString*)key type:(SettingType)type {
    if (type == kSettingGroup) {
        // group type
        for (int i = 0; i < _groups.count; ++i) {
            SettingItem* cur = _groups[i];
            if ([cur.key isEqualToString:key]) {
                return cur;
            }
        }
        return NULL;
    } else {
        // other type
        for (int i = 0; i < _configs.count; ++i) {
            NSMutableArray* group = _configs[i];
            for (int j = 0; j < group.count; ++j) {
                SettingItem* cur = group[j];
                if ([cur.key isEqualToString:key]) {
                    if (cur.type == type) {
                        return cur;
                    }
                    return NULL;
                }
            }
        }
        return NULL;
    }
    return NULL;
}

- (void)registerItems:(NSArray*)cfgs {
    for (int i = 0; i < cfgs.count; ++i) {
        [self setItem:cfgs[i]];
    }
}

- (void)setBool:(NSString*)key {
    [self setBool:key val:false];
}

- (void)setBool:(NSString*)key val:(BOOL)val {
    [self setItem:[SettingItem buildBool:key val:val hint:@""]];
}

- (void)setInt:(NSString*)key {
    [self setInt:key val:0];
}

- (void)setInt:(NSString*)key val:(int)val {
    [self setItem:[SettingItem buildInt:key val:val hint:@""]];
}

- (void)setDouble:(NSString*)key {
    [self setDouble:key val:0.];
}

- (void)setDouble:(NSString*)key val:(double)val {
    [self setItem:[SettingItem buildDouble:key val:val hint:@""]];
}

- (void)setString:(NSString*)key {
    [self setString:key val:@""];
}

- (void)setString:(NSString*)key val:(NSString*)val {
    [self setItem:[SettingItem buildString:key val:val hint:@""]];
}

- (void)setOptions:(NSString*)key {
    [self setOptions:key val:[SettingOptions build:@[] choose:0]];
}

- (void)setOptions:(NSString*)key val:(SettingOptions*)val {
    [self setItem:[SettingItem buildOptions:key val:val hint:@""]];
}

- (BOOL)getBool:(NSString*)key {
    return [self getBool:key def:false];
}

- (BOOL)getBool:(NSString*)key def:(BOOL)def {
    SettingItem* item = [self getItem:key type:kSettingBool];
    if (item != NULL) {
        NSNumber* val = (NSNumber*)item.value;
        return [val intValue] == 1;
    }
    return def;
}

- (int)getInt:(NSString*)key {
    return [self getInt:key def:0];
}

- (int)getInt:(NSString*)key def:(int)def {
    SettingItem* item = [self getItem:key type:kSettingNumber];
    if (item != NULL) {
        NSNumber* val = (NSNumber*)item.value;
        return [val intValue];
    }
    return def;
}

- (double)getDouble:(NSString*)key {
    return [self getDouble:key def:0];
}

- (double)getDouble:(NSString*)key def:(double)def {
    SettingItem* item = [self getItem:key type:kSettingNumber];
    if (item != NULL) {
        NSNumber* val = (NSNumber*)item.value;
        return [val doubleValue];
    }
    return def;
}

- (NSString*)getString:(NSString*)key {
    return [self getString:key def:@""];
}

- (NSString*)getString:(NSString*)key def:(NSString*)def {
    SettingItem* item = [self getItem:key type:kSettingString];
    if (item != NULL) {
        return (NSString*)item.value;
    }
    return def;
}

- (SettingOptions*)getOptions:(NSString*)key {
    return [self getOptions:key def:[SettingOptions build:@[] choose:0]];
}

- (SettingOptions*)getOptions:(NSString*)key def:(SettingOptions*)def {
    SettingItem* item = [self getItem:key type:kSettingOptions];
    if (item != NULL) {
        return (SettingOptions*)item.value;
    }
    return def;
}

- (NSString*)getOptionsValue:(NSString*)key {
    SettingItem* item = [self getItem:key type:kSettingOptions];
    if (item != NULL) {
        SettingOptions *options = (SettingOptions*)item.value;
        return options.optionsArray[options.chooseIdx];
    }
    return @"";
}

@end

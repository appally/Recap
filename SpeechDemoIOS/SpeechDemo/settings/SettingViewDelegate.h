//
//  SettingViewDelegate.h
//  SpeechDemo
//
//  Created by bytedance on 2021/3/26.
//  Copyright © 2021 chengzihao.ds. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "Settings.h"

#pragma mark - SettingItemCell
@interface SettingItemCell : UITableViewCell<UITextFieldDelegate>
@property (weak, nonatomic) Settings *settings;
@property (weak, nonatomic) UITableView* parent;

-(void)init:(Settings*)settings parent:(UITableView*)parent;
-(SettingItem*)getCorrespondItem;

- (BOOL)textFieldShouldReturn:(UITextField *)textField;
@end

#pragma mark - SettingBoolCell
@interface SettingBoolCell : SettingItemCell
@property (weak, nonatomic) IBOutlet UILabel *keyLabel;
@property (weak, nonatomic) IBOutlet UISwitch *valSwitch;

-(void)switchAction:(UISwitch*)sender;
@end

#pragma mark - SettingIntCell
@interface SettingNumberCell : SettingItemCell
@property (weak, nonatomic) IBOutlet UILabel *keyLabel;
@property (weak, nonatomic) IBOutlet UITextField *valTextField;

-(void)textFieldDidChange :(UITextField *)textField;
@end

#pragma mark - SettingStringCell
@interface SettingStringCell : SettingItemCell
@property (weak, nonatomic) IBOutlet UILabel *keyLabel;
@property (weak, nonatomic) IBOutlet UITextField *valTextField;

-(void)textFieldDidChange :(UITextField *)textField;
@end

#pragma mark - SettingOptionsCell
@interface SettingOptionsCell : SettingItemCell<UIPickerViewDelegate, UIPickerViewDataSource>

@property (weak, nonatomic) IBOutlet UILabel *keyLabel;
@property (weak, nonatomic) IBOutlet UITextField *valTextField;
@property (strong, nonatomic) UIPickerView *pickerView;
@property (strong, nonatomic) UIToolbar *pickerToolbar;

-(void)pickerConfirm;
-(void)pickerCancel;
@end

#pragma mark - SettingViewDelegate
@interface SettingViewDelegate : NSObject<UITableViewDelegate, UITableViewDataSource>
@property (strong, nonatomic) Settings* settings;

+ (instancetype)build:(Settings*)settings;

@end


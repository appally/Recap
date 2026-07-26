//
//  SettingViewDelegate.m
//  SpeechDemo
//
//  Created by bytedance on 2021/3/26.
//  Copyright © 2021 chengzihao.ds. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "SettingViewDelegate.h"

#pragma mark - SettingItemCell
@implementation SettingItemCell

-(void)init:(Settings*)settings parent:(UITableView*)parent {
    self.settings = settings;
    self.parent = parent;
}

-(SettingItem*)getCorrespondItem {
    NSIndexPath* path = [self.parent indexPathForCell:self];
    NSMutableArray* group = self.settings.configs[path.section];
    return group[path.row];
}

// auto close keyboard when click return
- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return NO;
}
@end


#pragma mark - SettingBoolCell
@implementation SettingBoolCell

-(void)init:(Settings*)settings parent:(UITableView*)parent {
    [super init:settings parent:parent];
    [self.valSwitch addTarget:self action:@selector(switchAction:) forControlEvents:UIControlEventValueChanged];
}

-(void)switchAction:(UISwitch*)sender {
    SettingItem* item = [self getCorrespondItem];
    [self.settings setBool:item.key val:sender.isOn];
}

@end

#pragma mark - SettingNumberCell
@implementation SettingNumberCell

-(void)init:(Settings*)settings parent:(UITableView*)parent {
    [super init:settings parent:parent];
    self.valTextField.delegate = self;
    [self.valTextField addTarget:self action:@selector(textFieldDidChange:) forControlEvents:UIControlEventEditingChanged];
}

-(void)textFieldDidChange :(UITextField *)textField {
    SettingItem* item = [self getCorrespondItem];
    // if input empty, do nothing
    if ([textField.text length] > 0) {
        [self.settings setDouble:item.key val:[textField.text doubleValue]];
    }
}

@end

#pragma mark - SettingStringCell
@implementation SettingStringCell

-(void)init:(Settings*)settings parent:(UITableView*)parent {
    [super init:settings parent:parent];
    self.valTextField.delegate = self;
    [self.valTextField addTarget:self action:@selector(textFieldDidChange:) forControlEvents:UIControlEventEditingChanged];
}

-(void)textFieldDidChange :(UITextField *)textField {
    SettingItem* item = [self getCorrespondItem];
    [self.settings setString:item.key val:textField.text];
}

@end

#pragma mark - SettingOptionsCell
@implementation SettingOptionsCell

-(void)init:(Settings*)settings parent:(UITableView*)parent {
    [super init:settings parent:parent];

    // init picker view
    self.pickerView = [[UIPickerView alloc] init];
    self.pickerView.dataSource = self;
    self.pickerView.delegate = self;

    // init picker toolbar
    self.pickerToolbar = [[UIToolbar alloc]initWithFrame:
                          CGRectMake(0, self.frame.size.height-
                                     self.pickerView.frame.size.height-20, self.bounds.size.width, 40)];
    UIBarButtonItem *confirmBtn = [[UIBarButtonItem alloc] initWithTitle:@"Confirm" style:UIBarButtonItemStyleDone target:self action:@selector(pickerConfirm)];
    UIBarButtonItem *flexibleBBI = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    [self.pickerToolbar setBarStyle:UIBarStyleDefault];
    NSArray *toolbarItems = [NSArray arrayWithObjects:flexibleBBI, confirmBtn, nil];
    [self.pickerToolbar setItems:toolbarItems];
    
    // show pickerView
    self.valTextField.delegate = self;
    self.valTextField.inputView = self.pickerView;
    self.valTextField.inputAccessoryView = self.pickerToolbar;
}

// PickerView width
- (CGFloat)pickerView:(UIPickerView *)pickerView widthForComponent:(NSInteger)component {
    return self.bounds.size.width;
}

// PickerView select event
- (void)pickerView:(UIPickerView *)pickerView didSelectRow:(NSInteger)row inComponent:(NSInteger)component {
    SettingItem* item = [self getCorrespondItem];
    SettingOptions* options = (SettingOptions*)item.value;
    options.chooseIdx = (int)row;
    [self.settings setOptions:item.key val:options];
    [self.valTextField setText:options.optionsArray[row]];
}

// PickerView show options
-(NSString*)pickerView:(UIPickerView *)pickerView titleForRow:(NSInteger)row forComponent:(NSInteger)component {
    SettingItem* item = [self getCorrespondItem];
    SettingOptions* options = (SettingOptions*)item.value;
    return options.optionsArray[row];
}

// PickerView column number
- (NSInteger)numberOfComponentsInPickerView:(UIPickerView *)pickerView {
    return 1;
}

// PickerView row number for each column
- (NSInteger)pickerView:(UIPickerView *)pickerView numberOfRowsInComponent:(NSInteger)component {
    SettingItem* item = [self getCorrespondItem];
    return ((SettingOptions*)item.value).optionsArray.count;
}

// PickerToolbar confirm button click event
-(void)pickerConfirm {
    if ([self.valTextField isFirstResponder]) {
        [self.valTextField resignFirstResponder];
    }
}
@end

#pragma mark - SettingViewDelegate

@implementation SettingViewDelegate

static NSString* nibName = @"SpeechSettingItem";
static CGFloat sectionHeaderHeight = 30;
static CGFloat sectionFooterHeight = 30;

+ (instancetype)build:(Settings*)settings {
    SettingViewDelegate* instance = [[self alloc] init];
    instance.settings = settings;
    return instance;
}

// row number for each section
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSMutableArray *curGroup = _settings.configs[section];
    NSLog(@"numberOfRowsInSection %ld", curGroup.count);
    return curGroup.count;
}

// section number
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    NSLog(@"numberOfSectionsInTableView %ld", _settings.groups.count);
    return _settings.groups.count;
}

// section title
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    SettingItem *groupItem = _settings.groups[section];
    return groupItem.key;
}

// section header height
- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return sectionHeaderHeight;
}

// section footer height
- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    return sectionFooterHeight;
}

// generate TableViewCell
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell* cell;
    NSMutableArray* group = _settings.configs[indexPath.section];
    SettingItem* item = group[indexPath.row];
    
    NSString *CellTableIndentifier = NULL;
    switch (item.type) {
        case kSettingBool:
            {
                CellTableIndentifier = @"SettingBool";
                SettingBoolCell* bCell = [tableView dequeueReusableCellWithIdentifier:CellTableIndentifier];
                if(bCell == nil) {
                    NSArray * nib = [[NSBundle mainBundle] loadNibNamed:nibName owner:self options:nil];
                    bCell = [nib objectAtIndex:item.type];
                    [bCell init:_settings parent:tableView];
                }
                [bCell.keyLabel setText:item.key];
                [bCell.valSwitch setOn:[(NSNumber*)item.value intValue] == 1];
                
                cell = bCell;
            }
            break;
        case kSettingNumber:
            {
                CellTableIndentifier = @"SettingNumber";
                SettingNumberCell *iCell = [tableView dequeueReusableCellWithIdentifier:CellTableIndentifier];
                if(iCell == nil) {
                    NSArray * nib = [[NSBundle mainBundle] loadNibNamed:nibName owner:self options:nil];
                    iCell = [nib objectAtIndex:item.type];
                    [iCell init:_settings parent:tableView];
                }
                [iCell.keyLabel setText:item.key];
                [iCell.valTextField setText:[(NSNumber*)item.value stringValue]];
                [iCell.valTextField setPlaceholder:(NSString*)item.hint];
                
                cell = iCell;
            }
            break;
        case kSettingString:
            {
                CellTableIndentifier = @"SettingString";
                SettingStringCell *sCell = [tableView dequeueReusableCellWithIdentifier:CellTableIndentifier];
                if(sCell == nil) {
                    NSArray * nib = [[NSBundle mainBundle] loadNibNamed:nibName owner:self options:nil];
                    sCell = [nib objectAtIndex:item.type];
                    [sCell init:_settings parent:tableView];
                }
                [sCell.keyLabel setText:item.key];
                [sCell.valTextField setText:(NSString*)item.value];
                [sCell.valTextField setPlaceholder:(NSString*)item.hint];
                
                cell = sCell;
            }
            break;
        case kSettingOptions:
            {
                CellTableIndentifier = @"SettingOptions";
                SettingOptionsCell *oCell = [tableView dequeueReusableCellWithIdentifier:CellTableIndentifier];
                if(oCell == nil) {
                    NSArray * nib = [[NSBundle mainBundle] loadNibNamed:nibName owner:self options:nil];
                    oCell = [nib objectAtIndex:item.type];
                    [oCell init:_settings parent:tableView];
                }
                SettingOptions *options = (SettingOptions*)item.value;
                [oCell.keyLabel setText:item.key];
                [oCell.valTextField setText:options.optionsArray[options.chooseIdx]];
                [oCell.valTextField setPlaceholder:item.hint];
                
                cell = oCell;
            }
            break;
        default:
            NSLog(@"Unsupported SettingType: %ld", item.type);
            break;
    }
    cell.accessibilityIdentifier = item.key;
    return cell;
}

@synthesize description;

@synthesize hash;

@synthesize superclass;

@end

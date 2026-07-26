//
//  SettingsViewController.m
//  SpeechDemo
//
//  Created by fangweiwei on 2020/2/28.
//  Copyright © 2020 fangweiwei. All rights reserved.
//

#import "SettingsViewController.h"
#import "SettingsHelper.h"
#import "SettingViewDelegate.h"

@interface SettingsViewController () <UITextFieldDelegate>

@property (weak, nonatomic) IBOutlet UITableView *settingTableView;
@property (strong, nonatomic) SettingViewDelegate *settingViewDelegate;

@end

@implementation SettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    SettingsHelper* settingsInstance = [SettingsHelper shareInstance];
    self.settingViewDelegate = [SettingViewDelegate build:[settingsInstance getSettings:self.viewId]];
    UITableView *tableView = self.settingTableView ?: self.tableView;
    tableView.delegate = self.settingViewDelegate;
    tableView.dataSource = self.settingViewDelegate;
}


#pragma mark - Navigation

// In a storyboard-based application, you will often want to do a little preparation before navigation
- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    // Get the new view controller using [segue destinationViewController].
    // Pass the selected object to the new view controller.
    [segue destinationViewController];
}


@end

//
//  IDYRecordingWindow.h
//  DYZB
//
//  Created by qiyun on 17/2/7.
//  Copyright © 2017年 mydouyu. All rights reserved.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
typedef void (^RecordingCloseBlock) (void);

@interface
IDYRecordingWindow : UIWindow

+ (instancetype)recordingWindowShareInstance;

// register new window to current view
- (void)showRecordingWindow;

// remove from superView , dealloc window
- (void)dismissRecordingWindow;

// close recording window response of callback
@property (copy, nonatomic, nonnull) RecordingCloseBlock    closeBlock;

@end

NS_ASSUME_NONNULL_END

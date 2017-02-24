//
//  IDYRecordingWindow.m
//  DYZB
//
//  Created by qiyun on 17/2/7.
//  Copyright © 2017年 mydouyu. All rights reserved.
//

#import "IDYRecordingWindow.h"
#import "IDYScreenRecorderManager.h"
#import <AVFoundation/AVFoundation.h>

@interface IDYRecordingWindow ()<UIGestureRecognizerDelegate>

@property (strong, nonatomic) UIImageView       *bottomImageView;
@property (strong, nonatomic) UIButton          *record;
@property (strong, nonatomic) UIProgressView    *progress;
@property (strong, nonatomic) CAShapeLayer      *toastShapeLayer;
@property (strong, nonatomic) AVPlayerLayer     *playerLayer;
@property (strong, nonatomic) AVPlayer          *player;
@property (strong, nonatomic) IDYScreenRecorderManager *recorder;

@end

#define kIDYTIME_FRAME_SECOND       0.2
#define kIDYTIME_EXECUTE_COUNT      ((1/kIDYTIME_FRAME_SECOND) * 10)
#define KIDYTIME_LIMIT_VALUE        ((1/kIDYTIME_FRAME_SECOND) * 3)
#define KIDYRECORDING_TOAST_MSG     @"录制时长不得少于3秒"

@implementation IDYRecordingWindow{
    
    CGFloat idy_window_height,idy_window_width;
    
    dispatch_queue_t     _idy_dispatch_queue;
    dispatch_source_t    _idy_dispatch_timer;
    
    NSInteger   _executeCount;
}

static IDYRecordingWindow *recordingWindow = NULL;
+ (instancetype)recordingWindowShareInstance{
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        
        recordingWindow = [[IDYRecordingWindow alloc] init];
        recordingWindow.recorder = [IDYScreenRecorderManager sharedInstance];
    });
    return recordingWindow;
}

- (id)init{
    
    if (self == [super init]) {
        
        _executeCount = 0;
        _idy_dispatch_queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
        
        [self configure];
    }
    return self;
}

#pragma mark    -   get method

- (UIImageView *)bottomImageView{
    
    if (!_bottomImageView) {
        
        idy_window_height = CGRectGetHeight(self.bounds);
        idy_window_width = CGRectGetWidth(self.bounds);
        
        _bottomImageView = [[UIImageView alloc] initWithFrame:CGRectMake(0,
                                                                         idy_window_height,
                                                                         idy_window_width,
                                                                         idy_window_height / 5)];
        
        _bottomImageView.backgroundColor = [[UIColor lightGrayColor] colorWithAlphaComponent:0.1];
        _bottomImageView.userInteractionEnabled = YES;
    }
    return _bottomImageView;
}


- (UIProgressView *)progress{
    
    if (!_progress) {
        
        _progress = [[UIProgressView alloc] initWithFrame:CGRectMake(0, 0, idy_window_width, 15)];
        _progress.progress = 0.0f;
        _progress.backgroundColor = [UIColor whiteColor];
        _progress.progressTintColor = [UIColor redColor];
    }
    return _progress;
}


- (CAShapeLayer *)toastShapeLayer{
    
    if (!_toastShapeLayer) {
        
        CATextLayer *textLayer = [CATextLayer layer];
        textLayer.string = KIDYRECORDING_TOAST_MSG;
        textLayer.fontSize = 14.0f;
        textLayer.wrapped = YES;
        textLayer.foregroundColor = [UIColor whiteColor].CGColor;
        textLayer.alignmentMode = kCAAlignmentCenter;
        
        _toastShapeLayer = [[CAShapeLayer alloc] init];
        _toastShapeLayer.frame = CGRectMake(idy_window_width * 0.3,
                                            idy_window_height / 6 * 5 - 45,
                                            idy_window_width * 0.4,
                                            35);
        
        textLayer.frame = CGRectMake(0,
                                     5,
                                     idy_window_width * 0.4,
                                     25);
        [_toastShapeLayer addSublayer:textLayer];
        
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0,
                                                                                0,
                                                                                idy_window_width * 0.4,
                                                                                35)
                                                        cornerRadius:4];
        _toastShapeLayer.path = path.CGPath;
        [path moveToPoint:CGPointMake(idy_window_width * 0.4/2 - 10, 35)];
        [path addLineToPoint:CGPointMake(idy_window_width * 0.4/2, 45)];
        [path addLineToPoint:CGPointMake(idy_window_width * 0.4/2 + 10, 35)];
        
        _toastShapeLayer.path = path.CGPath;
        _toastShapeLayer.fillColor = [UIColor purpleColor].CGColor;
        _toastShapeLayer.strokeColor = [UIColor purpleColor].CGColor;
        
        CAKeyframeAnimation *transformAnima = [CAKeyframeAnimation animation];
        transformAnima.keyPath = @"position.y";
        transformAnima.values = @[ @0, @10, @-10, @10, @0 ];
        transformAnima.keyTimes = @[ @0, @(1 / 6.0), @(3 / 6.0), @(5 / 6.0), @1 ];
        transformAnima.duration = 2.5;
        transformAnima.additive = YES;
        transformAnima.repeatCount = MAXFLOAT;
        [_toastShapeLayer addAnimation:transformAnima forKey:@"shake"];
    }
    return _toastShapeLayer;
}

- (AVPlayerLayer *)playerLayer{
    
    if (!_playerLayer) {
        
        _player = nil;
        _playerLayer = [AVPlayerLayer playerLayerWithPlayer:self.player];
        _playerLayer.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.4].CGColor;
        _playerLayer.cornerRadius = 4;
        _playerLayer.borderColor = [UIColor redColor].CGColor;
        _playerLayer.borderWidth = 2;
        _playerLayer.shadowOffset = CGSizeMake(-3, -3);
        _playerLayer.shadowColor = [UIColor purpleColor].CGColor;
        _playerLayer.frame = CGRectInset(self.bounds, idy_window_width * 0.1, idy_window_height * 0.1);
        _playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    }
    return _playerLayer;
}

- (AVPlayer *)player{
    
    if (!_player) {
        
        _player = [AVPlayer playerWithURL:self.recorder.videoURL];
        
        /* observer paly completed */
        _player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(playerCompletionAction:)
                                                     name:AVPlayerItemDidPlayToEndTimeNotification
                                                   object:[_player currentItem]];
    }
    return _player;
}

#pragma mark    -   private method

- (void)configure{
    
    self.backgroundColor = [UIColor clearColor];
    [self setUserInteractionEnabled:YES];
    self.windowLevel = UIWindowLevelNormal;
    
    UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(recordingCancel)];
    [self addGestureRecognizer:tapGesture];
    [self addSubview:self.bottomImageView];
    
    UIButton *cancel = [[UIButton alloc] initWithFrame:CGRectMake(idy_window_width * 0.1,
                                                                  idy_window_height / 5 * 0.2,
                                                                  idy_window_width * 0.2,
                                                                  idy_window_height / 5 * 0.4)];
    [cancel setTitle:@"取消" forState:UIControlStateNormal];
    [cancel addTarget:self action:@selector(recordingCancel) forControlEvents:UIControlEventTouchUpInside];
    [cancel setTintColor:[UIColor whiteColor]];
    [self.bottomImageView addSubview:cancel];
    
    
    self.record = [[UIButton alloc] initWithFrame:CGRectMake(idy_window_width/2 - (idy_window_height / 5 * 0.7 / 2),
                                                             idy_window_height / 5 * 0.1,
                                                             idy_window_height / 5 * 0.7,
                                                             idy_window_height / 5 * 0.7)];
    [self.record setImage:[UIImage imageNamed:@"btn_record_default"] forState:UIControlStateNormal];
    [self.record setImage:[UIImage imageNamed:@"btn_record_seleted"] forState:UIControlStateSelected];
    [self.record addTarget:self action:@selector(recordingAction:) forControlEvents:UIControlEventTouchUpInside];
    [self.bottomImageView addSubview:self.record];
    [self.bottomImageView addSubview:self.progress];
}

- (void)showRecordingWindow{
    
    [self becomeKeyWindow];
    [self makeKeyAndVisible];
    self.hidden = NO;
    
    [UIView animateWithDuration:0.5 animations:^{
        
        self.bottomImageView.frame = CGRectMake(0,
                                                idy_window_height / 6 * 5,
                                                idy_window_width,
                                                idy_window_height / 5);
    }];
}

- (void)dismissRecordingWindow{
    
    if (!self.record.selected) {
        
        [UIView animateWithDuration:0.5
                         animations:^{
                             
                             self.bottomImageView = [[UIImageView alloc] initWithFrame:CGRectMake(0,
                                                                                                  idy_window_height,
                                                                                                  idy_window_width,
                                                                                                  0)];
                         } completion:^(BOOL finished) {
                             
                             [self resignKeyWindow];
                             [self.bottomImageView removeFromSuperview];
                             [self removeFromSuperview];
                             self.hidden = YES;
                         }];
    }
    
    if (_idy_dispatch_timer) dispatch_source_cancel(_idy_dispatch_timer);
    self.record.selected = NO;
    self.progress.progress = 0.0f;
}

#pragma mark    -   event method

// 点击窗口或者点击取消
- (void)recordingCancel{
    
    if (!self.record.selected) {
        
        if (self.closeBlock) self.closeBlock();
        [self dismissRecordingWindow];
    }else{
        
        if (_idy_dispatch_timer) dispatch_source_cancel(_idy_dispatch_timer);
        self.record.selected = NO;
        self.progress.progress = 0.0f;
        [self.recorder clearAllCache];
    }
}

- (void)recordingOfFinished{
    
    [self recordingCancel];
    
    if (self.recorder.isRecording) {
        
        [self.recorder stopRecordingWithCompletionHanlder:^(BOOL success) {
            
            NSLog(@"Finished recording");
            NSLog(@"new video of path >>>>>>>>>>>>>>>>>>>   %@",self.recorder.videoURL);
            
            UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(clickBackground)];
            tapGesture.delegate = self;
            [self.recorder.presentationView addGestureRecognizer:tapGesture];
            
            [self.recorder.presentationView.layer addSublayer:self.playerLayer];
            [self.player play];
        }];
    }
}

- (void)clickBackground{
    
    [_playerLayer removeFromSuperlayer];
    _playerLayer = nil;
    _player = nil;
}

- (void)recordingAction:(UIButton *)sender{
    
    sender.selected = !sender.selected ;
    
    if (sender.selected) {
        
        if (!self.recorder.isRecording) {
            
            [self.recorder startRecordingWithCompletionHanlder:^(BOOL success) {
                
                NSLog(@"Start recording");
            }];
        }
        
        _executeCount = 0;
        _idy_dispatch_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,  _idy_dispatch_queue);
        dispatch_source_set_timer(_idy_dispatch_timer, DISPATCH_TIME_NOW, kIDYTIME_FRAME_SECOND * NSEC_PER_SEC, 0 * NSEC_PER_SEC);
        dispatch_source_set_event_handler(_idy_dispatch_timer, ^{
            
            dispatch_async(dispatch_get_main_queue(), ^{
                
                if (_executeCount > kIDYTIME_EXECUTE_COUNT){
                    
                    [self dismissRecordingWindow];
                    [self recordingOfFinished];
                }
                else{
                    
                    [self.progress setProgress:_executeCount/kIDYTIME_EXECUTE_COUNT animated:YES];
                    _executeCount ++ ;
                }
            });
        });
        dispatch_resume(_idy_dispatch_timer);
        
    }else{
        
        if (_executeCount < KIDYTIME_LIMIT_VALUE) {
            
            self.record.selected = YES;
            [self.layer addSublayer:self.toastShapeLayer];
            
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                
                [_toastShapeLayer removeAllAnimations];
                [_toastShapeLayer removeFromSuperlayer];
                _toastShapeLayer = nil;
            });
            
        }else [self recordingOfFinished];
        
        [self recordingCancel];
    }
}


- (void)playerCompletionAction:(NSNotificationCenter *)not{
    
    [self.player seekToTime:CMTimeMake(0, 600)];
}

#pragma mark    -   UIGestureRecognizer delegate

// called before touchesBegan:withEvent: is called on the gesture recognizer for a new touch. return NO to prevent the gesture recognizer from seeing this touch
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch{
    
    if (!CGRectContainsPoint(self.playerLayer.frame, [touch locationInView:self.recorder.presentationView])) {
        
        [self clickBackground];
        return YES;
        
    }else return NO;
}

- (void)dealloc{
    
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

/*
 // Only override drawRect: if you perform custom drawing.
 // An empty implementation adversely affects performance during animation.
 - (void)drawRect:(CGRect)rect {
 // Drawing code
 }
 */

@end

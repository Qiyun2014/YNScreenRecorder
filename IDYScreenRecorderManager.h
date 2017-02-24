//
//  IDYScreenRecorderManager.h
//  GoPro_Demo
//
//  Created by qiyun on 17/2/5.
//  Copyright © 2017年 qiyun. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <UIKit/UIKit.h>
#import <CoreMedia/CMSampleBuffer.h>
#import <AudioToolbox/AudioToolbox.h>

typedef void (^RecorderOfStatusBlock)(BOOL success);
typedef OSStatus (*IDYAudio_FillBufferTrampoline) (AudioConverterRef inAudioConverter, UInt32 *ioNumberDataPackets,AudioBufferList *ioData);

typedef NS_ENUM(NSInteger, SRWriteStatus) {
    
    SRWriteStatusUnknow = 0x00,
    SRWriteStatusUnknowPath,                // the path of mutilMedia file output
    SRWriteStatusCanNotAddInput,            // assetWriter can not add AVAssetWriterInput
    SRWriteStatusCanNotAppendPixel,         // appending the sample buffer
    SRWriteStatusCanNotSaveVideoToAlbum,
    SRWriteStatusSemaphoreSigned,
    SRWriteStatusCanNotCreateSampleBuffer
};


@protocol
IDYScreenRecorderManagerDelegate <NSObject>

// current screen video frame
- (void)realTimeFrameInContext:(CGContextRef *)contextRef;

// description error infomation of writing
- (void)screenRecordingStatus:(SRWriteStatus)status;

@end


@protocol
IDYRecorderAction <NSObject>

// start
- (void)startRecordingWithCompletionHanlder:(RecorderOfStatusBlock)completionBlock;

// stop
- (void)stopRecordingWithCompletionHanlder:(RecorderOfStatusBlock)completionBlock;

// add audio data to media file  <GPUImageMovieWriter  processAudioBuffer>
- (void)processAudioBuffer:(CMSampleBufferRef)audioBuffer;

// copy of the data from the audioBuffer, and sets that as the CMSampleBuffer's data buffer
- (void)writePCMAudioBuffer:(void *)audioBuffer size:(long)size samples:(UInt32)samples;

// write pcm buffer to file, only pcm vaild
- (void)writeAudioBuffer:(unsigned char *)buffer size:(UInt32)size samples:(int)samples;

@end


/////////////////////////////////////////////////////////////////////////////////////////////////////

@interface
IDYScreenRecorderManager : NSObject<IDYRecorderAction>{
    
    IDYAudio_FillBufferTrampoline audioFillBuffer;
}

+ (instancetype)sharedInstance;

// current recording status
@property (nonatomic, readonly) BOOL isRecording;

// delegate is only required when implementing IDYScreenRecorderManagerDelegate - see below
@property (nonatomic, weak) id <IDYScreenRecorderManagerDelegate> delegate;

// if saveURL is nil, video will be saved into camera roll, this property can not be changed whilst recording is in progress
@property (strong, nonatomic) NSURL *videoURL;

// if not set presentationView, default recording the window images
@property (weak, nonatomic) UIView  *presentationView;

// all for a short time video clear
- (void)clearAllCache;

@end


/////////////////////////////////////////////////////////////////////////////////////////////////////

@interface
UIViewController (ScreenRecorder)

// add gesture recognizer to UIViewController , play or stop with control action
- (void)prepareScreenRecorder;

@end


//
//  IDYScreenRecorderManager.m
//  GoPro_Demo
//
//  Created by qiyun on 17/2/5.
//  Copyright © 2017年 qiyun. All rights reserved.
//  屏幕录制过程中，可以选定制定视图作为图像获取源，用于过滤覆盖层的不可用信息，如（UIWindow，UIAlertControl等）

#import "IDYScreenRecorderManager.h"
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <AssetsLibrary/AssetsLibrary.h>
#import <CoreAudio/CoreAudioTypes.h>
#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>
#import <OpenAL/OpenAL.h>
#include <sys/time.h>

#define kFRAMES_PER_SECOND  8
#define kAUDIO_BUFFER_CONVERT 0

#define kSCREEN_RECORDING_ERROR(STATUS,DESCRIPTION)\
if (self.delegate && [self.delegate respondsToSelector:@selector(screenRecordingStatus:)]) {\
[self.delegate screenRecordingStatus:STATUS];\
NSLog(DESCRIPTION);\
}\

@interface IDYScreenRecorderManager ()

@property (strong, nonatomic) AVAssetWriter *videoWriter;
@property (strong, nonatomic) AVAssetWriterInput *videoWriterInput;
@property (strong, nonatomic) AVAssetWriterInput *audioWriterInput;
@property (strong, nonatomic) AVAssetWriterInputPixelBufferAdaptor *avAdaptor;
@property (strong, nonatomic) CADisplayLink *displayLink;

@property (nonatomic) CFTimeInterval firstTimeStamp;
@property (nonatomic) BOOL isRecording;

@end

@implementation IDYScreenRecorderManager{
    
    dispatch_queue_t        _render_queue;
    dispatch_queue_t        _append_pixelBuffer_queue;
    dispatch_semaphore_t    _frameRenderingSemaphore;
    dispatch_semaphore_t    _pixelAppendSemaphore;
    
    CGSize _viewSize;
    CGFloat _scale;
    
    CGColorSpaceRef         _rgbColorSpace;
    CVPixelBufferPoolRef    _outputBufferPool;
    
    AudioStreamBasicDescription _audioFormat;
    CMAudioFormatDescriptionRef _audioFormatDesc;
    AudioStreamBasicDescription _outAudioFormat;
    CMAudioFormatDescriptionRef _outAudioFormatDesc;
    
    AudioConverterRef           _audioConverter;
    AudioBufferList             _outAudioBufferList;
    UInt32                      _outputPacketSize;
    UInt8                       *_aac_audioBuffer;
}

#if kAUDIO_BUFFER_CONVERT
struct fillComplexBufferInputProc_t { AudioBufferList *bufferList; UInt32 frames;  };
static OSStatus fillComplexBufferInputProc(AudioConverterRef             inAudioConverter,
                                           UInt32                        *ioNumberDataPackets,
                                           AudioBufferList               *ioData,
                                           AudioStreamPacketDescription  **outDataPacketDescription,
                                           void                          *inUserData) {
    
    struct fillComplexBufferInputProc_t *arg = inUserData;
    ioData->mBuffers[0].mData = arg->bufferList->mBuffers[0].mData;
    ioData->mBuffers[0].mDataByteSize = arg->bufferList->mBuffers[0].mDataByteSize;
    ioData->mBuffers[0].mNumberChannels = arg->bufferList->mBuffers[0].mNumberChannels;
    *ioNumberDataPackets = (arg->bufferList->mBuffers[0].mDataByteSize/2);
    
    return noErr;
}
#endif

static OSStatus IDYFillBufferCallBack(AudioConverterRef inAudioConverter, UInt32 *ioNumberDataPackets,AudioBufferList *ioData){
    
    return noErr;
}
/*
 static OSStatus IDYFillBufferTrampoline(AudioConverterRef               inAudioConverter,
 UInt32*                         ioNumberDataPackets,
 AudioBufferList*                ioData,
 AudioStreamPacketDescription**  outDataPacketDescription,
 void*                           inUserData)
 {
 IDYScreenRecorderManager *recorderManager = (__bridge IDYScreenRecorderManager *)ioData;
 return recorderManager->audioFillBuffer(inAudioConverter,ioNumberDataPackets, ioData);
 }
 */

static IDYScreenRecorderManager *RecorderManager = NULL;

+ (instancetype)sharedInstance{
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        
        RecorderManager = [[self alloc] init];
    });
    
    return RecorderManager;
}


- (instancetype)init
{
    self = [super init];
    
    if (self) {
        
        _viewSize = [UIApplication sharedApplication].delegate.window.bounds.size;
        _scale = [UIScreen mainScreen].scale;
        self->audioFillBuffer = IDYFillBufferCallBack;
        
        // record half size resolution for retina iPads
        if ((UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) && _scale > 1) {
            _scale = 1.0;
        }
        _isRecording = NO;
        
        _append_pixelBuffer_queue = dispatch_queue_create("IDYScreenRecorderManager.append_queue", DISPATCH_QUEUE_SERIAL);
        _render_queue = dispatch_queue_create("IDYScreenRecorderManager.render_queue", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(_render_queue, dispatch_get_global_queue( DISPATCH_QUEUE_PRIORITY_HIGH, 0));
        _frameRenderingSemaphore = dispatch_semaphore_create(1);
        _pixelAppendSemaphore = dispatch_semaphore_create(1);
    }
    return self;
}


- (void)setVideoURL:(NSURL *)videoURL
{
    if (!_isRecording) _videoURL = videoURL;
    else{
        
        kSCREEN_RECORDING_ERROR(SRWriteStatusUnknow,@"");
    }
}


#pragma mark - private

- (BOOL)setVideoWriterInput
{
    _rgbColorSpace = CGColorSpaceCreateDeviceRGB();
    // output video setting, such as: video pixel height and width ,and so on
    NSDictionary *bufferAttributes = @{(id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
                                       (id)kCVPixelBufferCGBitmapContextCompatibilityKey : @YES,
                                       (id)kCVPixelBufferWidthKey : @(_viewSize.width * _scale),
                                       (id)kCVPixelBufferHeightKey : @(_viewSize.height * _scale),
                                       (id)kCVPixelBufferBytesPerRowAlignmentKey : @(_viewSize.width * _scale * 4)
                                       };
    
    _outputBufferPool = NULL;
    CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)(bufferAttributes), &_outputBufferPool);
    
    NSError* error = nil;
    _videoWriter = [[AVAssetWriter alloc] initWithURL:self.videoURL ?: [self tempFileURL]
                                             fileType:AVFileTypeQuickTimeMovie
                                                error:&error];

    NSParameterAssert(_videoWriter);
    NSAssert(!error, [error description]);
    
    NSInteger pixelNumber = _viewSize.width * _viewSize.height * _scale;
    NSDictionary* videoCompression = @{AVVideoAverageBitRateKey: @(pixelNumber * 11.4)};
    
    NSDictionary* videoSettings = @{AVVideoCodecKey: AVVideoCodecH264,
                                    AVVideoWidthKey: [NSNumber numberWithInt:_viewSize.width*_scale],
                                    AVVideoHeightKey: [NSNumber numberWithInt:_viewSize.height*_scale],
                                    AVVideoCompressionPropertiesKey: videoCompression};
    
    _videoWriterInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
    NSParameterAssert(_videoWriterInput);
    _videoWriterInput.expectsMediaDataInRealTime = YES;
    _videoWriterInput.transform = [self videoTransformForDeviceOrientation];
    
    // pixel buffer attributes setting
    NSDictionary *sourcePixelBufferAttributesDictionary = [NSDictionary dictionaryWithObjectsAndKeys:
                                                           [NSNumber numberWithInt:kCVPixelFormatType_420YpCbCr8BiPlanarFullRange], kCVPixelBufferPixelFormatTypeKey,
                                                           [NSNumber numberWithInt:_viewSize.width], kCVPixelBufferWidthKey,
                                                           [NSNumber numberWithInt:_viewSize.height], kCVPixelBufferHeightKey,
                                                           nil];
    
    // creates a new pixel buffer adaptor to receive pixel buffers for writing to the output file.
    _avAdaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:_videoWriterInput
                                                                                  sourcePixelBufferAttributes:sourcePixelBufferAttributesDictionary];
    
    if ([_videoWriter canAddInput:_videoWriterInput]) [_videoWriter addInput:_videoWriterInput];
    else {
        kSCREEN_RECORDING_ERROR(SRWriteStatusCanNotAddInput,@"counld not add video input to wirter ....");
    }
    
    [self setAudioWriterInput];
    
    if ([_videoWriter canAddInput:_audioWriterInput]){ [_videoWriter addInput:_audioWriterInput];
    }else {
        kSCREEN_RECORDING_ERROR(SRWriteStatusCanNotAddInput,@"counld not add audio input to wirter ...");
    }
    
    BOOL success;
    
    if (_videoWriter.status != AVAssetWriterStatusFailed) {
        
        success = [_videoWriter startWriting];
        [_videoWriter startSessionAtSourceTime:CMTimeMake(0, 1000)];
        
    }else {
        kSCREEN_RECORDING_ERROR(SRWriteStatusUnknow, @"Create assetWriter failed...");
        return success;
    }
    
    return success;
}

// Add a Audio AssetWriterInput
- (void)setAudioWriterInput{
    
    // If the sample buffer contains audio data and the AVAssetWriterInput was intialized with an outputSettings dictionary then the format must be linear PCM
    // example : https://developer.apple.com/library/prerelease/content/samplecode/MatrixMixerTest/Listings/PublicUtility_CAStreamBasicDescription_h.html
    
#if !IDYAUDIO_FORMAT_IS_PCM
    _audioFormat.mSampleRate         = 44100;
    _audioFormat.mFormatID           = kAudioFormatLinearPCM;
    _audioFormat.mFormatFlags        = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    _audioFormat.mChannelsPerFrame   = 2;
    _audioFormat.mFramesPerPacket    = 1;
    _audioFormat.mBitsPerChannel     = 16; // (44100 * 16 * 1 / 8)
    _audioFormat.mBytesPerFrame      = (_audioFormat.mBitsPerChannel / 8) * _audioFormat.mChannelsPerFrame;
    _audioFormat.mBytesPerPacket     = _audioFormat.mBytesPerFrame;
    _audioFormat.mReserved           = 0;
    
    CMAudioFormatDescriptionCreate(kCFAllocatorDefault,&_audioFormat,0,NULL,0, NULL,NULL,&_outAudioFormatDesc);
#else
    _audioFormat.mSampleRate       = 44100;         // some sampleRate: 48000 44100 24000
    _audioFormat.mFormatID         = kAudioFormatMPEG4AAC;
    _audioFormat.mFormatFlags      = kMPEG4Object_AAC_SSR;
    _audioFormat.mFramesPerPacket  = 1024;
    _audioFormat.mChannelsPerFrame = 1;             // auido tracks
#endif
    
    AudioChannelLayout acl;
    bzero( &acl, sizeof(acl));
    acl.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo;
    
    NSDictionary*  audioOutputSettings;
    
    // output aac audio format of file
    audioOutputSettings = [NSDictionary dictionaryWithObjectsAndKeys:
                           [ NSNumber numberWithInt: kAudioFormatMPEG4AAC],                         AVFormatIDKey,
                           [ NSNumber numberWithInt: 2 ],                                           AVNumberOfChannelsKey,
                           [ NSNumber numberWithFloat: 44100.0 ],                                   AVSampleRateKey,
                           [ NSData dataWithBytes: &acl length: sizeof( AudioChannelLayout ) ],     AVChannelLayoutKey,
                           [ NSNumber numberWithInt: 64000 ],                                       AVEncoderBitRateKey,      //64000 or 128000
                           nil];
    
    _audioWriterInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:audioOutputSettings];
    _audioWriterInput.expectsMediaDataInRealTime = YES;
    
#if kAUDIO_BUFFER_CONVERT
    [self converterRef];
#endif
}

- (AudioConverterRef)converterRef{
    
    if (!_audioConverter) {
        
        _aac_audioBuffer = malloc(4096);
        
        // Always initialize the fields of a new audio stream basic description structure to zero, as shown here: ...
        _outAudioFormat.mChannelsPerFrame = 1;
        _outAudioFormat.mSampleRate = 44100;
        _outAudioFormat.mFramesPerPacket = 1024;
        _outAudioFormat.mFormatID = kAudioFormatMPEG4AAC;
        _outAudioFormat.mFormatFlags = kMPEG4Object_AAC_SSR;
        
        AudioClassDescription *description = [self getAudioClassDescriptionWithType:_outAudioFormat.mFormatID fromManufacturer:kAppleSoftwareAudioCodecManufacturer];
        if (!description) {
            NSLog(@"initConverterPCMToAAC get audio class Descriptin error.");
            return false;
        }
        
        UInt32 outputBitrate = 128*1024; // 128 kbps
        UInt32 propSize = sizeof(outputBitrate);
        
        AudioConverterReset(_audioConverter);
        OSStatus result = AudioConverterNewSpecific(&_audioFormat, &_outAudioFormat, 1, description, &_audioConverter);
        if (noErr != result) {
            perror("AudioConverterNewSpecific \n");
        }
        
        result = AudioConverterSetProperty(_audioConverter, kAudioConverterEncodeBitRate, propSize, &outputBitrate);
        if (noErr != result) {
            perror("AudioConverterSetProperty \n");
        }
        
        UInt32 prop;
        prop = kAudioConverterSampleRateConverterComplexity_Mastering;
        result = AudioConverterSetProperty(_audioConverter,
                                           kAudioConverterSampleRateConverterComplexity,
                                           sizeof(prop), &prop);
        
        prop = kAudioConverterQuality_Max;
        result = AudioConverterSetProperty(_audioConverter,
                                           kAudioConverterSampleRateConverterQuality,
                                           sizeof(prop), &prop);
        UInt32 value;
        UInt32 size = sizeof value;
        UInt32 primeMethod = kConverterPrimeMethod_None;
        AudioConverterSetProperty(_audioConverter, kAudioConverterPrimeMethod, size, &primeMethod);
        
        result = AudioConverterGetProperty(_audioConverter, kAudioConverterPropertyMaximumOutputPacketSize, &propSize, &_outputPacketSize);
        if (noErr != result) {
            perror("AudioConverterGetProperty \n");
        }
        
        //_outputPacketSize = 4096;
        _outAudioBufferList.mNumberBuffers = 1;
        _outAudioBufferList.mBuffers[0].mDataByteSize = _outputPacketSize;
        _outAudioBufferList.mBuffers[0].mData = _aac_audioBuffer;
        _outAudioBufferList.mBuffers[0].mNumberChannels = 1;
    }
    return _audioConverter;
}

#pragma mark    - private method

- (CGAffineTransform)videoTransformForDeviceOrientation
{
    CGAffineTransform videoTransform;
    
    switch ([UIDevice currentDevice].orientation) {
            
        case UIDeviceOrientationLandscapeLeft:
            videoTransform = CGAffineTransformMakeRotation(-M_PI_2);
            break;
        case UIDeviceOrientationLandscapeRight:
            videoTransform = CGAffineTransformMakeRotation(M_PI_2);
            break;
        case UIDeviceOrientationPortraitUpsideDown:
            videoTransform = CGAffineTransformMakeRotation(M_PI);
            break;
        default:
            videoTransform = CGAffineTransformIdentity;
    }
    return videoTransform;
}


- (NSURL *)tempFileURL
{
    NSString *outputPath = [NSHomeDirectory() stringByAppendingPathComponent:@"tmp/screenCapture.mp4"];
    [self removeTempFilePath:outputPath];
    return [NSURL fileURLWithPath:outputPath];
}

- (void)removeTempFilePath:(NSString *)filePath
{
    NSFileManager* fileManager = [NSFileManager defaultManager];
    
    if ([fileManager fileExistsAtPath:filePath]) {
        
        NSError* error;
        if ([fileManager removeItemAtPath:filePath error:&error] == NO) {
            
            NSLog(@"Could not delete old recording:%@", [error localizedDescription]);
        }
    }
}

- (void)completeRecordingSession:(RecorderOfStatusBlock)completionBlock;
{
    dispatch_async(_render_queue, ^{
        dispatch_sync(_append_pixelBuffer_queue, ^{
            
            [_audioWriterInput markAsFinished];
            [_videoWriterInput markAsFinished];
            
            if (_videoWriter.status != AVAssetWriterStatusWriting) {
                
                NSDate *maxDate = [NSDate dateWithTimeIntervalSinceNow:0.5];
                [[NSRunLoop currentRunLoop] runUntilDate:maxDate];
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self cleanup];
                    if (completionBlock) completionBlock(YES);
                    kSCREEN_RECORDING_ERROR(SRWriteStatusUnknow, @"The writer status is not writing , counld't finished...");
                });
            }else{
                
                [self.videoWriter finishWritingWithCompletionHandler:^{
                    
                    void (^completion)(void) = ^() {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [self cleanup];
                            if (completionBlock) completionBlock(YES);
                        });
                    };
                    
                    self.videoURL = _videoWriter.outputURL;
                    if ([UIDevice currentDevice].systemVersion.floatValue <= 9.0f) {
                        
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                        ALAssetsLibrary *library = [[ALAssetsLibrary alloc] init];
                        [library writeVideoAtPathToSavedPhotosAlbum:_videoWriter.outputURL completionBlock:^(NSURL *assetURL, NSError *error) {
                            if (error) {
                                kSCREEN_RECORDING_ERROR(SRWriteStatusCanNotSaveVideoToAlbum, @"Error copying video to camera roll");
                                if (completionBlock) completionBlock(YES);
                                [self cleanup];
                            } else {
                                completion();
                            }
                        }];
#pragma clang diagnostic pop
                        
                    }else{
                        
                        [IDYScreenRecorderManager videoSaveOfPath:_videoWriter.outputURL.path photoAlbumHanlder:^(BOOL success, NSError *error) {
                            if (error) {
                                kSCREEN_RECORDING_ERROR(SRWriteStatusCanNotSaveVideoToAlbum, @"Error copying video to camera roll");
                                if (completionBlock) completionBlock(YES);
                                [self cleanup];
                            } else {
                                completion();
                            }
                        }];
                    }
                }];
            }
        });
    });
}

- (void)cleanup
{
    if (self.videoWriter){
        
        AudioConverterDispose(_audioConverter);
        if (_aac_audioBuffer) free(_aac_audioBuffer);
        CVPixelBufferPoolRelease(_outputBufferPool);
        self.avAdaptor = nil;
        self.videoWriterInput = nil;
        self.videoWriter = nil;
        self.firstTimeStamp = 0;
        CGColorSpaceRelease(_rgbColorSpace);
        dispatch_semaphore_signal(_frameRenderingSemaphore);
    }
}

#pragma mark    -   writer video

- (void)writeVideoFrame
{
    // throttle the number of frames to prevent meltdown
    // technique gleaned from Brad Larson's answer here: http://stackoverflow.com/a/5956119
    if (dispatch_semaphore_wait(_frameRenderingSemaphore, DISPATCH_TIME_NOW) != 0) {
        return;
    }
    dispatch_async(_render_queue, ^{
        if (![_videoWriterInput isReadyForMoreMediaData]) return;

        if (!self.firstTimeStamp) {
            self.firstTimeStamp = _displayLink.timestamp;
        }
        CFTimeInterval elapsed = (_displayLink.timestamp - self.firstTimeStamp);
        CMTime timeStamp = CMTimeMakeWithSeconds(elapsed, 1000);
        
        CVPixelBufferRef pixelBuffer = NULL;
        CGContextRef bitmapContext = [self createPixelBufferAndBitmapContext:&pixelBuffer];
        
        if (self.delegate) {
            [self.delegate realTimeFrameInContext:&bitmapContext];
        }
        
        // draw each window into the context (other windows include UIKeyboard, UIAlert)
        // FIX: UIKeyboard is currently only rendered correctly in portrait orientation
        dispatch_sync(dispatch_get_main_queue(), ^{
            UIGraphicsPushContext(bitmapContext); {

                if (self.presentationView) {
                    [self.presentationView drawViewHierarchyInRect:self.presentationView.frame afterScreenUpdates:NO];

                }else{
                    for (UIWindow *window in [[UIApplication sharedApplication] windows]) {
                        [window drawViewHierarchyInRect:CGRectMake(0, 0, _viewSize.width, _viewSize.height) afterScreenUpdates:NO];
                    }
                }
            } UIGraphicsPopContext();
        });

        // append pixelBuffer on a async dispatch_queue, the next frame is rendered whilst this one appends
        // must not overwhelm the queue with pixelBuffers, therefore:
        // check if _append_pixelBuffer_queue is ready
        // if it’s not ready, release pixelBuffer and bitmapContext
        if (dispatch_semaphore_wait(_pixelAppendSemaphore, DISPATCH_TIME_NOW) == 0) {
            dispatch_async(_append_pixelBuffer_queue, ^{
                
                BOOL success = [_avAdaptor appendPixelBuffer:pixelBuffer withPresentationTime:timeStamp];
                if (!success) {
                    kSCREEN_RECORDING_ERROR(SRWriteStatusCanNotAppendPixel, @"Warning: Unable to write buffer to video");
                }else
                    NSLog(@"Write buffer to video success...");
                
                CGContextRelease(bitmapContext);
                CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
                CVPixelBufferRelease(pixelBuffer);
                
                dispatch_semaphore_signal(_pixelAppendSemaphore);
            });
        } else {
            
            CGContextRelease(bitmapContext);
            CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
            CVPixelBufferRelease(pixelBuffer);
            dispatch_semaphore_signal(_pixelAppendSemaphore);

        }
        dispatch_semaphore_signal(_frameRenderingSemaphore);
    });
}

// create contextRef associate with pixelBuffer
- (CGContextRef)createPixelBufferAndBitmapContext:(CVPixelBufferRef *)pixelBuffer
{
    CVPixelBufferPoolCreatePixelBuffer(NULL, _outputBufferPool, pixelBuffer);
    CVPixelBufferLockBaseAddress(*pixelBuffer, 0);
    
    CGContextRef bitmapContext = NULL;
    bitmapContext = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(*pixelBuffer),
                                          CVPixelBufferGetWidth(*pixelBuffer),
                                          CVPixelBufferGetHeight(*pixelBuffer),
                                          8,
                                          CVPixelBufferGetBytesPerRow(*pixelBuffer),
                                          _rgbColorSpace,
                                          kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst
                                          );
    CGContextScaleCTM(bitmapContext, _scale, _scale);
    CGAffineTransform flipVertical = CGAffineTransformMake(1, 0, 0, -1, 0, _viewSize.height);
    CGContextConcatCTM(bitmapContext, flipVertical);
    
    return bitmapContext;
}

#pragma mark    -   writer audio

// writring audioBuffer to assetWiter of output local file
- (void)processAudioBuffer:(CMSampleBufferRef)audioBuffer{
    
    if (!_audioWriterInput.readyForMoreMediaData && !_isRecording) {
        
        CFRelease(audioBuffer);
        return;
    }
    
    //need to introspect into the opaque CMBlockBuffer structure to find its raw sample buffers.
    CMBlockBufferRef buffer = CMSampleBufferGetDataBuffer(audioBuffer);
    AudioBufferList audioBufferList;
    
    CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(audioBuffer,
                                                            NULL,
                                                            &audioBufferList,
                                                            sizeof(audioBufferList),
                                                            NULL,
                                                            NULL,
                                                            kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                                                            &buffer
                                                            );
    
    CMTime currentSampleTime = CMSampleBufferGetOutputPresentationTimeStamp(audioBuffer);
    
    void(^write)() = ^() {
        
        if(_videoWriter.status == AVAssetWriterStatusWriting)
        {
            if (![_audioWriterInput appendSampleBuffer:audioBuffer])
                NSLog(@"Problem appending audio buffer at time: %@", CFBridgingRelease(CMTimeCopyDescription(kCFAllocatorDefault, currentSampleTime)));
        }
        else
        {
            NSLog(@"Wrote an audio frame %@", CFBridgingRelease(CMTimeCopyDescription(kCFAllocatorDefault, currentSampleTime)));
        }
        
        CFRelease(audioBuffer);
    };
    
    
    dispatch_async(_render_queue, ^{
        
        if (![_audioWriterInput isReadyForMoreMediaData]) return;
        if (dispatch_semaphore_wait(_pixelAppendSemaphore, DISPATCH_TIME_NOW) == 0) {
            
            dispatch_async(_append_pixelBuffer_queue, ^{
                
                write();
                dispatch_semaphore_signal(_pixelAppendSemaphore);
            });
        } else {
            
            CFRelease(audioBuffer);
            NSLog(@"appending audio buffer faild....");
        }
        
        dispatch_semaphore_signal(_frameRenderingSemaphore);
    });
}


// get audio input buffer from pointer of audioBuffer, the length is defalt 4096
// input audio buffer is pcm audio format , use is convert to aac format after, generated CMSampleBuffer writer to AVAssetWirter with file
- (void)writePCMAudioBuffer:(void *)audioBuffer size:(long)size samples:(UInt32)samples{
    
    size = size>>2;
    
#if kAUDIO_BUFFER_CONVERT
    
    // create audiobuffer list, play audio data to store
    AudioBufferList *theDataBuffer = (AudioBufferList *) malloc(sizeof(AudioBufferList) *1);
    theDataBuffer->mNumberBuffers = 1;
    theDataBuffer->mBuffers[0].mDataByteSize = (UInt32)bLength;
    theDataBuffer->mBuffers[0].mNumberChannels = 1;
    theDataBuffer->mBuffers[0].mData = audioBuffer;
    
    // Converts data supplied by an input callback function, supporting non-interleaved and packetized formats.
    UInt32 frames = 1;
    AudioStreamPacketDescription outPacketDescription[frames];
    OSStatus result = AudioConverterFillComplexBuffer(_audioConverter,
                                                      fillComplexBufferInputProc,
                                                      &(struct fillComplexBufferInputProc_t) { .bufferList = theDataBuffer, .frames = frames },
                                                      &frames,
                                                      &_outAudioBufferList,
                                                      outPacketDescription);
    
    if (result != noErr) {
        
        perror("audio converter fill faild ...");
        return;
    }
    
    NSLog(@"convert to data success... size = %d",outPacketDescription->mDataByteSize);
    
#endif
    
    //memset(&_aac_audioBuffer + outPacketDescription->mDataByteSize, 0, bLength-outPacketDescription->mDataByteSize);
    OSStatus status = -1;
    CMSampleBufferRef sampleBuffer;
    
    // CMSampleBuffers require a CMBlockBuffer to hold the media data; we create a blockBuffer here from the AudioQueueBuffer's data.
    CMBlockBufferRef blockBuffer;
    CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault,
                                       (kAUDIO_BUFFER_CONVERT)?_aac_audioBuffer:audioBuffer,
                                       size,
                                       kCFAllocatorNull,
                                       NULL,
                                       0,
                                       size,
                                       kCMBlockBufferAssureMemoryNowFlag,
                                       &blockBuffer);
    
    // Timestamp of current sample
    CFAbsoluteTime currentTime = CFAbsoluteTimeGetCurrent();
    CFTimeInterval elapsedTime = currentTime - self.firstTimeStamp;
    CMTime timeStamp = CMTimeMake(elapsedTime, 1000000000);
    
    status = CMAudioFormatDescriptionCreate(kCFAllocatorDefault, (kAUDIO_BUFFER_CONVERT)?&_outAudioFormat:&_audioFormat, 0, NULL, 0, NULL, NULL, &_audioFormatDesc);
    if (status != noErr) {
        
        NSLog(@"create audio format description faild ...");
        return;
    }
    
    // Creates an CMSampleBuffer containing audio given packetDescriptions instead of sizing and timing info
    status = CMAudioSampleBufferCreateWithPacketDescriptions(kCFAllocatorDefault,
                                                             blockBuffer,
                                                             true,
                                                             NULL,
                                                             NULL,
                                                             _audioFormatDesc,
                                                             samples,
                                                             timeStamp,
                                                             NULL,
                                                             &sampleBuffer);
    if (status != noErr) {
        
        NSLog(@"create audioSample packet descriptions error ...");
        CFRelease(sampleBuffer);
        CFRelease(blockBuffer);
        return;
    }
    
    
    void(^write)() = ^(){
        
        // Add the audio sample to the asset writer input
        if (CMSampleBufferIsValid(sampleBuffer) && _isRecording) {
            
            if(![_audioWriterInput appendSampleBuffer:sampleBuffer]){
                
                // print an error
                NSLog(@"problem appending audio buffer at time %@",CMTimeCopyDescription(kCFAllocatorDefault, timeStamp));
                CFRelease(sampleBuffer);
            }else{
                NSLog(@"write audio buffer success 。。。");
                CFRelease(sampleBuffer);
                [NSThread sleepForTimeInterval:0.01];
                //[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
            }
        }else{
            // either do nothing and just print an error, or queue the CMSampleBuffer
            // somewhere and add it later, when the AVAssetWriterInput is ready
            NSLog(@"counld not write a frame...");
            CMSampleBufferInvalidate(sampleBuffer);
        }
    };
    
    // pixel buffer queue append manager, prevent thread lock
    dispatch_async(_render_queue, ^{
        
        if (dispatch_semaphore_wait(_pixelAppendSemaphore, DISPATCH_TIME_NOW) == 0) {
            
            dispatch_async(_append_pixelBuffer_queue, ^{
                
                if ([_audioWriterInput isReadyForMoreMediaData] && _videoWriter.status == AVAssetWriterStatusWriting) write();
                dispatch_semaphore_signal(_pixelAppendSemaphore);
            });
        }
        dispatch_semaphore_signal(_frameRenderingSemaphore);
    });
    
    if (blockBuffer) CFRelease(blockBuffer);
}


- (void)writeAudioBuffer:(unsigned char *)buffer size:(UInt32)size samples:(int)samples{
    
    if (!_isRecording && !self.firstTimeStamp) return;
    
    CMSampleBufferRef sampleBuffer              = NULL;
    CMBlockBufferRef blockBuffer                = NULL;
    
    // 编码时所应接收的原始数据长度
    CMItemCount numberOfSamples                 = samples; // value = bitrate/duration; // Stream #0:1, 9, 1/90000: Audio: aac ([15][0][0][0] / 0x000F), 22050 Hz, stereo, fltp
    
    OSStatus result = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault,
                                                         NULL,
                                                         size,
                                                         kCFAllocatorDefault,
                                                         NULL,
                                                         0,
                                                         size,
                                                         kCMBlockBufferAssureMemoryNowFlag,
                                                         &blockBuffer);
    if(result != noErr)
    {
        NSLog(@"Error creating CMBlockBuffer");
        return;
    }
    
    result = CMBlockBufferReplaceDataBytes(buffer, blockBuffer, 0, size);
    if(result != noErr)
    {
        NSLog(@"Error filling CMBlockBuffer");
        return;
    }
    
    // Timestamp of current sample
    CFTimeInterval elapsed = (_displayLink.timestamp - self.firstTimeStamp);
    CMTime timeStamp = CMTimeMakeWithSeconds(elapsed, 1000);
    NSLog(@"audio time stamp = %lld",timeStamp.value/timeStamp.timescale);
    
    result = CMAudioSampleBufferCreateWithPacketDescriptions(kCFAllocatorDefault,
                                                             blockBuffer,
                                                             TRUE,
                                                             0,
                                                             NULL,
                                                             _outAudioFormatDesc,
                                                             numberOfSamples,
                                                             timeStamp,
                                                             NULL,
                                                             &sampleBuffer);
    if(result != noErr)
    {
        NSLog(@"Error creating CMSampleBuffer");
        if (blockBuffer) CFRelease(blockBuffer);
        return;
    }
    CFRelease(blockBuffer);

    void(^write)() = ^(){
        
        while(! _audioWriterInput.readyForMoreMediaData) {
            NSDate *maxDate = [NSDate dateWithTimeIntervalSinceNow:0.5];
            [[NSRunLoop currentRunLoop] runUntilDate:maxDate];
        }
        
        // Add the audio sample to the asset writer input
        if (CMSampleBufferIsValid(sampleBuffer) && _isRecording) {
            
            if(![_audioWriterInput appendSampleBuffer:sampleBuffer]){
                // print an error
                kSCREEN_RECORDING_ERROR(SRWriteStatusCanNotAppendPixel, @"problem appending audio buffer");
                CFRelease(sampleBuffer);
            }else{
                NSLog(@"write audio buffer success 。。。");
                CFRelease(sampleBuffer);
            }
        }else{
            // either do nothing and just print an error, or queue the CMSampleBuffer
            // somewhere and add it later, when the AVAssetWriterInput is ready
            NSLog(@"counld not write a frame...");
            CMSampleBufferInvalidate(sampleBuffer);
        }
    };
    
    // pixel buffer queue append manager, prevent thread lock
    dispatch_async(_render_queue, ^{
        
        if ([_audioWriterInput isReadyForMoreMediaData] && _videoWriter.status == AVAssetWriterStatusWriting) write();
    });
}


#pragma mark    -   recorder action

- (void)startRecordingWithCompletionHanlder:(RecorderOfStatusBlock)completionBlock{
    
    @synchronized (self) {
        
        self.firstTimeStamp = 0;
        [self removeTempFilePath:self.videoURL.path];
    }
    
    if (!_isRecording) {
        
        if ([self setVideoWriterInput]){
            
            completionBlock(YES);
            
            // reset semaphore,Signal (increment) a semaphore.
            dispatch_semaphore_signal(_frameRenderingSemaphore);
        }else {
            
            // The encoder required for this media is busy, NSLocalizedRecoverySuggestion=Stop any other actions that encode media and try again
            completionBlock(NO);
            NSLog(@"AVAsserWriter writer error = %@",_videoWriter.error);
            [self cleanup];
            return;
        }
        
        _isRecording = (_videoWriter.status == AVAssetWriterStatusWriting);
        _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(writeVideoFrame)];
        
        // The system fps default is 60, it's too big
        if ([[UIDevice currentDevice] systemVersion].floatValue < 10.0){
            
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            _displayLink.frameInterval = 3;
#pragma clang diagnostic pop
            
        }else
            _displayLink.preferredFramesPerSecond = kFRAMES_PER_SECOND;
        [_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    }
}

- (void)stopRecordingWithCompletionHanlder:(RecorderOfStatusBlock)completionBlock{
    
    if (_isRecording) {
        
        _isRecording = NO;
        [_displayLink removeFromRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        [_displayLink invalidate];
        [self completeRecordingSession:completionBlock];
    }
}


#pragma mark    -   unitl method

+ (void)videoSaveOfPath:(NSString *)path photoAlbumHanlder:(void (^) (BOOL success, NSError *error))complete NS_AVAILABLE(10_10, 8_0){
    
    PHFetchOptions *fetchOptions = [[PHFetchOptions alloc] init];
    fetchOptions.includeAssetSourceTypes = PHAssetSourceTypeUserLibrary;
    
    /* PHAssetCollection:get videos from ablum name ; countOfAssetsWithMediaType: media files */
    PHFetchResult *fetchResult = [PHAssetCollection fetchAssetCollectionsWithType:PHAssetCollectionTypeAlbum
                                                                          subtype:PHAssetCollectionSubtypeAlbumRegular
                                                                          options:fetchOptions];
    
    dispatch_block_t aBlock = ^{
        
        NSURL *localFileUrl = [NSURL fileURLWithPath:path];
        
        /* changeRequest ，PHAssetCollectionChangeRequest edit video */
        PHAssetChangeRequest *assetChangeRequest = [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:localFileUrl];
        
        if (fetchResult.firstObject != nil) {
            
            PHAssetCollectionChangeRequest *assetCollectionChangeRequest = [PHAssetCollectionChangeRequest changeRequestForAssetCollection:fetchResult.firstObject];
            [assetCollectionChangeRequest addAssets:@[[assetChangeRequest placeholderForCreatedAsset]]];
        }
    };
    
    /* handlers are invoked on an arbitrary serial queue */
    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:aBlock completionHandler:^(BOOL success, NSError *error) {
        
        if (complete) complete(success, error);
    }];
}


- (AudioClassDescription *)getAudioClassDescriptionWithType:(UInt32)type fromManufacturer:(UInt32)manufacturer
{
    static AudioClassDescription desc;
    
    UInt32 encoderSpecifier = type;
    OSStatus st;
    
    UInt32 size;
    st = AudioFormatGetPropertyInfo(kAudioFormatProperty_Encoders,
                                    sizeof(encoderSpecifier),
                                    &encoderSpecifier,
                                    &size);
    if (st) {
        NSLog(@"error getting audio format propery info: %d", (int)(st));
        return nil;
    }
    
    unsigned int count = size / sizeof(AudioClassDescription);
    AudioClassDescription descriptions[count];
    st = AudioFormatGetProperty(kAudioFormatProperty_Encoders,
                                sizeof(encoderSpecifier),
                                &encoderSpecifier,
                                &size,
                                descriptions);
    if (st) {
        NSLog(@"error getting audio format propery: %d", (int)(st));
        return nil;
    }
    
    for (unsigned int i = 0; i < count; i++) {
        if ((type == descriptions[i].mSubType) &&
            (manufacturer == descriptions[i].mManufacturer)) {
            memcpy(&desc, &(descriptions[i]), sizeof(desc));
            return &desc;
        }
    }
    
    return nil;
}

- (void)clearAllCache{
    
    _isRecording = NO;
    
    if (_videoWriter.status == AVAssetWriterStatusWriting) {
        
        // finishWritingWithCompletionHandler: Cannot call method when status is 1'
        dispatch_async(_render_queue, ^{
            
            [_videoWriterInput markAsFinished];
            [_audioWriterInput markAsFinished];
            
            dispatch_sync(_append_pixelBuffer_queue, ^{
                [_videoWriter finishWritingWithCompletionHandler:^{
                    
                    if (_videoWriter) [self cleanup];
                    _isRecording = NO;
                }];
            });
        });
    }else{
        
        [self cleanup];
        _isRecording = NO;
    }
}

- (unsigned long)currentTimestamp{
    
    struct timeval tv;
    if (gettimeofday(&tv, NULL) != 0)
        return 0;
    
    return (tv.tv_sec*1000  + tv.tv_usec / 1000)/1000;
}

@end



@implementation UIViewController (ScreenRecorder)

- (void)prepareScreenRecorder;
{
    UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(recorderGesture:)];
    tapGesture.numberOfTapsRequired = 2;
    tapGesture.delaysTouchesBegan = YES;
    [self.view addGestureRecognizer:tapGesture];
}


- (void)recorderGesture:(UIGestureRecognizer *)recognizer
{
    IDYScreenRecorderManager *recorder = [IDYScreenRecorderManager sharedInstance];
    recorder.presentationView = self.view;
    
    if (recorder.isRecording) {
        
        [recorder stopRecordingWithCompletionHanlder:^(BOOL success) {
            
            NSLog(@"Finished recording");
            [self playEndSound];
        }];
        
    } else {
        
        [recorder startRecordingWithCompletionHanlder:^(BOOL success) {
            
            NSLog(@"Start recording");
            [self playStartSound];
        }];
    }
}


- (void)playStartSound
{
    NSURL *url = [NSURL URLWithString:@"/System/Library/Audio/UISounds/begin_record.caf"];
    SystemSoundID soundID;
    AudioServicesCreateSystemSoundID((__bridge CFURLRef)url, &soundID);
    AudioServicesPlaySystemSound(soundID);
}

- (void)playEndSound
{
    NSURL *url = [NSURL URLWithString:@"/System/Library/Audio/UISounds/end_record.caf"];
    SystemSoundID soundID;
    AudioServicesCreateSystemSoundID((__bridge CFURLRef)url, &soundID);
    AudioServicesPlaySystemSound(soundID);
}

@end

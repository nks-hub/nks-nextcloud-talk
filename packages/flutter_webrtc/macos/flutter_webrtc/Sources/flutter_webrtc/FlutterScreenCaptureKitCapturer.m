#import "FlutterScreenCaptureKitCapturer.h"

#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>

#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#endif

@interface FlutterScreenCaptureKitCapturer ()
#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
<SCStreamOutput>
#endif
@property(nonatomic, strong) RTCVideoCapturer *capturer;
@property(nonatomic, weak) id<RTCVideoCapturerDelegate> delegate;
@property(nonatomic, strong) dispatch_queue_t captureQueue;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) BOOL startingStream;
@property(nonatomic) BOOL stoppingStream;
@property(nonatomic, copy) void (^startCompletion)(NSError *);
@property(nonatomic, strong) NSMutableArray *stopCompletions;
#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
@property(nonatomic, strong) SCStream *stream API_AVAILABLE(macos(12.3));
#endif
@end

@implementation FlutterScreenCaptureKitCapturer

- (instancetype)initWithDelegate:(id<RTCVideoCapturerDelegate>)delegate {
  self = [super init];
  if (self) {
    _delegate = delegate;
    _capturer = [[RTCVideoCapturer alloc] initWithDelegate:delegate];
    _captureQueue = dispatch_queue_create("com.iperius.sck.capture", DISPATCH_QUEUE_SERIAL);
    _stopCompletions = [NSMutableArray array];
  }
  return self;
}

- (void)startCaptureWithFPS:(NSInteger)fps
                   sourceId:(NSString* _Nullable)sourceId
                  onStarted:(void (^)(NSError * _Nullable error))onStarted {
#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
  if (@available(macOS 12.3, *)) {
    dispatch_async(self.captureQueue, ^{
      if (self.startCompletion != nil || self.stream != nil) {
        onStarted([NSError errorWithDomain:@"FlutterScreenCaptureKit" code:-3
            userInfo:@{NSLocalizedDescriptionKey: @"Capture is already starting or active"}]);
        return;
      }
      NSUInteger generation = ++self.generation;
      self.startCompletion = onStarted;
      [self requestShareableContent:^(SCShareableContent *content, NSError *error) {
        dispatch_async(self.captureQueue, ^{
          if (generation != self.generation) return;
          if (error != nil) {
            [self completeStart:error];
            return;
          }

          SCDisplay *display = [self selectDisplayFromContent:content sourceId:sourceId];
          if (display == nil) {
            [self completeStart:[NSError errorWithDomain:@"FlutterScreenCaptureKit" code:-1
                userInfo:@{NSLocalizedDescriptionKey: @"No matching display"}]];
            return;
          }

          self.stream = [self createStreamForDisplay:display fps:fps];
          NSError *addOutputError = nil;
          [self.stream addStreamOutput:self type:SCStreamOutputTypeScreen
                    sampleHandlerQueue:self.captureQueue error:&addOutputError];
          if (addOutputError != nil) {
            self.stream = nil;
            [self completeStart:addOutputError];
            return;
          }

          self.startingStream = YES;
          [self.stream startCaptureWithCompletionHandler:^(NSError *startError) {
            dispatch_async(self.captureQueue, ^{
              self.startingStream = NO;
              if (generation != self.generation) {
                [self stopStream];
              } else if (startError != nil) {
                self.stream = nil;
                [self completeStart:startError];
              } else {
                [self completeStart:nil];
              }
            });
          }];
        });
      }];
    });
    return;
  }
#endif

  NSError *unavailable = [NSError errorWithDomain:@"FlutterScreenCaptureKit"
                                             code:-2
                                         userInfo:@{NSLocalizedDescriptionKey: @"ScreenCaptureKit not available"}];
  onStarted(unavailable);
}

- (void)stopCaptureWithCompletion:(void (^)(void))completion {
#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
  if (@available(macOS 12.3, *)) {
    dispatch_async(self.captureQueue, ^{
      ++self.generation;
      [self.stopCompletions addObject:[completion copy]];
      [self completeStart:[NSError errorWithDomain:@"FlutterScreenCaptureKit" code:-4
          userInfo:@{NSLocalizedDescriptionKey: @"Capture was cancelled"}]];
      // SCStream must finish starting before stop can release its capture session.
      if (!self.startingStream) [self stopStream];
    });
    return;
  }
#endif
  completion();
}

#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
- (void)requestShareableContent:(void (^)(SCShareableContent *, NSError *))completion
    API_AVAILABLE(macos(12.3)) {
  [SCShareableContent getShareableContentWithCompletionHandler:completion];
}

- (SCStream *)createStreamForDisplay:(SCDisplay *)display fps:(NSInteger)fps
    API_AVAILABLE(macos(12.3)) {
  SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
  SCStreamConfiguration *config = [SCStreamConfiguration new];
  config.width = display.width;
  config.height = display.height;
  config.minimumFrameInterval = CMTimeMake(1, (int32_t)MAX(1, fps));
  config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
  if (@available(macOS 13.0, *)) config.showsCursor = YES;
  return [[SCStream alloc] initWithFilter:filter configuration:config delegate:nil];
}

- (void)completeStart:(NSError *)error {
  void (^completion)(NSError *) = self.startCompletion;
  self.startCompletion = nil;
  if (completion) completion(error);
}

- (void)stopStream API_AVAILABLE(macos(12.3)) {
  if (self.stoppingStream) return;
  SCStream *stream = self.stream;
  if (stream == nil) {
    [self completeStop];
    return;
  }
  self.stoppingStream = YES;
  [stream stopCaptureWithCompletionHandler:^(__unused NSError *error) {
    dispatch_async(self.captureQueue, ^{
      self.stream = nil;
      self.stoppingStream = NO;
      [self completeStop];
    });
  }];
}

- (void)completeStop {
  NSArray *completions = [self.stopCompletions copy];
  [self.stopCompletions removeAllObjects];
  for (void (^completion)(void) in completions) completion();
}

- (SCDisplay *)selectDisplayFromContent:(SCShareableContent *)content
                               sourceId:(NSString *)sourceId API_AVAILABLE(macos(12.3)) {
  if (content.displays.count == 0) {
    return nil;
  }

  if (sourceId != nil && sourceId.length > 0) {
    for (SCDisplay *display in content.displays) {
      if ([[NSString stringWithFormat:@"%u", display.displayID] isEqualToString:sourceId]) {
        return display;
      }
    }
    return nil;
  }

  CGDirectDisplayID mainDisplay = CGMainDisplayID();
  for (SCDisplay *display in content.displays) {
    if (display.displayID == mainDisplay) {
      return display;
    }
  }

  return content.displays.firstObject;
}

- (void)stream:(SCStream *)stream
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
        ofType:(SCStreamOutputType)type API_AVAILABLE(macos(12.3)) {
  if (type != SCStreamOutputTypeScreen || stream != self.stream ||
      self.stopCompletions.count > 0 || self.startingStream) {
    return;
  }

  CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
  if (pixelBuffer == nil) {
    return;
  }

  CMTime timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
  int64_t timeStampNs = (int64_t)(CMTimeGetSeconds(timestamp) * 1000000000.0);

  id<RTCVideoFrameBuffer> rtcBuffer = [[RTCCVPixelBuffer alloc] initWithPixelBuffer:pixelBuffer];
  RTCVideoFrame *frame = [[RTCVideoFrame alloc] initWithBuffer:rtcBuffer
                                                      rotation:RTCVideoRotation_0
                                                   timeStampNs:timeStampNs];
  [self.delegate capturer:self.capturer didCaptureVideoFrame:frame];
}
#endif

@end

#import <XCTest/XCTest.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <flutter_webrtc/FlutterScreenCaptureKitCapturer.h>
#import <flutter_webrtc/FlutterRTCDesktopCapturer.h>

@interface FlutterScreenCaptureKitCapturer (Testing)
- (void)requestShareableContent:(void (^)(SCShareableContent *, NSError *))completion;
- (SCStream *)createStreamForDisplay:(SCDisplay *)display fps:(NSInteger)fps;
- (SCDisplay *)selectDisplayFromContent:(SCShareableContent *)content sourceId:(NSString *)sourceId;
@end

@interface FlutterWebRTCPlugin (CaptureTesting)
- (Class)desktopCapturerClass;
- (RTCDesktopCapturer *)legacyCapturerWithSource:(RTCDesktopSource *)source
                                captureDelegate:(id<RTCVideoCapturerDelegate>)delegate;
@end

@interface LegacyCapture : NSObject
@property(nonatomic, strong) id selectedSource;
@property(nonatomic) BOOL usedDefault;
@end
@implementation LegacyCapture
- (instancetype)initWithSource:(id)source delegate:(id)delegate captureDelegate:(id)frames {
  self = [super init];
  if (self) self.selectedSource = source;
  return self;
}
- (instancetype)initWithDefaultScreen:(id)delegate captureDelegate:(id)frames {
  self = [super init];
  if (self) self.usedDefault = YES;
  return self;
}
@end

@interface CapturePlugin : FlutterWebRTCPlugin
@end
@implementation CapturePlugin
- (Class)desktopCapturerClass { return [LegacyCapture class]; }
@end

@interface CaptureDisplay : NSObject
@property(nonatomic) CGDirectDisplayID displayID;
@end
@implementation CaptureDisplay
@end

@interface CaptureContent : NSObject
@property(nonatomic, copy) NSArray *displays;
@end
@implementation CaptureContent
@end

@interface DelayedStream : NSObject
@property(nonatomic, copy) void (^started)(NSError *);
@property(nonatomic, copy) void (^stopped)(NSError *);
@property(nonatomic) NSUInteger stopCount;
@property(nonatomic, strong) XCTestExpectation *startRequested;
@property(nonatomic, strong) XCTestExpectation *stopRequested;
@end
@implementation DelayedStream
- (BOOL)addStreamOutput:(id)output type:(SCStreamOutputType)type
    sampleHandlerQueue:(dispatch_queue_t)queue error:(NSError **)error { return YES; }
- (void)startCaptureWithCompletionHandler:(void (^)(NSError *))completion {
  self.started = completion;
  [self.startRequested fulfill];
}
- (void)stopCaptureWithCompletionHandler:(void (^)(NSError *))completion {
  self.stopCount++;
  self.stopped = completion;
  [self.stopRequested fulfill];
}
@end

@interface DelayedCapturer : FlutterScreenCaptureKitCapturer
@property(nonatomic, copy) void (^contentReady)(SCShareableContent *, NSError *);
@property(nonatomic, strong) XCTestExpectation *contentRequested;
@property(nonatomic, strong) DelayedStream *testStream;
@property(nonatomic) NSUInteger streamCount;
@end
@implementation DelayedCapturer
- (void)requestShareableContent:(void (^)(SCShareableContent *, NSError *))completion {
  self.contentReady = completion;
  [self.contentRequested fulfill];
}
- (SCStream *)createStreamForDisplay:(SCDisplay *)display fps:(NSInteger)fps {
  self.streamCount++;
  return (SCStream *)self.testStream;
}
@end

@interface CaptureFrames : NSObject <RTCVideoCapturerDelegate>
@property(nonatomic, strong) XCTestExpectation *firstFrame;
@property(nonatomic) BOOL receivedFrame;
@end
@implementation CaptureFrames
- (void)capturer:(RTCVideoCapturer *)capturer didCaptureVideoFrame:(RTCVideoFrame *)frame {
  if (!self.receivedFrame && frame.width > 0 && frame.height > 0) {
    self.receivedFrame = YES;
    [self.firstFrame fulfill];
  }
}
@end

@interface ScreenCaptureTests : XCTestCase
@end
@implementation ScreenCaptureTests
- (void)testRealScreenCaptureDeliversFramesWhenAuthorized {
  XCTSkipIf(!CGPreflightScreenCaptureAccess(),
            @"Screen recording permission is not granted to the test host");
  CaptureFrames *frames = [CaptureFrames new];
  frames.firstFrame = [self expectationWithDescription:@"screen frame"];
  FlutterScreenCaptureKitCapturer *capturer = [[FlutterScreenCaptureKitCapturer alloc] initWithDelegate:frames];
  XCTestExpectation *started = [self expectationWithDescription:@"real capture started"];
  __block NSError *startError = nil;
  [capturer startCaptureWithFPS:10 sourceId:nil onStarted:^(NSError *error) {
    startError = error;
    [started fulfill];
  }];
  [self waitForExpectations:@[started] timeout:15];
  XCTAssertNil(startError);
  if (startError == nil) [self waitForExpectations:@[frames.firstFrame] timeout:15];
  XCTestExpectation *stopped = [self expectationWithDescription:@"real capture stopped"];
  [capturer stopCaptureWithCompletion:^{ [stopped fulfill]; }];
  [self waitForExpectations:@[stopped] timeout:15];
}

- (SCShareableContent *)contentWithIds:(NSArray<NSNumber *> *)ids {
  NSMutableArray *displays = [NSMutableArray array];
  for (NSNumber *number in ids) {
    CaptureDisplay *display = [CaptureDisplay new];
    display.displayID = number.unsignedIntValue;
    [displays addObject:display];
  }
  CaptureContent *content = [CaptureContent new];
  content.displays = displays;
  return (SCShareableContent *)content;
}

- (DelayedCapturer *)capturer {
  DelayedCapturer *capturer = [[DelayedCapturer alloc] initWithDelegate:nil];
  capturer.contentRequested = [self expectationWithDescription:@"content requested"];
  capturer.testStream = [DelayedStream new];
  return capturer;
}

- (void)testRequestedDisplayIsPreserved {
  FlutterScreenCaptureKitCapturer *capturer = [[FlutterScreenCaptureKitCapturer alloc] initWithDelegate:nil];
  SCDisplay *display = [capturer selectDisplayFromContent:[self contentWithIds:@[@101, @202]] sourceId:@"202"];
  XCTAssertEqual(display.displayID, 202u);
}

- (void)testMissingRequestedDisplayDoesNotFallBack {
  FlutterScreenCaptureKitCapturer *capturer = [[FlutterScreenCaptureKitCapturer alloc] initWithDelegate:nil];
  XCTAssertNil([capturer selectDisplayFromContent:[self contentWithIds:@[@101]] sourceId:@"202"]);
  XCTAssertNil([capturer selectDisplayFromContent:[self contentWithIds:@[]] sourceId:nil]);
  XCTAssertEqual([capturer selectDisplayFromContent:[self contentWithIds:@[@101]] sourceId:nil].displayID, 101u);
}

- (void)testStopDuringEnumerationPreventsLateStreamCreation {
  DelayedCapturer *capturer = [self capturer];
  XCTestExpectation *cancelled = [self expectationWithDescription:@"start cancelled"];
  [capturer startCaptureWithFPS:30 sourceId:@"202" onStarted:^(NSError *error) {
    XCTAssertEqual(error.code, -4);
    [cancelled fulfill];
  }];
  [self waitForExpectations:@[capturer.contentRequested] timeout:2];
  XCTestExpectation *stopped = [self expectationWithDescription:@"stopped"];
  [capturer stopCaptureWithCompletion:^{ [stopped fulfill]; }];
  [self waitForExpectations:@[cancelled, stopped] timeout:2];
  capturer.contentReady([self contentWithIds:@[@202]], nil);
  XCTestExpectation *drained = [self expectationWithDescription:@"late content drained"];
  [capturer stopCaptureWithCompletion:^{ [drained fulfill]; }];
  [self waitForExpectations:@[drained] timeout:2];
  XCTAssertEqual(capturer.streamCount, 0u);
}

- (void)testStopWaitsForDelayedSystemStartAndStop {
  DelayedCapturer *capturer = [self capturer];
  capturer.testStream.startRequested = [self expectationWithDescription:@"stream starting"];
  capturer.testStream.stopRequested = [self expectationWithDescription:@"stream stopping"];
  XCTestExpectation *cancelled = [self expectationWithDescription:@"cancelled"];
  [capturer startCaptureWithFPS:30 sourceId:@"202" onStarted:^(NSError *error) {
    XCTAssertEqual(error.code, -4);
    [cancelled fulfill];
  }];
  [self waitForExpectations:@[capturer.contentRequested] timeout:2];
  capturer.contentReady([self contentWithIds:@[@202]], nil);
  [self waitForExpectations:@[capturer.testStream.startRequested] timeout:2];
  __block BOOL didStop = NO;
  XCTestExpectation *stopped = [self expectationWithDescription:@"stopped"];
  [capturer stopCaptureWithCompletion:^{ didStop = YES; [stopped fulfill]; }];
  [self waitForExpectations:@[cancelled] timeout:2];
  XCTAssertFalse(didStop);
  XCTAssertEqual(capturer.testStream.stopCount, 0u);
  capturer.testStream.started(nil);
  [self waitForExpectations:@[capturer.testStream.stopRequested] timeout:2];
  XCTAssertFalse(didStop);
  capturer.testStream.stopped(nil);
  [self waitForExpectations:@[stopped] timeout:2];
  XCTAssertEqual(capturer.testStream.stopCount, 1u);
}

- (void)testStartErrorIsDeliveredOnceAndAllowsRetry {
  DelayedCapturer *capturer = [self capturer];
  capturer.testStream.startRequested = [self expectationWithDescription:@"stream starting"];
  XCTestExpectation *failed = [self expectationWithDescription:@"start failed"];
  [capturer startCaptureWithFPS:30 sourceId:@"202" onStarted:^(NSError *error) {
    XCTAssertEqual(error.code, 42);
    [failed fulfill];
  }];
  [self waitForExpectations:@[capturer.contentRequested] timeout:2];
  capturer.contentReady([self contentWithIds:@[@202]], nil);
  [self waitForExpectations:@[capturer.testStream.startRequested] timeout:2];
  capturer.testStream.started([NSError errorWithDomain:@"test" code:42 userInfo:nil]);
  [self waitForExpectations:@[failed] timeout:2];
  capturer.contentRequested = [self expectationWithDescription:@"retry requested"];
  XCTestExpectation *retryFailed = [self expectationWithDescription:@"retry content failed"];
  [capturer startCaptureWithFPS:30 sourceId:@"202" onStarted:^(NSError *error) {
    XCTAssertEqual(error.code, 43);
    [retryFailed fulfill];
  }];
  [self waitForExpectations:@[capturer.contentRequested] timeout:2];
  capturer.contentReady(nil, [NSError errorWithDomain:@"test" code:43 userInfo:nil]);
  [self waitForExpectations:@[retryFailed] timeout:2];
}

- (void)testLegacyCapturerReceivesExplicitSource {
  CapturePlugin *plugin = [CapturePlugin new];
  id source = [NSObject new];
  LegacyCapture *selected = (LegacyCapture *)[plugin legacyCapturerWithSource:source captureDelegate:nil];
  XCTAssertEqual(selected.selectedSource, source);
  XCTAssertFalse(selected.usedDefault);
  LegacyCapture *defaultScreen = (LegacyCapture *)[plugin legacyCapturerWithSource:nil captureDelegate:nil];
  XCTAssertTrue(defaultScreen.usedDefault);
}
@end

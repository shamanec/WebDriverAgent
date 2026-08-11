//
//  FBGadsCommands.m
//  WebDriverAgent
//
//  Created by Nikola Shabanov on 17.09.25.
//  Copyright © 2025 Facebook. All rights reserved.
//

#import "FBGadsCommands.h"
#import "XCUIDevice+Gads.h"
#import "XCUIDevice+FBHelpers.h"
#import "XCUIApplication+FBHelpers.h"

#import <sys/sysctl.h>

@import UniformTypeIdentifiers;

#import "FBCapabilities.h"
#import "FBConfiguration.h"
#import "FBProtocolHelpers.h"
#import "FBRouteRequest.h"
#import "FBSession.h"
#import "FBSettings.h"
#import "FBActiveAppDetectionPoint.h"
#import "FBXCodeCompatibility.h"
#import "FBCommandStatus.h"
#import "FBElementTypeTransformer.h"
#import "FBRoute.h"
#import "FBResponsePayload.h"
#import "FBRouteRequest.h"
#import "FBScreenshot.h"
#import "FBXCAccessibilityElement.h"
#import "FBXCAXClientProxy.h"
#import "FBXCElementSnapshot.h"
#import "RouteResponse.h"
#import "XCUIScreen.h"
#import "FBImageProcessor.h"


/**
 * Response payload that serializes to compact (non-pretty-printed) JSON.
 *
 * The stock FBResponseJSONPayload always serializes with NSJSONWritingPrettyPrinted,
 * which roughly doubles the wire size of a large element tree. For /source-fast the
 * payload size is the whole point, so this payload owns its serialization instead.
 */
@interface FBGadsCompactJSONPayload : NSObject <FBResponsePayload>

- (instancetype)initWithObject:(NSDictionary *)object;

@end

@implementation FBGadsCompactJSONPayload {
  NSDictionary *_object;
}

- (instancetype)initWithObject:(NSDictionary *)object
{
  if ((self = [super init])) {
    _object = object;
  }
  return self;
}

- (void)dispatchWithResponse:(RouteResponse *)response
{
  NSError *error;
  NSData *jsonData = [NSJSONSerialization dataWithJSONObject:_object options:0 error:&error];
  if (nil == jsonData) {
    NSString *fallback = [NSString stringWithFormat:@"{\"value\":null,\"error\":\"%@\"}",
                          error.localizedDescription ?: @"JSON serialization failed"];
    jsonData = (NSData *)[fallback dataUsingEncoding:NSUTF8StringEncoding];
  }
  [response setHeader:@"Content-Type" value:@"application/json;charset=UTF-8"];
  [response setStatusCode:200];
  [response respondWithData:jsonData];
}

@end


/**
 * The minimal accessibility attribute set fetched per node for /source-fast.
 *
 * The regular /source snapshot requests the full default attribute set for every
 * element in the hierarchy; this list keeps only what a remote-control client needs
 * to render and target elements. The names are passed through XCElementSnapshot's
 * sanitizer so any attributes the snapshot machinery itself requires are retained.
 */
static NSArray<NSString *> *FBGadsFastSourceAttributes(void)
{
  static NSArray<NSString *> *attributes;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    // The element hierarchy is produced by the request parameters (maxDepth /
    // traverseFromParentsToChildren), NOT by an attribute. Do not add
    // XC_kAXXCAttributeChildren here: array-valued attributes break NSSecureCoding
    // of the XPC reply (XCElementSnapshot only decodes value/number/string/dict
    // attribute values) and the whole snapshot response gets dropped.
    NSArray<NSString *> *minimal = @[
      @"XC_kAXXCAttributeElementType",
      @"XC_kAXXCAttributeIdentifier",
      @"XC_kAXXCAttributeLabel",
      @"XC_kAXXCAttributeValue",
      @"XC_kAXXCAttributeFrame",
    ];
    Class snapshotClass = NSClassFromString(@"XCElementSnapshot");
    attributes = [snapshotClass respondsToSelector:@selector(sanitizedElementSnapshotHierarchyAttributesForAttributes:isMacOS:)]
      ? [snapshotClass sanitizedElementSnapshotHierarchyAttributesForAttributes:minimal isMacOS:NO]
      : minimal;
  });
  return attributes;
}

// NSJSONSerialization throws on NaN/Inf, which corrupted AX frames can contain
static inline double FBGadsFiniteOrZero(CGFloat value)
{
  return isfinite(value) ? (double)value : 0.0;
}

/**
 * Converts a snapshot subtree into a lean dictionary, bottom-up.
 *
 * When pruning is enabled, subtrees that are entirely off-screen are culled: children
 * are processed first, and a node is kept if any descendant survived OR its own frame
 * intersects the screen rectangle. The bottom-up order matters — recycled list
 * containers (UITableView/UICollectionView cells) report stale off-screen frames
 * while the rows they render have correct on-screen frames, so a top-down frame test
 * would drop visible content. Empty/invalid frames never intersect, which means
 * zero-frame containers only survive when they host kept descendants.
 *
 * Returns nil when the whole subtree is off-screen. Child order matches /source.
 */
static NSDictionary * _Nullable FBGadsLeanTreeForSnapshot(id<FBXCElementSnapshot> snapshot,
                                                          BOOL pruneOffscreen,
                                                          CGRect screenRect)
{
  NSMutableArray<NSDictionary *> *keptChildren = [NSMutableArray array];
  for (id<FBXCElementSnapshot> child in snapshot.children) {
    @autoreleasepool {
      NSDictionary *childInfo = FBGadsLeanTreeForSnapshot(child, pruneOffscreen, screenRect);
      if (nil != childInfo) {
        [keptChildren addObject:childInfo];
      }
    }
  }

  CGRect frame = snapshot.frame;
  BOOL isOnScreen = !CGRectIsEmpty(frame) && CGRectIntersectsRect(frame, screenRect);
  if (pruneOffscreen && !isOnScreen && 0 == keptChildren.count) {
    return nil;
  }

  NSMutableDictionary *info = [NSMutableDictionary dictionary];
  info[@"type"] = [FBElementTypeTransformer shortStringWithElementType:snapshot.elementType];
  info[@"rect"] = @{
    @"x": @(FBGadsFiniteOrZero(CGRectGetMinX(frame))),
    @"y": @(FBGadsFiniteOrZero(CGRectGetMinY(frame))),
    @"width": @(FBGadsFiniteOrZero(CGRectGetWidth(frame))),
    @"height": @(FBGadsFiniteOrZero(CGRectGetHeight(frame))),
  };
  // Empty strings are omitted entirely instead of serializing "" or null
  if (snapshot.identifier.length > 0) {
    info[@"name"] = snapshot.identifier;
  }
  if (snapshot.label.length > 0) {
    info[@"label"] = snapshot.label;
  }
  id value = snapshot.value;
  if ([value isKindOfClass:NSString.class]) {
    if (((NSString *)value).length > 0) {
      info[@"value"] = value;
    }
  } else if ([value isKindOfClass:NSNumber.class]) {
    info[@"value"] = value;
  } else if (nil != value) {
    info[@"value"] = [value description];
  }
  if (keptChildren.count > 0) {
    info[@"children"] = keptChildren;
  }
  return info;
}


@implementation FBGadsCommands

#pragma mark - <FBCommandHandler>

+ (NSArray *)routes
{
  return
  @[
    [[FBRoute GET:@"/screenshot-hq"].withoutSession respondWithTarget:self action:@selector(takeScreenshotGadsHighQuality:)],
    [[FBRoute GET:@"/screenshot"].withoutSession respondWithTarget:self action:@selector(takeScreenshotGads:)],
    [[FBRoute GET:@"/screenshot-lq"].withoutSession respondWithTarget:self action:@selector(takeScreenshotGadsLowQuality:)],
    [[FBRoute POST:@"/wda/apps/activate"].withoutSession respondWithTarget:self action:@selector(handleAppActivateNoSession:)],
    [[FBRoute POST:@"/wda/apps/terminate"].withoutSession respondWithTarget:self action:@selector(handleAppTerminateNoSession:)],
    [[FBRoute POST:@"/wda/tap"].withoutSession respondWithTarget:self action:@selector(handleDeviceTap:)],
    [[FBRoute POST:@"/wda/swipe"].withoutSession respondWithTarget:self action:@selector(handleDeviceSwipe:)],
    [[FBRoute POST:@"/wda/type"].withoutSession respondWithTarget:self action:@selector(handleDeviceType:)],
    [[FBRoute POST:@"/wda/touchAndHold"].withoutSession respondWithTarget:self action:@selector(handleTouchAndHold:)],
    [[FBRoute POST:@"/wda/doubleTap"].withoutSession respondWithTarget:self action:@selector(handleDoubleTap:)],
    [[FBRoute POST:@"/wda/pinch"].withoutSession respondWithTarget:self action:@selector(handlePinch:)],
    [[FBRoute POST:@"/wda/dragDrop"].withoutSession respondWithTarget:self action:@selector(handleDragDrop:)],
    [[FBRoute POST:@"/wda/edgeSwipe"].withoutSession respondWithTarget:self action:@selector(handleEdgeSwipe:)],
    [[FBRoute POST:@"/wda/twoFingerScroll"].withoutSession respondWithTarget:self action:@selector(handleTwoFingerScroll:)],
    [[FBRoute POST:@"/gads-update-stream-settings"].withoutSession respondWithTarget:self action:@selector(handleUpdateStreamSettings:)],
    [[FBRoute POST:@"/wda/appSwitcher"].withoutSession respondWithTarget:self action:@selector(handleAppSwitcher:)],
    [[FBRoute POST:@"/wda/startBroadcast"].withoutSession respondWithTarget:self action:@selector(handleStartBroadcast:)],
    [[FBRoute GET:@"/source-fast"].withoutSession respondWithTarget:self action:@selector(handleGetFastSourceGads:)],
  ];
}

/**
 * No-session version of screenshot capture with maximum quality
 *
 * This method provides high-quality screenshot capture without requiring an active session.
 * Uses full compression quality (1.0) for maximum image fidelity.
 *
 * Direct JPEG output without additional processing
 *
 * Use case: When you need the highest quality screenshot for detailed analysis
 * or when file size is not a concern.
 */
+ (id<FBResponsePayload>)takeScreenshotGadsHighQuality:(FBRouteRequest *)request
{
  NSError *error;
    CGFloat compressionQuality = 1;
    long long mainScreenID = [XCUIScreen.mainScreen displayID];

    NSData *screenshotData = [FBScreenshot takeInOriginalResolutionWithScreenID:mainScreenID
                                                             compressionQuality:compressionQuality
                                                                            uti:UTTypeJPEG
                                                                        timeout:1
                                                                          error:&error];
    if (nil == screenshotData) {
      return FBResponseWithStatus([FBCommandStatus unableToCaptureScreenErrorWithMessage:error.description traceback:nil]);
    }

    NSString *screenshot = [screenshotData base64EncodedStringWithOptions:0];
    return FBResponseWithObject(@{@"screenshot": screenshot});
}

/**
 * No-session version of screenshot capture with balanced quality and scaling
 *
 * This method provides screenshot capture without requiring an active session,
 * with intelligent scaling to balance quality and file size.
 *
 * Moderate compression (0.7) for good quality with reasonable file size
 * Smart scaling using sqrt(0.8) to compensate for double scaling in FBImageProcessor
 * Uses FBImageProcessor following the same pattern as MJPEG server
 *
 * Notes:
 * - Uses sqrt(0.8) scaling factor to achieve approximately 80% linear dimensions
 * - FBImageProcessor applies scaling to both size and format.scale, hence the sqrt compensation
 *
 * Use case: Standard screenshot endpoint with good balance of quality and performance.
 */
+ (id<FBResponsePayload>)takeScreenshotGads:(FBRouteRequest *)request
{
    NSError *error;
    long long mainScreenID = [XCUIScreen.mainScreen displayID];

    NSData *screenshotData = [FBScreenshot takeInOriginalResolutionWithScreenID:mainScreenID
                                                             compressionQuality:0.7
                                                                            uti:UTTypeJPEG
                                                                        timeout:1
                                                                          error:&error];
    if (nil == screenshotData) {
      return FBResponseWithStatus([FBCommandStatus unableToCaptureScreenErrorWithMessage:error.description traceback:nil]);
    }

    CGFloat scalingFactor = sqrt(0.8);
    FBImageProcessor *imageProcessor = [[FBImageProcessor alloc] init];
    NSData *scaledImageData = [imageProcessor scaledImageWithData:screenshotData
                                                              uti:UTTypeJPEG
                                                    scalingFactor:scalingFactor
                                               compressionQuality:0.7
                                                            error:&error];

    if (nil == scaledImageData) {
      return FBResponseWithStatus([FBCommandStatus unableToCaptureScreenErrorWithMessage:error.description traceback:nil]);
    }

    NSString *screenshot = [scaledImageData base64EncodedStringWithOptions:0];
    return FBResponseWithObject(@{@"screenshot": screenshot});
}

/**
 * No-session version of screenshot capture optimized for minimal file size
 *
 * This method provides screenshot capture without requiring an active session,
 * with aggressive scaling and compression to minimize file size while maintaining usability.
 *
 * Notes:
 * - Uses sqrt(0.5) ≈ 0.707 scaling factor to achieve 50% linear dimensions
 * - Results in ~25% of original image area (50% width × 50% height)
 *
 * Use case: When bandwidth is limited or storage space is constrained, but screenshot
 * content still needs to be recognizable for basic analysis.
 */
+ (id<FBResponsePayload>)takeScreenshotGadsLowQuality:(FBRouteRequest *)request
{
  NSError *error;
  long long mainScreenID = [XCUIScreen.mainScreen displayID];

  NSData *screenshotData = [FBScreenshot takeInOriginalResolutionWithScreenID:mainScreenID
                                                           compressionQuality:0.7
                                                                          uti:UTTypeJPEG
                                                                      timeout:1
                                                                        error:&error];
  if (nil == screenshotData) {
    return FBResponseWithStatus([FBCommandStatus unableToCaptureScreenErrorWithMessage:error.description traceback:nil]);
  }

  CGFloat scalingFactor = sqrt(0.5);
  FBImageProcessor *imageProcessor = [[FBImageProcessor alloc] init];
  NSData *scaledImageData = [imageProcessor scaledImageWithData:screenshotData
                                                            uti:UTTypeJPEG
                                                  scalingFactor:scalingFactor
                                             compressionQuality:0.7
                                                          error:&error];

  if (nil == scaledImageData) {
    return FBResponseWithStatus([FBCommandStatus unableToCaptureScreenErrorWithMessage:error.description traceback:nil]);
  }

  NSString *screenshot = [scaledImageData base64EncodedStringWithOptions:0];
  return FBResponseWithObject(@{@"screenshot": screenshot});
}

// MARK - Custom app activation without session
+ (id<FBResponsePayload>)handleAppActivateNoSession:(FBRouteRequest *)request
{
  NSString *bundleId = (NSString *)request.arguments[@"bundleId"];
  if (bundleId.length == 0) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"bundleId is required" traceback:nil]);
  }

  // Get the current idle timeout
  NSTimeInterval previousTimeout = FBConfiguration.waitForIdleTimeout;
  // Init the application
  XCUIApplication *app = [[XCUIApplication alloc] initWithBundleIdentifier:bundleId];
  // Set the idle timeout to 0 before activating app
  // Because activating WebDriverAgent will wait for idle and it is too long
  // Setting app.fb_shouldWaitForQuiescence does not work
  FBConfiguration.waitForIdleTimeout = 0;
  [app activate];
  // Rever to the original idle timeout from before activation
  FBConfiguration.waitForIdleTimeout = previousTimeout;
  return FBResponseWithOK();
}

// MARK - Custom app termination without session
+ (id<FBResponsePayload>)handleAppTerminateNoSession:(FBRouteRequest *)request
{
  NSString *bundleId = (NSString *)request.arguments[@"bundleId"];
  if (bundleId.length == 0) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"bundleId is required" traceback:nil]);
  }

  XCUIApplication *app = [[XCUIApplication alloc] initWithBundleIdentifier:bundleId];
  [app terminate];
  return FBResponseWithOK();
}

+ (id<FBResponsePayload>)handleUpdateStreamSettings:(FBRouteRequest *)request
{
  NSDictionary *args = request.arguments;

  NSUInteger fps = args[@"fps"] ? [args[@"fps"] unsignedIntegerValue] : 30;
  NSUInteger quality = args[@"quality"] ? [args[@"quality"] unsignedIntegerValue] : 75;
  NSUInteger scalingFactor = args[@"scalingFactor"] ? [args[@"scalingFactor"] unsignedIntegerValue] : 50;

  [FBConfiguration setMjpegServerFramerate:fps];
  [FBConfiguration setMjpegServerScreenshotQuality:quality];
  [FBConfiguration setMjpegScalingFactor:scalingFactor];

  return FBResponseWithObject(@{
    @"fps": @([FBConfiguration mjpegServerFramerate]),
    @"quality": @([FBConfiguration mjpegServerScreenshotQuality]),
    @"scalingFactor": @([FBConfiguration mjpegScalingFactor]),
  });
}

+ (id<FBResponsePayload>)handleAppSwitcher:(FBRouteRequest *)request
{
  CGFloat screenWidth = [request.arguments[@"screenWidth"] doubleValue];
  CGFloat screenHeight = [request.arguments[@"screenHeight"] doubleValue];
  CGFloat duration = request.arguments[@"duration"] ? [request.arguments[@"duration"] doubleValue] : 0.3;
  [XCUIDevice.sharedDevice fb_synthOpenAppSwitcherWithScreenWidth:screenWidth screenHeight:screenHeight duration:duration];
  return FBResponseWithOK();
}

+ (id <FBResponsePayload>)handleDeviceType:(FBRouteRequest *)request
{
  NSString *text = request.arguments[@"text"];
  [XCUIDevice.sharedDevice fb_enqueueTypeText:text];
  return FBResponseWithOK();
}

+ (id <FBResponsePayload>)handleDeviceTap:(FBRouteRequest *)request
{
  CGFloat x = [request.arguments[@"x"] doubleValue];
  CGFloat y = [request.arguments[@"y"] doubleValue];
  [XCUIDevice.sharedDevice
    fb_synthTapWithX:x
    y:y];

  return FBResponseWithOK();
}

+ (id <FBResponsePayload>)handleDeviceSwipe:(FBRouteRequest *)request
{
  CGFloat startX = [request.arguments[@"startX"] doubleValue];
  CGFloat startY = [request.arguments[@"startY"] doubleValue];
  CGFloat endX = [request.arguments[@"endX"] doubleValue];
  CGFloat endY = [request.arguments[@"endY"] doubleValue];
  CGFloat delay = [request.arguments[@"delay"] doubleValue];
  [XCUIDevice.sharedDevice
    fb_synthSwipe:startX
    y1:startY x2:endX y2:endY delay:delay];

  return FBResponseWithOK();
}

+ (id <FBResponsePayload>)handleTouchAndHold:(FBRouteRequest *)request
{
  CGFloat x = [request.arguments[@"x"] doubleValue];
  CGFloat y = [request.arguments[@"y"] doubleValue];
  CGFloat delay = [request.arguments[@"duration"] doubleValue];
  [XCUIDevice.sharedDevice
   fb_synthTouchAndHold:x y:y delay:delay];

  return FBResponseWithOK();
}

/**
 * Synthesizes a pinch-to-zoom gesture using two coordinated finger movements
 *
 * Creates a multi-touch gesture where two fingers move simultaneously from/to
 * positions calculated around a center point. The scale determines how far apart
 * the fingers are - smaller scale = fingers closer (zoom out), larger scale =
 * fingers farther apart (zoom in).
 *
 * centerX The horizontal coordinate of the pinch center in screen points
 * centerY The vertical coordinate of the pinch center in screen points
 * startScale Initial distance between fingers (1.0 = 100pt apart)
 * endScale Final distance between fingers (2.0 = 200pt apart for zoom in)
 * duration Duration of the pinch gesture in seconds
 *
 * Note: Scale > 1.0 zooms in, scale < 1.0 zooms out. Typical range: 0.5-3.0
 */
+ (id <FBResponsePayload>)handlePinch:(FBRouteRequest *)request
{
  CGFloat centerX = [request.arguments[@"centerX"] doubleValue];
  CGFloat centerY = [request.arguments[@"centerY"] doubleValue];
  CGFloat startScale = [request.arguments[@"startScale"] doubleValue] ?: 1.0;
  CGFloat endScale = [request.arguments[@"endScale"] doubleValue] ?: 2.0;
  CGFloat duration = [request.arguments[@"duration"] doubleValue] ?: 1.0;

  [XCUIDevice.sharedDevice
   fb_synthPinchWithCenterX:centerX
                    centerY:centerY
                 startScale:startScale
                   endScale:endScale
                   duration:duration];

  return FBResponseWithOK();
}

/**
 * Synthesizes a drag and drop gesture from one point to another
 *
 * Creates a touch sequence that presses down at the start point, holds for
 * selection, moves to the target point, and releases. This simulates the
 * standard iOS drag-and-drop interaction pattern used for reordering items,
 * moving files, or dragging content between applications.
 *
 * startX Starting horizontal coordinate in screen points
 * startY Starting vertical coordinate in screen points
 * endX Ending horizontal coordinate in screen points
 * endY Ending vertical coordinate in screen points
 * holdTime Duration to hold at start before moving (selection time)
 * dragDuration Duration of the movement from start to end
 *
 * Note: holdTime should be 0.5+ seconds for reliable selection.
 * Total gesture time = holdTime + dragDuration.
 */
+ (id <FBResponsePayload>)handleDragDrop:(FBRouteRequest *)request
{
  CGFloat startX = [request.arguments[@"startX"] doubleValue];
  CGFloat startY = [request.arguments[@"startY"] doubleValue];
  CGFloat endX = [request.arguments[@"endX"] doubleValue];
  CGFloat endY = [request.arguments[@"endY"] doubleValue];
  CGFloat holdTime = [request.arguments[@"holdTime"] doubleValue] ?: 0.5;
  CGFloat dragDuration = [request.arguments[@"dragDuration"] doubleValue] ?: 1.0;

  [XCUIDevice.sharedDevice
   fb_synthDragFromX:startX
               Y:startY
             toX:endX
               Y:endY
        holdTime:holdTime
    dragDuration:dragDuration];

  return FBResponseWithOK();
}

/**
 * Synthesizes an edge swipe gesture from a screen edge inward
 *
 * Creates a swipe gesture that starts from the very edge of the screen and
 * moves inward by the specified distance. This simulates iOS system gestures
 * like Control Center (bottom edge), Notification Center (top edge), back
 * navigation (left edge), and app switcher (right edge on some devices).
 *
 * edge The screen edge/region to swipe from: 0=top-left, 1=top-right, 2=left-center, 3=bottom-center, 4=right-center
 * distance How far to swipe inward from the edge in screen points
 * duration Duration of the swipe gesture in seconds
 *
 * Note: Edge values: 0=top-left, 1=top-right, 2=left-center, 3=bottom-center, 4=right-center. Distance typically
 * 50-200 points. Be careful with system gesture conflicts.
 */
+ (id <FBResponsePayload>)handleEdgeSwipe:(FBRouteRequest *)request
{
  NSInteger edge = [request.arguments[@"edge"] integerValue];
  CGFloat distance = [request.arguments[@"distance"] doubleValue] ?: 100.0;
  CGFloat duration = [request.arguments[@"duration"] doubleValue] ?: 0.5;

  BOOL success;
  if (edge == 3) {
    // Bottom edge uses high-level XCUICoordinate approach
    success = [XCUIDevice.sharedDevice fb_synthEdgeSwipeBottomHighLevel:distance duration:duration];
  } else {
    // All other edges use low-level XCPointerEventPath approach
    success = [XCUIDevice.sharedDevice fb_synthEdgeSwipeLowLevel:edge distance:distance duration:duration];
  }

  return success ? FBResponseWithOK() : FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:@"Edge swipe failed" traceback:nil]);
}

/**
 * Synthesizes a double tap gesture at the specified coordinates
 *
 * Creates two rapid tap events at the same location with a short interval
 * between them. This simulates the iOS double-tap gesture commonly used for
 * zooming, text selection, or activating special actions in apps.
 *
 * x The horizontal coordinate in screen points
 * y The vertical coordinate in screen points
 * tapDelay Delay between the two taps in seconds (typically 0.1-0.3)
 *
 * Note: tapDelay should be 0.1-0.3 seconds for reliable recognition.
 * Each individual tap lasts 50ms with tapDelay between them.
 */
+ (id <FBResponsePayload>)handleDoubleTap:(FBRouteRequest *)request
{
  CGFloat x = [request.arguments[@"x"] doubleValue];
  CGFloat y = [request.arguments[@"y"] doubleValue];
  CGFloat tapDelay = [request.arguments[@"tapDelay"] doubleValue] ?: 0.2;

  [XCUIDevice.sharedDevice
   fb_synthDoubleTapWithX:x
                        y:y
                 tapDelay:tapDelay];

  return FBResponseWithOK();
}

/**
 * Synthesizes a two-finger scroll gesture for precise content navigation
 *
 * Creates a synchronized two-finger movement that simulates trackpad-style
 * scrolling. Unlike single-finger swipes that trigger navigation gestures,
 * two-finger scrolling provides smooth content movement with momentum and
 * is recognized by iOS as content manipulation rather than navigation.
 *
 * startX Starting horizontal coordinate for scroll center
 * startY Starting vertical coordinate for scroll center
 * endX Ending horizontal coordinate for scroll center
 * endY Ending vertical coordinate for scroll center
 * duration Duration of the scroll gesture in seconds
 * fingerSpacing Distance between the two fingers in screen points
 *
 * Note: fingerSpacing typically 30-80 points. Larger spacing may be more
 * reliable but could conflict with pinch gestures.
 */
/**
 * Starts a screen broadcast by automating Control Center interaction
 *
 * This endpoint performs a multi-step UI automation flow:
 * 1. Detects device type (Face ID vs Home Button) via safe area insets
 * 2. Opens Control Center with the appropriate swipe gesture
 * 3. Finds and long-presses the Screen Recording button to open the broadcast picker
 * 4. Selects the specified app from the broadcast picker
 * 5. Taps "Start Broadcast"
 *
 * appName (required) The name of the broadcast app to select in the picker
 * screenRecordingName (optional) The accessibility label of the Screen Recording button, defaults to "Screen Recording"
 * timeout (optional) Timeout in seconds for each element lookup, defaults to 5.0
 *
 * Note: This blocks the HTTP response until the full flow completes (several seconds).
 * Accessibility labels may change between iOS versions.
 */
/**
 * Returns the hardware model identifier, e.g. "iPhone11,8" for the iPhone XR.
 * On the Simulator hw.machine is the host architecture, so the real identifier is read
 * from the SIMULATOR_MODEL_IDENTIFIER environment variable instead.
 */
+ (NSString *)fb_deviceModelIdentifier
{
  NSString *simIdentifier = NSProcessInfo.processInfo.environment[@"SIMULATOR_MODEL_IDENTIFIER"];
  if (simIdentifier.length > 0) {
    return simIdentifier;
  }
  size_t size = 0;
  if (sysctlbyname("hw.machine", NULL, &size, NULL, 0) != 0 || size == 0) {
    return @"";
  }
  char *machine = malloc(size);
  if (NULL == machine) {
    return @"";
  }
  NSString *identifier = @"";
  if (sysctlbyname("hw.machine", machine, &size, NULL, 0) == 0) {
    identifier = [NSString stringWithUTF8String:machine] ?: @"";
  }
  free(machine);
  return identifier;
}

/**
 * Whether the current device has a hardware Home button (so Control Center is opened by
 * swiping up from the bottom, and pressButton:Home works).
 *
 * iPhone X (iPhone10,3 / iPhone10,6) was the first Face ID phone, but it shares generation
 * 10 with the Home-button iPhone 8/8+ (iPhone10,1/10,2/10,4/10,5). From generation 11 on,
 * the only Home-button phones are the SE models (iPhone SE 2 = iPhone12,8, SE 3 = iPhone14,6).
 * iPads and unknown models default to NO (Face ID gesture), which also opens Control Center
 * on modern iPads.
 */
+ (BOOL)fb_isHomeButtonDevice
{
  NSString *model = [self fb_deviceModelIdentifier];
  if (![model hasPrefix:@"iPhone"]) {
    return NO;
  }

  NSScanner *scanner = [NSScanner scannerWithString:[model substringFromIndex:@"iPhone".length]];
  NSInteger major = 0;
  NSInteger minor = 0;
  if (![scanner scanInteger:&major]) {
    return NO;
  }
  [scanner scanString:@"," intoString:NULL];
  [scanner scanInteger:&minor];

  if (major < 10) {
    return YES;
  }
  if (major == 10) {
    return minor == 1 || minor == 2 || minor == 4 || minor == 5;
  }
  // Generation 11+: Face ID everywhere except the Home-button SE models.
  return (major == 12 && minor == 8) || (major == 14 && minor == 6);
}

/**
 * Performs one Control Center opening gesture.
 *
 * Device type (Face ID vs Home button) cannot be reliably detected from the WDA runner's
 * own window safe-area, so instead of detecting we try both gestures and let the caller
 * verify which one actually revealed Control Center.
 *
 * faceIDGesture YES: pull down from the extreme top-right edge (Face ID devices). The
 *               touch must start at the very top edge (y ~ 0) and travel well into the
 *               screen for the system to recognise the pull.
 *               NO: swipe up from the bottom edge (Home button devices).
 */
+ (void)fb_openControlCenterWithFaceIDGesture:(BOOL)faceIDGesture
{
  // Use only normalized coordinates so we don't read activeApp.frame, which would force
  // an accessibility snapshot on every attempt.
  XCUIApplication *activeApp = XCUIApplication.fb_activeApplication;

  if (faceIDGesture) {
    // Pull down ~35% from the extreme top-right edge.
    XCUICoordinate *start = [activeApp coordinateWithNormalizedOffset:CGVectorMake(0.95, 0.0)];
    XCUICoordinate *end = [activeApp coordinateWithNormalizedOffset:CGVectorMake(0.95, 0.35)];
    [start pressForDuration:0.05 thenDragToCoordinate:end];
  } else {
    // Swipe up ~35% from the bottom edge.
    XCUICoordinate *start = [activeApp coordinateWithNormalizedOffset:CGVectorMake(0.5, 1.0)];
    XCUICoordinate *end = [activeApp coordinateWithNormalizedOffset:CGVectorMake(0.5, 0.65)];
    [start pressForDuration:0.05 thenDragToCoordinate:end];
  }

  // Let the Control Center animation settle.
  [NSThread sleepForTimeInterval:0.5];
}

+ (id<FBResponsePayload>)handleStartBroadcast:(FBRouteRequest *)request
{
  NSString *appName = (NSString *)request.arguments[@"appName"];
  if (appName.length == 0) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"appName is required" traceback:nil]);
  }

  NSString *screenRecordingName = request.arguments[@"screenRecordingName"] ?: @"Screen Recording";
  NSTimeInterval timeout = request.arguments[@"timeout"] ? [request.arguments[@"timeout"] doubleValue] : 5.0;

  XCUIApplication *springboard = [[XCUIApplication alloc] initWithBundleIdentifier:@"com.apple.springboard"];

  // Step 0: Go to the home screen to dismiss any open UI (Control Center, picker, etc.).
  // Activating SpringBoard works on all devices, unlike pressButton:Home which is a no-op
  // on Face ID devices (no hardware Home button).
  [[XCUIDevice sharedDevice] fb_goToHomescreenWithError:nil];
  [NSThread sleepForTimeInterval:0.5];

  // Step 1: Open Control Center, retrying and verifying that the Screen Recording
  // button actually appeared. A mis-detected device type or a swipe that the system
  // reads as App Switcher/Home can otherwise silently fail the whole flow.
  XCUIElement *screenRecBtn = springboard.buttons[screenRecordingName];
  BOOL opened = NO;
  // Pick the first gesture from the device model (reliable), then keep the other as a
  // fallback, alternating until the Screen Recording button appears.
  BOOL faceIDFirst = ![self fb_isHomeButtonDevice];
  BOOL gestureSequence[] = { faceIDFirst, !faceIDFirst, faceIDFirst, !faceIDFirst };
  NSInteger maxAttempts = sizeof(gestureSequence) / sizeof(gestureSequence[0]);
  for (NSInteger attempt = 0; attempt < maxAttempts && !opened; attempt++) {
    [self fb_openControlCenterWithFaceIDGesture:gestureSequence[attempt]];
    opened = [screenRecBtn waitForExistenceWithTimeout:timeout];
    if (!opened) {
      // A wrong swipe may have opened the App Switcher or gone Home; reset and retry.
      [[XCUIDevice sharedDevice] fb_goToHomescreenWithError:nil];
      [NSThread sleepForTimeInterval:0.5];
    }
  }
  if (!opened) {
    return FBResponseWithStatus([FBCommandStatus noSuchElementErrorWithMessage:
      [NSString stringWithFormat:@"Could not find '%@' button in Control Center within %.0fs", screenRecordingName, timeout]
      traceback:nil]);
  }

  // Step 3: Long press to open the broadcast picker
  [screenRecBtn pressForDuration:1.0];

  // Step 4: Find and tap the target app in the broadcast picker
  // Broadcast apps appear as Button elements in the picker
  XCUIElement *appElement = springboard.buttons[appName];
  if (![appElement waitForExistenceWithTimeout:timeout]) {
    return FBResponseWithStatus([FBCommandStatus noSuchElementErrorWithMessage:
      [NSString stringWithFormat:@"Could not find app '%@' in broadcast picker within %.0fs", appName, timeout]
      traceback:nil]);
  }
  [appElement tap];

  // Step 5: Tap the start button, which is labelled "Start Broadcast" or "Start Sharing"
  // depending on the iOS version.
  NSArray<NSString *> *startLabels = @[@"Start Broadcast", @"Start Sharing"];
  NSPredicate *startPredicate = [NSPredicate predicateWithFormat:@"label IN %@", startLabels];
  XCUIElement *startBtn = [springboard.buttons matchingPredicate:startPredicate].firstMatch;
  if (![startBtn waitForExistenceWithTimeout:timeout]) {
    return FBResponseWithStatus([FBCommandStatus noSuchElementErrorWithMessage:
      [NSString stringWithFormat:@"Could not find a start button (%@)", [startLabels componentsJoinedByString:@" / "]]
      traceback:nil]);
  }
  [startBtn tap];

  // No need to wait out the 3-2-1 countdown: ReplayKit starts the broadcast on its own
  // once tapped. Activate SpringBoard to return to a known state from whatever app is
  // foreground. (Works on all devices, unlike pressButton:Home which is a no-op on Face
  // ID devices.)
  [[XCUIDevice sharedDevice] fb_goToHomescreenWithError:nil];

  return FBResponseWithOK();
}

/**
 * Fast, lean element tree of the frontmost application
 *
 * Differences from the regular /source?format=json:
 * - The accessibility snapshot fetches only a minimal attribute set (type, identifier,
 *   label, value, frame) instead of the full default set, which is where the regular
 *   endpoint spends most of its time on large trees.
 * - The snapshot root is the frontmost application's raw accessibility element, so no
 *   XCUIApplication construction or wait-for-quiescence is involved.
 * - Each node serializes only: type, rect, and (when non-empty) name, label, value,
 *   children. No null placeholders.
 * - Subtrees entirely off screen are culled bottom-up (a node is kept when its own
 *   frame intersects the app frame OR any descendant was kept — see
 *   FBGadsLeanTreeForSnapshot for why recycled list containers need the bottom-up
 *   order). Pass ?onScreen=0 to keep the complete tree.
 * - The response JSON is compact, not pretty-printed.
 *
 * Response shape: {"value": <tree>, "elapsedMs": <server-side build time>}
 */
+ (id<FBResponsePayload>)handleGetFastSourceGads:(FBRouteRequest *)request
{
  BOOL onScreenOnly = nil == request.parameters[@"onScreen"] || [request.parameters[@"onScreen"] boolValue];
  NSDate *started = [NSDate date];

  id<FBXCAccessibilityElement> appElement = [FBXCAXClientProxy.sharedClient activeApplications].firstObject;
  if (nil == appElement) {
    return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:@"Cannot determine the currently active application"
                                                               traceback:nil]);
  }

  NSError *error;
  id<FBXCElementSnapshot> snapshot = [FBXCAXClientProxy.sharedClient snapshotForElement:appElement
                                                                             attributes:FBGadsFastSourceAttributes()
                                                                                inDepth:YES
                                                                                  error:&error];
  if (nil == snapshot) {
    return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:
                                 [NSString stringWithFormat:@"Cannot take an accessibility snapshot: %@", error.description]
                                                               traceback:nil]);
  }

  // The application's own frame is the screen rectangle for pruning; if it is
  // reported empty the pruning would drop everything, so fall back to the full tree
  CGRect screenRect = snapshot.frame;
  BOOL prune = onScreenOnly && !CGRectIsEmpty(screenRect);
  NSDictionary *tree = FBGadsLeanTreeForSnapshot(snapshot, prune, screenRect);

  NSNumber *elapsedMs = @((long)(-started.timeIntervalSinceNow * 1000));
  return [[FBGadsCompactJSONPayload alloc] initWithObject:@{
    @"value": tree ?: NSNull.null,
    @"elapsedMs": elapsedMs,
  }];
}

+ (id <FBResponsePayload>)handleTwoFingerScroll:(FBRouteRequest *)request
{
  CGFloat startX = [request.arguments[@"startX"] doubleValue];
  CGFloat startY = [request.arguments[@"startY"] doubleValue];
  CGFloat endX = [request.arguments[@"endX"] doubleValue];
  CGFloat endY = [request.arguments[@"endY"] doubleValue];
  CGFloat duration = [request.arguments[@"duration"] doubleValue] ?: 0.8;
  CGFloat fingerSpacing = [request.arguments[@"fingerSpacing"] doubleValue] ?: 50.0;

  [XCUIDevice.sharedDevice
   fb_synthTwoFingerScrollFromX:startX
                              Y:startY
                            toX:endX
                              Y:endY
                       duration:duration
                  fingerSpacing:fingerSpacing];

  return FBResponseWithOK();
}

@end


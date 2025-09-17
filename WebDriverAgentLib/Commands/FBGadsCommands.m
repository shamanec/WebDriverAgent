//
//  FBGadsCommands.m
//  WebDriverAgent
//
//  Created by Nikola Shabanov on 17.09.25.
//  Copyright © 2025 Facebook. All rights reserved.
//

#import "FBGadsCommands.h"

#import "FBCapabilities.h"
#import "FBConfiguration.h"
#import "FBProtocolHelpers.h"
#import "FBRouteRequest.h"
#import "FBSession.h"
#import "FBSettings.h"
#import "FBActiveAppDetectionPoint.h"
#import "FBXCodeCompatibility.h"
#import "FBCommandStatus.h"
#import "FBRoute.h"

@implementation FBGadsCommands

#pragma mark - <FBCommandHandler>

+ (NSArray *)routes
{
  return
  @[
    [[FBRoute GET:@"/appium/settings"].withoutSession respondWithTarget:self action:@selector(handleGetSettingsGads:)],
    [[FBRoute POST:@"/appium/settings"].withoutSession respondWithTarget:self action:@selector(handleSetSettingsGads:)],
  ];
}

/**
 * No-session version of FBSessionCommands.handleGetSettings
 *
 * This method is based on FBSessionCommands.handleGetSettings (line 352) but designed
 * to work without requiring an active WebDriver session.
 *
 * Key differences from the original session-required version:
 * 1. Safe access to session-specific settings (defaultActiveApplication, defaultAlertAction)
 *    - Returns empty strings when no session exists instead of crashing
 * 2. Conditional inclusion of settings that may not always be available
 *    - activeAppDetectionPoint only added if coordinates exist
 *    - includeNonModalElements only set if the feature is supported
 * 3. Excludes session-dependent features:
 *    - autoClickAlertSelector (requires session for alerts monitor)
 *
 * When updating: Compare with FBSessionCommands.handleGetSettings and sync any new
 * settings, ensuring proper session-safe access patterns are maintained.
 */
+ (id<FBResponsePayload>)handleGetSettingsGads:(FBRouteRequest *)request
{
  FBSession *session = request.session;

  NSMutableDictionary *settings = [@{
    FB_SETTING_USE_COMPACT_RESPONSES: @([FBConfiguration shouldUseCompactResponses]),
    FB_SETTING_ELEMENT_RESPONSE_ATTRIBUTES: [FBConfiguration elementResponseAttributes],
    FB_SETTING_MJPEG_SERVER_SCREENSHOT_QUALITY: @([FBConfiguration mjpegServerScreenshotQuality]),
    FB_SETTING_MJPEG_SERVER_FRAMERATE: @([FBConfiguration mjpegServerFramerate]),
    FB_SETTING_MJPEG_SCALING_FACTOR: @([FBConfiguration mjpegScalingFactor]),
    FB_SETTING_MJPEG_FIX_ORIENTATION: @([FBConfiguration mjpegShouldFixOrientation]),
    FB_SETTING_SCREENSHOT_QUALITY: @([FBConfiguration screenshotQuality]),
    FB_SETTING_KEYBOARD_AUTOCORRECTION: @([FBConfiguration keyboardAutocorrection]),
    FB_SETTING_KEYBOARD_PREDICTION: @([FBConfiguration keyboardPrediction]),
    FB_SETTING_SNAPSHOT_MAX_DEPTH: @([FBConfiguration snapshotMaxDepth]),
    FB_SETTING_USE_FIRST_MATCH: @([FBConfiguration useFirstMatch]),
    FB_SETTING_WAIT_FOR_IDLE_TIMEOUT: @([FBConfiguration waitForIdleTimeout]),
    FB_SETTING_ANIMATION_COOL_OFF_TIMEOUT: @([FBConfiguration animationCoolOffTimeout]),
    FB_SETTING_BOUND_ELEMENTS_BY_INDEX: @([FBConfiguration boundElementsByIndex]),
    FB_SETTING_REDUCE_MOTION: @([FBConfiguration reduceMotionEnabled]),
    FB_SETTING_INCLUDE_NON_MODAL_ELEMENTS: @([FBConfiguration includeNonModalElements]),
    FB_SETTING_ACCEPT_ALERT_BUTTON_SELECTOR: FBConfiguration.acceptAlertButtonSelector ?: @"",
    FB_SETTING_DISMISS_ALERT_BUTTON_SELECTOR: FBConfiguration.dismissAlertButtonSelector ?: @"",
    FB_SETTING_MAX_TYPING_FREQUENCY: @([FBConfiguration maxTypingFrequency]),
    FB_SETTING_RESPECT_SYSTEM_ALERTS: @([FBConfiguration shouldRespectSystemAlerts]),
    FB_SETTING_USE_CLEAR_TEXT_SHORTCUT: @([FBConfiguration useClearTextShortcut]),
    FB_SETTING_INCLUDE_HITTABLE_IN_PAGE_SOURCE: @([FBConfiguration includeHittableInPageSource]),
    FB_SETTING_INCLUDE_NATIVE_FRAME_IN_PAGE_SOURCE: @([FBConfiguration includeNativeFrameInPageSource]),
    FB_SETTING_INCLUDE_MIN_MAX_VALUE_IN_PAGE_SOURCE: @([FBConfiguration includeMinMaxValueInPageSource]),
    FB_SETTING_LIMIT_XPATH_CONTEXT_SCOPE: @([FBConfiguration limitXpathContextScope]),
#if !TARGET_OS_TV
    FB_SETTING_SCREENSHOT_ORIENTATION: [FBConfiguration humanReadableScreenshotOrientation] ?: @"",
#endif
  } mutableCopy];

  // Safe access to session-specific settings
  settings[FB_SETTING_DEFAULT_ACTIVE_APPLICATION] = session ? (session.defaultActiveApplication ?: @"") : @"";
  settings[FB_SETTING_DEFAULT_ALERT_ACTION] = session ? (session.defaultAlertAction ?: @"") : @"";

  if ([XCUIElement fb_supportsNonModalElementsInclusion]) {
    settings[FB_SETTING_INCLUDE_NON_MODAL_ELEMENTS] = @([FBConfiguration includeNonModalElements]);
  }

  if (FBActiveAppDetectionPoint.sharedInstance.stringCoordinates) {
    settings[FB_SETTING_ACTIVE_APP_DETECTION_POINT] = FBActiveAppDetectionPoint.sharedInstance.stringCoordinates;
  }

  return FBResponseWithObject(settings);
}

/**
 * No-session version of FBSessionCommands.handleSetSettings
 *
 * This method is based on FBSessionCommands.handleSetSettings (line 548) but designed
 * to work without requiring an active WebDriver session.
 *
 * Key differences from the original session-required version:
 * 1. Safe access to session-specific settings:
 *    - defaultActiveApplication: Only set if session exists
 *    - defaultAlertAction: Only set if session exists and value is valid string
 * 2. Session-dependent feature handling:
 *    - includeNonModalElements: Only set if feature is supported by iOS SDK
 *    - activeAppDetectionPoint: Set globally, works without session
 * 3. Excludes session-dependent features:
 *    - autoClickAlertSelector: Requires session for alerts monitor enable/disable
 * 4. Uses different null checking pattern:
 *    - Original: nil != [settings objectForKey:key]
 *    - This version: settings[key] (more concise, same functionality)
 * 5. Returns handleGetSettingsGads instead of handleGetSettings
 *
 * When updating: Compare with FBSessionCommands.handleSetSettings and sync any new
 * settings, ensuring session-safe access patterns and proper null checks are maintained.
 * Pay attention to settings that require session state or iOS SDK feature checks.
 */
+ (id<FBResponsePayload>)handleSetSettingsGads:(FBRouteRequest *)request
{
  NSDictionary* settings = request.arguments[@"settings"];
  FBSession *session = request.session;

  if (settings[FB_SETTING_USE_COMPACT_RESPONSES]) {
    [FBConfiguration setShouldUseCompactResponses:[settings[FB_SETTING_USE_COMPACT_RESPONSES] boolValue]];
  }
  if (settings[FB_SETTING_ELEMENT_RESPONSE_ATTRIBUTES]) {
    [FBConfiguration setElementResponseAttributes:(NSString *)settings[FB_SETTING_ELEMENT_RESPONSE_ATTRIBUTES]];
  }
  if (settings[FB_SETTING_MJPEG_SERVER_SCREENSHOT_QUALITY]) {
    [FBConfiguration setMjpegServerScreenshotQuality:[settings[FB_SETTING_MJPEG_SERVER_SCREENSHOT_QUALITY] unsignedIntegerValue]];
  }
  if (settings[FB_SETTING_MJPEG_SERVER_FRAMERATE]) {
    [FBConfiguration setMjpegServerFramerate:[settings[FB_SETTING_MJPEG_SERVER_FRAMERATE] unsignedIntegerValue]];
  }
  if (settings[FB_SETTING_SCREENSHOT_QUALITY]) {
    [FBConfiguration setScreenshotQuality:[settings[FB_SETTING_SCREENSHOT_QUALITY] unsignedIntegerValue]];
  }
  if (settings[FB_SETTING_MJPEG_SCALING_FACTOR]) {
    [FBConfiguration setMjpegScalingFactor:[settings[FB_SETTING_MJPEG_SCALING_FACTOR] floatValue]];
  }
  if (settings[FB_SETTING_MJPEG_FIX_ORIENTATION]) {
    [FBConfiguration setMjpegShouldFixOrientation:[settings[FB_SETTING_MJPEG_FIX_ORIENTATION] boolValue]];
  }
  if (settings[FB_SETTING_KEYBOARD_AUTOCORRECTION]) {
    [FBConfiguration setKeyboardAutocorrection:[settings[FB_SETTING_KEYBOARD_AUTOCORRECTION] boolValue]];
  }
  if (settings[FB_SETTING_KEYBOARD_PREDICTION]) {
    [FBConfiguration setKeyboardPrediction:[settings[FB_SETTING_KEYBOARD_PREDICTION] boolValue]];
  }
  if (settings[FB_SETTING_RESPECT_SYSTEM_ALERTS]) {
    [FBConfiguration setShouldRespectSystemAlerts:[settings[FB_SETTING_RESPECT_SYSTEM_ALERTS] boolValue]];
  }
  if (settings[FB_SETTING_SNAPSHOT_MAX_DEPTH]) {
    [FBConfiguration setSnapshotMaxDepth:[settings[FB_SETTING_SNAPSHOT_MAX_DEPTH] intValue]];
  }
  if (settings[FB_SETTING_USE_FIRST_MATCH]) {
    [FBConfiguration setUseFirstMatch:[settings[FB_SETTING_USE_FIRST_MATCH] boolValue]];
  }
  if (settings[FB_SETTING_BOUND_ELEMENTS_BY_INDEX]) {
    [FBConfiguration setBoundElementsByIndex:[settings[FB_SETTING_BOUND_ELEMENTS_BY_INDEX] boolValue]];
  }
  if (settings[FB_SETTING_REDUCE_MOTION]) {
    [FBConfiguration setReduceMotionEnabled:[settings[FB_SETTING_REDUCE_MOTION] boolValue]];
  }
  if (settings[FB_SETTING_DEFAULT_ACTIVE_APPLICATION] && session) {
    session.defaultActiveApplication = (NSString *)settings[FB_SETTING_DEFAULT_ACTIVE_APPLICATION];
  }
  if (settings[FB_SETTING_ACTIVE_APP_DETECTION_POINT]) {
    NSError *error;
    if (![FBActiveAppDetectionPoint.sharedInstance setCoordinatesWithString:(NSString *)settings[FB_SETTING_ACTIVE_APP_DETECTION_POINT]
                                                                      error:&error]) {
      return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:error.localizedDescription traceback:nil]);
    }
  }
  if (settings[FB_SETTING_INCLUDE_NON_MODAL_ELEMENTS] && [XCUIElement fb_supportsNonModalElementsInclusion]) {
    [FBConfiguration setIncludeNonModalElements:[settings[FB_SETTING_INCLUDE_NON_MODAL_ELEMENTS] boolValue]];
  }
  if (settings[FB_SETTING_ACCEPT_ALERT_BUTTON_SELECTOR]) {
    [FBConfiguration setAcceptAlertButtonSelector:(NSString *)settings[FB_SETTING_ACCEPT_ALERT_BUTTON_SELECTOR]];
  }
  if (settings[FB_SETTING_DISMISS_ALERT_BUTTON_SELECTOR]) {
    [FBConfiguration setDismissAlertButtonSelector:(NSString *)settings[FB_SETTING_DISMISS_ALERT_BUTTON_SELECTOR]];
  }
  if (settings[FB_SETTING_WAIT_FOR_IDLE_TIMEOUT]) {
    [FBConfiguration setWaitForIdleTimeout:[settings[FB_SETTING_WAIT_FOR_IDLE_TIMEOUT] doubleValue]];
  }
  if (settings[FB_SETTING_ANIMATION_COOL_OFF_TIMEOUT]) {
    [FBConfiguration setAnimationCoolOffTimeout:[settings[FB_SETTING_ANIMATION_COOL_OFF_TIMEOUT] doubleValue]];
  }
  if ([settings[FB_SETTING_DEFAULT_ALERT_ACTION] isKindOfClass:NSString.class] && session) {
    session.defaultAlertAction = [settings[FB_SETTING_DEFAULT_ALERT_ACTION] lowercaseString];
  }
  if (settings[FB_SETTING_MAX_TYPING_FREQUENCY]) {
    [FBConfiguration setMaxTypingFrequency:[settings[FB_SETTING_MAX_TYPING_FREQUENCY] unsignedIntegerValue]];
  }
  if (settings[FB_SETTING_USE_CLEAR_TEXT_SHORTCUT]) {
    [FBConfiguration setUseClearTextShortcut:[settings[FB_SETTING_USE_CLEAR_TEXT_SHORTCUT] boolValue]];
  }
  if (settings[FB_SETTING_INCLUDE_HITTABLE_IN_PAGE_SOURCE]) {
    [FBConfiguration setIncludeHittableInPageSource:[settings[FB_SETTING_INCLUDE_HITTABLE_IN_PAGE_SOURCE] boolValue]];
  }
  if (settings[FB_SETTING_INCLUDE_NATIVE_FRAME_IN_PAGE_SOURCE]) {
    [FBConfiguration setIncludeNativeFrameInPageSource:[settings[FB_SETTING_INCLUDE_NATIVE_FRAME_IN_PAGE_SOURCE] boolValue]];
  }
  if (settings[FB_SETTING_INCLUDE_MIN_MAX_VALUE_IN_PAGE_SOURCE]) {
    [FBConfiguration setIncludeMinMaxValueInPageSource:[settings[FB_SETTING_INCLUDE_MIN_MAX_VALUE_IN_PAGE_SOURCE] boolValue]];
  }
  if (settings[FB_SETTING_LIMIT_XPATH_CONTEXT_SCOPE]) {
    [FBConfiguration setLimitXpathContextScope:[settings[FB_SETTING_LIMIT_XPATH_CONTEXT_SCOPE] boolValue]];
  }

#if !TARGET_OS_TV
  if (settings[FB_SETTING_SCREENSHOT_ORIENTATION]) {
    NSError *error;
    if (![FBConfiguration setScreenshotOrientation:(NSString *)settings[FB_SETTING_SCREENSHOT_ORIENTATION] error:&error]) {
      return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:error.localizedDescription traceback:nil]);
    }
  }
#endif

  return [self handleGetSettingsGads:request];
}

@end


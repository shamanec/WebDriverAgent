//
//  FBGadsCommands.m
//  WebDriverAgent
//
//  Created by Nikola Shabanov on 17.09.25.
//  Copyright © 2025 Facebook. All rights reserved.
//

#import "FBGadsCommands.h"
#import "XCUIDevice+Gads.h"

@import UniformTypeIdentifiers;

#import "FBCapabilities.h"
#import "XCUIApplication.h"

#import "FBConfiguration.h"
#import "FBProtocolHelpers.h"
#import "FBRouteRequest.h"
#import "FBSession.h"
#import "FBSettings.h"
#import "FBActiveAppDetectionPoint.h"
#import "FBXCodeCompatibility.h"
#import "FBCommandStatus.h"
#import "FBRoute.h"
#import "FBResponsePayload.h"
#import "FBRouteRequest.h"
#import "FBScreenshot.h"
#import "XCUIScreen.h"
#import "FBImageProcessor.h"


@implementation FBGadsCommands

#pragma mark - <FBCommandHandler>

+ (NSArray *)routes
{
  return
  @[
    [[FBRoute GET:@"/appium/settings"].withoutSession respondWithTarget:self action:@selector(handleGetSettingsGads:)],
    [[FBRoute POST:@"/appium/settings"].withoutSession respondWithTarget:self action:@selector(handleSetSettingsGads:)],
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
    [[FBRoute POST:@"/gads/audio/prepare"].withoutSession respondWithTarget:self action:@selector(handleAudioPrepare:)],
    [[FBRoute POST:@"/gads/audio/stop"].withoutSession respondWithTarget:self action:@selector(handleAudioStop:)],
  ];
}

// Must match the Darwin notification name observed by gads-broadcast-extension
// (see SampleHandler.swift `broadcastShouldStopNotification`).
static NSString *const FBGadsAudioBroadcastShouldStopNotification = @"io.gads.wda.audio.broadcastShouldStop";
// Production broadcast host: GADSBroadcast (h264-broadcast-extension target,
// CFBundleDisplayName="GADSBroadcast"). Hosts an RPSystemBroadcastPickerView
// pre-targeted at gads-broadcast-extension and auto-presses its button onAppear.
static NSString *const FBGadsBroadcastHostBundleIdentifier = @"com.gads.h264-broadcast-extension";

#pragma mark - Audio broadcast control

/**
 * Bring the GADSBroadcast host app to the foreground so its embedded
 * RPSystemBroadcastPickerView fires the iOS broadcast sheet, then drive the
 * springboard sheet to confirm the GADSBroadcast row + tap "Start Broadcast".
 *
 * Body (optional): { "target": "<display-name>" }. Defaults to "GADSBroadcast".
 * The display name is what iOS renders for each row in the picker; whichever
 * extension's row is currently the radio selection determines which appex
 * spawns. iOS persists the last-used selection across sessions, so on cold
 * picker openings we still need the manual sheet drive (Phase 2 swipe) to
 * cover the case where another extension was last-selected.
 */
+ (id<FBResponsePayload>)handleAudioPrepare:(FBRouteRequest *)request
{
  NSString *target = @"GADSBroadcast";
  id rawTarget = request.arguments[@"target"];
  if (rawTarget != nil && rawTarget != (id)[NSNull null]) {
    if (![rawTarget isKindOfClass:NSString.class] || ((NSString *)rawTarget).length == 0) {
      return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"target must be a non-empty string when provided" traceback:nil]);
    }
    target = (NSString *)rawTarget;
  }
  NSLog(@"[GADSAudio] /gads/audio/prepare entry target='%@'", target);

  XCUIApplication *app = [[XCUIApplication alloc]
                          initWithBundleIdentifier:FBGadsBroadcastHostBundleIdentifier];
  // Match handleAppActivateNoSession: zero out wait-for-idle around launch
  // (xctest's default idle wait can be much longer than the broadcast UX).
  NSTimeInterval previousTimeout = FBConfiguration.waitForIdleTimeout;
  FBConfiguration.waitForIdleTimeout = 0;
  [app launch];
  FBConfiguration.waitForIdleTimeout = previousTimeout;

  // Last-mile autotap: after GADSBroadcast's `buttonPressed:` fires, iOS 26
  // presents a system sheet shaped as a radio-button list — one row per app
  // with a broadcast extension — plus a single action button "Iniciar
  // Gravação". iOS decides broadcast (recordingType=1, spawns appex) vs local
  // systemRecording (recordingType=2, .mov in Photos) based on which radio is
  // selected when the action button is tapped. `preferredExtension` is only
  // a visual hint; iOS keeps the last-used radio selected (typically Photos),
  // so we tap the GADSBroadcast row first and only then tap the action button.
  // Older iOS / some locales expose a separate "Iniciar Transmissão" / "Start
  // Broadcast" button — handled as Path A.
  NSLog(@"[GADSAudio] scheduling system-sheet autotap target='%@'", target);
  dispatch_async(dispatch_get_main_queue(), ^{
    NSLog(@"[GADSAudio] autotap entered target='%@'", target);

    XCUIApplication *springboard = [[XCUIApplication alloc] initWithBundleIdentifier:@"com.apple.springboard"];

    NSArray<NSString *> *broadcastLabels = @[
      @"Iniciar Transmissão",
      @"Iniciar Difusão",
      @"Start Broadcast",
      @"Iniciar transmisión",
      @"Démarrer la diffusion",
      @"Übertragung starten",
    ];
    NSArray<NSString *> *stopLabels = @[
      @"Parar Gravação",
      @"Stop Recording",
      @"Parar Transmissão",
      @"Parar Difusão",
      @"Stop Broadcast",
      @"Parar grabación",
      @"Arrêter l'enregistrement",
      @"Aufnahme stoppen",
    ];
    NSArray<NSString *> *actionButtonLabels = @[
      // Start (broadcast inactive — normal flow)
      @"Iniciar Gravação",
      @"Start Recording",
      @"Iniciar Transmissão",
      @"Iniciar Difusão",
      @"Start Broadcast",
      @"Iniciar grabación",
      @"Démarrer l'enregistrement",
      @"Aufnahme starten",
      // Stop (broadcast active — already broadcasting)
      @"Parar Gravação",
      @"Stop Recording",
      @"Parar Transmissão",
      @"Parar Difusão",
      @"Stop Broadcast",
      @"Parar grabación",
      @"Arrêter l'enregistrement",
      @"Aufnahme stoppen",
    ];
    NSPredicate *broadcastPredicate = [NSPredicate predicateWithFormat:@"label IN %@", broadcastLabels];
    NSPredicate *stopPredicate = [NSPredicate predicateWithFormat:@"label IN %@", stopLabels];
    NSPredicate *actionPredicate = [NSPredicate predicateWithFormat:@"label IN %@", actionButtonLabels];
    NSPredicate *targetMatch = [NSPredicate predicateWithFormat:@"label == %@", target];

    // Phase 0 — dismiss residual "broadcast ended/stopped" system alert.
    NSArray<NSString *> *dismissLabels = @[
      @"OK",
      @"Ok",
      @"Concluído",
      @"Done",
      @"Dispensar",
      @"Cerrar",
      @"Fermer",
      @"Schließen",
    ];
    NSPredicate *dismissPredicate = [NSPredicate predicateWithFormat:@"label IN %@", dismissLabels];
    XCUIElement *dismissBtn = [[springboard.alerts.buttons matchingPredicate:dismissPredicate] firstMatch];
    if (dismissBtn.exists && dismissBtn.isHittable) {
      NSLog(@"[GADSAudio] Phase 0: dismissing residual broadcast alert ('%@')", dismissBtn.label);
      [dismissBtn tap];
      [NSThread sleepForTimeInterval:0.4];
    }

    NSUInteger maxAttempts = 3;
    XCUIElement *recordBtn = nil;

    // Phase 1 — locate an entry point. On each attempt: try Path A (direct
    // broadcast button) first; if absent, look for the record button so we
    // can use Phase 2 (swipe). Retry up to maxAttempts to absorb the sheet
    // animation latency.
    for (NSUInteger attempt = 1; attempt <= maxAttempts; attempt++) {
      // Path A — explicit broadcast button. Multi-type search: buttons, then any.
      XCUIElement *broadcastBtn = [[springboard.buttons matchingPredicate:broadcastPredicate] firstMatch];
      if (!broadcastBtn.exists) {
        XCUIElement *anyBcast = [[[springboard descendantsMatchingType:XCUIElementTypeAny] matchingPredicate:broadcastPredicate] firstMatch];
        if (anyBcast.exists) { broadcastBtn = anyBcast; }
      }
      if (broadcastBtn.exists && broadcastBtn.isHittable) {
        // Gate: a hittable broadcast-mode action button only proves SOME
        // broadcast extension is currently selected -- not necessarily the
        // requested target. Confirm before tapping; otherwise fall through to
        // Phase 2 swipe loop so we can change the radio first. Use exact-match
        // value strings only ("1" / "Selected" / "Selecionado") to avoid
        // false positives from substring matching.
        XCUIElement *targetCheck = [[springboard.buttons matchingPredicate:targetMatch] firstMatch];
        if (!targetCheck.exists) {
          XCUIElement *anyTarget = [[[springboard descendantsMatchingType:XCUIElementTypeAny] matchingPredicate:targetMatch] firstMatch];
          if (anyTarget.exists) { targetCheck = anyTarget; }
        }
        BOOL targetIsSelected = NO;
        if (targetCheck.exists) {
          targetIsSelected = [targetCheck isSelected];
          if (!targetIsSelected) {
            NSString *valStr = [NSString stringWithFormat:@"%@", targetCheck.value ?: @""];
            if ([valStr isEqualToString:@"1"] || [valStr isEqualToString:@"Selected"] || [valStr isEqualToString:@"Selecionado"]) {
              targetIsSelected = YES;
            }
          }
        }
        if (targetIsSelected) {
          NSLog(@"[GADSAudio] Phase 1 Path A: target '%@' selected; tapping action button '%@'", target, broadcastBtn.label);
          [broadcastBtn tap];
          [NSThread sleepForTimeInterval:1.5];
          [[XCUIDevice sharedDevice] pressButton:XCUIDeviceButtonHome];
          NSLog(@"[GADSAudio] pressed Home");
          return;
        }

        NSLog(@"[GADSAudio] Phase 1 Path A: target '%@' not selected; falling through to Phase 2 swipe", target);
        // do not return; proceed to Path B prep below so we can swipe.
      }

      // Path B prep — locate record button. Multi-type search: buttons, then any.
      XCUIElement *foundRecord = [[springboard.buttons matchingPredicate:actionPredicate] firstMatch];
      if (!foundRecord.exists) {
        XCUIElement *anyRec = [[[springboard descendantsMatchingType:XCUIElementTypeAny] matchingPredicate:actionPredicate] firstMatch];
        if (anyRec.exists) { foundRecord = anyRec; }
      }
      if (foundRecord.exists && foundRecord.isHittable) {
        recordBtn = foundRecord;
        break;
      }

      [NSThread sleepForTimeInterval:0.6];
    }

    if (!(recordBtn.exists && recordBtn.isHittable)) {
      NSLog(@"[GADSAudio] Phase 1 ABORT: no broadcast button and no record button found after %lu attempts (target='%@')", (unsigned long)maxAttempts, target);
      return;
    }

    // Phase 1.5 — detect already-broadcasting state. iOS 26 persists the
    // broadcast across sessions: when the picker re-opens with the target
    // still active, the action button is "Parar Transmissão" / "Stop
    // Broadcast" instead of "Iniciar Gravação". In that case the swipe + tap
    // dance is unnecessary (and would TOGGLE OFF the broadcast). Just press
    // Home to dismiss the picker, leaving the broadcast running.
    XCUIElement *stopBtn = [[springboard.buttons matchingPredicate:stopPredicate] firstMatch];
    if (!stopBtn.exists) {
      XCUIElement *anyStop = [[[springboard descendantsMatchingType:XCUIElementTypeAny] matchingPredicate:stopPredicate] firstMatch];
      if (anyStop.exists) { stopBtn = anyStop; }
    }
    if (stopBtn.exists && stopBtn.isHittable) {
      NSLog(@"[GADSAudio] Phase 1.5: broadcast already active (action button='%@', target='%@'). Pressing Home to dismiss picker without changes.", stopBtn.label, target);
      [[XCUIDevice sharedDevice] pressButton:XCUIDeviceButtonHome];
      return;
    }

    // Phase 2 — iOS 26 broadcast picker is a HORIZONTAL CAROUSEL of radio
    // options. Each swipeLeft advances the selection by one position.
    // The row's frame stays at its logical Y in the tree on every swipe;
    // what changes is `isHittable`, which flips to 1 ONLY when the target is
    // the currently-selected radio. Swipe up to maxHorizontalSwipes times,
    // re-querying after each swipe, until the target becomes hittable — then
    // tap to confirm and tap the action button.
    XCUIElement *extBtn = [[springboard.buttons matchingPredicate:targetMatch] firstMatch];
    if (!extBtn.exists) {
      XCUIElement *anyExt = [[[springboard descendantsMatchingType:XCUIElementTypeAny] matchingPredicate:targetMatch] firstMatch];
      if (anyExt.exists) { extBtn = anyExt; }
    }
    if (!extBtn.exists) {
      NSLog(@"[GADSAudio] Phase 2 ABORT: target '%@' not found in tree", target);
      return;
    }

    // Pick a swipe target. Prefer the pager indicator (canonical anchor for
    // paging the carousel), fall back to the Fotos row (page 1 anchor), then
    // to springboard itself.
    XCUIElement *swipeTarget = nil;
    NSPredicate *pagerMatch = [NSPredicate predicateWithFormat:@"label CONTAINS[c] %@ OR label CONTAINS[c] %@", @"Barra de rolagem horizontal", @"horizontal scroll"];
    XCUIElement *pager = [[[springboard descendantsMatchingType:XCUIElementTypeAny] matchingPredicate:pagerMatch] firstMatch];
    if (pager.exists) {
      swipeTarget = pager;
    } else {
      XCUIElement *fotosBtn = [[springboard.buttons matchingIdentifier:@"Fotos"] firstMatch];
      if (!fotosBtn.exists) {
        fotosBtn = [[springboard.buttons matchingPredicate:[NSPredicate predicateWithFormat:@"label == %@", @"Fotos"]] firstMatch];
      }
      swipeTarget = fotosBtn.exists ? fotosBtn : springboard;
    }

    NSUInteger maxHorizontalSwipes = 10;
    NSUInteger horizSwipe = 0;
    while (!extBtn.isHittable && horizSwipe < maxHorizontalSwipes) {
      horizSwipe++;
      [swipeTarget swipeLeft];
      [NSThread sleepForTimeInterval:0.4];
      extBtn = [[springboard.buttons matchingPredicate:targetMatch] firstMatch];
      if (!extBtn.exists) {
        XCUIElement *anyAfter = [[[springboard descendantsMatchingType:XCUIElementTypeAny] matchingPredicate:targetMatch] firstMatch];
        if (anyAfter.exists) { extBtn = anyAfter; }
      }
    }

    if (!extBtn.exists || !extBtn.isHittable) {
      NSLog(@"[GADSAudio] Phase 2 ABORT: target '%@' never became hittable after %lu horizontal swipes",
            target, (unsigned long)horizSwipe);
      return;
    }

    NSLog(@"[GADSAudio] Phase 2: tapping target '%@' (selected after %lu swipes)", target, (unsigned long)horizSwipe);
    [extBtn tap];
    [NSThread sleepForTimeInterval:0.5];

    XCUIElement *extBtnAfter = [[springboard.buttons matchingPredicate:targetMatch] firstMatch];
    if (!extBtnAfter.exists) {
      XCUIElement *anyAfter = [[[springboard descendantsMatchingType:XCUIElementTypeAny] matchingPredicate:targetMatch] firstMatch];
      if (anyAfter.exists) { extBtnAfter = anyAfter; }
    }

    // Safety gate: never tap the action button unless the post-tap
    // accessibility state confirms the requested target is the selected
    // radio. Tapping with the wrong radio spawns the wrong broadcast
    // extension and breaks the entire E2E pipeline.
    BOOL isTargetSelected = [extBtnAfter isSelected];
    if (!isTargetSelected) {
      NSString *valStr = [NSString stringWithFormat:@"%@", extBtnAfter.value ?: @""];
      if ([valStr isEqualToString:@"1"] || [valStr isEqualToString:@"Selected"] || [valStr isEqualToString:@"Selecionado"]) {
        isTargetSelected = YES;
      }
    }

    if (!isTargetSelected) {
      NSLog(@"[GADSAudio] Phase 2 ABORT: target '%@' tap did not register as radio selection (isSelected=%d value=%@); not tapping action to avoid wrong-extension broadcast",
            target, [extBtnAfter isSelected], extBtnAfter.value);
      return;
    }

    XCUIElement *finalAction = [[springboard.buttons matchingPredicate:actionPredicate] firstMatch];
    if (finalAction.exists && finalAction.isHittable) {
      NSLog(@"[GADSAudio] Phase 2: tapping action button '%@' (target='%@' confirmed selected)", finalAction.label, target);
      [finalAction tap];
      [NSThread sleepForTimeInterval:1.5];
      [[XCUIDevice sharedDevice] pressButton:XCUIDeviceButtonHome];
      NSLog(@"[GADSAudio] pressed Home");
    } else {
      NSLog(@"[GADSAudio] Phase 2 ABORT: action button not hittable after target '%@' selection", target);
    }
  });

  return FBResponseWithOK();
}

/**
 * Tell gads-broadcast-extension to call finishBroadcastWithError: by posting
 * a Darwin notification. The Darwin notification is the only IPC channel that
 * can wake the extension from another process (CFMessagePort/Mach are
 * sandbox-blocked). The extension installs an observer in
 * SampleHandler.broadcastStarted; provider calls this endpoint when the
 * WebRTC session ends.
 */
+ (id<FBResponsePayload>)handleAudioStop:(FBRouteRequest *)request
{
  CFNotificationCenterPostNotification(
    CFNotificationCenterGetDarwinNotifyCenter(),
    (__bridge CFStringRef)FBGadsAudioBroadcastShouldStopNotification,
    NULL, NULL, true);
  return FBResponseWithOK();
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
+ (id<FBResponsePayload>)handleStartBroadcast:(FBRouteRequest *)request
{
  NSString *appName = (NSString *)request.arguments[@"appName"];
  if (appName.length == 0) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"appName is required" traceback:nil]);
  }

  NSString *screenRecordingName = request.arguments[@"screenRecordingName"] ?: @"Screen Recording";
  NSTimeInterval timeout = request.arguments[@"timeout"] ? [request.arguments[@"timeout"] doubleValue] : 5.0;

  XCUIApplication *springboard = [[XCUIApplication alloc] initWithBundleIdentifier:@"com.apple.springboard"];

  // Step 0: Press Home twice to dismiss any open UI (Control Center, alerts, etc.)
  [[XCUIDevice sharedDevice] pressButton:XCUIDeviceButtonHome];
  [NSThread sleepForTimeInterval:0.5];
  [[XCUIDevice sharedDevice] pressButton:XCUIDeviceButtonHome];
  [NSThread sleepForTimeInterval:1.0];

  XCUIApplication *activeApp = XCUIApplication.fb_activeApplication;

  // Step 1: Detect device type and open Control Center
  // Face ID devices have bottom safe area > 0 (home indicator area)
  BOOL isFaceID = NO;
  UIWindow *window = UIApplication.sharedApplication.windows.firstObject;
  if (window && window.safeAreaInsets.bottom > 0) {
    isFaceID = YES;
  }

  if (isFaceID) {
    // Face ID: short swipe down from top-right corner
    // Keep the swipe short to avoid overshooting into Control Center content (e.g. AirPlay)
    XCUICoordinate *start = [activeApp coordinateWithNormalizedOffset:CGVectorMake(0.9, 0.01)];
    XCUICoordinate *end = [activeApp coordinateWithNormalizedOffset:CGVectorMake(0.9, 0.2)];
    [start pressForDuration:0.1 thenDragToCoordinate:end];
  } else {
    // Home Button: swipe up from bottom center
    XCUICoordinate *start = [activeApp coordinateWithNormalizedOffset:CGVectorMake(0.5, 0.99)];
    XCUICoordinate *end = [activeApp coordinateWithNormalizedOffset:CGVectorMake(0.5, 0.7)];
    [start pressForDuration:0.1 thenDragToCoordinate:end];
  }

  // Let the Control Center animation settle
  [NSThread sleepForTimeInterval:0.5];

  // Step 2: Find Screen Recording button in Control Center
  XCUIElement *screenRecBtn = springboard.buttons[screenRecordingName];
  if (![screenRecBtn waitForExistenceWithTimeout:timeout]) {
    return FBResponseWithStatus([FBCommandStatus noSuchElementErrorWithMessage:
      [NSString stringWithFormat:@"Could not find '%@' button in Control Center within %.0fs", screenRecordingName, timeout]
      traceback:nil]);
  }

  // Step 3: Long press to open the broadcast picker
  [screenRecBtn pressForDuration:1.5];

  // Step 4: Find and tap the target app in the broadcast picker
  // Broadcast apps appear as Button elements in the picker
  XCUIElement *appElement = springboard.buttons[appName];
  if (![appElement waitForExistenceWithTimeout:timeout]) {
    return FBResponseWithStatus([FBCommandStatus noSuchElementErrorWithMessage:
      [NSString stringWithFormat:@"Could not find app '%@' in broadcast picker within %.0fs", appName, timeout]
      traceback:nil]);
  }
  [appElement tap];

  // Step 5: Tap Start Broadcast
  XCUIElement *startBtn = springboard.buttons[@"Start Broadcast"];
  if (![startBtn waitForExistenceWithTimeout:timeout]) {
    return FBResponseWithStatus([FBCommandStatus noSuchElementErrorWithMessage:
      @"Could not find 'Start Broadcast' button" traceback:nil]);
  }
  [startBtn tap];

  // Wait for the 3-second countdown before broadcast actually starts
  [NSThread sleepForTimeInterval:3.0];

  // Dismiss the broadcast menus by pressing Home twice
  [[XCUIDevice sharedDevice] pressButton:XCUIDeviceButtonHome];
  [NSThread sleepForTimeInterval:0.5];
  [[XCUIDevice sharedDevice] pressButton:XCUIDeviceButtonHome];
  [NSThread sleepForTimeInterval:0.5];

  return FBResponseWithOK();
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


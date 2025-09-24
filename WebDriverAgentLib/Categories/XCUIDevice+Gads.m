//
//  XCUIDeviceGads.m
//  WebDriverAgent
//
//  Created by Nikola Shabanov on 18.09.25.
//  Copyright © 2025 Facebook. All rights reserved.
//

#import "XCUIDevice+Gads.h"

#import "XCUIDevice.h"
#import "XCPointerEventPath.h"
#import "XCSynthesizedEventRecord.h"
#import "XCTRunnerDaemonSession.h"
#import "XCUIApplication+FBHelpers.h"


@implementation XCUIDevice (Gads)

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-load-method"

/**
 * Synthesizes text input events to type the given string on the focused text field
 *
 * This method creates a keyboard input event path using XCPointerEventPath and executes
 * it through the iOS event synthesis system. The events are sent asynchronously without
 * waiting for completion to maintain UI responsiveness in device farm scenarios.
 *
 * @param text The string to type. Empty strings are ignored.
 * @return YES if the event was successfully queued, NO if text is empty
 *
 * Note: Uses 60 characters/second typing speed. Fast consecutive calls may result
 * in character dropping due to iOS event system limitations.
 */
- (BOOL)fb_synthTypeText:(NSString *)text
{
  if (text.length == 0) {
    return NO;
  }

  // Create an event path specifically for text/keyboard input
  XCPointerEventPath *path = [[XCPointerEventPath alloc] initForTextInput];
  [path typeText:text
        atOffset:0.0                    // Start immediately
     typingSpeed:60                     // 60 characters per second
    shouldRedact:NO];                   // Don't redact for security logging

  NSString *name = [NSString stringWithFormat:@"Type '%@'", text];

  // Create an event record container to hold the typing event path
  XCSynthesizedEventRecord *eventRecord =
  [[XCSynthesizedEventRecord alloc] initWithName:name];
  [eventRecord addPointerEventPath:path];

  // Execute the event asynchronously through iOS event synthesizer
  // Empty completion block maintains UI responsiveness for fast typing
  [[self eventSynthesizer]
   synthesizeEvent:eventRecord
   completion:(id)^(BOOL result, NSError *invokeError) {} ];

  return YES;
}

/**
 * Synthesizes a single tap gesture at the specified screen coordinates
 *
 * Creates a touch-down and touch-up event sequence at the given point using
 * XCPointerEventPath. The tap has a duration of 50ms which mimics natural
 * human touch timing.
 *
 * @param x The horizontal coordinate in screen points
 * @param y The vertical coordinate in screen points
 * @return YES if the tap event was successfully queued
 *
 * Note: Coordinates are in screen points, not pixels. Origin (0,0) is top-left.
 */
- (BOOL)fb_synthTapWithX:(CGFloat)x
                       y:(CGFloat)y
{
  CGPoint point = CGPointMake(x,y);

  CGFloat tapDuration = 0.05;  // 50ms tap duration for natural feel

  // Create touch event path starting with finger down at specified point
  XCPointerEventPath *pointerEventPath = [[XCPointerEventPath alloc] initForTouchAtPoint:point offset:0];
  [pointerEventPath liftUpAtOffset:tapDuration];  // Lift finger after duration

  // Package the touch event for execution
  XCSynthesizedEventRecord *eventRecord = [[XCSynthesizedEventRecord alloc] initWithName:nil interfaceOrientation:0];
  [eventRecord addPointerEventPath:pointerEventPath];

  // Execute tap event asynchronously
  [[self eventSynthesizer]
   synthesizeEvent:eventRecord
   completion:(id)^(BOOL result, NSError *invokeError) {} ];
  return YES;
}

/**
 * Synthesizes a swipe gesture from one point to another over a specified duration
 *
 * Creates a touch sequence that starts at (x1,y1), moves to (x2,y2) over the
 * given delay period, then lifts up. This simulates a finger drag gesture.
 *
 * @param x1 Starting horizontal coordinate in screen points
 * @param y1 Starting vertical coordinate in screen points
 * @param x2 Ending horizontal coordinate in screen points
 * @param y2 Ending vertical coordinate in screen points
 * @param delay Duration of the swipe in seconds (affects swipe speed)
 * @return YES if the swipe event was successfully queued
 *
 * Note: Longer delays create slower swipes. Typical values: 0.5-2.0 seconds.
 */
- (BOOL)fb_synthSwipe:(CGFloat)x1
                   y1:(CGFloat)y1
                   x2:(CGFloat)x2
                   y2:(CGFloat)y2
                delay:(CGFloat)delay
{
  CGPoint point1 = CGPointMake(x1,y1);
  CGPoint point2 = CGPointMake(x2,y2);

  // Create touch path starting at first point
  XCPointerEventPath *pointerEventPath = [[XCPointerEventPath alloc] initForTouchAtPoint:point1 offset:0];
  [pointerEventPath moveToPoint:point2 atOffset:delay];  // Move finger to end point over delay duration
  [pointerEventPath liftUpAtOffset:delay];               // Lift finger when movement completes

  // Package the swipe gesture for execution
  XCSynthesizedEventRecord *eventRecord = [[XCSynthesizedEventRecord alloc] initWithName:nil interfaceOrientation:0];
  [eventRecord addPointerEventPath:pointerEventPath];

  // Execute swipe event asynchronously
  [[self eventSynthesizer]
   synthesizeEvent:eventRecord
   completion:(id)^(BOOL result, NSError *invokeError) {} ];
  return YES;
}

/**
 * Synthesizes a touch-and-hold gesture at the specified coordinates
 *
 * Creates a touch event that presses down at the given point and maintains
 * pressure for the specified duration. This is commonly used to trigger
 * context menus, long-press actions, or force-touch interactions.
 *
 * @param x The horizontal coordinate in screen points
 * @param y The vertical coordinate in screen points
 * @param delay Duration to hold the touch in seconds
 * @return YES if the touch-and-hold event was successfully queued
 *
 * Note: Most iOS long-press gestures require 0.5+ seconds. Context menus
 * typically appear after 0.75-1.0 seconds of sustained pressure.
 */
- (BOOL)fb_synthTouchAndHold:(CGFloat)x
                           y:(CGFloat)y
                       delay:(CGFloat)delay
{
  CGPoint point1 = CGPointMake(x,y);

  // Create touch path that starts with finger down at specified point
  XCPointerEventPath *pointerEventPath = [[XCPointerEventPath alloc] initForTouchAtPoint:point1 offset:0];
  [pointerEventPath pressDownAtOffset: delay];  // Maintain pressure for delay duration

  // Package the long-press gesture for execution
  XCSynthesizedEventRecord *eventRecord = [[XCSynthesizedEventRecord alloc] initWithName:nil interfaceOrientation:0];
  [eventRecord addPointerEventPath:pointerEventPath];

  // Execute touch-and-hold event asynchronously
  [[self eventSynthesizer]
   synthesizeEvent:eventRecord
   completion:(id)^(BOOL result, NSError *invokeError) {} ];
  return YES;
}

/**
 * Synthesizes a pinch-to-zoom gesture using two coordinated finger movements
 *
 * Creates a multi-touch gesture where two fingers move simultaneously from/to
 * positions calculated around a center point. The scale determines how far apart
 * the fingers are - smaller scale = fingers closer (zoom out), larger scale =
 * fingers farther apart (zoom in).
 *
 * @param centerX The horizontal coordinate of the pinch center in screen points
 * @param centerY The vertical coordinate of the pinch center in screen points
 * @param startScale Initial distance between fingers (1.0 = 100pt apart)
 * @param endScale Final distance between fingers (2.0 = 200pt apart for zoom in)
 * @param duration Duration of the pinch gesture in seconds
 * @return YES if the pinch event was successfully queued
 *
 * Note: Scale > 1.0 zooms in, scale < 1.0 zooms out. Typical range: 0.5-3.0
 */
- (BOOL)fb_synthPinchWithCenterX:(CGFloat)centerX
                         centerY:(CGFloat)centerY
                      startScale:(CGFloat)startScale
                        endScale:(CGFloat)endScale
                        duration:(CGFloat)duration
{
  CGPoint center = CGPointMake(centerX, centerY);
  CGFloat baseDistance = 100.0; // Base distance between fingers in points

  // Calculate finger positions based on center and scale factors
  CGFloat startDistance = baseDistance * startScale;
  CGFloat endDistance = baseDistance * endScale;

  // Position fingers horizontally around center point
  CGPoint finger1Start = CGPointMake(center.x - startDistance/2, center.y);
  CGPoint finger1End = CGPointMake(center.x - endDistance/2, center.y);
  CGPoint finger2Start = CGPointMake(center.x + startDistance/2, center.y);
  CGPoint finger2End = CGPointMake(center.x + endDistance/2, center.y);

  // Create first finger event path
  XCPointerEventPath *finger1Path = [[XCPointerEventPath alloc] initForTouchAtPoint:finger1Start offset:0];
  [finger1Path moveToPoint:finger1End atOffset:duration];
  [finger1Path liftUpAtOffset:duration];

  // Create second finger event path
  XCPointerEventPath *finger2Path = [[XCPointerEventPath alloc] initForTouchAtPoint:finger2Start offset:0];
  [finger2Path moveToPoint:finger2End atOffset:duration];
  [finger2Path liftUpAtOffset:duration];

  // Coordinate both finger paths in a single multi-touch event
  XCSynthesizedEventRecord *eventRecord = [[XCSynthesizedEventRecord alloc] initWithName:@"Pinch" interfaceOrientation:0];
  [eventRecord addPointerEventPath:finger1Path];
  [eventRecord addPointerEventPath:finger2Path];

  // Execute pinch gesture asynchronously
  [[self eventSynthesizer]
   synthesizeEvent:eventRecord
   completion:(id)^(BOOL result, NSError *invokeError) {} ];

  return YES;
}

/**
 * Synthesizes a drag and drop gesture from one point to another
 *
 * Creates a touch sequence that presses down at the start point, holds for
 * selection, moves to the target point, and releases. This simulates the
 * standard iOS drag-and-drop interaction pattern used for reordering items,
 * moving files, or dragging content between applications.
 *
 * @param startX Starting horizontal coordinate in screen points
 * @param startY Starting vertical coordinate in screen points
 * @param endX Ending horizontal coordinate in screen points
 * @param endY Ending vertical coordinate in screen points
 * @param holdTime Duration to hold at start before moving (selection time)
 * @param dragDuration Duration of the movement from start to end
 * @return YES if the drag and drop event was successfully queued
 *
 * Note: holdTime should be 0.5+ seconds for reliable selection.
 * Total gesture time = holdTime + dragDuration.
 */
- (BOOL)fb_synthDragFromX:(CGFloat)startX
                        Y:(CGFloat)startY
                      toX:(CGFloat)endX
                        Y:(CGFloat)endY
                 holdTime:(CGFloat)holdTime
             dragDuration:(CGFloat)dragDuration
{
  CGPoint startPoint = CGPointMake(startX, startY);
  CGPoint endPoint = CGPointMake(endX, endY);

  // Create drag path with press, hold, move, release sequence
  XCPointerEventPath *dragPath = [[XCPointerEventPath alloc] initForTouchAtPoint:startPoint offset:0];

  // Hold at source point for item selection (important for drag-and-drop recognition)
  [dragPath pressDownAtOffset:holdTime];

  // Move finger from source to target over specified duration
  [dragPath moveToPoint:endPoint atOffset:holdTime + dragDuration];

  // Release finger at target to complete drop
  [dragPath liftUpAtOffset:holdTime + dragDuration];

  // Package drag and drop gesture for execution
  XCSynthesizedEventRecord *eventRecord = [[XCSynthesizedEventRecord alloc] initWithName:@"DragDrop" interfaceOrientation:0];
  [eventRecord addPointerEventPath:dragPath];

  // Execute drag and drop event asynchronously
  [[self eventSynthesizer]
   synthesizeEvent:eventRecord
   completion:(id)^(BOOL result, NSError *invokeError) {} ];

  return YES;
}

/**
 * Low-level edge swipe for top-left, top-right, left, and right edges
 *
 * Uses XCPointerEventPath for basic edge gestures that don't require
 * iOS system gesture recognition.
 *
 * @param edge 0=top-left, 1=top-right, 2=left-center, 4=right-center
 * @param distance How far to swipe inward from the edge in screen points
 * @param duration Duration of the swipe gesture in seconds
 */
- (BOOL)fb_synthEdgeSwipeLowLevel:(NSInteger)edge
                         distance:(CGFloat)distance
                         duration:(CGFloat)duration
{
  CGRect screenBounds = [[UIScreen mainScreen] bounds];
  CGPoint startPoint, endPoint;
  CGFloat cornerOffset = 50.0;
  CGFloat edgeMargin = 1.0;

  switch (edge) {
    case 0: // Top-left
      startPoint = CGPointMake(cornerOffset, edgeMargin);
      endPoint = CGPointMake(cornerOffset, distance);
      break;
    case 1: // Top-right
      startPoint = CGPointMake(screenBounds.size.width - cornerOffset, edgeMargin);
      endPoint = CGPointMake(screenBounds.size.width - cornerOffset, distance);
      break;
    case 2: // Left edge
      startPoint = CGPointMake(edgeMargin, screenBounds.size.height / 2);
      endPoint = CGPointMake(distance, screenBounds.size.height / 2);
      break;
    case 4: // Right edge
      startPoint = CGPointMake(screenBounds.size.width - edgeMargin, screenBounds.size.height / 2);
      endPoint = CGPointMake(screenBounds.size.width - distance, screenBounds.size.height / 2);
      break;
    default:
      return NO;
  }

  XCPointerEventPath *edgePath = [[XCPointerEventPath alloc] initForTouchAtPoint:startPoint offset:0];
  [edgePath moveToPoint:endPoint atOffset:duration];
  [edgePath liftUpAtOffset:duration];

  XCSynthesizedEventRecord *eventRecord = [[XCSynthesizedEventRecord alloc] initWithName:@"EdgeSwipeLowLevel" interfaceOrientation:0];
  [eventRecord addPointerEventPath:edgePath];

  [[self eventSynthesizer] synthesizeEvent:eventRecord completion:(id)^(BOOL result, NSError *invokeError) {}];
  return YES;
}

/**
 * High-level bottom edge swipe for Control Center
 *
 * Uses XCUICoordinate with normalized coordinates (0.5, 0.99) to (0.5, 0.7)
 * to properly trigger iOS system gesture recognition for Control Center.
 */
- (BOOL)fb_synthEdgeSwipeBottomHighLevel:(CGFloat)distance
                                duration:(CGFloat)duration
{
  XCUIApplication *app = XCUIApplication.fb_activeApplication;

  // Use proven normalized coordinates: center x, 99% down to 70% down
  XCUICoordinate *startCoordinate = [app coordinateWithNormalizedOffset:CGVectorMake(0.5, 0.99)];
  XCUICoordinate *endCoordinate = [app coordinateWithNormalizedOffset:CGVectorMake(0.5, 0.7)];

  [startCoordinate pressForDuration:0.1 thenDragToCoordinate:endCoordinate];
  return YES;
}

/**
 * Synthesizes a double tap gesture at the specified coordinates
 *
 * Creates two rapid tap events at the same location with a short interval
 * between them. This simulates the iOS double-tap gesture commonly used for
 * zooming, text selection, or activating special actions in apps.
 *
 * @param x The horizontal coordinate in screen points
 * @param y The vertical coordinate in screen points
 * @param tapDelay Delay between the two taps in seconds (typically 0.1-0.3)
 * @return YES if the double tap event was successfully queued
 *
 * Note: tapDelay should be 0.1-0.3 seconds for reliable recognition.
 * Each individual tap lasts 50ms with tapDelay between them.
 */
- (BOOL)fb_synthDoubleTapWithX:(CGFloat)x
                             y:(CGFloat)y
                      tapDelay:(CGFloat)tapDelay
{
  CGPoint point = CGPointMake(x, y);
  CGFloat singleTapDuration = 0.05; // 50ms per tap

  // Create first tap path
  XCPointerEventPath *firstTapPath = [[XCPointerEventPath alloc] initForTouchAtPoint:point offset:0];
  [firstTapPath liftUpAtOffset:singleTapDuration];

  // Create second tap path with delay after first tap completes
  CGFloat secondTapStartTime = singleTapDuration + tapDelay;
  XCPointerEventPath *secondTapPath = [[XCPointerEventPath alloc] initForTouchAtPoint:point offset:secondTapStartTime];
  [secondTapPath liftUpAtOffset:secondTapStartTime + singleTapDuration];

  // Package both taps as a single coordinated gesture
  XCSynthesizedEventRecord *eventRecord = [[XCSynthesizedEventRecord alloc] initWithName:@"DoubleTap" interfaceOrientation:0];
  [eventRecord addPointerEventPath:firstTapPath];
  [eventRecord addPointerEventPath:secondTapPath];

  // Execute double tap event asynchronously
  [[self eventSynthesizer]
   synthesizeEvent:eventRecord
   completion:(id)^(BOOL result, NSError *invokeError) {} ];

  return YES;
}

/**
 * Synthesizes a two-finger scroll gesture for precise content navigation
 *
 * Creates a synchronized two-finger movement that simulates trackpad-style
 * scrolling. Unlike single-finger swipes that trigger navigation gestures,
 * two-finger scrolling provides smooth content movement with momentum and
 * is recognized by iOS as content manipulation rather than navigation.
 *
 * @param startX Starting horizontal coordinate for scroll center
 * @param startY Starting vertical coordinate for scroll center
 * @param endX Ending horizontal coordinate for scroll center
 * @param endY Ending vertical coordinate for scroll center
 * @param duration Duration of the scroll gesture in seconds
 * @param fingerSpacing Distance between the two fingers in screen points
 * @return YES if the two-finger scroll event was successfully queued
 *
 * Note: fingerSpacing typically 30-80 points. Larger spacing may be more
 * reliable but could conflict with pinch gestures.
 */
- (BOOL)fb_synthTwoFingerScrollFromX:(CGFloat)startX
                                   Y:(CGFloat)startY
                                 toX:(CGFloat)endX
                                   Y:(CGFloat)endY
                            duration:(CGFloat)duration
                       fingerSpacing:(CGFloat)fingerSpacing
{
  CGPoint startPoint = CGPointMake(startX, startY);
  CGPoint endPoint = CGPointMake(endX, endY);

  // Calculate movement vector and perpendicular spacing vector
  CGVector movement = CGVectorMake(endPoint.x - startPoint.x, endPoint.y - startPoint.y);
  CGVector perpendicular = CGVectorMake(-movement.dy, movement.dx); // Rotate 90 degrees

  // Normalize perpendicular vector and scale by finger spacing
  CGFloat length = sqrt(perpendicular.dx * perpendicular.dx + perpendicular.dy * perpendicular.dy);
  if (length > 0) {
    perpendicular.dx = (perpendicular.dx / length) * (fingerSpacing / 2);
    perpendicular.dy = (perpendicular.dy / length) * (fingerSpacing / 2);
  } else {
    // Fallback to horizontal spacing if no movement
    perpendicular = CGVectorMake(fingerSpacing / 2, 0);
  }

  // Calculate parallel finger positions
  CGPoint finger1Start = CGPointMake(startPoint.x + perpendicular.dx, startPoint.y + perpendicular.dy);
  CGPoint finger1End = CGPointMake(endPoint.x + perpendicular.dx, endPoint.y + perpendicular.dy);
  CGPoint finger2Start = CGPointMake(startPoint.x - perpendicular.dx, startPoint.y - perpendicular.dy);
  CGPoint finger2End = CGPointMake(endPoint.x - perpendicular.dx, endPoint.y - perpendicular.dy);

  // Create synchronized finger paths
  XCPointerEventPath *finger1Path = [[XCPointerEventPath alloc] initForTouchAtPoint:finger1Start offset:0];
  [finger1Path moveToPoint:finger1End atOffset:duration];
  [finger1Path liftUpAtOffset:duration];

  XCPointerEventPath *finger2Path = [[XCPointerEventPath alloc] initForTouchAtPoint:finger2Start offset:0];
  [finger2Path moveToPoint:finger2End atOffset:duration];
  [finger2Path liftUpAtOffset:duration];

  // Coordinate both fingers as a single multi-touch scroll event
  XCSynthesizedEventRecord *eventRecord = [[XCSynthesizedEventRecord alloc] initWithName:@"TwoFingerScroll" interfaceOrientation:0];
  [eventRecord addPointerEventPath:finger1Path];
  [eventRecord addPointerEventPath:finger2Path];

  // Execute two-finger scroll event asynchronously
  [[self eventSynthesizer]
   synthesizeEvent:eventRecord
   completion:(id)^(BOOL result, NSError *invokeError) {} ];

  return YES;
}

@end

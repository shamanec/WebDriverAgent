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


@implementation XCUIDevice (Gads)

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-load-method"

- (BOOL)fb_synthTypeText:(NSString *)text
{
  if (text.length == 0) {
    return NO;
  }
  
  XCPointerEventPath *path = [[XCPointerEventPath alloc] initForTextInput];
  [path typeText:text
        atOffset:0.0
     typingSpeed:60
    shouldRedact:NO];
  
  NSString *name = [NSString stringWithFormat:@"Type '%@'", text];
  
  XCSynthesizedEventRecord *eventRecord =
  [[XCSynthesizedEventRecord alloc] initWithName:name];
  [eventRecord addPointerEventPath:path];
  
  [[self eventSynthesizer]
   synthesizeEvent:eventRecord
   completion:(id)^(BOOL result, NSError *invokeError) {} ];
  
  return YES;
}

- (BOOL)fb_synthTapWithX:(CGFloat)x
                       y:(CGFloat)y
{
  CGPoint point = CGPointMake(x,y);
  
  CGFloat tapDuration = 0.05;
  
  XCPointerEventPath *pointerEventPath = [[XCPointerEventPath alloc] initForTouchAtPoint:point offset:0];
  [pointerEventPath liftUpAtOffset:tapDuration];
  
  XCSynthesizedEventRecord *eventRecord = [[XCSynthesizedEventRecord alloc] initWithName:nil interfaceOrientation:0];
  [eventRecord addPointerEventPath:pointerEventPath];
  
  [[self eventSynthesizer]
   synthesizeEvent:eventRecord
   completion:(id)^(BOOL result, NSError *invokeError) {} ];
  return YES;
}

- (BOOL)fb_synthSwipe:(CGFloat)x1
                   y1:(CGFloat)y1
                   x2:(CGFloat)x2
                   y2:(CGFloat)y2
                delay:(CGFloat)delay
{
  CGPoint point1 = CGPointMake(x1,y1);
  CGPoint point2 = CGPointMake(x2,y2);
  
  XCPointerEventPath *pointerEventPath = [[XCPointerEventPath alloc] initForTouchAtPoint:point1 offset:0];
  [pointerEventPath moveToPoint:point2 atOffset:delay];
  [pointerEventPath liftUpAtOffset:delay];
  
  XCSynthesizedEventRecord *eventRecord = [[XCSynthesizedEventRecord alloc] initWithName:nil interfaceOrientation:0];
  [eventRecord addPointerEventPath:pointerEventPath];
  
  [[self eventSynthesizer]
   synthesizeEvent:eventRecord
   completion:(id)^(BOOL result, NSError *invokeError) {} ];
  return YES;
}

- (BOOL)fb_synthTouchAndHold:(CGFloat)x
                           y:(CGFloat)y
                       delay:(CGFloat)delay
{
  CGPoint point1 = CGPointMake(x,y);
  
  XCPointerEventPath *pointerEventPath = [[XCPointerEventPath alloc] initForTouchAtPoint:point1 offset:0];
  [pointerEventPath pressDownAtOffset: delay];
  
  XCSynthesizedEventRecord *eventRecord = [[XCSynthesizedEventRecord alloc] initWithName:nil interfaceOrientation:0];
  [eventRecord addPointerEventPath:pointerEventPath];
  
  [[self eventSynthesizer]
   synthesizeEvent:eventRecord
   completion:(id)^(BOOL result, NSError *invokeError) {} ];
  return YES;
}

@end

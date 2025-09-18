//
//  XCUIDeviceGads.h
//  WebDriverAgent
//
//  Created by Nikola Shabanov on 18.09.25.
//  Copyright © 2025 Facebook. All rights reserved.
//


#import <XCTest/XCTest.h>

@interface XCUIDevice (Gads)

- (BOOL)fb_synthTypeText:(NSString *)text;

- (BOOL)fb_synthTapWithX:(CGFloat)x
                       y:(CGFloat)y;

- (BOOL)fb_synthSwipe:(CGFloat)x1
                   y1:(CGFloat)y1
                   x2:(CGFloat)x2
                   y2:(CGFloat)y2
                   delay:(CGFloat)delay;

- (BOOL)fb_synthTouchAndHold:(CGFloat)x
                           y:(CGFloat)y
                       delay:(CGFloat)delay;

- (BOOL)fb_synthPinchWithCenterX:(CGFloat)centerX
                         centerY:(CGFloat)centerY
                      startScale:(CGFloat)startScale
                        endScale:(CGFloat)endScale
                        duration:(CGFloat)duration;

- (BOOL)fb_synthDragFromX:(CGFloat)startX
                        Y:(CGFloat)startY
                      toX:(CGFloat)endX
                        Y:(CGFloat)endY
                 holdTime:(CGFloat)holdTime
             dragDuration:(CGFloat)dragDuration;

- (BOOL)fb_synthEdgeSwipeLowLevel:(NSInteger)edge
                         distance:(CGFloat)distance
                         duration:(CGFloat)duration;

- (BOOL)fb_synthEdgeSwipeBottomHighLevel:(CGFloat)distance
                                duration:(CGFloat)duration;

- (BOOL)fb_synthDoubleTapWithX:(CGFloat)x
                             y:(CGFloat)y
                      tapDelay:(CGFloat)tapDelay;

- (BOOL)fb_synthTwoFingerScrollFromX:(CGFloat)startX
                                   Y:(CGFloat)startY
                                 toX:(CGFloat)endX
                                   Y:(CGFloat)endY
                            duration:(CGFloat)duration
                       fingerSpacing:(CGFloat)fingerSpacing;

@end

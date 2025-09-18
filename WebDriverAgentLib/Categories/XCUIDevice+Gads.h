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

@end

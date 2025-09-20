//
//  FBMjpegServerGads.h
//  WebDriverAgent
//
//  Created by Nikola Shabanov on 20.09.25.
//  Copyright © 2025 Facebook. All rights reserved.
//

#import "FBTCPSocket.h"

NS_ASSUME_NONNULL_BEGIN

@interface FBMjpegServerGads : NSObject <FBTCPSocketDelegate>

/**
 The default constructor for the screenshot bradcaster service.
 This service sends low resolution screenshots 10 times per seconds
 to all connected clients.
 */
- (instancetype)init;

@end

NS_ASSUME_NONNULL_END

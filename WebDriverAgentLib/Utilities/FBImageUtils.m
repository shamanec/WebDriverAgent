/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "FBImageUtils.h"

#import "FBMacros.h"
#import "FBConfiguration.h"

// https://en.wikipedia.org/wiki/List_of_file_signatures
static uint8_t PNG_MAGIC[] = { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };
static const NSUInteger PNG_MAGIC_LEN = 8;
static uint8_t JPG_MAGIC[] = { 0xff, 0xd8, 0xff };
static const NSUInteger JPG_MAGIC_LEN = 3;

BOOL FBIsPngImage(NSData *imageData)
{
  if (nil == imageData || [imageData length] < PNG_MAGIC_LEN) {
    return NO;
  }

  static NSData* pngMagicStartData = nil;
  static dispatch_once_t oncePngToken;
  dispatch_once(&oncePngToken, ^{
    pngMagicStartData = [NSData dataWithBytesNoCopy:(void*)PNG_MAGIC length:PNG_MAGIC_LEN freeWhenDone:NO];
  });

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wassign-enum"
  NSRange range = [imageData rangeOfData:pngMagicStartData options:kNilOptions range:NSMakeRange(0, PNG_MAGIC_LEN)];
#pragma clang diagnostic pop
  return range.location != NSNotFound;
}

NSData *FBToPngData(NSData *imageData) {
  if (nil == imageData || [imageData length] < PNG_MAGIC_LEN) {
    return nil;
  }
  if (FBIsPngImage(imageData)) {
    return imageData;
  }

  UIImage *image = [UIImage imageWithData:imageData];
  return nil == image ? nil : (NSData *)UIImagePNGRepresentation(image);
}

BOOL FBIsJpegImage(NSData *imageData)
{
  if (nil == imageData || [imageData length] < JPG_MAGIC_LEN) {
    return NO;
  }

  static NSData* jpgMagicStartData = nil;
  static dispatch_once_t onceJpgToken;
  dispatch_once(&onceJpgToken, ^{
    jpgMagicStartData = [NSData dataWithBytesNoCopy:(void*)JPG_MAGIC length:JPG_MAGIC_LEN freeWhenDone:NO];
  });

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wassign-enum"
  NSRange range = [imageData rangeOfData:jpgMagicStartData options:kNilOptions range:NSMakeRange(0, JPG_MAGIC_LEN)];
#pragma clang diagnostic pop
  return range.location != NSNotFound;
}

NSData *FBToJpegData(NSData *imageData, CGFloat compressionQuality) {
  if (nil == imageData || [imageData length] < JPG_MAGIC_LEN) {
    return nil;
  }
  if (FBIsJpegImage(imageData)) {
    return imageData;
  }
  
  UIImage *image = [UIImage imageWithData:imageData];
  return nil == image ? nil : (NSData *)UIImageJPEGRepresentation(image, compressionQuality);
}

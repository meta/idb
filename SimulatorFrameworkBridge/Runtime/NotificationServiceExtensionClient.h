/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <TargetConditionals.h>

#import <Foundation/Foundation.h>

#if TARGET_OS_IOS && !TARGET_OS_MACCATALYST

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, FBNotificationServiceExtensionStatus) {
  FBNotificationServiceExtensionStatusDelivered,
  FBNotificationServiceExtensionStatusSuppressed,
  FBNotificationServiceExtensionStatusFailed,
};

@interface FBNotificationServiceExtensionResult : NSObject
@property (nonatomic, readonly) FBNotificationServiceExtensionStatus status;
@property (nullable, nonatomic, readonly, copy) NSString *failure;
@end

/** Runs on the guest's serving thread, which pumps its run loop until Apple's extension host completes. */
@interface FBNotificationServiceExtensionClient : NSObject
+ (FBNotificationServiceExtensionResult *)sendToBundleID:(NSString *)bundleID
                                             jsonPayload:(NSString *)jsonPayload NS_SWIFT_NAME(send(bundleID:jsonPayload:));
- (instancetype)initWithManager:(id)manager center:(id)center;
- (FBNotificationServiceExtensionResult *)sendToBundleID:(NSString *)bundleID
                                             jsonPayload:(NSString *)jsonPayload
                                                 timeout:(NSTimeInterval)timeout NS_SWIFT_NAME(send(bundleID:jsonPayload:timeout:));
@end

NS_ASSUME_NONNULL_END
#endif

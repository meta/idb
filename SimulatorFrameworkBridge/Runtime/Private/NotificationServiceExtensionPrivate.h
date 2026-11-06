/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>

@interface UNCNotificationServiceExtension : NSObject
- (dispatch_queue_t)queue;
- (nullable UNNotificationContent *)mutateContentForNotificationRequest:(UNNotificationRequest *)request error:(NSError **)error;
- (void)cleanUp;
@end

@interface UNCNotificationServiceExtensionManager : NSObject
- (nullable UNCNotificationServiceExtension *)extensionForBundleIdentifier:(NSString *)bundleIdentifier error:(NSError **)error;
@end

@interface UNNotificationRequest (FBServiceExtension)
+ (nullable instancetype)requestWithIdentifier:(NSString *)identifier
                                   pushPayload:(NSDictionary<NSString *, id> *)payload
                              bundleIdentifier:(NSString *)bundleIdentifier;
@end

@interface UNNotificationContent (FBServiceExtension)
- (BOOL)unc_willAlertUser;
@end

@interface UNUserNotificationCenter (FBServiceExtension)
- (void)addNotificationRequest:(UNNotificationRequest *)request withCompletionHandler:(void (^)(NSError *error))handler;
@end

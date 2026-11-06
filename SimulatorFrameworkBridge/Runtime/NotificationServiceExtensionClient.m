/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "NotificationServiceExtensionClient.h"

#if TARGET_OS_IOS && !TARGET_OS_MACCATALYST

 #import <dlfcn.h>

 #import "Private/NotificationServiceExtensionPrivate.h"
 #import "Private/UserNotificationsPrivate.h"

@interface FBNotificationServiceExtensionResult ()
- (instancetype)initWithStatus:(FBNotificationServiceExtensionStatus)status failure:(NSString *)failure;
@end

@implementation FBNotificationServiceExtensionResult
- (instancetype)initWithStatus:(FBNotificationServiceExtensionStatus)status failure:(NSString *)failure
{
  self = [super init];
  if (self) {
    _status = status;
    _failure = [failure copy];
  }
  return self;
}

@end

static FBNotificationServiceExtensionResult *Failed(NSString *reason)
{
  return [[FBNotificationServiceExtensionResult alloc] initWithStatus:FBNotificationServiceExtensionStatusFailed failure:reason];
}

@interface FBServiceExtensionCompletion : NSObject
@property (nonatomic, readonly) CFRunLoopRef loop;
@property (nonatomic, readonly) CFRunLoopSourceRef source;
- (FBNotificationServiceExtensionResult *)result;
- (BOOL)isPending;
// The deadline and insertion begin under one lock; no insertion starts after expiry wins.
- (BOOL)insertIfPending:(void (^)(void))insertion;
- (void)expire;
- (void)finish:(FBNotificationServiceExtensionResult *)result;
- (void)stop;
@end

static void CompletionReady(void *context)
{
  [(__bridge FBServiceExtensionCompletion *)context stop];
}

@implementation FBServiceExtensionCompletion
{
  FBNotificationServiceExtensionResult *_result;
  BOOL _insertionStarted;
}
- (instancetype)init
{
  self = [super init];
  if (self) {
    _loop = CFRunLoopGetCurrent();
    CFRetain(_loop);
    CFRunLoopSourceContext context = {0};
    context.info = (__bridge void *)self;
    context.perform = CompletionReady;
    _source = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context);
  }
  return self;
}

- (void)dealloc
{
  CFRelease(_source);
  CFRelease(_loop);
}

- (FBNotificationServiceExtensionResult *)result
{
  @synchronized(self) { return _result; }
}

- (BOOL)isPending
{
  @synchronized(self) { return _result == nil; }
}

- (BOOL)insertIfPending:(void (^)(void))insertion
{
  @synchronized(self) {
    if (_result || _insertionStarted) {
      return NO;
    }
    _insertionStarted = YES;
    // The center initiates an asynchronous request. Hold the deadline lock through initiation,
    // not through its completion. Synchronous callbacks can reenter this recursive monitor.
    insertion();
    return YES;
  }
}

- (void)expire
{
  @synchronized(self) {
    NSString *reason = _insertionStarted
    ? @"Timed out waiting for notification insertion; delivery outcome may be unknown"
    : @"Timed out waiting for NSE processing; notification insertion was not started";
    [self finish:Failed(reason)];
  }
}

- (void)finish:(FBNotificationServiceExtensionResult *)result
{
  @synchronized(self) {
    if (_result) {
      return;
    }
    _result = result;
  }
  CFRunLoopSourceSignal(_source);
  CFRunLoopWakeUp(_loop);
}

- (void)stop
{
  CFRunLoopStop(_loop);
}

@end

@implementation FBNotificationServiceExtensionClient
{
  UNCNotificationServiceExtensionManager *_manager;
  UNUserNotificationCenter *_center;
}

+ (FBNotificationServiceExtensionResult *)sendToBundleID:(NSString *)bundleID jsonPayload:(NSString *)jsonPayload
{
  @try {
    // Keep the framework loaded while any extension session uses its classes.
    if (!dlopen("/System/Library/PrivateFrameworks/UserNotificationsCore.framework/UserNotificationsCore", RTLD_NOW | RTLD_LOCAL)) {
      return Failed([NSString stringWithFormat:@"Could not load UserNotificationsCore: %s", dlerror()]);
    }
    Class managerClass = NSClassFromString(@"UNCNotificationServiceExtensionManager");
    if (![managerClass instancesRespondToSelector:@selector(extensionForBundleIdentifier:error:)]) {
      return Failed(@"The runtime cannot discover notification service extensions");
    }
    id center = [[UNUserNotificationCenter alloc] initWithBundleIdentifier:bundleID];
    id manager = [managerClass new];
    FBNotificationServiceExtensionClient *client = [[self alloc] initWithManager:manager center:center];
    return [client sendToBundleID:bundleID jsonPayload:jsonPayload timeout:40];
  } @catch (NSException *exception) {
    return Failed([NSString stringWithFormat:@"Notification service extension setup raised: %@", exception]);
  }
}

- (instancetype)initWithManager:(id)manager center:(id)center
{
  self = [super init];
  if (self) {
    _manager = manager;
    _center = center;
  }
  return self;
}

- (FBNotificationServiceExtensionResult *)sendToBundleID:(NSString *)bundleID
                                             jsonPayload:(NSString *)jsonPayload
                                                 timeout:(NSTimeInterval)timeout
{
  NSData *data = [jsonPayload dataUsingEncoding:NSUTF8StringEncoding];
  if (!data || data.length > 4096) {
    return Failed(@"The push payload must be UTF-8 JSON of at most 4096 bytes");
  }
  NSError *error = nil;
  id payload = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
  if (![payload isKindOfClass:NSDictionary.class]) {
    return Failed(error.localizedDescription ?: @"The push payload is not a JSON object");
  }
  id aps = payload[@"aps"];
  if (![aps isKindOfClass:NSDictionary.class] || ![aps[@"mutable-content"] isEqual:@1]) {
    return Failed(@"NSE delivery requires aps.mutable-content: 1");
  }
  UNNotificationRequest *request;
  UNCNotificationServiceExtension *extension;
  @try {
    if (![UNNotificationRequest respondsToSelector:@selector(requestWithIdentifier:pushPayload:bundleIdentifier:)]) {
      return Failed(@"The runtime cannot build a push notification request");
    }
    request = [UNNotificationRequest requestWithIdentifier:NSUUID.UUID.UUIDString pushPayload:payload bundleIdentifier:bundleID];
    if (!request || (!request.content.title.length && !request.content.body.length)) {
      return Failed(@"NSE delivery requires a push with alert text");
    }
    extension = [_manager extensionForBundleIdentifier:bundleID error:&error];
    if (!extension || error) {
      return Failed(error.localizedDescription ?: @"The application has no notification service extension");
    }
    if (![extension respondsToSelector:@selector(queue)]
        || ![extension respondsToSelector:@selector(mutateContentForNotificationRequest:error:)]
        || ![extension respondsToSelector:@selector(cleanUp)]
        || ![_center respondsToSelector:@selector(addNotificationRequest:withCompletionHandler:)]) {
      return Failed(@"The runtime cannot execute and deliver notification service extension requests");
    }
  } @catch (NSException *exception) {
    return Failed([NSString stringWithFormat:@"Notification service extension discovery raised: %@", exception]);
  }

  UNUserNotificationCenter *center = _center;
  FBServiceExtensionCompletion *completion = [FBServiceExtensionCompletion new];
  CFRunLoopAddSource(completion.loop, completion.source, kCFRunLoopDefaultMode);
  CFRunLoopTimerRef timer = CFRunLoopTimerCreateWithHandler(
    kCFAllocatorDefault,
    CFAbsoluteTimeGetCurrent() + MAX(0, timeout),
    0,
    0,
    0, ^(CFRunLoopTimerRef timer) {
      [completion expire];
    });
  CFRunLoopAddTimer(completion.loop, timer, kCFRunLoopDefaultMode);
  @try {
    dispatch_queue_t queue = [extension queue];
    if (!queue) {
      [completion finish:Failed(@"The notification service extension has no execution queue")];
    } else {
      dispatch_async(queue, ^{
        @autoreleasepool {
          @try {
            NSError *mutationError = nil;
            UNNotificationContent *content = [extension mutateContentForNotificationRequest:request error:&mutationError];
            if (![completion isPending]) {
              [extension cleanUp];
              return;
            }
            if (!content || mutationError) {
              [extension cleanUp];
              [completion finish:Failed(mutationError.localizedDescription ?: @"The NSE returned no content")];
              return;
            }
            if (![content respondsToSelector:@selector(unc_willAlertUser)]) {
              [extension cleanUp];
              [completion finish:Failed(@"The runtime cannot determine whether the NSE suppressed this notification")];
              return;
            }
            if (![content unc_willAlertUser]) {
              [extension cleanUp];
              [completion finish:[[FBNotificationServiceExtensionResult alloc] initWithStatus:FBNotificationServiceExtensionStatusSuppressed failure:nil]];
              return;
            }
            UNNotificationRequest *mutated = [UNNotificationRequest requestWithIdentifier:request.identifier content:content trigger:request.trigger];
            BOOL started = [completion insertIfPending:^{
              [center addNotificationRequest:mutated
                       withCompletionHandler:^(NSError *insertionError) {
                         FBNotificationServiceExtensionResult *outcome = insertionError ? Failed(insertionError.localizedDescription)
                         : [[FBNotificationServiceExtensionResult alloc] initWithStatus:FBNotificationServiceExtensionStatusDelivered failure:nil];
                         @try {
                           // Insertion has consumed attachments. Cleanup must not overwrite its observed outcome.
                           [extension cleanUp];
                         } @catch (NSException *exception) {
                           NSLog(@"[NotificationServiceExtension] Insertion cleanup raised: %@", exception);
                         }
                         // The oneshot guest can exit as soon as finish wakes its serving thread.
                         [completion finish:outcome];
                       }];
            }];
            if (!started) {
              [extension cleanUp];
            }
          } @catch (NSException *exception) {
            @try {
              [extension cleanUp];
            } @catch (NSException *cleanupException) {
              NSLog(@"[NotificationServiceExtension] Cleanup raised: %@", cleanupException);
            }
            [completion finish:Failed([NSString stringWithFormat:@"Notification service extension execution raised: %@", exception])];
          }
        }
      });
    }
    // This is the oneshot guest's serving thread, not a companion cooperative thread. The main run loop
    // must keep handling extension-host messages while mutation runs on Apple's per-extension queue.
    while (![completion result]) {
      CFRunLoopRun();
    }
  } @catch (NSException *exception) {
    [completion finish:Failed([NSString stringWithFormat:@"Notification service extension queue raised: %@", exception])];
  }
  CFRunLoopTimerInvalidate(timer);
  CFRelease(timer);
  CFRunLoopRemoveSource(completion.loop, completion.source, kCFRunLoopDefaultMode);
  NSLog(@"[NotificationServiceExtension] %@: outcome=%ld", bundleID, (long)[completion result].status);
  return [completion result];
}

@end
#endif

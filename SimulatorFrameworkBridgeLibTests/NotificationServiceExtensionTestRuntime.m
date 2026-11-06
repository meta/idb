/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "NotificationServiceExtensionTestRuntime.h"

#import <SimulatorFrameworkBridgeRuntime/NotificationServiceExtensionClient.h>

#import "../SimulatorFrameworkBridge/Runtime/Private/NotificationServiceExtensionPrivate.h"

@interface TestExtensionContent : UNMutableNotificationContent
@end
@implementation TestExtensionContent
- (BOOL)unc_willAlertUser { return self.body.length > 0; }

@end

@interface TestExtension : NSObject
@property (nonatomic, copy) NSString *scenario;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) NSCondition *mutationCondition;
@property (nonatomic) BOOL mutationReleased;
@property (nonatomic) NSInteger mutations;
@property (nonatomic) NSInteger cleanups;
@property (nonatomic) BOOL controlledCleanup;
@property (nonatomic, strong) NSCondition *cleanupCondition;
@property (nonatomic) BOOL cleanupEntered;
@property (nonatomic) BOOL cleanupReleased;
@property (nonatomic) BOOL loopExitedDuringCleanup;
@property (nonatomic) CFRunLoopRef servingLoop;
@end
@implementation TestExtension
- (instancetype)init
{
  self = [super init];
  if (self) {
    _queue = dispatch_queue_create("service-extension-test", DISPATCH_QUEUE_SERIAL);
    _mutationCondition = [NSCondition new];
    _cleanupCondition = [NSCondition new];
  }
  return self;
}

- (UNNotificationContent *)mutateContentForNotificationRequest:(UNNotificationRequest *)request error:(NSError **)error
{
  self.mutations += 1;
  if ([self.scenario isEqualToString:@"timeout"]) {
    [self.mutationCondition lock];
    while (!self.mutationReleased) {
      [self.mutationCondition wait];
    }
    [self.mutationCondition unlock];
  }
  if ([self.scenario isEqualToString:@"raise"]) {
    @throw [NSException exceptionWithName:@"TestException" reason:@"mutation raised" userInfo:nil];
  }
  if ([self.scenario isEqualToString:@"error"]) {
    *error = [NSError errorWithDomain:@"TestExtension" code:1 userInfo:@{NSLocalizedDescriptionKey : @"mutation failed"}];
    return nil;
  }
  TestExtensionContent *content = [TestExtensionContent new];
  content.body = [self.scenario isEqualToString:@"suppressed"] ? @"" : @"Changed by the NSE";
  content.title = @"Processed";
  return content;
}

- (void)cleanUp
{
  if (self.controlledCleanup) {
    [self.cleanupCondition lock];
    self.cleanupEntered = YES;
    [self.cleanupCondition broadcast];
    while (!self.cleanupReleased) {
      [self.cleanupCondition wait];
    }
    [self.cleanupCondition unlock];
  }
  self.cleanups += 1;
  if ([self.scenario hasPrefix:@"cleanup-raise"]) {
    @throw [NSException exceptionWithName:@"TestCleanupException" reason:@"cleanup raised" userInfo:nil];
  }
}

@end

@interface TestExtensionManager : NSObject
@property (nonatomic, strong) TestExtension *extension;
@property (nonatomic) NSInteger lookups;
@end
@implementation TestExtensionManager
- (id)extensionForBundleIdentifier:(NSString *)bundleID error:(NSError **)error
{
  self.lookups += 1;
  return self.extension;
}

@end

@interface TestExtensionCenter : NSObject
@property (nonatomic, strong) UNNotificationRequest *posted;
@property (nonatomic) NSInteger insertions;
@property (nonatomic) BOOL fail;
@property (nonatomic) BOOL asynchronous;
@property (nonatomic, strong) dispatch_queue_t callbackQueue;
@property (nonatomic, strong) TestExtension *extension;
@end
@implementation TestExtensionCenter
- (void)addNotificationRequest:(UNNotificationRequest *)request withCompletionHandler:(void (^)(NSError *))handler
{
  self.posted = request;
  self.insertions += 1;
  void (^complete)(void) = ^{
    handler(self.fail ? [NSError errorWithDomain:@"TestCenter" code:1 userInfo:@{NSLocalizedDescriptionKey : @"insertion refused"}] : nil);
  };
  if (self.asynchronous) {
    // Force the serving run loop to see cleanup pending, independent of thread scheduling.
    CFRunLoopPerformBlock(self.extension.servingLoop,
      kCFRunLoopDefaultMode, ^{
        [self.extension.cleanupCondition lock];
        while (!self.extension.cleanupEntered) {
          [self.extension.cleanupCondition wait];
        }
        [self.extension.cleanupCondition unlock];
      });
    CFRunLoopWakeUp(self.extension.servingLoop);
    dispatch_async(self.callbackQueue, complete);
  } else {
    complete();
  }
}

@end

// These declarations reach the production completion object without exporting it from the runtime module.
@interface FBServiceExtensionCompletion : NSObject
- (BOOL)insertIfPending:(void (^)(void))insertion;
- (void)expire;
- (void)finish:(FBNotificationServiceExtensionResult *)result;
- (FBNotificationServiceExtensionResult *)result;
@end

NSDictionary<NSString *, id> *FBNotificationServiceExtensionDeadlineTestRun(NSString *scenario)
{
  FBServiceExtensionCompletion *completion = [FBServiceExtensionCompletion new];
  if ([scenario isEqualToString:@"expired-before-insertion"]) {
    [completion expire];
  }
  __block NSInteger insertions = 0;
  BOOL started = [completion insertIfPending:^{
    insertions += 1;
    if ([scenario isEqualToString:@"synchronous-completion"]) {
      [completion finish:[FBNotificationServiceExtensionResult new]];
    }
  }];
  [completion expire];
  // A repeated submission must never insert twice or replace the terminal outcome.
  BOOL restarted = [completion insertIfPending:^{ insertions += 1; }];
  return @{@"status" : @([completion result].status), @"error" : [completion result].failure ?: @"",
           @"insertions" : @(insertions), @"started" : @(started), @"restarted" : @(restarted)};
}

NSDictionary<NSString *, id> *FBNotificationServiceExtensionTestRun(NSString *scenario)
{
  TestExtension *extension = [TestExtension new];
  extension.scenario = scenario;
  TestExtensionManager *manager = [TestExtensionManager new];
  manager.extension = [scenario isEqualToString:@"missing"] ? nil : extension;
  TestExtensionCenter *center = [TestExtensionCenter new];
  center.fail = [scenario isEqualToString:@"insertion-error"] || [scenario isEqualToString:@"cleanup-raise-insertion-error"];
  center.asynchronous = [scenario isEqualToString:@"asynchronous-insertion"];
  center.callbackQueue = dispatch_queue_create("service-extension-insertion-completion-test", DISPATCH_QUEUE_SERIAL);
  center.extension = extension;
  extension.controlledCleanup = center.asynchronous;
  extension.servingLoop = CFRunLoopGetCurrent();
  CFRunLoopObserverRef cleanupObserver = NULL;
  if (extension.controlledCleanup) {
    cleanupObserver = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault,
      kCFRunLoopBeforeWaiting | kCFRunLoopExit,
      true,
      0,
      ^(CFRunLoopObserverRef observer, CFRunLoopActivity activity) {
        [extension.cleanupCondition lock];
        if (extension.cleanupEntered && !extension.cleanupReleased) {
          // Normal processing reaches before-waiting; an early finish exits the run loop instead.
          extension.loopExitedDuringCleanup = activity == kCFRunLoopExit;
          extension.cleanupReleased = YES;
          [extension.cleanupCondition broadcast];
        }
        [extension.cleanupCondition unlock];
      });
    CFRunLoopAddObserver(extension.servingLoop, cleanupObserver, kCFRunLoopDefaultMode);
  }
  NSString *payload = @"{\"aps\":{\"alert\":{\"body\":\"Original\"},\"mutable-content\":1}}";
  if ([scenario isEqualToString:@"invalid"]) {
    payload = @"[]";
  }
  if ([scenario isEqualToString:@"nonmutable"]) {
    payload = @"{\"aps\":{\"alert\":{\"body\":\"Original\"}}}";
  }
  if ([scenario isEqualToString:@"oversized"]) {
    payload = [@" " stringByPaddingToLength:4097 withString:@" " startingAtIndex:0];
  }
  FBNotificationServiceExtensionClient *client = [[FBNotificationServiceExtensionClient alloc] initWithManager:manager center:center];
  FBNotificationServiceExtensionResult *result = [client sendToBundleID:@"com.example.App" jsonPayload:payload timeout:[scenario isEqualToString:@"timeout"] ? 0 : 5];
  NSInteger cleanupsAtReturn = extension.cleanups;
  if (cleanupObserver) {
    CFRunLoopObserverInvalidate(cleanupObserver);
    CFRelease(cleanupObserver);
  }
  [extension.cleanupCondition lock];
  extension.cleanupReleased = YES;
  [extension.cleanupCondition broadcast];
  [extension.cleanupCondition unlock];
  // Join the fake's late work before reading its counters or allowing the test to end.
  [extension.mutationCondition lock];
  extension.mutationReleased = YES;
  [extension.mutationCondition signal];
  [extension.mutationCondition unlock];
  dispatch_sync(extension.queue, ^{});
  dispatch_sync(center.callbackQueue, ^{});
  return @{@"status" : @(result.status), @"error" : result.failure ?: @"", @"body" : center.posted.content.body ?: @"",
           @"lookups" : @(manager.lookups), @"mutations" : @(extension.mutations), @"insertions" : @(center.insertions), @"cleanups" : @(extension.cleanups), @"cleanupsAtReturn" : @(cleanupsAtReturn), @"loopExitedDuringCleanup" : @(extension.loopExitedDuringCleanup)};
}

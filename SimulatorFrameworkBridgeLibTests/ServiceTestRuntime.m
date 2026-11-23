/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "ServiceTestRuntime.h"

#import <dlfcn.h>
#import <objc/runtime.h>
#import <stdio.h>
#import <unistd.h>

#import <SimulatorFrameworkBridgeRuntime/AccessibilityClientProvider.h>

#import "../SimulatorFrameworkBridge/Runtime/Private/AccessibilityRuntime_Private.h"
#import "../SimulatorFrameworkBridge/Runtime/Private/BulletinBoardPrivate.h"
#import "FBAXFakeRuntime.h"

@interface FakeNotificationSettingsGateway ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, BBSectionInfo *> *sections;
@end

@implementation FakeNotificationSettingsGateway
- (instancetype)init
{
  self = [super init];
  if (self) {
    _sections = [NSMutableDictionary dictionary];
    _writtenSectionIDs = [NSMutableArray array];
  }
  return self;
}

- (id)sectionInfoForSectionID:(NSString *)sectionID
{
  return self.sections[sectionID];
}

- (void)setSectionInfo:(id)sectionInfo forSectionID:(NSString *)sectionID
{
  self.sections[sectionID] = sectionInfo;
  [self.writtenSectionIDs addObject:sectionID];
}

- (NSArray<NSString *> *)allSectionIDs
{
  return self.sections.allKeys;
}

@end

Class FBHealthAuthorizationStoreClass(void)
{
  dlopen("/System/Library/Frameworks/HealthKit.framework/HealthKit", RTLD_NOW);
  return objc_lookUpClass("HKAuthorizationStore");
}

BOOL FBHealthRuntimeDeclaresSelector(NSString *selectorName)
{
  Class cls = FBHealthAuthorizationStoreClass();
  return cls != Nil && [cls instancesRespondToSelector:NSSelectorFromString(selectorName)];
}

NSException *FBExceptionRaisedBy(void (^NS_NOESCAPE block)(void))
{
  @try {
    block();
    return nil;
  } @catch (NSException *exception) {
    return exception;
  }
}

@implementation FBSectionInfoWithOnlyNotificationCenterFlag
@end

@implementation FBSectionInfoWithoutEffectiveFlags
@end

BOOL FBNotificationAllowsNotifications(id sectionInfo)
{
  return [(BBSectionInfo *)sectionInfo allowsNotifications];
}

NSInteger FBNotificationAuthorizationStatus(id sectionInfo)
{
  return [(BBSectionInfo *)sectionInfo authorizationStatus];
}

BOOL FBNotificationShowsInNotificationCenter(id sectionInfo)
{
  return [(BBSectionInfo *)sectionInfo showsInNotificationCenter];
}

BOOL FBNotificationShowsInLockScreen(id sectionInfo)
{
  return [(BBSectionInfo *)sectionInfo showsInLockScreen];
}

NSString *FBStdoutWhileRunning(void (^NS_NOESCAPE block)(void))
{
  NSPipe *pipe = [NSPipe pipe];
  // Drained on another queue for as long as the block runs, rather than after it returns: a
  // pipe nobody is reading holds only a buffer's worth (16-64KB on Darwin), and the write that
  // fills it blocks forever inside `printf`. That would hang the whole test process rather
  // than fail one test, and what these services print is not bounded - `notifications list`
  // prints a record per section, and an accessibility read prints a hierarchy.
  NSMutableData *written = [NSMutableData data];
  dispatch_queue_t queue = dispatch_queue_create("com.facebook.idb.stdout-capture", DISPATCH_QUEUE_SERIAL);
  dispatch_group_t draining = dispatch_group_create();
  NSFileHandle *reader = pipe.fileHandleForReading;
  fflush(stdout);
  int original = dup(STDOUT_FILENO);
  dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO);
  dispatch_group_async(draining,
    queue, ^{
      // Ends when the write end is closed below, which is what makes this read return empty.
      while (true) {
        NSData *chunk = [reader availableData];
        if (chunk.length == 0) {
          break;
        }
        [written appendData:chunk];
      }
    });
  @try {
    block();
  } @finally {
    fflush(stdout);
    dup2(original, STDOUT_FILENO);
    close(original);
    [pipe.fileHandleForWriting closeFile];
  }
  dispatch_group_wait(draining, DISPATCH_TIME_FOREVER);
  NSString *output = [[NSString alloc] initWithData:written encoding:NSUTF8StringEncoding];
  return output;
}

NSDictionary<NSString *, id> *FBParsedJSONLine(NSString *output)
{
  NSData *data = [output dataUsingEncoding:NSUTF8StringEncoding];
  return [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
}

NSDictionary<NSString *, NSNumber *> *FBAXRuntimeQueueProbe(BOOL raise)
{
  __block BOOL offMain = NO;
  __block NSUInteger calls = 0;
  NSException *expected = [NSException exceptionWithName:NSInternalInconsistencyException reason:@"worker failed" userInfo:nil];
  NSException *caught = nil;
  @try {
    FBAXBridgeRunOffMainQueue(^{
      offMain = !NSThread.isMainThread;
      calls++;
      if (raise) {
        @throw expected;
      }
    });
  } @catch (NSException *exception) {
    caught = exception;
  }
  return @{@"offMain" : @(offMain), @"calls" : @(calls), @"sameException" : @(caught == expected), @"caught" : @(caught != nil)};
}

NSDictionary<NSString *, id> *FBNotificationSectionSnapshot(id sectionInfo)
{
  BBSectionInfo *section = sectionInfo;
  return @{
    @"sectionID" : section.sectionID ?: @"",
    @"allowsNotifications" : @(section.allowsNotifications),
    @"authorizationStatus" : @(section.authorizationStatus),
    @"alertType" : @(section.alertType),
    @"lockScreenSetting" : @(section.lockScreenSetting),
    @"notificationCenterSetting" : @(section.notificationCenterSetting),
  };
}

void FBNotificationSetPresentation(id sectionInfo, NSUInteger alert, NSUInteger lockScreen, NSUInteger center)
{
  BBSectionInfo *section = sectionInfo;
  section.alertType = alert;
  section.lockScreenSetting = lockScreen;
  section.notificationCenterSetting = center;
}

NSDictionary<NSString *, id> *FBAXRuntimeInitializationProbe(FBAXRuntimeInitializationMode mode, BOOL prepare, NSDictionary<NSString *, id> *(^NS_NOESCAPE handleRequest)(void))
{
  FBAXFakeRuntime *runtime = [FBAXFakeRuntime new];
  runtime.deviceSettings[@(FBAXDeviceSettingReduceMotion)] = @YES;
  __block NSUInteger calls = 0;
  [FBAXClientProvider setRuntimeFactoryForTesting:^id<FBAXRuntime>(NSString **error) {
    calls++;
    switch (mode) {
      case FBAXRuntimeInitializationModeSuccess:
        return runtime;
      case FBAXRuntimeInitializationModeFailureWithMessage:
        if (error) {
          *error = @"missing test framework";
        }
        return nil;
      case FBAXRuntimeInitializationModeFailureWithoutMessage:
      default:
        return nil;
      case FBAXRuntimeInitializationModeExceptionWithReason:
      case FBAXRuntimeInitializationModeExceptionWithoutReason:
        @throw [NSException exceptionWithName:NSInternalInconsistencyException
                                       reason:mode == FBAXRuntimeInitializationModeExceptionWithReason ? @"initialization failed" : nil
                                     userInfo:nil];
    }
  }];
  NSString *preparationException = nil;
  NSDictionary *response = nil;
  @try {
    if (prepare) {
      @try {
        [FBAXClientProvider prepare];
      } @catch (NSException *exception) {
        preparationException = exception.reason ?: exception.name;
      }
    }
    response = handleRequest();
  } @finally {
    [FBAXClientProvider setRuntimeFactoryForTesting:nil];
  }
  return @{@"preparationException" : preparationException ?: NSNull.null, @"calls" : @(calls), @"response" : response};
}

NSDictionary<NSString *, NSNumber *> *FBAXBridgeServeProbe(int (^NS_NOESCAPE run)(void))
{
  FBAXFakeRuntime *runtime = [FBAXFakeRuntime new];
  __block NSUInteger calls = 0;
  [FBAXClientProvider setRuntimeFactoryForTesting:^id<FBAXRuntime>(NSString **error) {
    calls++;
    return runtime;
  }];
  int status;
  @try {
    status = run();
  } @finally {
    [FBAXClientProvider setRuntimeFactoryForTesting:nil];
  }
  return @{@"status" : @(status), @"calls" : @(calls)};
}

@implementation FBFakeDeliveredNotificationsCenter

- (void)getDeliveredNotificationsWithCompletionHandler:(void (^)(NSArray<UNNotification *> *notifications))completionHandler
{
  self.wasAsked = YES;
  completionHandler(self.notifications ?: @[]);
}

@end

@implementation FBFakeDeliveredNotificationsRemover

- (instancetype)init
{
  self = [super init];
  if (self) {
    _removedBundleIDs = @[];
  }
  return self;
}

- (void)removeAllDeliveredNotificationsForBundleIdentifier:(NSString *)bundleIdentifier
                                         completionHandler:(void (^)(BOOL success))completionHandler
{
  self.removedBundleIDs = [self.removedBundleIDs arrayByAddingObject:bundleIdentifier];
  completionHandler(self.succeeds);
}

@end

@implementation FBRaisingDeliveredNotificationsRemover

- (void)removeAllDeliveredNotificationsForBundleIdentifier:(NSString *)bundleIdentifier
                                         completionHandler:(void (^)(BOOL success))completionHandler
{
  [NSException raise:NSInternalInconsistencyException format:@"connection invalidated"];
}

@end

@implementation FBSilentDeliveredNotificationsRemover

- (void)removeAllDeliveredNotificationsForBundleIdentifier:(NSString *)bundleIdentifier
                                         completionHandler:(void (^)(BOOL success))completionHandler
{}

@end

@implementation FBRaisingDeliveredNotificationsCenter

- (void)getDeliveredNotificationsWithCompletionHandler:(void (^)(NSArray<UNNotification *> *notifications))completionHandler
{
  [NSException raise:NSInvalidArgumentException format:@"no notification settings for this bundle"];
}

@end

@implementation FBSilentDeliveredNotificationsCenter

- (void)getDeliveredNotificationsWithCompletionHandler:(void (^)(NSArray<UNNotification *> *notifications))completionHandler
{}

@end

@interface FBAsynchronousDeliveredNotificationsCenter ()
@property (nonatomic, strong) dispatch_queue_t queue;
@end

@implementation FBAsynchronousDeliveredNotificationsCenter

- (instancetype)init
{
  self = [super init];
  if (self) {
    _queue = dispatch_queue_create("com.facebook.idb.delivered-notifications-tests", DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

- (void)getDeliveredNotificationsWithCompletionHandler:(void (^)(NSArray<UNNotification *> *notifications))completionHandler
{
  dispatch_async(self.queue, ^{
    completionHandler(@[]);
  });
}

@end

@implementation FBFakeDeliveredNotification

- (instancetype)request
{
  return self;
}

- (id)content
{
  return nil;
}

@end

@implementation FBRaisingDeliveredNotification
- (id)content
{
  [NSException raise:NSInvalidArgumentException format:@"notification content unavailable"];
  return nil;
}

@end

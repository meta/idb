/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "HealthTestRuntime.h"

#import <stdio.h>
#import <unistd.h>

#import <SimulatorFrameworkBridgeRuntime/HealthSettingsClient.h>

@interface FBHealthTestRuntime ()
@property (nonatomic, strong) NSMutableArray<void (^)(void)> *pendingCallbacks;
@end

static FBHealthTestRuntime *currentRuntime;

static void raiseIfRequested(NSString *operation)
{
  if ([currentRuntime.raisedOperation isEqualToString:operation]) {
    [NSException raise:@"HealthTest" format:@"%@ failed", operation];
  }
}

static NSError *testError(NSString *message)
{
  return message ? [NSError errorWithDomain:@"HealthTest" code:1 userInfo:@{NSLocalizedDescriptionKey : message}] : nil;
}

static void completeBoolean(NSString *stage, BOOL ok, NSString *message, void (^completion)(BOOL, NSError *))
{
  if ([currentRuntime.omittedCompletion isEqual:stage]) {
    return;
  }
  NSError *error = testError(message);
  if ([currentRuntime.deferredCompletion isEqual:stage]) {
    [currentRuntime.pendingCallbacks addObject:^{ completion(ok, error); }];
  } else if (currentRuntime.asyncCompletions) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ completion(ok, error); });
  } else {
    completion(ok, error);
  }
}

@interface FBHealthOpaqueValue : NSObject
@end
@implementation FBHealthOpaqueValue
- (NSString *)description { return @"opaque-value"; }

@end

@interface FBHealthRecord : NSObject
@property (nonatomic, copy) NSDictionary *values;
@end
@implementation FBHealthRecord
- (BOOL)respondsToSelector:(SEL)selector
{
  return self.values[NSStringFromSelector(selector)] != nil || [super respondsToSelector:selector];
}

- (id)valueForKey:(NSString *)key
{
  raiseIfRequested(@"record");
  id value = self.values[key];
  if (value == NSNull.null) {
    return nil;
  }
  return [value isEqual:@"<opaque>"] ? [FBHealthOpaqueValue new] : value;
}

@end

@interface FBHealthStoreProbe : NSObject
@end
@implementation FBHealthStoreProbe
- (instancetype)init
{
  self = [super init];
  if (self) {
    raiseIfRequested(@"healthStore");
    [currentRuntime.operations addObject:@"healthStore"];
  }
  return self;
}

@end

@interface FBHealthTypeProbe : NSObject
@end
@implementation FBHealthTypeProbe
+ (id)resolve:(NSString *)identifier factory:(NSString *)factory
{
  raiseIfRequested(@"factory");
  [currentRuntime.factoryCalls addObject:[NSString stringWithFormat:@"%@:%@", factory, identifier]];
  return [currentRuntime.typeFactories[identifier] isEqual:factory] ? identifier : nil;
}

+ (id)quantityTypeForIdentifier:(NSString *)identifier { return [self resolve:identifier factory:@"HKQuantityType"]; }

+ (id)categoryTypeForIdentifier:(NSString *)identifier { return [self resolve:identifier factory:@"HKCategoryType"]; }

+ (id)characteristicTypeForIdentifier:(NSString *)identifier { return [self resolve:identifier factory:@"HKCharacteristicType"]; }

+ (id)correlationTypeForIdentifier:(NSString *)identifier { return [self resolve:identifier factory:@"HKCorrelationType"]; }

+ (id)documentTypeForIdentifier:(NSString *)identifier { return [self resolve:identifier factory:@"HKDocumentType"]; }

@end

@interface FBHealthAuthorizationProbe : NSObject
@end
@implementation FBHealthAuthorizationProbe
- (instancetype)initWithHealthStore:(id)store
{
  self = [super init];
  if (self) {
    raiseIfRequested(@"authorizationStore");
    [currentRuntime.operations addObject:@"authorizationStore"];
    currentRuntime.arguments[@"expectedHealthStore"] = @([store isKindOfClass:FBHealthStoreProbe.class]);
  }
  return self;
}

- (BOOL)respondsToSelector:(SEL)selector
{
  if (selector == @selector(setAuthorizationStatuses:authorizationModes:modeInfos:forBundleIdentifier:options:completion:)) {
    return (currentRuntime.setterVariants & 2) != 0;
  }
  if (selector == @selector(setAuthorizationStatuses:authorizationModes:forBundleIdentifier:options:completion:)) {
    return (currentRuntime.setterVariants & 1) != 0;
  }
  return [super respondsToSelector:selector];
}

- (void)setRequestedAuthorizationForBundleIdentifier:(NSString *)bundleID shareTypes:(NSSet *)shareTypes readTypes:(NSSet *)readTypes completion:(void (^)(BOOL, NSError *))completion
{
  raiseIfRequested(@"seed");
  [currentRuntime.operations addObject:@"seed"];
  currentRuntime.arguments[@"seedBundle"] = bundleID;
  currentRuntime.arguments[@"shareTypes"] = shareTypes;
  currentRuntime.arguments[@"readTypes"] = readTypes;
  completeBoolean(@"seed", currentRuntime.seedOK, currentRuntime.seedError, completion);
}

- (void)captureSet:(NSDictionary *)statuses modes:(NSDictionary *)modes bundleID:(NSString *)bundleID options:(NSUInteger)options completion:(void (^)(BOOL, NSError *))completion
{
  currentRuntime.arguments[@"statuses"] = statuses;
  currentRuntime.arguments[@"modes"] = modes;
  currentRuntime.arguments[@"setBundle"] = bundleID;
  currentRuntime.arguments[@"options"] = @(options);
  completeBoolean(@"set", currentRuntime.setOK, currentRuntime.setError, completion);
}

- (void)setAuthorizationStatuses:(NSDictionary *)statuses authorizationModes:(NSDictionary *)modes modeInfos:(NSDictionary *)modeInfos forBundleIdentifier:(NSString *)bundleID options:(NSUInteger)options completion:(void (^)(BOOL, NSError *))completion
{
  raiseIfRequested(@"setModern");
  [currentRuntime.operations addObject:@"setModern"];
  currentRuntime.arguments[@"modeInfos"] = modeInfos;
  [self captureSet:statuses modes:modes bundleID:bundleID options:options completion:completion];
}

- (void)setAuthorizationStatuses:(NSDictionary *)statuses authorizationModes:(NSDictionary *)modes forBundleIdentifier:(NSString *)bundleID options:(NSUInteger)options completion:(void (^)(BOOL, NSError *))completion
{
  raiseIfRequested(@"setLegacy");
  [currentRuntime.operations addObject:@"setLegacy"];
  [self captureSet:statuses modes:modes bundleID:bundleID options:options completion:completion];
}

- (void)resetAuthorizationStatusForBundleIdentifier:(NSString *)bundleID completion:(void (^)(BOOL, NSError *))completion
{
  raiseIfRequested(@"clear");
  [currentRuntime.operations addObject:@"clear"];
  currentRuntime.arguments[@"clearBundle"] = bundleID;
  completeBoolean(@"clear", currentRuntime.clearOK, currentRuntime.clearError, completion);
}

- (void)fetchAuthorizationRecordsForBundleIdentifier:(NSString *)bundleID completion:(void (^)(NSArray *, NSError *))completion
{
  raiseIfRequested(@"list");
  [currentRuntime.operations addObject:@"list"];
  currentRuntime.arguments[@"listBundle"] = bundleID;
  NSMutableArray *records = [NSMutableArray array];
  for (NSDictionary *values in currentRuntime.records) {
    FBHealthRecord *record = [FBHealthRecord new];
    record.values = values;
    [records addObject:record];
  }
  if ([currentRuntime.omittedCompletion isEqual:@"list"]) {
    return;
  }
  NSError *error = testError(currentRuntime.fetchError);
  if ([currentRuntime.deferredCompletion isEqual:@"list"]) {
    [currentRuntime.pendingCallbacks addObject:^{ completion(records, error); }];
  } else if (currentRuntime.asyncCompletions) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ completion(records, error); });
  } else {
    completion(records, error);
  }
}

@end

@implementation FBHealthTestRuntime
- (instancetype)init
{
  self = [super init];
  if (self) {
    _typeFactories = @{};
    _missingClasses = [NSSet set];
    _setterVariants = 3;
    _seedOK = YES;
    _setOK = YES;
    _clearOK = YES;
    _omittedCompletion = @"";
    _deferredCompletion = @"";
    _pendingCallbacks = [NSMutableArray array];
    _raisedOperation = @"";
    _records = @[];
    _operations = [NSMutableArray array];
    _factoryCalls = [NSMutableArray array];
    _arguments = [NSMutableDictionary dictionary];
  }
  return self;
}

- (void)install
{
  currentRuntime = self;
  FBHealthSetClassLookupForTesting(^Class (NSString *name) {
    if ([self.missingClasses containsObject:name]) {
      return Nil;
    }
    if ([name isEqual:@"HKHealthStore"]) {
      return FBHealthStoreProbe.class;
    }
    if ([name isEqual:@"HKAuthorizationStore"]) {
      return FBHealthAuthorizationProbe.class;
    }
    return FBHealthTypeProbe.class;
  });
}

- (void)completePendingCallbacks
{
  NSArray<void (^)(void)> *callbacks = [self.pendingCallbacks copy];
  [self.pendingCallbacks removeAllObjects];
  dispatch_semaphore_t finished = dispatch_semaphore_create(0);
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
    for (void (^callback)(void) in callbacks) {
      callback();
    }
    dispatch_semaphore_signal(finished);
  });
  dispatch_semaphore_wait(finished, DISPATCH_TIME_FOREVER);
}

- (void)uninstall
{
  FBHealthSetClassLookupForTesting(nil);
  currentRuntime = nil;
}

- (NSDictionary<NSString *, id> *)runService:(NSInteger (^NS_NOESCAPE)(void))service
{
  [self install];
  fflush(stdout);
  FILE *capture = tmpfile();
  int saved = dup(STDOUT_FILENO);
  NSCAssert(capture && saved >= 0, @"Cannot capture Health output");
  int redirected = dup2(fileno(capture), STDOUT_FILENO);
  NSCAssert(redirected >= 0, @"Cannot redirect Health output");
  NSInteger status = -1;
  NSString *raisedException = nil;
  @try {
    status = service();
  } @catch (NSException *exception) {
    raisedException = exception.name;
  } @finally {
    fflush(stdout);
    dup2(saved, STDOUT_FILENO);
    close(saved);
    [self uninstall];
  }
  rewind(capture);
  NSMutableData *data = [NSMutableData data];
  unsigned char buffer[1024];
  size_t count;
  while ((count = fread(buffer, 1, sizeof(buffer), capture)) > 0) {
    [data appendBytes:buffer length:count];
  }
  fclose(capture);
  if (raisedException) {
    return @{@"exception" : raisedException};
  }
  NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  return @{@"status" : @(status), @"output" : output};
}

@end

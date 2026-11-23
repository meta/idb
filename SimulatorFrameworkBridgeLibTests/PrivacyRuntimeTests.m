/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <XCTest/XCTest.h>

#import <SimulatorFrameworkBridgeRuntime/PrivacyRuntime.h>

static NSMutableArray<NSDictionary *> *privacyCalls;
static NSUInteger rejectPrivacyCall;
static BOOL raisePrivacyException;
static CFStringRef testNoKill = CFSTR("TestNoKill");

static Boolean recordPrivacyCall(CFStringRef service, CFStringRef bundleID, CFDictionaryRef options, NSString *operation, Boolean allowed)
{
  if (raisePrivacyException) {
    [NSException raise:@"TCCException" format:@"synthetic daemon exception"];
  }
  [privacyCalls addObject:@{@"service" : (__bridge NSString *)service,
                            @"bundleID" : (__bridge NSString *)bundleID,
                            @"options" : (__bridge NSDictionary *)options,
                            @"operation" : operation, @"allowed" : @(allowed)}];
  return privacyCalls.count != rejectPrivacyCall;
}

static Boolean testSetAccess(CFStringRef service, CFStringRef bundleID, Boolean allowed, CFDictionaryRef options)
{
  return recordPrivacyCall(service, bundleID, options, @"set", allowed);
}

static Boolean testResetAccess(CFStringRef service, CFStringRef bundleID, CFDictionaryRef options)
{
  return recordPrivacyCall(service, bundleID, options, @"reset", false);
}

static void *privacySymbol(const char *name)
{
  if (strcmp(name, "TCCAccessSetForBundleIdWithOptions") == 0) {
    return (void *)testSetAccess;
  }
  if (strcmp(name, "TCCAccessResetForBundleIdWithOptions") == 0) {
    return (void *)testResetAccess;
  }
  if (strcmp(name, "kTCCSetNoKill") == 0) {
    return &testNoKill;
  }
  return NULL;
}

@interface PrivacyRuntimeTests : XCTestCase
@end

@implementation PrivacyRuntimeTests
- (void)setUp
{
  [super setUp];
  privacyCalls = [NSMutableArray array];
  rejectPrivacyCall = NSNotFound;
  raisePrivacyException = NO;
  testNoKill = CFSTR("TestNoKill");
}

- (FBPrivacyOutcome *)update:(BOOL)approved services:(NSArray<NSString *> *)services
{
  return [FBPrivacyBinding updateBundleID:@"app"
                                 services:services
                                 approved:approved
                                 resolver:^void *(const char *name) {
                                   return privacySymbol(name);
                                 }];
}

- (void)testApprovalRequestsAllowedRatherThanLimitedAndPreservesProcess
{
  FBPrivacyOutcome *result = [self update:YES services:@[@"kTCCServicePhotos", @"kTCCServiceCamera"]];
  XCTAssertEqual(result.status, FBPrivacyStatusCompleted);
  XCTAssertNil(result.failureReason);
  XCTAssertEqual(privacyCalls.count, 2u);
  for (NSDictionary *call in privacyCalls) {
    XCTAssertEqualObjects(call[@"bundleID"], @"app");
    XCTAssertEqualObjects(call[@"operation"], @"set");
    XCTAssertEqualObjects(call[@"allowed"], @YES);
    XCTAssertEqualObjects(call[@"options"], (@{@"auth_value" : @2, @"TestNoKill" : @YES}));
  }
  XCTAssertEqualObjects(privacyCalls[0][@"service"], @"kTCCServicePhotos");
  XCTAssertEqualObjects(privacyCalls[1][@"service"], @"kTCCServiceCamera");
}

- (void)testRevokeResetsOnlyTheRequestedServiceWithoutDenyingOrKilling
{
  XCTAssertEqual([self update:NO services:@[@"kTCCServicePhotos"]].status, FBPrivacyStatusCompleted);
  XCTAssertEqual(privacyCalls.count, 1u);
  XCTAssertEqualObjects(privacyCalls[0][@"operation"], @"reset");
  XCTAssertEqualObjects(privacyCalls[0][@"service"], @"kTCCServicePhotos");
  XCTAssertEqualObjects(privacyCalls[0][@"options"], (@{@"TestNoKill" : @YES}));
}

- (void)testApprovalDoesNotRequireResetSymbol
{
  FBPrivacyOutcome *result = [FBPrivacyBinding updateBundleID:@"app"
                                                     services:@[@"kTCCServiceCamera"]
                                                     approved:YES
                                                     resolver:^void *(const char *name) {
                                                       return strcmp(name, "TCCAccessResetForBundleIdWithOptions") == 0 ? NULL : privacySymbol(name);
                                                     }];
  XCTAssertEqual(result.status, FBPrivacyStatusCompleted);
  XCTAssertEqual(privacyCalls.count, 1u);
  XCTAssertEqualObjects(privacyCalls[0][@"operation"], @"set");
}

- (void)testRevokeDoesNotRequireSetSymbol
{
  FBPrivacyOutcome *result = [FBPrivacyBinding updateBundleID:@"app"
                                                     services:@[@"kTCCServiceCamera"]
                                                     approved:NO
                                                     resolver:^void *(const char *name) {
                                                       return strcmp(name, "TCCAccessSetForBundleIdWithOptions") == 0 ? NULL : privacySymbol(name);
                                                     }];
  XCTAssertEqual(result.status, FBPrivacyStatusCompleted);
  XCTAssertEqual(privacyCalls.count, 1u);
  XCTAssertEqualObjects(privacyCalls[0][@"operation"], @"reset");
}

- (void)testMissingOperationSymbolFailsBeforeAnyMutation
{
  for (NSNumber *approved in @[@YES, @NO]) {
    NSString *missing = approved.boolValue
    ? @"TCCAccessSetForBundleIdWithOptions"
    : @"TCCAccessResetForBundleIdWithOptions";
    FBPrivacyOutcome *result = [FBPrivacyBinding updateBundleID:@"app"
                                                       services:@[@"kTCCServiceCamera"]
                                                       approved:approved.boolValue
                                                       resolver:^void *(const char *name) {
                                                         NSString *symbol = @(name);
                                                         return [missing isEqualToString:symbol] ? NULL : privacySymbol(name);
                                                       }];
    XCTAssertEqual(result.status, FBPrivacyStatusUnavailable);
    XCTAssertTrue([result.failureReason containsString:missing]);
    XCTAssertEqual(privacyCalls.count, 0u);
  }
}

- (void)testMissingNoKillFailsBeforeAnyMutation
{
  testNoKill = NULL;
  for (NSNumber *approved in @[@YES, @NO]) {
    FBPrivacyOutcome *result = [self update:approved.boolValue services:@[@"kTCCServicePhotos"]];
    XCTAssertEqual(result.status, FBPrivacyStatusUnavailable);
    XCTAssertTrue([result.failureReason containsString:@"kTCCSetNoKill"]);
    XCTAssertEqual(privacyCalls.count, 0u);
  }
}

- (void)testDaemonFailureStopsTheBatchAndIdentifiesTheService
{
  rejectPrivacyCall = 2;
  for (NSNumber *approved in @[@YES, @NO]) {
    [privacyCalls removeAllObjects];
    FBPrivacyOutcome *result = [self update:approved.boolValue services:@[@"kTCCServiceCamera", @"kTCCServicePhotos", @"kTCCServiceMicrophone"]];
    XCTAssertEqual(result.status, FBPrivacyStatusFailed);
    XCTAssertTrue([result.failureReason containsString:@"kTCCServicePhotos"]);
    XCTAssertTrue([result.failureReason containsString:@"app"]);
    XCTAssertEqual(privacyCalls.count, 2u);
  }
}

- (void)testPrivateExceptionsBecomeFailures
{
  raisePrivacyException = YES;
  FBPrivacyOutcome *result = [self update:YES services:@[@"kTCCServiceCamera"]];
  XCTAssertEqual(result.status, FBPrivacyStatusFailed);
  XCTAssertEqualObjects(result.failureReason, @"synthetic daemon exception");
}

@end

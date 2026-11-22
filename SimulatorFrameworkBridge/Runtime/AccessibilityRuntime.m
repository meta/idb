/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "AccessibilityRuntime.h"

#import <dlfcn.h>
#import <objc/runtime.h>

#import "Private/AXPAttributes.h"
#import "Private/AXPTranslationPrivate.h"
#import "Private/AXRuntimePrivate.h"
#import "Private/AccessibilityPrivate.h"
#import "Private/AccessibilityRuntime_Private.h"
#import "Private/AccessibilityUtilitiesPrivate.h"
#import "Private/RunningBoardServicesPrivate.h"
#import "Private/XCTAutomationSupportPrivate.h"

#pragma mark - AX errors

/**
 * An AX error code with its name, e.g. "AX error -25204 (kAXErrorCannotComplete)", or the bare code when it has none.
 *
 * The names are the simulator runtime's own, from `XCTStringFromAXError` in XCTAutomationSupport, and differ from macOS's
 * `AXError.h`: -25214 is kAXErrorCalledOnNonMainThread rather than kAXErrorNotEnoughPrecision, and -25215 and -25216 exist
 * only here.
 */
static NSString *FBAXErrorDescription(int32_t axError)
{
  static NSDictionary<NSNumber *, NSString *> *names;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    names = @{
      @0 : @"kAXErrorSuccess",
      @(-25200) : @"kAXErrorFailure",
      @(-25201) : @"kAXErrorIllegalArgument",
      @(-25202) : @"kAXErrorInvalidUIElement",
      @(-25203) : @"kAXErrorInvalidUIElementObserver",
      @(-25204) : @"kAXErrorCannotComplete",
      @(-25205) : @"kAXErrorAttributeUnsupported",
      @(-25206) : @"kAXErrorActionUnsupported",
      @(-25207) : @"kAXErrorNotificationUnsupported",
      @(-25208) : @"kAXErrorNotImplemented",
      @(-25209) : @"kAXErrorNotificationAlreadyRegistered",
      @(-25210) : @"kAXErrorNotificationNotRegistered",
      @(-25211) : @"kAXErrorAPIDisabled",
      @(-25212) : @"kAXErrorNoValue",
      @(-25213) : @"kAXErrorParameterizedAttributeUnsupported",
      @(-25214) : @"kAXErrorCalledOnNonMainThread",
      @(-25215) : @"kAXErrorServerNotFound",
      @(-25216) : @"kAXErrorIPCTimeout",
    };
  });
  NSString *name = names[@(axError)];
  if (!name) {
    return [NSString stringWithFormat:@"AX error %d", axError];
  }
  return [NSString stringWithFormat:@"AX error %d (%@)", axError, name];
}

#pragma mark - Outcomes

@interface FBAXHitTestOutcome ()
@property (nullable, nonatomic, readwrite) NSNumber *axError;
@end

@interface FBAXWriteOutcome ()
@property (nullable, nonatomic, readwrite) NSNumber *axError;
@end

@implementation FBAXDeviceSettingMonitorOutcome
- (instancetype)initWithStatus:(FBAXDeviceSettingStatus)status
                       monitor:(id<FBAXDeviceSettingMonitor>)monitor
                 failureReason:(NSString *)failureReason
{
  self = [super init];
  if (self) {
    _status = status;
    _monitor = monitor;
    _failureReason = [failureReason copy];
  }
  return self;
}

+ (instancetype)resolved:(id<FBAXDeviceSettingMonitor>)monitor
{
  return [[self alloc] initWithStatus:FBAXDeviceSettingStatusResolved monitor:monitor failureReason:nil];
}

+ (instancetype)unavailable:(NSString *)failureReason
{
  return [[self alloc] initWithStatus:FBAXDeviceSettingStatusUnavailable monitor:nil failureReason:failureReason];
}

+ (instancetype)failed:(NSString *)failureReason
{
  return [[self alloc] initWithStatus:FBAXDeviceSettingStatusFailed monitor:nil failureReason:failureReason];
}

@end

@interface FBAXDarwinSettingMonitor : NSObject <FBAXDeviceSettingMonitor>
@property (nonatomic, copy) void (^handler)(void);
@property (nonatomic, copy) NSArray<NSString *> *names;
- (instancetype)initWithNames:(NSArray<NSString *> *)names handler:(void (^)(void))handler;
@end

static void FBAXSettingChanged(__unused CFNotificationCenterRef center,
                               void *observer,
                               __unused CFStringRef name,
                               __unused const void *object,
                               __unused CFDictionaryRef userInfo)
{
  FBAXDarwinSettingMonitor *monitor = (__bridge FBAXDarwinSettingMonitor *)observer;
  if (monitor.handler) {
    monitor.handler();
  }
}

@implementation FBAXDarwinSettingMonitor
- (instancetype)initWithNames:(NSArray<NSString *> *)names handler:(void (^)(void))handler
{
  self = [super init];
  if (self) {
    _names = [names copy];
    _handler = [handler copy];
    for (NSString *name in _names) {
      CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge void *)self,
        FBAXSettingChanged,
        (__bridge CFStringRef)name,
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
      );
    }
  }
  return self;
}

- (void)invalidate
{
  CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge void *)self);
  self.handler = nil;
}

- (void)dealloc
{
  [self invalidate];
}

@end

@implementation FBAXReadOutcome

- (instancetype)initWithStatus:(FBAXReadStatus)status
                    attributes:(nullable NSDictionary<NSString *, id> *)attributes
                         error:(nullable NSError *)error
{
  self = [super init];
  if (!self) {
    return nil;
  }
  _status = status;
  _attributes = [attributes copy];
  _error = error;
  return self;
}

+ (instancetype)read:(NSDictionary<NSString *, id> *)attributes
{
  return [[self alloc] initWithStatus:FBAXReadStatusRead attributes:attributes error:nil];
}

+ (instancetype)applicationUnavailable
{
  return [[self alloc] initWithStatus:FBAXReadStatusApplicationUnavailable attributes:nil error:nil];
}

+ (instancetype)applicationNotResponding
{
  return [[self alloc] initWithStatus:FBAXReadStatusApplicationNotResponding attributes:nil error:nil];
}

+ (instancetype)failed:(nullable NSError *)error
{
  return [[self alloc] initWithStatus:FBAXReadStatusFailed attributes:nil error:error];
}

- (nullable NSNumber *)axError
{
  NSNumber *code = self.error.userInfo[FBAXAccessibilityErrorKey];
  return [code isKindOfClass:NSNumber.class] ? code : nil;
}

+ (instancetype)failureForAttributeError:(nullable NSError *)error
{
  NSNumber *code = error.userInfo[FBAXAccessibilityErrorKey];
  if (![code isKindOfClass:NSNumber.class]) {
    return [self failed:error];
  }
  switch (code.intValue) {
    case FBAXErrorServerNotFound:
      return [self applicationUnavailable];
    case FBAXErrorIPCTimeout:
      return [self applicationNotResponding];
    default:
      return [self failed:error];
  }
}

@end

@implementation FBAXHitTestOutcome

- (instancetype)initWithStatus:(FBAXHitTestStatus)status
                       element:(nullable id)element
       owningProcessIdentifier:(pid_t)pid
                 failureReason:(nullable NSString *)failureReason
{
  self = [super init];
  if (!self) {
    return nil;
  }
  _status = status;
  _element = element;
  _owningProcessIdentifier = pid;
  _failureReason = [failureReason copy];
  return self;
}

+ (instancetype)hit:(id)element owningProcessIdentifier:(pid_t)pid
{
  return [[self alloc] initWithStatus:FBAXHitTestStatusHit
                              element:element
              owningProcessIdentifier:pid
                        failureReason:nil];
}

+ (instancetype)empty
{
  return [[self alloc] initWithStatus:FBAXHitTestStatusEmpty
                              element:nil
              owningProcessIdentifier:0
                        failureReason:nil];
}

+ (instancetype)applicationUnavailable
{
  return [[self alloc] initWithStatus:FBAXHitTestStatusApplicationUnavailable
                              element:nil
              owningProcessIdentifier:0
                        failureReason:nil];
}

+ (instancetype)applicationNotResponding
{
  return [[self alloc] initWithStatus:FBAXHitTestStatusApplicationNotResponding
                              element:nil
              owningProcessIdentifier:0
                        failureReason:nil];
}

+ (instancetype)failed:(NSString *)failureReason
{
  return [[self alloc] initWithStatus:FBAXHitTestStatusFailed
                              element:nil
              owningProcessIdentifier:0
                        failureReason:failureReason];
}

+ (instancetype)failedWithAXError:(int32_t)axError
{
  FBAXHitTestOutcome *outcome = [self failed:[NSString stringWithFormat:@"the hit-test failed with %@", FBAXErrorDescription(axError)]];
  outcome.axError = @(axError);
  return outcome;
}

+ (nullable instancetype)outcomeForHitTestError:(int32_t)axError hasElement:(BOOL)hasElement
{
  if (axError == FBAXErrorServerNotFound) {
    return [self applicationUnavailable];
  }
  if (axError == FBAXErrorIPCTimeout) {
    return [self applicationNotResponding];
  }
  if (axError == FBAXErrorInvalidUIElement || (axError == FBAXErrorSuccess && !hasElement)) {
    return [self empty];
  }
  if (axError != FBAXErrorSuccess) {
    return [self failedWithAXError:axError];
  }
  return nil;
}

@end

@implementation FBAXWriteOutcome

- (instancetype)initWithStatus:(FBAXWriteStatus)status failureReason:(nullable NSString *)failureReason
{
  self = [super init];
  if (!self) {
    return nil;
  }
  _status = status;
  _failureReason = [failureReason copy];
  return self;
}

+ (instancetype)written
{
  return [[self alloc] initWithStatus:FBAXWriteStatusWritten failureReason:nil];
}

+ (instancetype)empty
{
  return [[self alloc] initWithStatus:FBAXWriteStatusEmpty failureReason:nil];
}

+ (instancetype)assertionFailed:(NSString *)failureReason
{
  return [[self alloc] initWithStatus:FBAXWriteStatusAssertionFailed failureReason:failureReason];
}

+ (instancetype)applicationUnavailable
{
  return [[self alloc] initWithStatus:FBAXWriteStatusApplicationUnavailable failureReason:nil];
}

+ (instancetype)applicationNotResponding
{
  return [[self alloc] initWithStatus:FBAXWriteStatusApplicationNotResponding failureReason:nil];
}

+ (instancetype)failed:(NSString *)failureReason
{
  return [[self alloc] initWithStatus:FBAXWriteStatusFailed failureReason:failureReason];
}

+ (instancetype)failed:(NSString *)failureReason axError:(nullable NSNumber *)axError
{
  FBAXWriteOutcome *outcome = [self failed:failureReason];
  outcome.axError = axError;
  return outcome;
}

+ (instancetype)failedWithAXError:(int32_t)axError
{
  return [self failed:[NSString stringWithFormat:@"the accessibility runtime rejected the write with %@", FBAXErrorDescription(axError)] axError:@(axError)];
}

+ (instancetype)outcomeForWriteError:(int32_t)axError
{
  if (axError == FBAXErrorSuccess) {
    return [self written];
  }
  if (axError == FBAXErrorServerNotFound) {
    return [self applicationUnavailable];
  }
  if (axError == FBAXErrorIPCTimeout) {
    return [self applicationNotResponding];
  }
  return [self failedWithAXError:axError];
}

+ (instancetype)outcomeForPressError:(int32_t)axError fallback:(FBAXWriteOutcome *(^)(void))fallback
{
  if (axError == FBAXErrorFailure) {
    return fallback();
  }
  return [self outcomeForWriteError:axError];
}

@end

@implementation FBAXDisplayIdentity

- (instancetype)initWithUniqueID:(NSString *)uniqueID displayID:(uint32_t)displayID
{
  self = [super init];
  if (self) {
    _uniqueID = [uniqueID copy];
    _displayID = displayID;
  }
  return self;
}

@end

@implementation FBAXDisplayInventoryOutcome

- (instancetype)initWithStatus:(FBAXDisplayInventoryStatus)status
                      displays:(NSArray<FBAXDisplayIdentity *> *)displays
                 failureReason:(nullable NSString *)failureReason
{
  self = [super init];
  if (self) {
    _status = status;
    _displays = [displays copy];
    _failureReason = [failureReason copy];
  }
  return self;
}

+ (instancetype)available:(NSArray<FBAXDisplayIdentity *> *)displays
{
  return [[self alloc] initWithStatus:FBAXDisplayInventoryStatusAvailable displays:displays failureReason:nil];
}

+ (instancetype)unavailable:(NSString *)failureReason
{
  return [[self alloc] initWithStatus:FBAXDisplayInventoryStatusUnavailable displays:@[] failureReason:failureReason];
}

+ (instancetype)failed:(NSString *)failureReason
{
  return [[self alloc] initWithStatus:FBAXDisplayInventoryStatusFailed displays:@[] failureReason:failureReason];
}

@end

@implementation FBAXDeviceSettingOutcome

- (instancetype)initWithStatus:(FBAXDeviceSettingStatus)status
                       enabled:(BOOL)enabled
                 failureReason:(nullable NSString *)failureReason
{
  self = [super init];
  if (!self) {
    return nil;
  }
  _status = status;
  _enabled = enabled;
  _failureReason = [failureReason copy];
  return self;
}

+ (instancetype)resolved:(BOOL)enabled
{
  return [[self alloc] initWithStatus:FBAXDeviceSettingStatusResolved enabled:enabled failureReason:nil];
}

+ (instancetype)unavailable:(NSString *)failureReason
{
  return [[self alloc] initWithStatus:FBAXDeviceSettingStatusUnavailable enabled:NO failureReason:failureReason];
}

+ (instancetype)failed:(NSString *)failureReason
{
  return [[self alloc] initWithStatus:FBAXDeviceSettingStatusFailed enabled:NO failureReason:failureReason];
}

@end

@implementation FBAXFrontmostOutcome

- (instancetype)initWithStatus:(FBAXFrontmostStatus)status
             processIdentifier:(pid_t)pid
                 failureReason:(nullable NSString *)failureReason
{
  self = [super init];
  if (!self) {
    return nil;
  }
  _status = status;
  _processIdentifier = pid;
  _failureReason = [failureReason copy];
  return self;
}

+ (instancetype)resolved:(pid_t)pid
{
  return [[self alloc] initWithStatus:FBAXFrontmostStatusResolved processIdentifier:pid failureReason:nil];
}

+ (instancetype)applicationUnavailable:(NSString *)failureReason
{
  return [[self alloc] initWithStatus:FBAXFrontmostStatusApplicationUnavailable
                    processIdentifier:0
                        failureReason:failureReason];
}

+ (instancetype)applicationNotResponding:(NSString *)failureReason
{
  return [[self alloc] initWithStatus:FBAXFrontmostStatusApplicationNotResponding
                    processIdentifier:0
                        failureReason:failureReason];
}

+ (instancetype)unresolved:(NSString *)failureReason
{
  return [[self alloc] initWithStatus:FBAXFrontmostStatusUnresolved
                    processIdentifier:0
                        failureReason:failureReason];
}

@end

#pragma mark - Bound signatures

// Contract and rationale are on the declaration in AccessibilityRuntime.h.
const float FBAXMessagingTimeoutSeconds = 5.0f;

NSString *FBAXTypesOnly(const char *encoding)
{
  NSMutableString *types = [NSMutableString string];
  NSInteger depth = 0;
  for (const char *character = encoding; *character; character++) {
    switch (*character) {
      case '{':
      case '(':
      case '[':
        depth++;
        break;
      case '}':
      case ')':
      case ']':
        depth--;
        break;
      default:
        break;
    }
    if (depth == 0 && *character >= '0' && *character <= '9') {
      continue;
    }
    [types appendFormat:@"%c", *character];
  }
  return types;
}

NSString *_Nullable FBAXSignatureMismatch(const char *className,
                                          const char *selectorName,
                                          BOOL isClassMethod,
                                          const char *expected)
{
  NSString *name = [NSString stringWithFormat:@"%c[%s %s]", isClassMethod ? '+' : '-', className, selectorName];
  Class cls = objc_lookUpClass(className);
  if (!cls) {
    return [NSString stringWithFormat:@"%@ cannot be checked: %s is not in the runtime", name, className];
  }
  SEL selector = sel_registerName(selectorName);
  Method method = isClassMethod ? class_getClassMethod(cls, selector) : class_getInstanceMethod(cls, selector);
  if (!method) {
    return [NSString stringWithFormat:@"%@ is not in the runtime", name];
  }
  const char *encoding = method_getTypeEncoding(method);
  if (!encoding) {
    return [NSString stringWithFormat:@"%@ has no type encoding", name];
  }
  NSString *actual = FBAXTypesOnly(encoding);
  NSString *assumed = FBAXTypesOnly(expected);
  if ([actual isEqualToString:assumed]) {
    return nil;
  }
  return [NSString stringWithFormat:@"%@ is %@ but %@ was assumed", name, actual, assumed];
}

// Every private selector this file sends, with the encoding `method_getTypeEncoding` reports for it on a
// real runtime (taken from the runtime, never hand-written).
//
// `-[AXPTranslator setSupportsDelegateTokens:]` is absent on purpose: its `BOOL` encodes as `B` on
// arm64 and `c` on x86_64, so there is no one encoding to compare against.
typedef struct {
  const char *className;
  const char *selectorName;
  BOOL isClassMethod;
  const char *expected;
} FBAXBoundSelector;

static const FBAXBoundSelector kFBAXDisplaySelectors[] = {
  {"XCTAutomationSupport.XCTDisplayManager", "allDisplayIDs", YES, "@16@0:8"},
  {"XCTAutomationSupport.XCTDisplayManager", "uniqueIDForDisplayWithID:", YES, "@20@0:8I16"},
};

static const FBAXBoundSelector kFBAXBoundSelectors[] = {
  // AXRuntime
  {"AXElement", "elementWithAXUIElement:", YES, "@@:^{__AXUIElement=}"},
  {"AXElement", "press", NO, "B@:"},
  // XCTAutomationSupport
  {"XCTAccessibilityFramework", "initForRemoteAccess", NO, "@@:"},
  {"XCTAccessibilityFramework", "attributesForElement:attributes:error:", NO, "@@:@@^@"},
  {"XCAccessibilityElement", "elementWithProcessIdentifier:", YES, "@@:i"},
  {"XCAccessibilityElement", "elementWithAXUIElement:", YES, "@@:^{__AXUIElement=}"},
  {"XCAccessibilityElement", "AXUIElement", NO, "^{__AXUIElement=}@:"},
  // AccessibilityUtilities
  {"AXSettings", "sharedInstance", YES, "@@:"},
  {"AXSettings", "reduceMotionEnabled", NO, "B@:"},
  {"AXSettings", "setReduceMotionEnabled:", NO, "v@:B"},
  {"AXSettings", "buttonShapesEnabled", NO, "B@:"},
  {"AXSettings", "setButtonShapesEnabled:", NO, "v@:B"},
  {"AXSettings", "enhanceBackgroundContrastEnabled", NO, "B@:"},
  {"AXSettings", "setEnhanceBackgroundContrastEnabled:", NO, "v@:B"},
  // AccessibilityPlatformTranslation
  {"AXPTranslator", "sharediOSInstance", YES, "@@:"},
  {"AXPTranslator", "frontmostApplicationWithDisplayId:bridgeDelegateToken:", NO, "@@:I@"},
  {"AXPTranslator", "objectAtPoint:displayId:bridgeDelegateToken:", NO, "@@:{CGPoint=dd}I@"},
  {"AXPTranslator_iOS", "createPlatformElementFromTranslationObject:", NO, "^{__AXUIElement=}@:@"},
  {"AXPTranslator", "processTranslatorRequest:", NO, "@@:@"},
  {"AXPTranslator", "setBridgeTokenDelegate:", NO, "v@:@"},
  // Declared by the concrete iOS subclass `sharediOSInstance` vends, not by `AXPTranslator` itself.
  {"AXPTranslator_iOS", "translationObjectFromPlatformElement:", NO, "@@:^{__AXUIElement=}"},
  {"AXPTranslationObject", "pid", NO, "i@:"},
  {"AXPTranslatorRequest", "requestWithTranslation:", YES, "@@:@"},
  {"AXPTranslatorRequest", "setRequestType:", NO, "v@:Q"},
  {"AXPTranslatorRequest", "setAttributeType:", NO, "v@:Q"},
  {"AXPTranslatorRequest", "setClientType:", NO, "v@:Q"},
  {"AXPTranslatorRequest", "setParameters:", NO, "v@:@"},
  {"AXPTranslatorResponse", "resultData", NO, "@@:"},
  // RunningBoardServices
  {"RBSProcessPredicate", "predicateMatchingLaunchServicesProcesses", YES, "@@:"},
  {"RBSProcessState", "statesForPredicate:withDescriptor:error:", YES, "@@:@@o^@"},
  {"RBSProcessState", "endowmentNamespaces", NO, "@@:"},
  {"RBSProcessState", "process", NO, "@@:"},
  {"RBSProcessStateDescriptor", "descriptor", YES, "@@:"},
  {"RBSProcessStateDescriptor", "setValues:", NO, "v@:Q"},
  {"RBSProcessStateDescriptor", "setEndowmentNamespaces:", NO, "v@:@"},
  {"RBSProcessHandle", "pid", NO, "i@:"},
};

NSArray<NSString *> *FBAXSignatureWarnings(void)
{
  // Opened here rather than relied on being open, so the sweep sees every bound selector however it was
  // reached. dlopen on an already-open image is a refcount bump.
  dlopen(FBAXPathAXRuntime, RTLD_NOW);
  dlopen(FBAXPathXCTAutomationSupport, RTLD_NOW);
  dlopen(FBAXPathAccessibilityUtilities, RTLD_NOW);
  dlopen(FBAXPathAXPTranslation, RTLD_NOW);
  dlopen(FBAXPathRunningBoardServices, RTLD_NOW);

  NSMutableArray<NSString *> *warnings = [NSMutableArray array];
  for (size_t index = 0; index < sizeof(kFBAXBoundSelectors) / sizeof(*kFBAXBoundSelectors); index++) {
    const FBAXBoundSelector bound = kFBAXBoundSelectors[index];
    NSString *mismatch = FBAXSignatureMismatch(bound.className, bound.selectorName, bound.isClassMethod, bound.expected);
    if (mismatch) {
      [warnings addObject:mismatch];
    }
  }
  for (size_t index = 0; index < sizeof(kFBAXDisplaySelectors) / sizeof(*kFBAXDisplaySelectors); index++) {
    const FBAXBoundSelector bound = kFBAXDisplaySelectors[index];
    if (!objc_lookUpClass(bound.className)) {
      continue;
    }
    NSString *mismatch = FBAXSignatureMismatch(bound.className, bound.selectorName, bound.isClassMethod, bound.expected);
    if (mismatch) {
      [warnings addObject:mismatch];
    }
  }
  return warnings;
}

// Appends the signature sweep to a bind failure, so the message also names what else about the runtime
// moved. Swept only here: a process that bound cleanly has nothing to report.
static NSString *FBAXSetupFailure(NSString *reason)
{
  NSArray<NSString *> *warnings = FBAXSignatureWarnings();
  if (warnings.count == 0) {
    return reason;
  }
  return [NSString stringWithFormat:@"%@ (also: %@)", reason, [warnings componentsJoinedByString:@"; "]];
}

#pragma mark - The AXRuntime C entry points

// The AXRuntime entry points, resolved once, with the ownership each one transfers restated where the
// table is declared. `AXRuntimePrivate.h` carries the full contract; this is the reminder at the only
// place a raw AXUIElementRef is ever held.
typedef struct {
  void *(*createSystemWide)(void);                                            // returns +1
  int32_t (*copyElementAtPosition)(void *app, float x, float y, void **out);  // out-parameter is +1
  int32_t (*getPid)(void *element, pid_t *pid);                               // borrows
  int32_t (*performAction)(void *element, uint32_t action);                   // borrows
  int32_t (*setAttributeValue)(void *element, uint32_t attribute, const void *value);  // borrows both
  FBAXSetMessagingTimeoutFn setMessagingTimeout;
  // Device-wide accessibility automation mode. Optional: a runtime without it is not a setup failure,
  // because every read this bundle performs works either way — the flag changes how much structure the
  // target exposes, not whether it answers.
  bool (*automationEnabled)(void);
  // Device-wide AccessibilityUtilities settings. Optional: each setting reports unsupported when its
  // getter or setter is absent rather than breaking unrelated accessibility reads.
  FBAXAccessibilitySettingGetFn voiceOverEnabled;
  FBAXAccessibilitySettingSetFn voiceOverSetEnabled;
  // The single-fetch read's entry points. Optional as a group, for the same reason the snapshot selector
  // is resolved lazily: a runtime without them loses that one path and keeps every other.
  FBAXValueGetTypeFn valueGetType;                                  // borrows
  FBAXValueGetValueFn valueGetValue;                                // borrows
  FBAXDefaultSnapshotParametersFn defaultSnapshotParameters;
  FBAXAttributeNumbersForNamesFn attributeNumbersForNames;
  FBAXElementTypeFromAutomationTypeFn elementTypeFromAutomationType;
  // Proves a snapshot element is an AXUIElementRef before it reaches the C entry points, which do not
  // check. Optional: without it boundary continuation stays off.
  CFTypeID (*elementTypeID)(void);
  // The quiescence monitor's entry points. Optional as a group: a runtime without them cannot monitor,
  // and every other interaction is unaffected.
  FBAXPerformActionWithValueFn performActionWithValue;               // borrows
  FBAXObserverCreateFn observerCreate;                               // out-parameter is +1
  FBAXObserverAddNotificationFn observerAddNotification;             // borrows
  FBAXObserverGetRunLoopSourceFn observerGetRunLoopSource;           // returns borrowed
} FBAXRuntimeFunctions;

// The one place an `FBAXAction` becomes the number the C ABI takes. `-Wswitch-default` forces the
// `default`, which costs the exhaustiveness warning, so an action added without a mapping is caught here
// at run time: answer NO rather than send a number — the C ABI treats zero as a real action, not "none".
static BOOL FBAXActionIdentifierForAction(FBAXAction action, uint32_t *identifier)
{
  switch (action) {
    case FBAXActionPress:
      *identifier = FBAXActionIdentifierPress;
      return YES;
    case FBAXActionScrollUp:
      *identifier = FBAXActionIdentifierScrollUpByPage;
      return YES;
    case FBAXActionScrollDown:
      *identifier = FBAXActionIdentifierScrollDownByPage;
      return YES;
    case FBAXActionScrollLeft:
      *identifier = FBAXActionIdentifierScrollLeftByPage;
      return YES;
    case FBAXActionScrollRight:
      *identifier = FBAXActionIdentifierScrollRightByPage;
      return YES;
    case FBAXActionScrollToVisible:
      *identifier = FBAXActionIdentifierScrollToVisible;
      return YES;
    default:
      return NO;
  }
}

#pragma mark - Owned AXUIElement references

// The one owner of a raw AXUIElementRef in the product. Wrapping a +1 reference at acquisition makes the
// release ARC's job, so it happens exactly once on every early-return path.
@interface FBAXElementRef : NSObject

/** Takes ownership of an already-retained (+1) reference — what the AX runtime's Create and Copy give. */
- (instancetype)initWithOwnedElement:(const void *)element NS_DESIGNATED_INITIALIZER;

/**
 * Takes a reference of its own on a borrowed one. `-[XCAccessibilityElement AXUIElement]` returns a
 * reference that dies with the element that vended it; retaining lets a hit-test seed outlive it.
 */
+ (instancetype)retainingBorrowedElement:(void *)element;

+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)init NS_UNAVAILABLE;

/**
 * Runs `body` with the raw reference, keeping the wrapper alive for the whole call. A `void *` is
 * invisible to ARC, which could otherwise release the wrapper mid-call. `NS_NOESCAPE`: the reference is
 * guaranteed only for the call.
 */
- (int32_t)axErrorFromElement:(NS_NOESCAPE int32_t (^)(void *element))body;

/** As above, for the one caller that wants an object back rather than an AX error code. */
- (nullable id)objectFromElement:(NS_NOESCAPE id _Nullable (^)(void *element))body;

@end

@implementation FBAXElementRef
{
  void *_element;
}

- (instancetype)initWithOwnedElement:(const void *)element
{
  NSParameterAssert(element);
  self = [super init];
  if (!self) {
    return nil;
  }
  _element = (void *)element;
  return self;
}

+ (instancetype)retainingBorrowedElement:(void *)element
{
  return [[self alloc] initWithOwnedElement:(void *)CFRetain(element)];
}

- (void)dealloc
{
  CFRelease(_element);
}

- (int32_t)axErrorFromElement:(NS_NOESCAPE int32_t (^)(void *element))body
{
  // The local is what keeps the wrapper alive across the call: reading the ivar through a reference ARC
  // can see, rather than handing the pointer to someone it cannot.
  NS_VALID_UNTIL_END_OF_SCOPE FBAXElementRef *alive = self;
  return body(alive->_element);
}

- (nullable id)objectFromElement:(NS_NOESCAPE id _Nullable (^)(void *element))body
{
  NS_VALID_UNTIL_END_OF_SCOPE FBAXElementRef *alive = self;
  return body(alive->_element);
}

@end

// A retained reference on the AXUIElementRef behind a handle, for the duration of a call that needs the
// raw pointer (see `+retainingBorrowedElement:`).
static FBAXElementRef *_Nullable FBAXReferenceForElement(id element)
{
  // Handles are opaque above the seam, so a non-handle is a named failure rather than an unrecognised selector.
  if (![element respondsToSelector:@selector(AXUIElement)]) {
    return nil;
  }
  void *raw = [(XCAccessibilityElement *)element AXUIElement];
  if (!raw) {
    return nil;
  }
  return [FBAXElementRef retainingBorrowedElement:raw];
}

#pragma mark - Quiescence

BOOL FBAXQuiescenceReportForNotification(uint32_t notification, id _Nullable info, FBAXQuiescenceReport *report)
{
  switch (notification) {
    case FBAXNotificationApplicationSuspendedStatusChanged:
      *report = FBAXQuiescenceReportApplicationStateChanged;
      return YES;
    case FBAXNotificationUserTesting: {
      id event = [info isKindOfClass:NSDictionary.class] ? ((NSDictionary *)info)[@"event"] : nil;
      if ([event isEqual:@"RunLoopIsIdle"]) {
        *report = FBAXQuiescenceReportRunLoopIdle;
        return YES;
      }
      if ([event isEqual:@"AnimationsNonActive"]) {
        *report = FBAXQuiescenceReportAnimationsInactive;
        return YES;
      }
      if ([event isEqual:@"TouchEventsCompleted"]) {
        *report = FBAXQuiescenceReportTouchesCompleted;
        return YES;
      }
      return NO;
    }
    default:
      return NO;
  }
}

@interface FBAXLiveQuiescenceMonitor : NSObject <FBAXQuiescenceMonitor>
@end

@implementation FBAXLiveQuiescenceMonitor
{
  FBAXRuntimeFunctions _functions;
  FBAXQuiescenceHandler _handler;
  // The observer, owned. Its run-loop source is borrowed from it, so the observer outlives the source's
  // removal from `_runLoop`.
  id _observer;
  CFRunLoopSourceRef _source;
  CFRunLoopRef _runLoop;
  // Held for as long as the registrations made on it, which the runtime does not promise to retain.
  FBAXElementRef *_systemWide;
}

// The observer's callback. `refcon` is the monitor, unretained: the source is removed from the run loop
// before the monitor goes, and delivery happens only on that run loop, so the callback cannot outlive it.
static void FBAXQuiescenceObserverCallback(__unused void *observer, void *element, uint32_t notification, const void *info, void *refcon)
{
  FBAXLiveQuiescenceMonitor *monitor = (__bridge FBAXLiveQuiescenceMonitor *)refcon;
  [monitor deliverNotification:notification element:element info:(__bridge id)info];
}

- (nullable instancetype)initWithFunctions:(FBAXRuntimeFunctions)functions
                                   handler:(FBAXQuiescenceHandler)handler
                                     error:(NSString *_Nullable *_Nullable)error
{
  self = [super init];
  if (!self) {
    return nil;
  }
  _functions = functions;
  _handler = [handler copy];

  void *systemWide = _functions.createSystemWide();
  if (!systemWide) {
    if (error) {
      *error = @"AXUIElementCreateSystemWide returned NULL";
    }
    return nil;
  }
  _systemWide = [[FBAXElementRef alloc] initWithOwnedElement:systemWide];

  void *observer = NULL;
  int32_t createError = _functions.observerCreate(0, FBAXQuiescenceObserverCallback, &observer);
  if (createError != FBAXErrorSuccess || !observer) {
    if (error) {
      *error = [NSString stringWithFormat:@"AXObserverCreate failed with %@", FBAXErrorDescription(createError)];
    }
    return nil;
  }
  _observer = CFBridgingRelease(observer);

  for (NSNumber *notification in @[@(FBAXNotificationUserTesting), @(FBAXNotificationApplicationSuspendedStatusChanged)]) {
    int32_t addError = [_systemWide axErrorFromElement:^int32_t (void *element) {
      return self->_functions.observerAddNotification((__bridge void *)self->_observer, element, notification.unsignedIntValue, (__bridge void *)self);
    }];
    if (addError != FBAXErrorSuccess) {
      if (error) {
        *error = [NSString stringWithFormat:@"AXObserverAddNotification(%@) failed with %@", notification, FBAXErrorDescription(addError)];
      }
      return nil;
    }
  }

  _source = _functions.observerGetRunLoopSource((__bridge void *)_observer);
  if (!_source) {
    if (error) {
      *error = @"AXObserverGetRunLoopSource returned NULL";
    }
    return nil;
  }
  _runLoop = (CFRunLoopRef)CFRetain(CFRunLoopGetCurrent());
  CFRunLoopAddSource(_runLoop, _source, kCFRunLoopDefaultMode);
  return self;
}

- (void)dealloc
{
  [self invalidate];
}

- (void)deliverNotification:(uint32_t)notification element:(void *)element info:(nullable id)info
{
  // A strong local, so a handler that invalidates this client does not release itself mid-call.
  FBAXQuiescenceHandler handler = _handler;
  FBAXQuiescenceReport report;
  if (!handler || !FBAXQuiescenceReportForNotification(notification, info, &report)) {
    return;
  }
  pid_t pid = 0;
  if (report == FBAXQuiescenceReportApplicationStateChanged) {
    id named = [info isKindOfClass:NSDictionary.class] ? ((NSDictionary *)info)[@"pid"] : nil;
    pid = [named isKindOfClass:NSNumber.class] ? [named intValue] : 0;
  } else if (!element || _functions.getPid(element, &pid) != FBAXErrorSuccess) {
    pid = 0;
  }
  handler(report, pid);
}

- (FBAXWriteOutcome *)requestSignal:(FBAXQuiescenceSignal)signal fromApplication:(id)element
{
  if (!_observer) {
    return [FBAXWriteOutcome failed:@"the quiescence monitor has been invalidated"];
  }
  uint32_t action = 0;
  switch (signal) {
    case FBAXQuiescenceSignalRunLoopIdle:
      action = FBAXActionIdentifierBeginMonitoringIdleRunLoop;
      break;
    case FBAXQuiescenceSignalAnimationsInactive:
      action = FBAXActionIdentifierDetectAnimationsNonActive;
      break;
    default:
      return [FBAXWriteOutcome failed:[NSString stringWithFormat:@"no AX runtime identifier for quiescence signal %lu", (unsigned long)signal]];
  }
  FBAXElementRef *reference = FBAXReferenceForElement(element);
  if (!reference) {
    return [FBAXWriteOutcome failed:@"the element has no AXUIElement to monitor"];
  }
  int32_t axError = [reference axErrorFromElement:^int32_t (void *raw) {
    return self->_functions.performActionWithValue(raw, action, NULL);
  }];
  return [FBAXWriteOutcome outcomeForWriteError:axError];
}

- (void)invalidate
{
  _handler = nil;
  if (_runLoop && _source) {
    CFRunLoopRemoveSource(_runLoop, _source, kCFRunLoopDefaultMode);
  }
  if (_runLoop) {
    CFRelease(_runLoop);
  }
  _runLoop = NULL;
  _source = NULL;
  _observer = nil;
}

@end

#pragma mark - The in-guest window-server bridge delegate

// The bridge/token delegate for the in-guest AXPTranslator window-server frontmost. The host normally
// provides this delegate and services each per-element request over CoreSimulator; in-guest we close the
// loop locally: the callback routes every request the translator emits back into the translator's own
// `processTranslatorRequest:`, which resolves it against the guest AX server. This makes the iOS
// translator resolve the true window-server frontmost with no host round-trip. Requests are serviced
// serially by the guest, so the depth guard only bounds re-entrant sub-reads.
static NSInteger gAXPSelfServiceDepth = 0;
// The client the requests a translator emits during one interaction claim: set around an interaction that
// names a client and cleared after it, even if it raises, on the queue that runs it. Nil leaves those
// requests exactly as the translator built them.
static NSNumber *_Nullable gAXPSelfServiceClientType = nil;

// Runs `interaction` with the translator's own requests claiming `clientType`; zero claims none, so the
// requests pass through untouched.
static void FBAXBridgeWithSelfServiceClientType(NSUInteger clientType, void (^interaction)(void))
{
  gAXPSelfServiceClientType = clientType == 0 ? nil : @(clientType);
  @try {
    interaction();
  } @finally {
    gAXPSelfServiceClientType = nil;
  }
}

@interface FBAXWindowServerDelegate : NSObject <AXPTranslationTokenDelegateHelper>
@property (nonatomic, weak) AXPTranslator *translator;
@end
@implementation FBAXWindowServerDelegate
- (nullable AXPTranslationBridgeCallback)selfServiceCallback
{
  // Captured strongly by the block: the property is weak so the translator can go, but a callback the
  // translator is in the middle of calling must not have it vanish underneath.
  AXPTranslator *translator = self.translator;
  return ^id _Nullable (id request) {
    if (gAXPSelfServiceDepth > 500) {
      return nil;
    }
    gAXPSelfServiceDepth++;
    id result = nil;
    // Declaring the selector says what its signature is if the runtime has it, not that the runtime has
    // it — so the guard stays.
    NSNumber *clientType = gAXPSelfServiceClientType;
    if (clientType && [request respondsToSelector:@selector(setClientType:)]) {
      [(AXPTranslatorRequest *)request setClientType:clientType.unsignedIntegerValue];
    }
    if ([translator respondsToSelector:@selector(processTranslatorRequest:)]) {
      @try {
        result = [translator processTranslatorRequest:request];
      } @catch (NSException *exception) {
        result = nil;
      }
    }
    gAXPSelfServiceDepth--;
    return result;
  };
}

- (nullable AXPTranslationBridgeCallback)accessibilityTranslationDelegateBridgeCallbackWithToken:(NSString *)token { return [self selfServiceCallback]; }

- (nullable AXPTranslationBridgeCallback)accessibilityTranslationDelegateBridgeCallback { return [self selfServiceCallback]; }

- (CGRect)accessibilityTranslationConvertPlatformFrameToSystem:(CGRect)rect withToken:(NSString *)token { return rect; }

- (CGRect)accessibilityTranslationConvertPlatformFrameToSystem:(CGRect)rect { return rect; }

- (nullable id)accessibilityTranslationRootParentWithToken:(NSString *)token { return nil; }

- (nullable id)accessibilityTranslationRootParent { return nil; }

@end

// The AXPTranslator (iOS instance) wired for in-guest window-server frontmost, set up once and reused
// (installing the self-service delegate is the one-time cost). The delegate is retained here so it
// outlives the translator's weak/assign reference. Returns nil (with `*error` set) if AXPTranslator is
// unavailable.
static AXPTranslator *_Nullable FBAXBridgeWindowServerTranslator(NSString *_Nullable *_Nullable error)
{
  static AXPTranslator *translator;
  static FBAXWindowServerDelegate *delegate;
  static NSString *cachedError;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    dlopen(FBAXPathAXPTranslation, RTLD_NOW);
    // The class is still looked up by name — nothing in AXPTranslationPrivate.h is linked against, so
    // naming `AXPTranslator` as a receiver directly would be an undefined symbol. The `Class<...>` cast is
    // what lets the compiler check the class-method send against that class's own declaration.
    Class<AXPTranslatorClass> translatorClass = (Class<AXPTranslatorClass>)objc_lookUpClass("AXPTranslator");
    if (!translatorClass || ![translatorClass respondsToSelector:@selector(sharediOSInstance)]) {
      cachedError = @"AXPTranslator unavailable — is AccessibilityPlatformTranslation loaded?";
      return;
    }
    AXPTranslator *instance = [translatorClass sharediOSInstance];
    if (!instance) {
      cachedError = @"AXPTranslator sharediOSInstance was nil";
      return;
    }
    FBAXWindowServerDelegate *serviceDelegate = [FBAXWindowServerDelegate new];
    serviceDelegate.translator = instance;
    // Still guarded: a runtime without these setters raises rather than returning, and the reader would
    // rather report that than trap.
    @try {
      instance.bridgeTokenDelegate = serviceDelegate;
      instance.supportsDelegateTokens = YES;
    } @catch (NSException *exception) {
      cachedError = exception.reason ?: @"failed to wire the AXPTranslator bridge delegate";
      return;
    }
    translator = instance;
    delegate = serviceDelegate;
  });
  (void)delegate;  // retained only to outlive the translator's weak reference to its bridge delegate
  if (!translator && error) {
    *error = cachedError ?: @"AXPTranslator setup failed";
  }
  return translator;
}

// Runs `block` somewhere other than the main queue and waits for it to finish.
//
// AXPTranslator lazily enables its bridge runtime on first use, and that path asserts it is *not* running
// on the main queue (`-[AXPTranslator_iOS _enableAccessibilityBridgeRuntime]` calls
// `dispatch_assert_queue_not`). The in-guest self-service delegate re-enters the translator on whichever
// thread called in, so driving it from the reader's main thread trips the assert and traps the process.
void FBAXBridgeRunOffMainQueue(dispatch_block_t block)
{
  if (!NSThread.isMainThread) {
    block();
    return;
  }
  dispatch_semaphore_t completed = dispatch_semaphore_create(0);
  __block NSException *raised = nil;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    @try {
      block();
    } @catch (NSException *exception) {
      raised = exception;
    } @finally {
      dispatch_semaphore_signal(completed);
    }
  });
  dispatch_semaphore_wait(completed, DISPATCH_TIME_FOREVER);
  if (raised) {
    @throw raised;
  }
}

// The window-server frontmost query itself, which must already be off the main queue — see
// `FBAXBridgeRunOffMainQueue`. Asks the wired iOS translator for `frontmostApplicationWithDisplayId:0`
// and reads the owning pid of the returned application object.
static FBAXFrontmostOutcome *FBAXBridgeWindowServerFrontmostOffMain(uint32_t displayID)
{
  NSString *setupError = nil;
  AXPTranslator *translator = FBAXBridgeWindowServerTranslator(&setupError);
  if (!translator) {
    return [FBAXFrontmostOutcome unresolved:setupError ?: @"AXPTranslator unavailable"];
  }
  if (![translator respondsToSelector:@selector(frontmostApplicationWithDisplayId:bridgeDelegateToken:)]) {
    return [FBAXFrontmostOutcome unresolved:@"AXPTranslator does not respond to frontmostApplicationWithDisplayId:"];
  }
  AXPTranslationObject *application = [translator frontmostApplicationWithDisplayId:displayID bridgeDelegateToken:@"axbridge"];
  if (!application || ![application respondsToSelector:@selector(pid)]) {
    return [FBAXFrontmostOutcome unresolved:@"window-server frontmost returned no application object"];
  }
  pid_t pid = application.pid;
  if (pid <= 0) {
    return [FBAXFrontmostOutcome unresolved:[NSString stringWithFormat:@"window-server frontmost returned no pid (%d)", pid]];
  }
  return [FBAXFrontmostOutcome resolved:pid];
}

// The endowment namespace RunningBoard grants a process whose scene is on-screen. The foreground app is
// the launch-services process that holds it.
static NSString *const kFrontboardVisibilityEndowment = @"com.apple.frontboard.visibility";

#pragma mark - The live runtime

@implementation FBAXLiveRuntime
{
  XCTAccessibilityFramework *_framework;
  Class<XCAccessibilityElementClass> _elementClass;
  FBAXRuntimeFunctions _functions;
}

- (nullable instancetype)initWithError:(NSString *_Nullable *_Nullable)error
{
  self = [super init];
  if (!self) {
    return nil;
  }

  // Only the two the tree-reader bind requires. AccessibilityUtilities is optional and is opened for
  // device settings below without becoming a prerequisite for ordinary accessibility reads.
  dlopen(FBAXPathAXRuntime, RTLD_NOW);
  dlopen(FBAXPathXCTAutomationSupport, RTLD_NOW);
  dlopen(FBAXPathAccessibilityUtilities, RTLD_NOW);

  Class frameworkClass = objc_lookUpClass("XCTAccessibilityFramework");
  if (!frameworkClass) {
    if (error) {
      *error = FBAXSetupFailure(@"XCTAccessibilityFramework unavailable — is XCTAutomationSupport loaded?");
    }
    return nil;
  }
  _framework = [(XCTAccessibilityFramework *)[frameworkClass alloc] initForRemoteAccess];
  if (!_framework) {
    if (error) {
      *error = FBAXSetupFailure(@"initForRemoteAccess returned nil");
    }
    return nil;
  }

  _elementClass = (Class<XCAccessibilityElementClass>)objc_lookUpClass("XCAccessibilityElement");
  if (!_elementClass) {
    if (error) {
      *error = FBAXSetupFailure(@"XCAccessibilityElement unavailable");
    }
    return nil;
  }

  // Resolved here rather than per request, so a runtime missing an entry point is a setup failure naming
  // it rather than a request that gets partway and cannot finish.
  _functions.createSystemWide = dlsym(RTLD_DEFAULT, "AXUIElementCreateSystemWide");
  _functions.copyElementAtPosition = dlsym(RTLD_DEFAULT, "AXUIElementCopyElementAtPosition");
  _functions.getPid = dlsym(RTLD_DEFAULT, "AXUIElementGetPid");
  _functions.performAction = dlsym(RTLD_DEFAULT, "AXUIElementPerformAction");
  _functions.setAttributeValue = dlsym(RTLD_DEFAULT, "AXUIElementSetAttributeValue");
  _functions.setMessagingTimeout = dlsym(RTLD_DEFAULT, "AXUIElementSetMessagingTimeout");
  // Not part of the null check below: this one is optional, so a runtime without it degrades to
  // "cannot say" rather than failing a bind that every read would otherwise have survived.
  _functions.automationEnabled = dlsym(RTLD_DEFAULT, "_AXSAutomationEnabled");
  _functions.voiceOverEnabled = dlsym(RTLD_DEFAULT, "_AXSVoiceOverTouchEnabled");
  _functions.voiceOverSetEnabled = dlsym(RTLD_DEFAULT, "_AXSVoiceOverTouchSetEnabled");
  // Optional for the same reason, and checked where the single-fetch read uses them.
  _functions.valueGetType = dlsym(RTLD_DEFAULT, "AXValueGetType");
  _functions.valueGetValue = dlsym(RTLD_DEFAULT, "AXValueGetValue");
  _functions.defaultSnapshotParameters = dlsym(RTLD_DEFAULT, "XCTDefaultSnapshotParameters");
  _functions.attributeNumbersForNames = dlsym(RTLD_DEFAULT, "XCAXAccessibilityAttributesForStringAttributes");
  _functions.elementTypeFromAutomationType = dlsym(RTLD_DEFAULT, "XCTElementTypeFromAXAutomationType");
  _functions.elementTypeID = dlsym(RTLD_DEFAULT, "AXUIElementGetTypeID");
  _functions.performActionWithValue = dlsym(RTLD_DEFAULT, "AXUIElementPerformActionWithValue");
  _functions.observerCreate = dlsym(RTLD_DEFAULT, "AXObserverCreate");
  _functions.observerAddNotification = dlsym(RTLD_DEFAULT, "AXObserverAddNotification");
  _functions.observerGetRunLoopSource = dlsym(RTLD_DEFAULT, "AXObserverGetRunLoopSource");
  if (!_functions.createSystemWide || !_functions.copyElementAtPosition || !_functions.getPid
      || !_functions.performAction || !_functions.setAttributeValue || !_functions.setMessagingTimeout) {
    if (error) {
      *error = @"AXUIElementCreateSystemWide/CopyElementAtPosition/GetPid/PerformAction/SetAttributeValue/SetMessagingTimeout unavailable";
    }
    return nil;
  }

  // AX replies default to three seconds, including writes that initialize a keyboard or navigate.
  // Five seconds per reply leaves room for hit-test, assertion, write and two confirmation reads
  // inside the host's thirty-second socket wait. This changes only this guest client's process.
  void *system = _functions.createSystemWide();
  if (!system) {
    if (error) {
      *error = @"could not create a system-wide element to configure the AX reply timeout";
    }
    return nil;
  }
  FBAXElementRef *reference = [[FBAXElementRef alloc] initWithOwnedElement:system];
  int32_t timeoutError = [reference axErrorFromElement:^int32_t (void *element) {
    return self->_functions.setMessagingTimeout(element, FBAXMessagingTimeoutSeconds);
  }];
  if (timeoutError != FBAXErrorSuccess) {
    if (error) {
      *error = [NSString stringWithFormat:@"could not configure the AX reply timeout: %@", FBAXErrorDescription(timeoutError)];
    }
    return nil;
  }

  return self;
}

#pragma mark Display inventory

- (FBAXDisplayInventoryOutcome *)displayInventory
{
  Class<XCTDisplayManagerClass> manager = (Class<XCTDisplayManagerClass>)objc_lookUpClass("XCTAutomationSupport.XCTDisplayManager");
  if (!manager || ![manager respondsToSelector:@selector(allDisplayIDs)] || ![manager respondsToSelector:@selector(uniqueIDForDisplayWithID:)]) {
    return [FBAXDisplayInventoryOutcome unavailable:@"Accessibility display inventory is unavailable"];
  }
  for (size_t index = 0; index < sizeof(kFBAXDisplaySelectors) / sizeof(*kFBAXDisplaySelectors); index++) {
    const FBAXBoundSelector bound = kFBAXDisplaySelectors[index];
    NSString *mismatch = FBAXSignatureMismatch(bound.className, bound.selectorName, bound.isClassMethod, bound.expected);
    if (mismatch) {
      return [FBAXDisplayInventoryOutcome unavailable:mismatch];
    }
  }
  NSArray<NSNumber *> *identifiers = [manager allDisplayIDs];
  if (![identifiers isKindOfClass:NSArray.class] || identifiers.count > 32) {
    return [FBAXDisplayInventoryOutcome failed:@"Invalid accessibility display inventory"];
  }
  NSMutableSet<NSNumber *> *displayIDs = [NSMutableSet set];
  NSMutableSet<NSString *> *uniqueIDs = [NSMutableSet set];
  NSMutableArray<FBAXDisplayIdentity *> *displays = [NSMutableArray array];
  for (NSNumber *identifier in identifiers) {
    if (![identifier isKindOfClass:NSNumber.class]
        || CFGetTypeID((__bridge CFTypeRef)identifier) == CFBooleanGetTypeID()
        || CFNumberIsFloatType((__bridge CFNumberRef)identifier)
        || identifier.longLongValue <= 0 || identifier.unsignedLongLongValue > UINT32_MAX
        || [displayIDs containsObject:identifier]) {
      return [FBAXDisplayInventoryOutcome failed:@"Invalid or duplicate accessibility display ID"];
    }
    [displayIDs addObject:identifier];
    NSString *uniqueID = [manager uniqueIDForDisplayWithID:identifier.unsignedIntValue];
    if (![uniqueID isKindOfClass:NSString.class] || uniqueID.length == 0 || uniqueID.length > 1024 || [uniqueIDs containsObject:uniqueID]) {
      return [FBAXDisplayInventoryOutcome failed:@"Invalid or duplicate accessibility display identity"];
    }
    uniqueID = [uniqueID copy];
    [uniqueIDs addObject:uniqueID];
    [displays addObject:[[FBAXDisplayIdentity alloc] initWithUniqueID:uniqueID displayID:identifier.unsignedIntValue]];
  }
  return [FBAXDisplayInventoryOutcome available:displays];
}

#pragma mark Automation mode

- (BOOL)automationModeEnabled
{
  if (!_functions.automationEnabled) {
    return NO;
  }
  return _functions.automationEnabled();
}

- (BOOL)setAutomationModeEnabled:(BOOL)enabled
{
  dlopen(FBAXPathAccessibilityUtilities, RTLD_NOW);
  Class<AXSettingsClass> settingsClass = (Class<AXSettingsClass>)objc_lookUpClass("AXSettings");
  if (!settingsClass || ![settingsClass respondsToSelector:@selector(sharedInstance)]) {
    return [self automationModeEnabled];
  }
  AXSettings *settings = [settingsClass sharedInstance];
  if (!settings || ![settings respondsToSelector:@selector(setAutomationEnabled:)]) {
    return [self automationModeEnabled];
  }
  [settings setAutomationEnabled:enabled];

  // Read back rather than reporting the write. A preference write can fail silently — the sandbox
  // refuses it outright on a real device — and the target consults the preference per read, so what
  // matters to a caller is what the device now says, not that we asked.
  return [self automationModeEnabled];
}

- (nullable AXSettings *)deviceAccessibilitySettings
{
  Class<AXSettingsClass> settingsClass = (Class<AXSettingsClass>)objc_lookUpClass("AXSettings");
  if (!settingsClass || ![settingsClass respondsToSelector:@selector(sharedInstance)]) {
    return nil;
  }
  return [settingsClass sharedInstance];
}

- (FBAXDeviceSettingMonitorOutcome *)monitorDeviceSettings:(NSArray<NSNumber *> *)settings handler:(void (^)(void))handler
{
  static void *library;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    library = dlopen(FBAXPathAccessibility, RTLD_LAZY | RTLD_LOCAL);
  });
  NSMutableArray<NSString *> *names = [NSMutableArray array];
  for (NSNumber *setting in settings) {
    const char *symbolName = NULL;
    switch (setting.unsignedIntegerValue) {
      case FBAXDeviceSettingReduceMotion: symbolName = FBAXReduceMotionChangedSymbol; break;
      case FBAXDeviceSettingReduceTransparency: symbolName = FBAXReduceTransparencyChangedSymbol; break;
      case FBAXDeviceSettingButtonShapes: symbolName = FBAXButtonShapesChangedSymbol; break;
      case FBAXDeviceSettingIncreaseContrast: symbolName = FBAXIncreaseContrastChangedSymbol; break;
      case FBAXDeviceSettingVoiceOver:
      default:
        return [FBAXDeviceSettingMonitorOutcome unavailable:@"This device setting has no observation binding"];
    }
    FBAXAccessibilityNotificationSymbol symbol = library ? dlsym(library, symbolName) : NULL;
    if (!symbol || !*symbol) {
      return [FBAXDeviceSettingMonitorOutcome unavailable:@"Device setting notifications are unavailable on this runtime"];
    }
    [names addObject:(__bridge NSString *)*symbol];
  }
  return [FBAXDeviceSettingMonitorOutcome resolved:[[FBAXDarwinSettingMonitor alloc] initWithNames:names handler:handler]];
}

- (FBAXDeviceSettingOutcome *)enabledStateForDeviceSetting:(FBAXDeviceSetting)setting
{
  @try {
    switch (setting) {
      case FBAXDeviceSettingIncreaseContrast: {
        static void *library;
        static FBAXIncreaseContrastGetFn read;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
          library = dlopen(FBAXPathAccessibility, RTLD_LAZY | RTLD_LOCAL);
          read = library ? dlsym(library, FBAXIncreaseContrastGetSymbol) : NULL;
        });
        if (!read) {
          return [FBAXDeviceSettingOutcome unavailable:@"Increase Contrast is unavailable on this runtime"];
        }
        return [FBAXDeviceSettingOutcome resolved:read()];
      }
      case FBAXDeviceSettingReduceMotion: {
        AXSettings *settings = [self deviceAccessibilitySettings];
        if (!settings || ![settings respondsToSelector:@selector(reduceMotionEnabled)]) {
          return [FBAXDeviceSettingOutcome unavailable:@"Reduce Motion is unavailable on this runtime"];
        }
        return [FBAXDeviceSettingOutcome resolved:[settings reduceMotionEnabled]];
      }
      case FBAXDeviceSettingReduceTransparency: {
        AXSettings *settings = [self deviceAccessibilitySettings];
        if (!settings || ![settings respondsToSelector:@selector(enhanceBackgroundContrastEnabled)]) {
          return [FBAXDeviceSettingOutcome unavailable:@"Reduce Transparency is unavailable on this runtime"];
        }
        return [FBAXDeviceSettingOutcome resolved:[settings enhanceBackgroundContrastEnabled]];
      }
      case FBAXDeviceSettingButtonShapes: {
        AXSettings *settings = [self deviceAccessibilitySettings];
        if (!settings || ![settings respondsToSelector:@selector(buttonShapesEnabled)]) {
          return [FBAXDeviceSettingOutcome unavailable:@"Button Shapes is unavailable on this runtime"];
        }
        return [FBAXDeviceSettingOutcome resolved:[settings buttonShapesEnabled]];
      }
      case FBAXDeviceSettingVoiceOver:
        if (!_functions.voiceOverEnabled) {
          return [FBAXDeviceSettingOutcome unavailable:@"VoiceOver is unavailable on this runtime"];
        }
        return [FBAXDeviceSettingOutcome resolved:_functions.voiceOverEnabled()];
      default:
        return [FBAXDeviceSettingOutcome unavailable:@"Unknown device setting"];
    }
  } @catch (NSException *exception) {
    return [FBAXDeviceSettingOutcome failed:exception.reason ?: @"Device setting read raised an exception"];
  }
}

- (FBAXDeviceSettingOutcome *)setEnabled:(BOOL)enabled forDeviceSetting:(FBAXDeviceSetting)setting
{
  @try {
    switch (setting) {
      case FBAXDeviceSettingReduceMotion: {
        AXSettings *settings = [self deviceAccessibilitySettings];
        if (!settings || ![settings respondsToSelector:@selector(reduceMotionEnabled)]
            || ![settings respondsToSelector:@selector(setReduceMotionEnabled:)]) {
          return [FBAXDeviceSettingOutcome unavailable:@"Reduce Motion is unavailable on this runtime"];
        }
        [settings setReduceMotionEnabled:enabled];
        break;
      }
      case FBAXDeviceSettingReduceTransparency: {
        AXSettings *settings = [self deviceAccessibilitySettings];
        if (!settings || ![settings respondsToSelector:@selector(enhanceBackgroundContrastEnabled)]
            || ![settings respondsToSelector:@selector(setEnhanceBackgroundContrastEnabled:)]) {
          return [FBAXDeviceSettingOutcome unavailable:@"Reduce Transparency is unavailable on this runtime"];
        }
        [settings setEnhanceBackgroundContrastEnabled:enabled];
        break;
      }
      case FBAXDeviceSettingButtonShapes: {
        AXSettings *settings = [self deviceAccessibilitySettings];
        if (!settings || ![settings respondsToSelector:@selector(buttonShapesEnabled)]
            || ![settings respondsToSelector:@selector(setButtonShapesEnabled:)]) {
          return [FBAXDeviceSettingOutcome unavailable:@"Button Shapes is unavailable on this runtime"];
        }
        [settings setButtonShapesEnabled:enabled];
        break;
      }
      case FBAXDeviceSettingVoiceOver:
        if (!_functions.voiceOverEnabled || !_functions.voiceOverSetEnabled) {
          return [FBAXDeviceSettingOutcome unavailable:@"VoiceOver is unavailable on this runtime"];
        }
        _functions.voiceOverSetEnabled(enabled);
        break;
      case FBAXDeviceSettingIncreaseContrast:
      default:
        return [FBAXDeviceSettingOutcome unavailable:@"Unknown device setting"];
    }
  } @catch (NSException *exception) {
    return [FBAXDeviceSettingOutcome failed:exception.reason ?: @"Device setting write raised an exception"];
  }
  return [self enabledStateForDeviceSetting:setting];
}

#pragma mark Quiescence

- (nullable id<FBAXQuiescenceMonitor>)quiescenceMonitorWithHandler:(FBAXQuiescenceHandler)handler
                                                             error:(NSString *_Nullable *_Nullable)error
{
  if (!_functions.performActionWithValue || !_functions.observerCreate || !_functions.observerAddNotification
      || !_functions.observerGetRunLoopSource) {
    if (error) {
      *error = @"AXObserverCreate/AddNotification/GetRunLoopSource/AXUIElementPerformActionWithValue unavailable";
    }
    return nil;
  }
  return [[FBAXLiveQuiescenceMonitor alloc] initWithFunctions:_functions handler:handler error:error];
}

#pragma mark Element references

- (nullable FBAXElementRef *)referenceForElement:(id)element
{
  return FBAXReferenceForElement(element);
}

#pragma mark FBAXRuntime

- (nullable id)applicationElementForProcessIdentifier:(pid_t)pid
{
  return [_elementClass elementWithProcessIdentifier:pid];
}

// The snapshot path's failures, kept together so each one names what is missing rather than sharing a
// code with the others.
static NSError *FBAXSnapshotFailure(NSInteger code, NSString *description)
{
  return [NSError errorWithDomain:@"FBAXBridgeSnapshot"
                             code:code
                         userInfo:@{NSLocalizedDescriptionKey : description}];
}

// The body both snapshot entry points share, taking the raw reference the framework wants. The framework
// passes its argument straight to the accessibility call without unwrapping it, which is why the callers
// unwrap on their side of this seam rather than handing over the element wrapper the other methods take.
- (nullable id)snapshotOfReference:(id)reference
                    attributeNames:(NSArray<NSString *> *)names
                     namesByNumber:(NSDictionary<NSNumber *, NSString *> *_Nullable *_Nonnull)namesByNumber
                             error:(NSError **)error
{
  SEL selector = @selector(userTestingSnapshotForElement:options:error:);
  if (![_framework respondsToSelector:selector]) {
    if (error) {
      *error = FBAXSnapshotFailure(1, @"this runtime's XCTAccessibilityFramework has no userTestingSnapshotForElement:options:error:");
    }
    return nil;
  }
  if (!_functions.defaultSnapshotParameters || !_functions.attributeNumbersForNames) {
    if (error) {
      *error = FBAXSnapshotFailure(3, @"this runtime has no XCTDefaultSnapshotParameters/XCAXAccessibilityAttributesForStringAttributes");
    }
    return nil;
  }

  // Positional: the numbers come back in the order the names went in, so zipping the two recovers the
  // mapping the snapshot's numeric keys are read through. A result of another length cannot be zipped,
  // and guessing at the alignment would mislabel every attribute in the tree.
  NSArray<NSNumber *> *numbers = _functions.attributeNumbersForNames(names);
  if (![numbers isKindOfClass:NSArray.class] || numbers.count != names.count) {
    if (error) {
      *error = FBAXSnapshotFailure(4, @"the attribute name conversion answered a list of a different length");
    }
    return nil;
  }
  NSMutableDictionary<NSNumber *, NSString *> *inverse = [NSMutableDictionary dictionary];
  [numbers enumerateObjectsUsingBlock:^(id number, NSUInteger index, __unused BOOL *stop) {
    if ([number isKindOfClass:NSNumber.class]) {
      inverse[number] = names[index];
    }
  }];
  *namesByNumber = inverse;

  NSMutableDictionary *options = [_functions.defaultSnapshotParameters() mutableCopy] ?: [NSMutableDictionary dictionary];
  options[@"attributes"] = numbers;

  return [_framework userTestingSnapshotForElement:reference options:options error:error];
}

- (nullable id)snapshotOfElement:(id)element
                  attributeNames:(NSArray<NSString *> *)names
                   namesByNumber:(NSDictionary<NSNumber *, NSString *> *_Nullable *_Nonnull)namesByNumber
                           error:(NSError **)error
{
  // Unwrapped here, where the accessor is declared and its signature is checked.
  XCAccessibilityElement *wrapper = element;
  void *reference = [wrapper respondsToSelector:@selector(AXUIElement)] ? [wrapper AXUIElement] : NULL;
  if (!reference) {
    if (error) {
      *error = FBAXSnapshotFailure(2, @"the element carries no AXUIElement to snapshot");
    }
    return nil;
  }
  return [self snapshotOfReference:(__bridge id)reference attributeNames:names namesByNumber:namesByNumber error:error];
}

- (pid_t)owningProcessIdentifierForSnapshotElement:(id)element
{
  // The snapshot's element key holds a raw AXUIElementRef, which is exactly what the pid lookup takes —
  // but the C entry points do not check what they are handed, so the type is proven before the call
  // rather than trusted from the key's name. A failed lookup answers 0, the value the interface names
  // "unknown" — never a guess.
  if (!element || !_functions.getPid || !_functions.elementTypeID) {
    return 0;
  }
  if (CFGetTypeID((__bridge CFTypeRef)element) != _functions.elementTypeID()) {
    return 0;
  }
  pid_t pid = 0;
  if (_functions.getPid((__bridge void *)element, &pid) != FBAXErrorSuccess) {
    return 0;
  }
  return pid;
}

- (FBXCUIElementType)elementTypeForAutomationType:(NSUInteger)automationType
{
  return _functions.elementTypeFromAutomationType ? _functions.elementTypeFromAutomationType(automationType) : FBXCUIElementTypeAny;
}

- (pid_t)owningProcessIdentifierOfElement:(id)element
{
  // A translation object carries no platform element to ask.
  if (![element respondsToSelector:@selector(AXUIElement)]) {
    return 0;
  }
  return [self owningProcessIdentifierForSnapshotElement:(__bridge id)[element AXUIElement]];
}

- (nullable id)snapshotOfSnapshotElement:(nullable id)element
                          attributeNames:(NSArray<NSString *> *)names
                           namesByNumber:(NSDictionary<NSNumber *, NSString *> *_Nullable *_Nonnull)namesByNumber
                                   error:(NSError **)error
{
  // The snapshot's element key already holds the raw reference the framework wants; there is nothing to
  // unwrap. The reference is owned by the snapshot dictionary it came from, which the caller is holding.
  if (!element) {
    if (error) {
      *error = FBAXSnapshotFailure(2, @"the snapshot node carries no element to snapshot");
    }
    return nil;
  }
  return [self snapshotOfReference:element attributeNames:names namesByNumber:namesByNumber error:error];
}

- (BOOL)getRect:(CGRect *)rect fromValue:(id)value
{
  if (!rect || !value || !_functions.valueGetType || !_functions.valueGetValue) {
    return NO;
  }
  CFTypeRef reference = (__bridge CFTypeRef)value;
  if (_functions.valueGetType(reference) != FBAXValueTypeCGRect) {
    return NO;
  }
  return _functions.valueGetValue(reference, FBAXValueTypeCGRect, rect) ? YES : NO;
}

- (BOOL)getPoint:(CGPoint *)point fromValue:(id)value
{
  if (!point || !value || !_functions.valueGetType || !_functions.valueGetValue) {
    return NO;
  }
  CFTypeRef reference = (__bridge CFTypeRef)value;
  if (_functions.valueGetType(reference) != FBAXValueTypeCGPoint) {
    return NO;
  }
  return _functions.valueGetValue(reference, FBAXValueTypeCGPoint, point) ? YES : NO;
}

- (FBAXReadOutcome *)readAttributes:(NSArray<NSString *> *)attributes ofElement:(id)element
{
  if (![element respondsToSelector:@selector(AXUIElement)]) {
    // Semantic children are translation objects; XCTest attributes require a platform element.
    __block id platformElement = nil;
    FBAXBridgeRunOffMainQueue(^{
      Class translationClass = objc_lookUpClass("AXPTranslationObject");
      if (!translationClass || ![element isKindOfClass:translationClass]) {
        return;
      }
      NSString *setupError = nil;
      AXPTranslator *translator = FBAXBridgeWindowServerTranslator(&setupError);
      if (![translator respondsToSelector:@selector(createPlatformElementFromTranslationObject:)]) {
        return;
      }
      AXUIElementRef raw = [translator createPlatformElementFromTranslationObject:element];
      FBAXElementRef *owned = raw ? [[FBAXElementRef alloc] initWithOwnedElement:raw] : nil;
      platformElement = [owned objectFromElement:^id (void *reference) {
        return [self->_elementClass elementWithAXUIElement:reference];
      }];
    });
    if (!platformElement) {
      return [FBAXReadOutcome failureForAttributeError:[NSError errorWithDomain:@"FBAXRuntime"
                                                                           code:1
                                                                       userInfo:@{
                                                          NSLocalizedDescriptionKey : @"Could not convert a semantic accessibility element for attribute reading",
                                                        }]];
    }
    element = platformElement;
  }
  NSError *error = nil;
  NSDictionary<NSString *, id> *read = [_framework attributesForElement:element
                                                             attributes:attributes
                                                                  error:&error];
  if (![read isKindOfClass:NSDictionary.class]) {
    return [FBAXReadOutcome failureForAttributeError:error];
  }
  return [FBAXReadOutcome read:read];
}

// Every raw AXUIElementRef in the product is acquired inside this method and owned by an `FBAXElementRef`
// from the moment it is, and the hit is handed back already wrapped as an opaque element handle — so
// nothing outside can outlive or over-release either, and nothing inside has to remember to.
- (FBAXHitTestOutcome *)hitTestAtPoint:(CGPoint)point
                     processIdentifier:(pid_t)pid
                     displayIdentifier:(uint32_t)displayID
                            clientType:(NSUInteger)clientType
{
  __block FBAXHitTestOutcome *outcome = nil;
  FBAXBridgeRunOffMainQueue(^{
    NSString *setupError = nil;
    AXPTranslator *translator = FBAXBridgeWindowServerTranslator(&setupError);
    if (!translator || ![translator respondsToSelector:@selector(objectAtPoint:displayId:bridgeDelegateToken:)]
        || ![translator respondsToSelector:@selector(createPlatformElementFromTranslationObject:)]) {
      outcome = [FBAXHitTestOutcome failed:setupError ?: @"Display-specific accessibility hit testing is unavailable"];
      return;
    }
    __block AXPTranslationObject *translation = nil;
    FBAXBridgeWithSelfServiceClientType(clientType, ^{
      translation = [translator objectAtPoint:point displayId:displayID bridgeDelegateToken:@"axbridge"];
    });
    if (!translation) {
      outcome = [FBAXHitTestOutcome empty];
      return;
    }
    pid_t owningPid = translation.pid;
    if (owningPid <= 0) {
      outcome = [FBAXHitTestOutcome failed:@"Display hit test returned no owning process"];
      return;
    }
    if (pid > 0 && owningPid != pid) {
      outcome = [FBAXHitTestOutcome empty];
      return;
    }
    AXUIElementRef raw = [translator createPlatformElementFromTranslationObject:translation];
    FBAXElementRef *owned = raw ? [[FBAXElementRef alloc] initWithOwnedElement:raw] : nil;
    if (!owned) {
      outcome = [FBAXHitTestOutcome failed:@"Could not create the display hit element"];
      return;
    }
    id element = [owned objectFromElement:^id (void *reference) {
      return [self->_elementClass elementWithAXUIElement:reference];
    }];
    outcome = element ? [FBAXHitTestOutcome hit:element owningProcessIdentifier:owningPid]
    : [FBAXHitTestOutcome failed:@"Could not wrap the display hit element"];
  });
  return outcome ?: [FBAXHitTestOutcome failed:@"Display hit testing did not return an outcome"];
}

- (FBAXHitTestOutcome *)hitTestAtPoint:(CGPoint)point processIdentifier:(pid_t)pid
{
  // The seed is owned either way so both branches release alike; every raw use below goes through
  // `-axErrorFromElement:`.
  FBAXElementRef *seed = nil;
  if (pid > 0) {
    XCAccessibilityElement *root = [_elementClass elementWithProcessIdentifier:pid];
    if (!root) {
      return [FBAXHitTestOutcome failed:[NSString stringWithFormat:@"no application element for pid %d", pid]];
    }
    void *applicationElement = [root AXUIElement];
    if (!applicationElement) {
      return [FBAXHitTestOutcome failed:[NSString stringWithFormat:@"no AXUIElement for pid %d", pid]];
    }
    seed = [FBAXElementRef retainingBorrowedElement:applicationElement];
  } else {
    void *systemWide = _functions.createSystemWide();
    if (!systemWide) {
      return [FBAXHitTestOutcome failed:@"AXUIElementCreateSystemWide returned NULL"];
    }
    seed = [[FBAXElementRef alloc] initWithOwnedElement:systemWide];
  }

  __block void *copied = NULL;
  int32_t axError = [seed axErrorFromElement:^int32_t (void *element) {
    return self->_functions.copyElementAtPosition(element, (float)point.x, (float)point.y, &copied);
  }];
  // Wrapped before anything else can fail. The copy is +1 whenever it produced one, so from here every
  // exit releases it without having to say so — including the error paths, where the runtime is not
  // supposed to have produced an element at all but nothing stops it.
  FBAXElementRef *hit = copied ? [[FBAXElementRef alloc] initWithOwnedElement:copied] : nil;

  FBAXHitTestOutcome *unresolved = [FBAXHitTestOutcome outcomeForHitTestError:axError hasElement:hit != nil];
  if (unresolved) {
    return unresolved;
  }

  // The host tags the hit element with its owning process, so an unattributable hit is not a result. A
  // seeded hit-test already knows the pid and falls back to it; a system-wide one has no other source.
  __block pid_t owningPid = 0;
  int32_t pidError = [hit axErrorFromElement:^int32_t (void *element) {
    return self->_functions.getPid(element, &owningPid);
  }];
  if (pidError != FBAXErrorSuccess || owningPid <= 0) {
    if (pid <= 0) {
      NSString *reason = pidError == FBAXErrorSuccess ? @"the hit element reported no pid" : [NSString stringWithFormat:@"could not resolve the owning pid of the hit element: %@", FBAXErrorDescription(pidError)];
      return [FBAXHitTestOutcome failed:reason];
    }
    owningPid = pid;
  }

  // `elementWithAXUIElement:` takes a reference of its own, so the wrapper's goes when it leaves scope.
  XCAccessibilityElement *hitElement = [hit objectFromElement:^id _Nullable (void *element) {
    return [self->_elementClass elementWithAXUIElement:element];
  }];
  if (!hitElement) {
    return [FBAXHitTestOutcome failed:@"failed to read the hit element"];
  }
  return [FBAXHitTestOutcome hit:hitElement owningProcessIdentifier:owningPid];
}

- (FBAXWriteOutcome *)performAction:(FBAXAction)action onElement:(id)element
{
  // Only reachable when an `FBAXAction` case is added without a mapping in `FBAXActionIdentifierForAction`.
  uint32_t identifier = 0;
  if (!FBAXActionIdentifierForAction(action, &identifier)) {
    return [FBAXWriteOutcome failed:[NSString stringWithFormat:@"no AX runtime identifier for action %lu", (unsigned long)action]];
  }
  FBAXElementRef *reference = [self referenceForElement:element];
  if (!reference) {
    return [FBAXWriteOutcome failed:@"the element has no AXUIElement to act on"];
  }
  // A write is the shape most exposed to the reference dying under the call — it is live across a
  // cross-process round trip that lasts as long as the application takes to run the action.
  // `-axErrorFromElement:` is what holds it open for that.
  int32_t axError = [reference axErrorFromElement:^int32_t (void *raw) {
    return self->_functions.performAction(raw, identifier);
  }];
  if (action == FBAXActionPress) {
    FBAXWriteOutcome *(^fallback)(void) = ^FBAXWriteOutcome * {
      return [reference objectFromElement:^id (void *raw) {
        Class<FBAXNativeElementClass> nativeClass = (Class<FBAXNativeElementClass>)objc_lookUpClass("AXElement");
        if (![nativeClass respondsToSelector:@selector(elementWithAXUIElement:)]) {
          return [FBAXWriteOutcome failed:[NSString stringWithFormat:@"AXPress was refused with %@, and this runtime has no native element activation API", FBAXErrorDescription(FBAXErrorFailure)]];
        }
        AXElement *native = [nativeClass elementWithAXUIElement:raw];
        if (![native respondsToSelector:@selector(press)]) {
          return [FBAXWriteOutcome failed:[NSString stringWithFormat:@"AXPress was refused with %@, and the element has no native press operation", FBAXErrorDescription(FBAXErrorFailure)]];
        }
        return [native press] ? [FBAXWriteOutcome written] : [FBAXWriteOutcome failed:[NSString stringWithFormat:@"AXPress was refused with %@, and native activation could not activate the element or tap its visible point", FBAXErrorDescription(FBAXErrorFailure)]];
      }];
    };
    return [FBAXWriteOutcome outcomeForPressError:axError fallback:fallback];
  }
  return [FBAXWriteOutcome outcomeForWriteError:axError];
}

- (FBAXWriteOutcome *)setValue:(id)value onElement:(id)element
{
  FBAXElementRef *reference = [self referenceForElement:element];
  if (!reference) {
    return [FBAXWriteOutcome failed:@"the element has no AXUIElement to write to"];
  }
  // __bridge and not __bridge_retained: the runtime borrows the value, and `value` is an argument the
  // caller owns for longer than this call takes.
  int32_t axError = [reference axErrorFromElement:^int32_t (void *raw) {
    return self->_functions.setAttributeValue(raw, FBAXAttributeIdentifierValue, (__bridge const void *)value);
  }];
  return [FBAXWriteOutcome outcomeForWriteError:axError];
}

// The authoritative frontmost the host obtains through AXPTranslator, obtained here with no host
// round-trip.
- (FBAXFrontmostOutcome *)windowServerFrontmost
{
  return [self windowServerFrontmostOnDisplay:0];
}

- (FBAXFrontmostOutcome *)windowServerFrontmostOnDisplay:(uint32_t)displayID
{
  __block FBAXFrontmostOutcome *outcome = nil;
  FBAXBridgeRunOffMainQueue(^{
    outcome = FBAXBridgeWindowServerFrontmostOffMain(displayID);
  });
  return outcome ?: [FBAXFrontmostOutcome unresolved:@"window-server frontmost resolution failed"];
}

// Reads a batch of attributes through the translator rather than through XCTest's attribute bundle. The
// element may be an `XCAccessibilityElement` or a translation object the translator itself returned, and
// both are accepted so a walk can hand its own children straight back in.
- (nullable NSDictionary<NSNumber *, id> *)translatorAttributes:(NSArray<NSNumber *> *)attributes
                                                      ofElement:(id)element
                                                     clientType:(NSUInteger)clientType
{
  if (attributes.count == 0 || !element) {
    return nil;
  }
  __block NSDictionary *result = nil;
  FBAXBridgeRunOffMainQueue(^{
    NSString *setupError = nil;
    AXPTranslator *translator = FBAXBridgeWindowServerTranslator(&setupError);
    if (!translator) {
      return;
    }
    id translation = element;
    if ([element respondsToSelector:@selector(AXUIElement)]) {
      void *raw = [(XCAccessibilityElement *)element AXUIElement];
      if (!raw) {
        return;
      }
      translation = [translator translationObjectFromPlatformElement:raw];
    }
    if (!translation) {
      return;
    }
    Class requestClass = objc_lookUpClass("AXPTranslatorRequest");
    if (!requestClass) {
      return;
    }
    AXPTranslatorRequest *request = [requestClass requestWithTranslation:translation];
    request.requestType = FBAXPRequestTypeMultipleAttribute;
    if ([request respondsToSelector:@selector(setClientType:)]) {
      request.clientType = clientType;
    }
    // The handler subscripts `parameters` by this key; an array here throws and takes the reader down.
    request.parameters = @{@"attributes" : attributes};
    @try {
      FBAXBridgeWithSelfServiceClientType(clientType, ^{
        AXPTranslatorResponse *response = [translator processTranslatorRequest:request];
        id data = response.resultData;
        result = [data isKindOfClass:NSDictionary.class] ? data : nil;
      });
    } @catch (NSException *exception) {
      result = nil;
    }
  });
  return result;
}

// The launch-services process holding `com.apple.frontboard.visibility` is the foreground app — the
// window server's own notion, read from RunningBoard rather than the AX stack, so it needs neither an
// anchor nor the AX server. Requires the `com.apple.runningboard.process-state` entitlement; without it
// runningboardd answers "Client not entitled".
- (FBAXFrontmostOutcome *)runningBoardFrontmost
{
  dlopen(FBAXPathRunningBoardServices, RTLD_NOW);
  // Cast to the `Class<…>` protocols: `+descriptor` also exists on NSAppleEventDescriptor (see the header).
  Class<RBSProcessPredicateClass> predicateClass = (Class<RBSProcessPredicateClass>)objc_lookUpClass("RBSProcessPredicate");
  Class<RBSProcessStateClass> stateClass = (Class<RBSProcessStateClass>)objc_lookUpClass("RBSProcessState");
  Class<RBSProcessStateDescriptorClass> descriptorClass = (Class<RBSProcessStateDescriptorClass>)objc_lookUpClass("RBSProcessStateDescriptor");
  if (!predicateClass || !stateClass || ![stateClass respondsToSelector:@selector(statesForPredicate:withDescriptor:error:)]) {
    return [FBAXFrontmostOutcome unresolved:@"RunningBoardServices unavailable — is RunningBoardServices loaded?"];
  }

  RBSProcessPredicate *predicate = [predicateClass predicateMatchingLaunchServicesProcesses];

  // The descriptor selects which fields RunningBoard populates. Request the endowment namespaces so each
  // returned state carries its visibility endowment: the concrete "values" bitmask is not stable across
  // OS versions, so it is set to all-bits defensively and the specific endowment namespace is named too.
  RBSProcessStateDescriptor *descriptor = nil;
  if (descriptorClass) {
    descriptor = [descriptorClass descriptor];
    @try {
      if ([descriptor respondsToSelector:@selector(setValues:)]) {
        descriptor.values = ~0ull;
      }
      if ([descriptor respondsToSelector:@selector(setEndowmentNamespaces:)]) {
        descriptor.endowmentNamespaces = @[kFrontboardVisibilityEndowment];
      }
    } @catch (NSException *exception) {
      // fall through with the default descriptor
    }
  }

  NSError *error = nil;
  NSArray<RBSProcessState *> *states = [stateClass statesForPredicate:predicate withDescriptor:descriptor error:&error];
  if (![states isKindOfClass:NSArray.class]) {
    return [FBAXFrontmostOutcome unresolved:
            [NSString stringWithFormat:@"RunningBoard process-state query failed: %@", error ?: @"(no states returned)"]];
  }

  for (RBSProcessState *state in states) {
    if (![state respondsToSelector:@selector(endowmentNamespaces)]) {
      continue;
    }
    if (![state.endowmentNamespaces containsObject:kFrontboardVisibilityEndowment]) {
      continue;
    }
    RBSProcessHandle *process = [state respondsToSelector:@selector(process)] ? state.process : nil;
    if (!process || ![process respondsToSelector:@selector(pid)]) {
      continue;
    }
    if (process.pid > 0) {
      return [FBAXFrontmostOutcome resolved:process.pid];
    }
  }

  return [FBAXFrontmostOutcome unresolved:@"no launch-services process holds the on-screen visibility endowment"];
}

@end

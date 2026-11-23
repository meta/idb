/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBAXFakeRuntime.h"

static NSString *const kAXElementType = @"XC_kAXXCAttributeElementType";
static NSString *const kAXLabel = @"XC_kAXXCAttributeLabel";
static NSString *const kAXChildren = @"XC_kAXXCAttributeChildren";

@implementation FBAXGeometryDictionaryProbeValue
{
  NSDictionary *_values;
}

- (instancetype)initWithObjects:(const id [])objects forKeys:(const id<NSCopying> [])keys count:(NSUInteger)count
{
  self = [super init];
  if (self) {
    _values = [[NSDictionary alloc] initWithObjects:objects forKeys:keys count:count];
  }
  return self;
}

+ (instancetype)geometry
{
  id objects[] = {@1, @2, @3, @4};
  id<NSCopying> keys[] = {@"X", @"Y", @"Width", @"Height"};
  return [[self alloc] initWithObjects:objects forKeys:keys count:4];
}

+ (instancetype)attributes
{
  id objects[] = {@"UIApplication", @"label", @[]};
  id<NSCopying> keys[] = {kAXElementType, kAXLabel, kAXChildren};
  return [[self alloc] initWithObjects:objects forKeys:keys count:3];
}

- (NSUInteger)count
{
  return _values.count;
}

- (NSEnumerator *)keyEnumerator
{
  return [_values keyEnumerator];
}

- (id)objectForKey:(id)key
{
  self.lookups++;
  if (self.raises || (self.maximumSuccessfulLookups > 0 && self.lookups > self.maximumSuccessfulLookups)) {
    [NSException raise:NSInternalInconsistencyException format:@"geometry dictionary lookup failed"];
  }
  return [_values objectForKey:key];
}

- (id)copyWithZone:(NSZone *)zone
{
  return self;
}

@end

NSDictionary<NSString *, id> *FBAXGeometryDictionaryProbe(BOOL rectangle, BOOL raises)
{
  FBAXGeometryDictionaryProbeValue *value = nil;
  @try {
    value = [FBAXGeometryDictionaryProbeValue geometry];
    value.raises = raises;
    CGRect rect = CGRectZero;
    CGPoint point = CGPointZero;
    BOOL accepted = rectangle
    ? CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)value, &rect)
    : CGPointMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)value, &point);
    return @{@"accepted" : @(accepted), @"raised" : @NO, @"lookups" : @(value.lookups)};
  } @catch (NSException *exception) {
    return @{
      @"accepted" : @NO,
      @"raised" : @YES,
      @"lookups" : @(value.lookups),
      @"reason" : exception.reason ?: exception.name,
    };
  }
}

@implementation FBAXFakeElement

- (instancetype)init
{
  self = [super init];
  if (!self) {
    return nil;
  }
  _attributes = @{};
  _children = @[];
  _readStatus = FBAXReadStatusRead;
  return self;
}

+ (instancetype)readable:(NSString *)elementType
{
  FBAXFakeElement *element = [self new];
  element.attributes = @{kAXElementType : elementType, kAXLabel : elementType};
  return element;
}

+ (instancetype)applicationUnavailable
{
  FBAXFakeElement *element = [self new];
  element.readStatus = FBAXReadStatusApplicationUnavailable;
  return element;
}

+ (instancetype)applicationNotResponding
{
  FBAXFakeElement *element = [self new];
  element.readStatus = FBAXReadStatusApplicationNotResponding;
  return element;
}

+ (instancetype)failed:(nullable NSError *)error
{
  FBAXFakeElement *element = [self new];
  element.readStatus = FBAXReadStatusFailed;
  element.readError = error;
  return element;
}

@end

@implementation FBAXFakeRectValue

+ (instancetype)withRect:(CGRect)rect
{
  FBAXFakeRectValue *value = [self new];
  value->_rect = rect;
  return value;
}

@end

@implementation FBAXFakePointValue

+ (instancetype)withPoint:(CGPoint)point
{
  FBAXFakePointValue *value = [self new];
  value->_point = point;
  return value;
}

@end

@implementation FBAXFakeVisibilityValue

+ (instancetype)value
{
  return [[self alloc] init];
}

- (const char *)objCType
{
  return @encode(int);
}

- (void)checkNumericRead
{
  if (self.raises) {
    [NSException raise:NSInternalInconsistencyException format:@"visibility failed"];
  }
  if (self.raisesOnNumericRead) {
    [NSException raise:NSInternalInconsistencyException format:@"geometry coordinate failed"];
  }
}

- (void)getValue:(void *)value size:(NSUInteger)size
{
  [self checkNumericRead];
  int number = 0;
  memcpy(value, &number, MIN(size, sizeof(number)));
}

- (long long)longLongValue
{
  [self checkNumericRead];
  return 0;
}

- (unsigned long long)unsignedLongLongValue
{
  [self checkNumericRead];
  return 0;
}

- (double)doubleValue
{
  [self checkNumericRead];
  return 0;
}

- (BOOL)boolValue
{
  self.coordinateToInvalidate.raisesOnNumericRead = YES;
  if (self.raises) {
    [NSException raise:NSInternalInconsistencyException format:@"visibility failed"];
  }
  return NO;
}

@end

@implementation FBAXFakeOpaqueValue

- (NSString *)description
{
  if (self.raiseReason) {
    [NSException raise:NSInternalInconsistencyException format:@"%@", self.raiseReason];
  }
  return self.descriptionValue ?: @"opaque accessibility value";
}

@end

@implementation FBAXFakeGeometryValue

+ (instancetype)throwingOnAccess:(NSString *)access
{
  FBAXFakeGeometryValue *value = [[self alloc] init];
  value.raiseOnAccess = access;
  return value;
}

- (const char *)objCType
{
  if ([self.raiseOnAccess isEqualToString:@"type"]) {
    [NSException raise:NSInternalInconsistencyException format:@"geometry type failed"];
  }
  return @encode(CGRect);
}

- (void)getValue:(void *)value size:(NSUInteger)size
{
  if ([self.raiseOnAccess isEqualToString:@"value"]) {
    [NSException raise:NSInternalInconsistencyException format:@"geometry value failed"];
  }
  CGRect rect = CGRectMake(1, 2, 3, 4);
  memcpy(value, &rect, MIN(size, sizeof(rect)));
}

@end

@implementation FBAXFakeQuiescenceMonitor
{
  FBAXQuiescenceHandler _handler;
}

- (instancetype)initWithHandler:(FBAXQuiescenceHandler)handler
{
  self = [super init];
  if (self) {
    _handler = [handler copy];
    _requests = [NSMutableArray array];
    _requestOutcome = [FBAXWriteOutcome written];
  }
  return self;
}

- (FBAXWriteOutcome *)requestSignal:(FBAXQuiescenceSignal)signal fromApplication:(id)element
{
  [self.requests addObject:@{@"signal" : @(signal), @"element" : element}];
  return self.requestOutcome;
}

- (void)invalidate
{
  _invalidated = YES;
  _handler = nil;
}

- (void)deliver:(FBAXQuiescenceReport)report pid:(pid_t)pid
{
  if (_handler) {
    _handler(report, pid);
  }
}

@end

@implementation FBAXFakeDeviceSettingMonitor
- (void)deliver
{
  if (self.handler) {
    self.handler();
  }
}

- (void)invalidate
{
  _invalidated = YES;
  self.handler = nil;
}

@end

@implementation FBAXFakeRuntime
{
  NSUInteger _translatorReadCount;
  NSUInteger _snapshotCount;
  NSArray<NSString *> *_lastSnapshotAttributeNames;
}

- (instancetype)init
{
  self = [super init];
  if (!self) {
    return nil;
  }
  _operations = [NSMutableArray array];
  _readOutcomes = @[];
  _translatorResponses = @[];
  _translatorRequests = [NSMutableArray array];
  _snapshotResults = @[];
  _snapshotNameMappings = @[];
  _snapshotOwnerElements = [NSMutableArray array];
  _applicationElements = [NSMutableDictionary dictionary];
  _automationModeWrites = [NSMutableArray array];
  _quiescenceMonitors = [NSMutableArray array];
  _deviceSettings = [NSMutableDictionary dictionary];
  _deviceSettingMonitorOutcomes = [NSMutableDictionary dictionary];
  _deviceSettingMonitors = [NSMutableDictionary dictionary];
  _deviceSettingWrites = [NSMutableArray array];
  _displayInventoryOutcome = [FBAXDisplayInventoryOutcome available:@[]];
  _hitTestOutcome = [FBAXHitTestOutcome empty];
  _windowServerOutcome = [FBAXFrontmostOutcome unresolved:@"no window-server outcome configured"];
  _runningBoardOutcome = [FBAXFrontmostOutcome unresolved:@"no running-board outcome configured"];
  _writeOutcome = [FBAXWriteOutcome written];
  return self;
}

- (void)recordOperation:(NSString *)operation
{
  [self.operations addObject:operation];
  if ([self.raiseOnOperation isEqualToString:operation]) {
    [NSException raise:NSInternalInconsistencyException format:@"injected %@", operation];
  }
}

#pragma mark - FBAXRuntime

- (nullable id)applicationElementForProcessIdentifier:(pid_t)pid
{
  [self recordOperation:@"applicationElement"];
  return self.applicationElements[@(pid)];
}

- (FBAXDisplayInventoryOutcome *)displayInventory
{
  [self recordOperation:@"displayInventory"];
  return self.displayInventoryOutcome;
}

// The snapshot API's own keys, spelled here rather than shared with the service so a test fails if the
// service starts reading a different key than the runtime answers with.
static NSString *const kFakeSnapshotAttributes = @"UIAccessibilitySnapshotKeyAttributes";
static NSString *const kFakeSnapshotChildren = @"UIAccessibilitySnapshotKeyChildren";
static NSString *const kFakeSnapshotElement = @"UIAccessibilitySnapshotKeyElement";

// The attribute numbers this fake converts names to. Arbitrary, and deliberately not the runtime's:
// nothing above the seam may depend on a particular number, so a fake that used the real ones would let
// a hardcoded number pass.
static NSNumber *FBAXFakeAttributeNumber(NSUInteger index)
{
  return @(9000 + (NSInteger)index);
}

// Rebuilds one fake element as a snapshot node — attributes keyed by number, children nested under the
// snapshot's own key rather than exposed as an attribute, and the element itself under the element key.
//
// `ownerPid` is the owner of the element the snapshot is rooted at. A node another process draws is
// emitted with its attributes and none of its nesting — the live server serializes only what its own
// process owns — which is what lets a test construct the boundary the walk crosses and the snapshot
// stops at.
static NSDictionary *FBAXFakeSnapshotNode(FBAXFakeElement *element,
                                          NSDictionary<NSString *, NSNumber *> *numbersByName,
                                          pid_t ownerPid
)
{
  NSMutableDictionary *attributes = [NSMutableDictionary dictionary];
  for (NSString *name in element.attributes) {
    NSNumber *number = numbersByName[name];
    // Only what was asked for comes back, as the real snapshot does — an attribute outside the request
    // has no number, so it has no key to be answered under.
    if (number) {
      attributes[number] = element.attributes[name];
    }
  }
  NSMutableArray *children = [NSMutableArray array];
  if (element.owningProcessIdentifier == ownerPid) {
    for (FBAXFakeElement *child in element.children) {
      [children addObject:FBAXFakeSnapshotNode(child, numbersByName, ownerPid)];
    }
  }
  return @{
    kFakeSnapshotAttributes : attributes,
    kFakeSnapshotChildren : children,
    kFakeSnapshotElement : element,
  };
}

// The body both snapshot entry points share, once their own failure controls have had their say.
- (nullable id)snapshotRootedAtElement:(FBAXFakeElement *)element
                        attributeNames:(NSArray<NSString *> *)names
                         namesByNumber:(NSDictionary<NSNumber *, NSString *> *_Nullable *_Nonnull)namesByNumber
{
  NSUInteger fetchIndex = self.snapshotCount - 1;
  if (fetchIndex < self.snapshotResults.count) {
    *namesByNumber = fetchIndex < self.snapshotNameMappings.count ? self.snapshotNameMappings[fetchIndex] : nil;
    return self.snapshotResults[fetchIndex];
  }
  NSMutableDictionary<NSNumber *, NSString *> *inverse = [NSMutableDictionary dictionary];
  NSMutableDictionary<NSString *, NSNumber *> *forward = [NSMutableDictionary dictionary];
  [names enumerateObjectsUsingBlock:^(NSString *name, NSUInteger index, BOOL *stop) {
    NSNumber *number = FBAXFakeAttributeNumber(index);
    inverse[number] = name;
    forward[name] = number;
  }];
  *namesByNumber = inverse;
  return FBAXFakeSnapshotNode(element, forward, element.owningProcessIdentifier);
}

- (nullable id)snapshotOfElement:(id)element
                  attributeNames:(NSArray<NSString *> *)names
                   namesByNumber:(NSDictionary<NSNumber *, NSString *> *_Nullable *_Nonnull)namesByNumber
                           error:(NSError **)error
{
  [self recordOperation:@"snapshot"];
  _snapshotCount++;
  _lastSnapshotAttributeNames = [names copy];
  if (self.snapshotError) {
    if (error) {
      *error = self.snapshotError;
    }
    return nil;
  }
  if (self.snapshotAnswersNothing) {
    return nil;
  }
  return [self snapshotRootedAtElement:element attributeNames:names namesByNumber:namesByNumber];
}

- (pid_t)owningProcessIdentifierForSnapshotElement:(id)element
{
  [self recordOperation:@"snapshotOwner"];
  if (element) {
    [self.snapshotOwnerElements addObject:element];
  }
  if (![element isKindOfClass:FBAXFakeElement.class]) {
    return 0;
  }
  FBAXFakeElement *fake = element;
  if (fake.snapshotOwnerRaiseReason) {
    [NSException raise:NSInternalInconsistencyException format:@"%@", fake.snapshotOwnerRaiseReason];
  }
  return fake.owningProcessIdentifier;
}

- (FBXCUIElementType)elementTypeForAutomationType:(NSUInteger)automationType
{
  return (FBXCUIElementType)automationType;
}

- (pid_t)owningProcessIdentifierOfElement:(id)element
{
  return [element isKindOfClass:FBAXFakeElement.class] ? ((FBAXFakeElement *)element).owningProcessIdentifier : 0;
}

- (nullable id)snapshotOfSnapshotElement:(id)element
                          attributeNames:(NSArray<NSString *> *)names
                           namesByNumber:(NSDictionary<NSNumber *, NSString *> *_Nullable *_Nonnull)namesByNumber
                                   error:(NSError **)error
{
  [self recordOperation:@"snapshotContinuation"];
  _snapshotCount++;
  _lastSnapshotAttributeNames = [names copy];
  if (self.snapshotContinuationError) {
    if (error) {
      *error = self.snapshotContinuationError;
    }
    return nil;
  }
  if (self.snapshotContinuationAnswersNothing) {
    return nil;
  }
  return [self snapshotRootedAtElement:element attributeNames:names namesByNumber:namesByNumber];
}

- (BOOL)getRect:(CGRect *)rect fromValue:(id)value
{
  [self recordOperation:@"getRect"];
  // Only the sentinel unwraps; anything else answers NO and leaves `*rect` alone.
  if (!rect || ![value isKindOfClass:FBAXFakeRectValue.class]) {
    return NO;
  }
  *rect = ((FBAXFakeRectValue *)value).rect;
  return YES;
}

- (BOOL)getPoint:(CGPoint *)point fromValue:(id)value
{
  [self recordOperation:@"getPoint"];
  if (!point || ![value isKindOfClass:FBAXFakePointValue.class]) {
    return NO;
  }
  *point = ((FBAXFakePointValue *)value).point;
  return YES;
}

- (FBAXReadOutcome *)readAttributes:(NSArray<NSString *> *)attributes ofElement:(id)element
{
  [self recordOperation:@"readAttributes"];
  // Recorded before the outcome switch, so a read that fails still evidences what it asked for.
  _lastReadAttributes = [attributes copy];
  if (self.readOutcomes.count > 0) {
    FBAXReadOutcome *outcome = self.readOutcomes.firstObject;
    self.readOutcomes = [self.readOutcomes subarrayWithRange:NSMakeRange(1, self.readOutcomes.count - 1)];
    return outcome;
  }
  if (self.readRaiseReason) {
    [NSException raise:NSInternalInconsistencyException format:@"%@", self.readRaiseReason];
  }
  FBAXFakeElement *fake = element;
  if (fake.readRaiseReason) {
    [NSException raise:NSInternalInconsistencyException format:@"%@", fake.readRaiseReason];
  }
  switch (fake.readStatus) {
    case FBAXReadStatusRead:
      break;
    case FBAXReadStatusApplicationUnavailable:
      return [FBAXReadOutcome applicationUnavailable];
    case FBAXReadStatusApplicationNotResponding:
      return [FBAXReadOutcome applicationNotResponding];
    case FBAXReadStatusFailed:
    default:
      return [FBAXReadOutcome failed:fake.readError];
  }
  // Children come back as element handles, exactly as the live runtime returns them — the tree walk is
  // what turns them into nested dictionaries, and covering that is the point.
  FBAXGeometryDictionaryProbeValue *attributeRead = self.attributeRead;
  if (attributeRead) {
    return [FBAXReadOutcome read:attributeRead];
  }
  NSMutableDictionary<NSString *, id> *read = [fake.attributes mutableCopy];
  read[kAXChildren] = fake.children;
  return [FBAXReadOutcome read:read];
}

- (FBAXHitTestOutcome *)hitTestAtPoint:(CGPoint)point processIdentifier:(pid_t)pid
{
  [self recordOperation:@"hitTest"];
  _hitTestCount++;
  _lastHitTestPoint = point;
  _lastHitTestProcessIdentifier = pid;
  _lastHitTestDisplayIdentifier = nil;
  _lastHitTestClientType = nil;
  return self.hitTestOutcome;
}

- (FBAXHitTestOutcome *)hitTestAtPoint:(CGPoint)point
                     processIdentifier:(pid_t)pid
                     displayIdentifier:(uint32_t)displayID
                            clientType:(NSUInteger)clientType
{
  FBAXHitTestOutcome *outcome = [self hitTestAtPoint:point processIdentifier:pid];
  _lastHitTestDisplayIdentifier = @(displayID);
  _lastHitTestClientType = @(clientType);
  return outcome;
}

- (FBAXFrontmostOutcome *)windowServerFrontmostOnDisplay:(uint32_t)displayID
{
  FBAXFrontmostOutcome *outcome = [self windowServerFrontmost];
  _lastFrontmostDisplayIdentifier = @(displayID);
  return outcome;
}

- (FBAXWriteOutcome *)performAction:(FBAXAction)action onElement:(id)element
{
  [self recordOperation:@"performAction"];
  _performCount++;
  _lastPerformedAction = action;
  _lastWrittenElement = element;
  return self.writeOutcome;
}

- (FBAXWriteOutcome *)setValue:(id)value onElement:(id)element
{
  [self recordOperation:@"setValue"];
  _setValueCount++;
  _lastWrittenElement = element;
  _lastWrittenValue = value;
  return self.writeOutcome;
}

- (FBAXFrontmostOutcome *)windowServerFrontmost
{
  [self recordOperation:@"windowServerFrontmost"];
  _windowServerCount++;
  _lastFrontmostDisplayIdentifier = nil;
  return self.windowServerOutcome;
}

- (nullable NSDictionary<NSNumber *, id> *)translatorAttributes:(NSArray<NSNumber *> *)attributes
                                                      ofElement:(id)element
                                                     clientType:(NSUInteger)clientType
{
  [self recordOperation:@"translatorAttributes"];
  _translatorReadCount++;
  [self.translatorRequests addObject:@{@"attributes" : attributes, @"element" : element, @"clientType" : @(clientType)}];
  if (self.translatorRaiseAtRead == self.translatorReadCount) {
    [NSException raise:NSInternalInconsistencyException format:@"translator read %lu failed", (unsigned long)self.translatorReadCount];
  }
  NSUInteger responseIndex = self.translatorReadCount - 1;
  if (responseIndex < self.translatorResponses.count) {
    id response = self.translatorResponses[responseIndex];
    return response == NSNull.null ? nil : response;
  }
  return self.translatorAttributeValues;
}

- (FBAXFrontmostOutcome *)runningBoardFrontmost
{
  [self recordOperation:@"runningBoardFrontmost"];
  _runningBoardCount++;
  return self.runningBoardOutcome;
}

#pragma mark Automation mode

- (BOOL)automationModeEnabled
{
  [self recordOperation:@"automationRead"];
  return self.automationMode;
}

- (BOOL)setAutomationModeEnabled:(BOOL)enabled
{
  [self recordOperation:@"automationWrite"];
  [self.automationModeWrites addObject:@(enabled)];
  if (!self.automationModeWriteFails) {
    self.automationMode = enabled;
  }
  // Read back, exactly as the live runtime does: what a caller learns is the state afterwards, not that
  // the write was attempted.
  return self.automationMode;
}

#pragma mark Quiescence

- (nullable id<FBAXQuiescenceMonitor>)quiescenceMonitorWithHandler:(FBAXQuiescenceHandler)handler
                                                             error:(NSString *_Nullable *_Nullable)error
{
  [self recordOperation:@"quiescenceMonitor"];
  if (self.quiescenceMonitorError) {
    if (error) {
      *error = self.quiescenceMonitorError;
    }
    return nil;
  }
  FBAXFakeQuiescenceMonitor *monitor = [[FBAXFakeQuiescenceMonitor alloc] initWithHandler:handler];
  [self.quiescenceMonitors addObject:monitor];
  return monitor;
}

- (FBAXDeviceSettingMonitorOutcome *)monitorDeviceSettings:(NSArray<NSNumber *> *)settings handler:(void (^)(void))handler
{
  [self recordOperation:@"settingMonitor"];
  self.deviceSettingMonitoredSettings = [(self.deviceSettingMonitoredSettings ?: @[]) arrayByAddingObjectsFromArray:settings];
  FBAXDeviceSettingMonitorOutcome *monitorOutcome = self.deviceSettingMonitorOutcome;
  if (monitorOutcome) {
    return monitorOutcome;
  }
  for (NSNumber *setting in settings) {
    FBAXDeviceSettingMonitorOutcome *outcome = self.deviceSettingMonitorOutcomes[setting];
    if (outcome) {
      return outcome;
    }
  }
  FBAXFakeDeviceSettingMonitor *monitor = [FBAXFakeDeviceSettingMonitor new];
  monitor.handler = handler;
  for (NSNumber *setting in settings) {
    self.deviceSettingMonitors[setting] = monitor;
  }
  if ([settings containsObject:@(FBAXDeviceSettingReduceMotion)]) {
    self.deviceSettingMonitor = monitor;
  }
  return [FBAXDeviceSettingMonitorOutcome resolved:monitor];
}

- (FBAXDeviceSettingOutcome *)enabledStateForDeviceSetting:(FBAXDeviceSetting)setting
{
  [self recordOperation:@"settingRead"];
  FBAXDeviceSettingOutcome *readOutcome = self.deviceSettingReadOutcome;
  if (readOutcome) {
    return readOutcome;
  }
  NSNumber *enabled = self.deviceSettings[@(setting)];
  if (self.deviceSettingReadHandler) {
    self.deviceSettingReadHandler();
  }
  return enabled
  ? [FBAXDeviceSettingOutcome resolved:enabled.boolValue]
  : [FBAXDeviceSettingOutcome unavailable:@"setting unavailable"];
}

- (FBAXDeviceSettingOutcome *)setEnabled:(BOOL)enabled forDeviceSetting:(FBAXDeviceSetting)setting
{
  [self recordOperation:@"settingWrite"];
  if (!self.deviceSettings[@(setting)]) {
    return [FBAXDeviceSettingOutcome unavailable:@"setting unavailable"];
  }
  [self.deviceSettingWrites addObject:@{@"setting" : @(setting), @"enabled" : @(enabled)}];
  FBAXDeviceSettingOutcome *writeOutcome = self.deviceSettingWriteOutcome;
  if (writeOutcome) {
    return writeOutcome;
  }
  self.deviceSettings[@(setting)] = @(enabled);
  return [FBAXDeviceSettingOutcome resolved:enabled];
}

@end

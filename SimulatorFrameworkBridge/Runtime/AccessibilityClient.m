/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "AccessibilityClient.h"

#import "Private/AccessibilityElement_Private.h"

static void FBAXClientException(NSException *exception, NSError **error)
{
  NSLog(@"[AccessibilityService] answering a request raised: %@", exception);
  if (error) {
    *error = [NSError errorWithDomain:@"FBAXRuntimeException" code:1 userInfo:@{NSLocalizedDescriptionKey : exception.reason ?: exception.name}];
  }
}

@implementation FBAXElement
- (instancetype)initWithValue:(id)value
{
  self = [super init];
  if (self) {
    _value = value;
  }
  return self;
}

// Every read decodes fresh runtime elements, so identity is the runtime's equality (element ID), not the
// wrapper's pointer.
- (BOOL)isEqual:(id)object
{
  if (![object isKindOfClass:FBAXElement.class]) {
    return NO;
  }
  return [self.value isEqual:((FBAXElement *)object).value];
}

- (NSUInteger)hash
{
  return [self.value hash];
}

@end

@interface FBAXOptionalValue ()
- (instancetype)initWithValue:(nullable id)value;
@end

@implementation FBAXOptionalValue
- (instancetype)initWithValue:(id)value
{
  self = [super init];
  if (self) {
    _value = value;
  }
  return self;
}

@end

@interface FBAXElementHit ()
- (instancetype)initWithOutcome:(FBAXHitTestOutcome *)outcome;
@end

@implementation FBAXElementHit
- (instancetype)initWithOutcome:(FBAXHitTestOutcome *)outcome
{
  self = [super init];
  if (self) {
    _status = outcome.status;
    id element = outcome.element;
    _element = element ? [[FBAXElement alloc] initWithValue:element] : nil;
    _owningProcessIdentifier = outcome.owningProcessIdentifier;
    _failureReason = [outcome.failureReason copy];
    _axError = outcome.axError;
  }
  return self;
}

@end

@interface FBAXElementRead ()
- (instancetype)initWithOutcome:(FBAXReadOutcome *)outcome;
@end

@implementation FBAXElementRead
- (instancetype)initWithOutcome:(FBAXReadOutcome *)outcome
{
  self = [super init];
  if (self) {
    _status = outcome.status;
    if (outcome.attributes) {
      NSMutableDictionary *attributes = [NSMutableDictionary dictionary];
      for (id key in outcome.attributes) {
        attributes[key] = outcome.attributes[key];
      }
      _attributes = [attributes copy];
    }
    _error = outcome.error;
    _axError = outcome.axError;
  }
  return self;
}

- (NSArray<FBAXElement *> *)childrenWithError:(NSError **)error
{
  @try {
    id values = self.attributes[@"XC_kAXXCAttributeChildren"];
    if (![values isKindOfClass:NSArray.class]) {
      return @[];
    }
    NSMutableArray<FBAXElement *> *children = [NSMutableArray array];
    for (id value in values) {
      [children addObject:[[FBAXElement alloc] initWithValue:value]];
    }
    return children;
  } @catch (NSException *exception) {
    FBAXClientException(exception, error);
    return nil;
  }
}

@end

// Detach runtime containers under the caller's exception guard. Geometry metadata must survive too.
static id FBAXCopyAttributeContainers(id value)
{
  if ([value isKindOfClass:NSDictionary.class]) {
    NSMutableDictionary *snapshot = [NSMutableDictionary dictionary];
    for (id key in value) {
      snapshot[key] = FBAXCopyAttributeContainers(value[key]);
    }
    return [snapshot copy];
  }
  if ([value isKindOfClass:NSArray.class]) {
    NSMutableArray *snapshot = [NSMutableArray array];
    for (id item in value) {
      [snapshot addObject:FBAXCopyAttributeContainers(item)];
    }
    return [snapshot copy];
  }
  return value;
}

@interface FBAXQuiescenceMonitorClient ()
- (instancetype)initWithMonitor:(id<FBAXQuiescenceMonitor>)monitor;
@end

@implementation FBAXQuiescenceMonitorClient
{
  id<FBAXQuiescenceMonitor> _monitor;
}

- (instancetype)initWithMonitor:(id<FBAXQuiescenceMonitor>)monitor
{
  self = [super init];
  if (self) {
    _monitor = monitor;
  }
  return self;
}

- (FBAXWriteOutcome *)requestSignal:(FBAXQuiescenceSignal)signal fromApplication:(FBAXElement *)element error:(NSError **)error
{
  @try {
    return [_monitor requestSignal:signal fromApplication:element.value];
  } @catch (NSException *exception) {
    FBAXClientException(exception, error);
    return nil;
  }
}

- (void)invalidate
{
  @try {
    [_monitor invalidate];
  } @catch (NSException *exception) {
    FBAXClientException(exception, NULL);
  }
}

@end

@implementation FBAXClient
{
  id<FBAXRuntime> _runtime;
}

- (instancetype)initWithRuntime:(id<FBAXRuntime>)runtime
{
  self = [super init];
  if (self) {
    _runtime = runtime;
    _snapshots = [[FBAXSnapshotClient alloc] initWithRuntime:runtime];
  }
  return self;
}

- (FBAXOptionalValue<FBAXElement *> *)applicationElementForProcessIdentifier:(pid_t)pid error:(NSError **)error
{
  @try {
    id value = [_runtime applicationElementForProcessIdentifier:pid];
    FBAXElement *element = value ? [[FBAXElement alloc] initWithValue:value] : nil;
    return [[FBAXOptionalValue alloc] initWithValue:element];
  } @catch (NSException *exception) {
    FBAXClientException(exception, error);
    return nil;
  }
}

- (FBAXElementRead *)readAttributes:(NSArray<NSString *> *)attributes ofElement:(FBAXElement *)element error:(NSError **)error
{
  @try {
    return [[FBAXElementRead alloc] initWithOutcome:[_runtime readAttributes:attributes ofElement:element.value]];
  } @catch (NSException *exception) {
    FBAXClientException(exception, error);
    return nil;
  }
}

- (FBXCUIElementType)elementTypeForAutomationType:(NSUInteger)automationType
{
  return [_runtime elementTypeForAutomationType:automationType];
}

- (NSNumber *)owningProcessIdentifierOfElement:(FBAXElement *)element error:(NSError **)error
{
  @try {
    return @([_runtime owningProcessIdentifierOfElement:element.value]);
  } @catch (NSException *exception) {
    FBAXClientException(exception, error);
    return nil;
  }
}

- (FBAXElementHit *)hitTestAtPoint:(CGPoint)point processIdentifier:(pid_t)pid error:(NSError **)error
{
  @try {
    return [[FBAXElementHit alloc] initWithOutcome:[_runtime hitTestAtPoint:point processIdentifier:pid]];
  } @catch (NSException *exception) {
    FBAXClientException(exception, error);
    return nil;
  }
}

- (FBAXElementHit *)hitTestAtPoint:(CGPoint)point
                 processIdentifier:(pid_t)pid
                 displayIdentifier:(uint32_t)displayID
                        clientType:(NSUInteger)clientType
                             error:(NSError **)error
{
  @try {
    return [[FBAXElementHit alloc] initWithOutcome:[_runtime hitTestAtPoint:point processIdentifier:pid displayIdentifier:displayID clientType:clientType]];
  } @catch (NSException *exception) {
    FBAXClientException(exception, error);
    return nil;
  }
}

- (FBAXFrontmostOutcome *)windowServerFrontmostOnDisplay:(uint32_t)displayID error:(NSError **)error
{
  @try {
    return [_runtime windowServerFrontmostOnDisplay:displayID];
  } @catch (NSException *exception) {
    FBAXClientException(exception, error);
    return nil;
  }
}

- (FBAXWriteOutcome *)performAction:(FBAXAction)action onElement:(FBAXElement *)element error:(NSError **)error
{
  @try {
    return [_runtime performAction:action onElement:element.value];
  } @catch (NSException *exception) {
    FBAXClientException(exception, error);
    return nil;
  }
}

- (FBAXWriteOutcome *)setValue:(id)value onElement:(FBAXElement *)element error:(NSError **)error
{
  @try {
    return [_runtime setValue:value onElement:element.value];
  } @catch (NSException *exception) {
    FBAXClientException(exception, error);
    return nil;
  }
}

- (FBAXFrontmostOutcome *)windowServerFrontmostWithError:(NSError **)error
{
  @try {
    return [_runtime windowServerFrontmost];
  } @catch (NSException *exception) {
    FBAXClientException(exception, error);
    return nil;
  }
}

- (FBAXFrontmostOutcome *)runningBoardFrontmostWithError:(NSError **)error
{
  @try {
    return [_runtime runningBoardFrontmost];
  } @catch (NSException *exception) {
    FBAXClientException(exception, error);
    return nil;
  }
}

- (FBAXQuiescenceMonitorClient *)quiescenceMonitorWithHandler:(FBAXQuiescenceHandler)handler error:(NSError **)error
{
  @try {
    NSString *failure = nil;
    id<FBAXQuiescenceMonitor> monitor = [_runtime quiescenceMonitorWithHandler:handler error:&failure];
    if (!monitor) {
      if (error) {
        *error = [NSError errorWithDomain:@"FBAXQuiescence" code:1 userInfo:@{NSLocalizedDescriptionKey : failure ?: @"the runtime could not start a quiescence monitor"}];
      }
      return nil;
    }
    return [[FBAXQuiescenceMonitorClient alloc] initWithMonitor:monitor];
  } @catch (NSException *exception) {
    FBAXClientException(exception, error);
    return nil;
  }
}

- (NSNumber *)automationModeEnabledWithError:(NSError **)error
{
  @try {
    return @([_runtime automationModeEnabled]);
  } @catch (NSException *exception) {
    FBAXClientException(exception, error);
    return nil;
  }
}

- (NSNumber *)setAutomationModeEnabled:(BOOL)enabled error:(NSError **)error
{
  @try {
    return @([_runtime setAutomationModeEnabled:enabled]);
  } @catch (NSException *exception) {
    FBAXClientException(exception, error);
    return nil;
  }
}

- (FBAXDisplayInventoryOutcome *)displayInventory
{
  @try {
    return [_runtime displayInventory];
  } @catch (NSException *exception) {
    return [FBAXDisplayInventoryOutcome failed:[NSString stringWithFormat:@"the reader raised while answering: %@", exception.reason ?: exception.name]];
  }
}

- (FBAXDeviceSettingMonitorOutcome *)monitorDeviceSettings:(NSArray<NSNumber *> *)settings handler:(void (^)(void))handler
{
  @try {
    return [_runtime monitorDeviceSettings:settings handler:handler];
  } @catch (NSException *exception) {
    return [FBAXDeviceSettingMonitorOutcome failed:exception.reason ?: exception.name];
  }
}

- (FBAXDeviceSettingOutcome *)enabledStateForDeviceSetting:(FBAXDeviceSetting)setting error:(NSError **)error
{
  @try {
    return [_runtime enabledStateForDeviceSetting:setting];
  } @catch (NSException *exception) {
    FBAXClientException(exception, error);
    return nil;
  }
}

- (FBAXDeviceSettingOutcome *)setEnabled:(BOOL)enabled forDeviceSetting:(FBAXDeviceSetting)setting error:(NSError **)error
{
  @try {
    return [_runtime setEnabled:enabled forDeviceSetting:setting];
  } @catch (NSException *exception) {
    FBAXClientException(exception, error);
    return nil;
  }
}

- (FBAXOptionalValue<NSDictionary<NSNumber *, id> *> *)translatorAttributes:(NSArray<NSNumber *> *)attributes
                                                                  ofElement:(FBAXElement *)element
                                                                 clientType:(NSUInteger)clientType
                                                                      error:(NSError **)error
{
  @try {
    NSDictionary<NSNumber *, id> *values = [_runtime translatorAttributes:attributes ofElement:element.value clientType:clientType];
    return [[FBAXOptionalValue alloc] initWithValue:values ? FBAXCopyAttributeContainers(values) : nil];
  } @catch (NSException *exception) {
    FBAXClientException(exception, error);
    return nil;
  }
}

- (NSArray<FBAXElement *> *)translatorElements:(NSInteger)attribute
                                     ofElement:(FBAXElement *)element
                                    clientType:(NSUInteger)clientType
                                         error:(NSError **)error
{
  @try {
    NSDictionary<NSNumber *, id> *values = [_runtime translatorAttributes:@[@(attribute)] ofElement:element.value clientType:clientType];
    id list = values[@(attribute)];
    if (![list isKindOfClass:NSArray.class]) {
      return @[];
    }
    NSMutableArray<FBAXElement *> *elements = [NSMutableArray array];
    for (id value in list) {
      [elements addObject:[[FBAXElement alloc] initWithValue:value]];
    }
    return elements;
  } @catch (NSException *exception) {
    FBAXClientException(exception, error);
    return nil;
  }
}

- (FBAXOptionalValue<NSDictionary<NSString *, id> *> *)snapshotRectangleDictionary:(id)value error:(NSError **)error
{
  @try {
    CGRect geometry = CGRectZero;
    NSDictionary *snapshot = FBAXCopyAttributeContainers(value);
    BOOL valid = CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)snapshot, &geometry);
    return [[FBAXOptionalValue alloc] initWithValue:valid ? snapshot : nil];
  } @catch (NSException *exception) {
    FBAXClientException(exception, error);
    return nil;
  }
}

- (FBAXOptionalValue<NSDictionary<NSString *, id> *> *)snapshotPointDictionary:(id)value error:(NSError **)error
{
  @try {
    CGPoint geometry = CGPointZero;
    NSDictionary *snapshot = FBAXCopyAttributeContainers(value);
    BOOL valid = CGPointMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)snapshot, &geometry);
    return [[FBAXOptionalValue alloc] initWithValue:valid ? snapshot : nil];
  } @catch (NSException *exception) {
    FBAXClientException(exception, error);
    return nil;
  }
}

- (NSNumber *)matchesValue:(id)value expected:(NSString *)expected error:(NSError **)error
{
  @try {
    if ([value isKindOfClass:NSString.class]) {
      return @([value isEqualToString:expected]);
    }
    if (!value || value == NSNull.null) {
      return @NO;
    }
    return @([[value description] isEqualToString:expected]);
  } @catch (NSException *exception) {
    FBAXClientException(exception, error);
    return nil;
  }
}

- (FBAXOptionalValue<NSValue *> *)rectangleFromValue:(id)value error:(NSError **)error
{
  @try {
    CGRect geometry = CGRectZero;
    BOOL valid = NO;
    if ([value isKindOfClass:NSValue.class]) {
      if (strcmp([value objCType], @encode(CGRect)) == 0) {
        [value getValue:&geometry size:sizeof(geometry)];
        valid = YES;
      }
    } else {
      valid = [_runtime getRect:&geometry fromValue:value];
    }
    return [[FBAXOptionalValue alloc] initWithValue:valid ? [NSValue valueWithBytes:&geometry objCType:@encode(CGRect)] : nil];
  } @catch (NSException *exception) {
    FBAXClientException(exception, error);
    return nil;
  }
}

- (FBAXOptionalValue<NSValue *> *)pointFromValue:(id)value error:(NSError **)error
{
  @try {
    CGPoint geometry = CGPointZero;
    BOOL valid = NO;
    if ([value isKindOfClass:NSDictionary.class]) {
      valid = CGPointMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)value, &geometry);
    } else if ([value isKindOfClass:NSValue.class]) {
      if (strcmp([value objCType], @encode(CGPoint)) == 0) {
        [value getValue:&geometry size:sizeof(geometry)];
        valid = YES;
      }
    } else {
      valid = [_runtime getPoint:&geometry fromValue:value];
    }
    return [[FBAXOptionalValue alloc] initWithValue:valid ? [NSValue valueWithBytes:&geometry objCType:@encode(CGPoint)] : nil];
  } @catch (NSException *exception) {
    FBAXClientException(exception, error);
    return nil;
  }
}

- (FBAXOptionalValue<NSString *> *)descriptionOfValue:(id)value error:(NSError **)error
{
  @try {
    return [[FBAXOptionalValue alloc] initWithValue:[value description]];
  } @catch (NSException *exception) {
    FBAXClientException(exception, error);
    return nil;
  }
}

- (FBAXOptionalValue<NSString *> *)localizedDescriptionOfError:(NSError *)value error:(NSError **)error
{
  @try {
    return [[FBAXOptionalValue alloc] initWithValue:value.localizedDescription];
  } @catch (NSException *exception) {
    FBAXClientException(exception, error);
    return nil;
  }
}

@end

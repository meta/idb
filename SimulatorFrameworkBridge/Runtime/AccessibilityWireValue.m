/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "AccessibilityWireValue.h"

static void FBAXWireValueException(NSException *exception, NSError **error)
{
  NSLog(@"[AccessibilityService] answering a request raised: %@", exception);
  if (error) {
    *error = [NSError errorWithDomain:@"FBAXRuntimeException" code:1 userInfo:@{NSLocalizedDescriptionKey : exception.reason ?: exception.name}];
  }
}

static id FBAXWirePlainValue(id value)
{
  if (value == nil || value == NSNull.null) {
    return NSNull.null;
  }
  if ([value isKindOfClass:NSString.class]) {
    return [NSString stringWithString:value];
  }
  if ([value isKindOfClass:NSNumber.class]) {
    NSNumber *number = value;
    if (CFGetTypeID((__bridge CFTypeRef)number) == CFBooleanGetTypeID()) {
      return @(number.boolValue);
    }
    const char *type = number.objCType;
    if (strcmp(type, @encode(float)) == 0 || strcmp(type, @encode(double)) == 0) {
      return @(number.doubleValue);
    }
    if (strcmp(type, @encode(unsigned long long)) == 0 || strcmp(type, @encode(unsigned long)) == 0) {
      return @(number.unsignedLongLongValue);
    }
    return @(number.longLongValue);
  }
  if ([value isKindOfClass:NSDictionary.class]) {
    NSMutableDictionary *copy = [NSMutableDictionary dictionary];
    [(NSDictionary *)value
     enumerateKeysAndObjectsUsingBlock:^(id key, id object, __unused BOOL *stop) {
       copy[[key description]] = FBAXWirePlainValue(object);
     }];
    return copy;
  }
  if ([value isKindOfClass:NSArray.class]) {
    NSMutableArray *copy = [NSMutableArray array];
    for (id object in (NSArray *)value) {
      [copy addObject:FBAXWirePlainValue(object)];
    }
    return copy;
  }
  return [NSString stringWithFormat:@"%@", value];
}

@implementation FBAXWireValue

+ (id)plainValueOf:(id)value error:(NSError **)error
{
  @try {
    return FBAXWirePlainValue(value);
  } @catch (NSException *exception) {
    FBAXWireValueException(exception, error);
    return nil;
  }
}

+ (NSNumber *)booleanFromValue:(id)value error:(NSError **)error
{
  @try {
    return @([value boolValue]);
  } @catch (NSException *exception) {
    FBAXWireValueException(exception, error);
    return nil;
  }
}

+ (NSString *)formattedDescriptionOfValue:(id)value error:(NSError **)error
{
  @try {
    return [NSString stringWithFormat:@"%@", value];
  } @catch (NSException *exception) {
    FBAXWireValueException(exception, error);
    return nil;
  }
}

+ (NSNumber *)matchesStringValue:(id)value expected:(NSString *)expected error:(NSError **)error
{
  @try {
    return @([value isKindOfClass:NSString.class] && [value isEqualToString:expected]);
  } @catch (NSException *exception) {
    FBAXWireValueException(exception, error);
    return nil;
  }
}

@end

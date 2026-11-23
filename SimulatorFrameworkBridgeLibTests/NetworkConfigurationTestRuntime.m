/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "NetworkConfigurationTestRuntime.h"

#import <stdio.h>
#import <unistd.h>

#import <SimulatorFrameworkBridgeRuntime/SystemConfigurationLoader.h>

#import "../SimulatorFrameworkBridge/Runtime/Private/SystemConfigurationPrivate.h"

static FBNetworkConfigurationTestRuntime *runtime;

static SCDynStoreRef createStore(CFAllocatorRef allocator, CFStringRef name, void *callback, void *context)
{
  [runtime.operations addObject:[@"create:" stringByAppendingString:(__bridge NSString *)name]];
  return runtime.storeAvailable ? (void *)CFRetain(CFSTR("test store")) : NULL;
}

static CFStringRef createKey(CFAllocatorRef allocator)
{
  [runtime.operations addObject:@"key"];
  return CFRetain(CFSTR("State:/Network/Global/Proxies"));
}

static CFPropertyListRef copyValue(SCDynStoreRef store, CFStringRef key)
{
  [runtime.operations addObject:@"read"];
  [runtime.keys addObject:(__bridge NSString *)key];
  return runtime.configuration ? CFBridgingRetain(runtime.configuration) : NULL;
}

static Boolean setValue(SCDynStoreRef store, CFStringRef key, CFPropertyListRef value)
{
  [runtime.operations addObject:@"write"];
  [runtime.keys addObject:(__bridge NSString *)key];
  [runtime.writes addObject:(__bridge NSDictionary *)value];
  return runtime.writeSucceeds;
}

static Boolean notifyValue(SCDynStoreRef store, CFStringRef key)
{
  [runtime.operations addObject:@"notify"];
  [runtime.keys addObject:(__bridge NSString *)key];
  return runtime.notifySucceeds;
}

@implementation FBNetworkConfigurationTestRuntime

- (instancetype)init
{
  self = [super init];
  if (self) {
    _libraryAvailable = YES;
    _storeAvailable = YES;
    _writeSucceeds = YES;
    _notifySucceeds = YES;
    _missingSymbols = [NSSet set];
    _operations = [NSMutableArray array];
    _keys = [NSMutableArray array];
    _writes = [NSMutableArray array];
    _output = @"";
  }
  return self;
}

- (void)install
{
  runtime = self;
  FBSystemConfigurationSetLoaderForTesting(^void *{
    [runtime.operations addObject:@"load"];
    return runtime.libraryAvailable ? (__bridge void *)runtime : NULL;
  }, ^void *(void *library, const char *symbol) {
    NSString *name = [NSString stringWithUTF8String:symbol];
    [runtime.operations addObject:[@"lookup:" stringByAppendingString:name]];
    if ([runtime.missingSymbols containsObject:name]) {
      return NULL;
    }
    if ([name isEqualToString:@"SCDynamicStoreCreate"]) {
      return (void *)createStore;
    }
    if ([name isEqualToString:@"SCDynamicStoreKeyCreateProxies"]) {
      return (void *)createKey;
    }
    if ([name isEqualToString:@"SCDynamicStoreCopyValue"]) {
      return (void *)copyValue;
    }
    if ([name isEqualToString:@"SCDynamicStoreSetValue"]) {
      return (void *)setValue;
    }
    if ([name isEqualToString:@"SCDynamicStoreNotifyValue"]) {
      return (void *)notifyValue;
    }
    return NULL;
  });
}

- (void)uninstall
{
  FBSystemConfigurationSetLoaderForTesting(nil, nil);
  runtime = nil;
}

- (NSInteger)runService:(NSInteger (^NS_NOESCAPE)(void))service
{
  [self install];
  fflush(stdout);
  FILE *capture = tmpfile();
  int saved = dup(STDOUT_FILENO);
  NSAssert(capture && saved >= 0, @"Cannot capture service output");
  int redirected = dup2(fileno(capture), STDOUT_FILENO);
  NSAssert(redirected >= 0, @"Cannot redirect service output");
  @try {
    return service();
  } @finally {
    fflush(stdout);
    dup2(saved, STDOUT_FILENO);
    close(saved);
    rewind(capture);
    NSMutableData *data = [NSMutableData data];
    unsigned char buffer[1024];
    size_t count;
    while ((count = fread(buffer, 1, sizeof(buffer), capture)) > 0) {
      [data appendBytes:buffer length:count];
    }
    fclose(capture);
    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    _output = output;
    [self uninstall];
  }
}

@end

/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBXCTestMain.h"

#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "FBDebugLog.h"
#import "FBRuntimeTools.h"
#import "FBXCTestConstants.h"
#include "TargetConditionals.h"
#import "XCTestCaseHelpers.h"
#import "XCTestPrivate.h"
#import "XTSwizzle.h"

#if TARGET_OS_IPHONE
 #import <UIKit/UIKit.h>
#elif TARGET_OS_MAC
 #import <AppKit/AppKit.h>
#endif

__attribute__((constructor)) static void XCTestMainEntryPoint(void)
{
  FBDebugLog(@"[XCTestMainEntryPoint] Running inside: %@", [[NSBundle mainBundle] bundleIdentifier]);
  if (!NSProcessInfo.processInfo.environment[kEnv_ShimStartXCTest]) {
    FBDebugLog(@"[XCTestMainEntryPoint] %@ not present. Bye", kEnv_ShimStartXCTest);
    return;
  }
  if ([[[NSBundle mainBundle] bundleIdentifier] hasPrefix:@"com.apple.test"]) {
    FBDebugLog(@"[XCTestMainEntryPoint] Looks like I am running inside Apple's test runner app. Bye");
    return;
  }
  FBDebugLog(@"[XCTestMainEntryPoint] Hold back, trying to load test bundle");
  if (!FBXCTestMain()) {
    NSLog(@"[XCTestMainEntryPoint] Loading XCTest bundle failed, bye");
    exit(1);
  }
  FBDebugLog(@"[XCTestMainEntryPoint] End of XCTestMainEntryPoint");
}

static BOOL FBLoadXCTestIfNeeded(void)
{
  FBDebugLog(@"Env: %@", [NSProcessInfo processInfo].environment);

  if (objc_lookUpClass("XCTest")) {
    FBDebugLog(@"[XCTestMainEntryPoint] XCTest already loaded");
    return YES;
  }
  FBDebugLog(@"[XCTestMainEntryPoint] Loading XCTest framework");
  if (dlopen("XCTest.framework/XCTest", RTLD_LAZY)) {
    FBDebugLog(@"[XCTestMainEntryPoint] XCTest loaded");
    return YES;
  }
  FBDebugLog(@"[XCTestMainEntryPoint] Failed to load XCTest.framework. %@", [NSString stringWithUTF8String:dlerror()]);

  // Even though XCTest.framework actually is located in one of the `DYLD_FALLBACK_FRAMEWORK_PATH` directories, starting
  // on Xcode13.0/iOS15.0, dlopen does not look into those directories, failing to load XCTest.
  // As a last attempt, idb tries itself to find XCTest.framework and passes the absolute path to `dlopen`
  NSArray<NSString *> *fallbackFrameworkDirs = [[[NSProcessInfo processInfo].environment objectForKey:@"DYLD_FALLBACK_FRAMEWORK_PATH"] componentsSeparatedByString:@":"];

  FBDebugLog(@"[XCTestMainEntryPoint] Explicitly looking for XCTest.framework in DYLD_FALLBACK_FRAMEWORK_PATH: %@", fallbackFrameworkDirs);

  for (NSString *frameworkDir in fallbackFrameworkDirs) {
    NSString *possibleLocation = [frameworkDir stringByAppendingPathComponent:@"XCTest.framework/XCTest"];
    if ([NSFileManager.defaultManager fileExistsAtPath:possibleLocation isDirectory:nil]) {
      if (dlopen([possibleLocation cStringUsingEncoding:NSUTF8StringEncoding], RTLD_LAZY)) {
        FBDebugLog(@"[XCTestMainEntryPoint] Found and loaded XCTest from %@", possibleLocation);
        return YES;
      } else {
        FBDebugLog(@"[XCTestMainEntryPoint] Failed to load XCTest.framework. %@", [NSString stringWithUTF8String:dlerror()]);
      }
    } else {
      FBDebugLog(@"[XCTestMainEntryPoint] XCTest not found at %@", possibleLocation);
    }
  }
  FBDebugLog(@"[XCTestMainEntryPoint] Could not load XCTest.framework");
  return NO;
}

static void FBDeployBlockWhenAppLoads(void (^mainBlock)(void))
{
#if TARGET_OS_IPHONE
  NSString *notification = UIApplicationDidFinishLaunchingNotification;
#elif TARGET_OS_MAC
  NSString *notification = NSApplicationDidFinishLaunchingNotification;
#endif
  [[NSNotificationCenter defaultCenter]
   addObserverForName:notification
   object:nil
   queue:[NSOperationQueue mainQueue]
   usingBlock:^(__unused NSNotification *note) {
     mainBlock();
   }];
}

/// Construct an XCTTestIdentifier using the same logic used to list the tests.
/// The identifier will contain the swift module prefix for tests written in swift,
/// as they used to in Xcode versions prior to 15.0
static id XCTestCase__xctTestIdentifier(id self, __unused SEL sel)
{
  NSString *classNameOut = nil;
  NSString *methodNameOut = nil;
  NSString *testKeyOut = nil;
  parseXCTestCase(self, &classNameOut, &methodNameOut, &testKeyOut);

  Class XCTTestIdentifier_class = objc_lookUpClass("XCTTestIdentifier");
  return [[XCTTestIdentifier_class alloc] initWithStringRepresentation:[NSString stringWithFormat:@"%@/%@", classNameOut, methodNameOut] preserveModulePrefix:YES];
}

BOOL FBXCTestMain(void)
{
  if (!FBLoadXCTestIfNeeded()) {
    exit(TestShimExitCodeXCTestFailedLoading);
  }

  XTSwizzleSelectorForFunction(
    objc_getClass("XCTestCase"),
    @selector(_xctTestIdentifier),
    (IMP)XCTestCase__xctTestIdentifier
  );

  NSString *configurationPath = NSProcessInfo.processInfo.environment[@"XCTestConfigurationFilePath"];
  if (!configurationPath) {
    NSLog(@"Failed to load XCTest as XCTestConfigurationFilePath environment variable is empty");
    return NO;
  }
  NSError *error;
  NSData *data = [NSData dataWithContentsOfFile:configurationPath options:0 error:&error];
  if (!data) {
    NSLog(@"Failed to load data of %@ due to %@", configurationPath, error);
    return NO;
  }
  XCTestConfiguration *configuration = nil;
  if ([NSKeyedUnarchiver respondsToSelector:@selector(xct_unarchivedObjectOfClass:fromData:)]) {
    configuration = (XCTestConfiguration *)[NSKeyedUnarchiver xct_unarchivedObjectOfClass:NSClassFromString(@"XCTestConfiguration") fromData:data];
  } else {
    configuration = [NSKeyedUnarchiver unarchivedObjectOfClass:[NSString class] fromData:data error:&error];
  }
  if (!configuration) {
    NSLog(@"Loaded XCTestConfiguration is nil");
    return NO;
  }

  NSURL *testBundleURL = configuration.testBundleURL;
  if (!testBundleURL) {
    NSLog(@"XCTestConfiguration has no test bundle URL value");
    return NO;
  }

  NSBundle *testBundle = [NSBundle bundleWithURL:testBundleURL];
  if (!testBundle) {
    NSLog(@"Failed to open test bundle from %@", testBundleURL);
    return NO;
  }

  if (![testBundle loadAndReturnError:&error]) {
    NSLog(@"Failed load test bundle with error: %@", error);
    return NO;
  }
  void (*XCTestMain)(XCTestConfiguration *) = (void (*)(XCTestConfiguration *))FBRetrieveXCTestSymbol("_XCTestMain");
  FBDeployBlockWhenAppLoads(^{
    CFRunLoopPerformBlock([NSRunLoop mainRunLoop].getCFRunLoop,
      kCFRunLoopCommonModes, ^{
        XCTestMain(configuration);
      });
  });
  return YES;
}

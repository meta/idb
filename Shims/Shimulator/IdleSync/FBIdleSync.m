/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

// What keeps the process busy, observed from load in a process armed with `IDB_IDLE_SYNC=1`. README.md has the rules.

#import <TargetConditionals.h>

#import "FBIdleSyncTrackers.h"

#if TARGET_OS_IPHONE

 #import <objc/runtime.h>
 #import <stdatomic.h>
 #import <sys/time.h>

 #import <Foundation/Foundation.h>
 #import <QuartzCore/QuartzCore.h>

 #import <dispatch/dispatch.h>

const uint64_t FBIdleSyncDefaultBusyThresholdMs = 8;

// How long every condition must have stopped holding before the process counts as idle.
static const uint64_t FBIdleQuietWindowMs = 100;
// An animation longer than this is a spinner or a loop, which never ends while the UI waits.
static const double FBIdleLongestTrackedAnimationSeconds = 2.0;

// Main thread work shorter than this is a timer or a display link tick with nothing to show.
static _Atomic(uint64_t) sBusyThresholdMs = FBIdleSyncDefaultBusyThresholdMs;
static _Atomic(bool) sMainAwake = false;
static _Atomic(uint64_t) sMainWakeAtMs = 0;
static _Atomic(uint64_t) sMainLastWorkEndMs = 0;
static _Atomic(uint64_t) sAnimationsUntilMs = 0;

// Implemented by the Swift bootstrap, which runs the Shimulator client.
extern void FBIdleSyncStartClient(void);

static uint64_t FBIdleNowMs(void)
{
  struct timeval tv;
  gettimeofday(&tv, NULL);
  return (uint64_t)tv.tv_sec * 1000 + (uint64_t)tv.tv_usec / 1000;
}

static void FBIdleExtendAnimations(uint64_t untilMs)
{
  uint64_t current = atomic_load(&sAnimationsUntilMs);
  while (untilMs > current && !atomic_compare_exchange_weak(&sAnimationsUntilMs, &current, untilMs)) {}
}

 #pragma mark - Main run loop

static void FBIdleObserveMainRunLoop(void)
{
  CFRunLoopObserverRef observer = CFRunLoopObserverCreateWithHandler(
    kCFAllocatorDefault,
    kCFRunLoopAfterWaiting | kCFRunLoopBeforeWaiting,
    true,
    LONG_MAX,
    ^(CFRunLoopObserverRef _, CFRunLoopActivity activity) {
      uint64_t now = FBIdleNowMs();
      if (activity == kCFRunLoopAfterWaiting) {
        atomic_store(&sMainWakeAtMs, now);
        atomic_store(&sMainAwake, true);
      } else {
        // A wall clock that stepped back reads as no work, rather than as work that never ends.
        uint64_t wakeAt = atomic_load(&sMainWakeAtMs);
        if (now >= wakeAt && now - wakeAt >= atomic_load(&sBusyThresholdMs)) {
          atomic_store(&sMainLastWorkEndMs, now);
        }
        atomic_store(&sMainAwake, false);
      }
    });
  CFRunLoopAddObserver(CFRunLoopGetMain(), observer, kCFRunLoopCommonModes);
  CFRelease(observer);
}

 #pragma mark - Core Animation

static void (*sOriginalAddAnimation)(id, SEL, CAAnimation *, NSString *);

// 0 when the layer or an ancestor is paused: its time stands still, so its animations never end.
static double FBIdleEffectiveSpeed(CALayer *layer)
{
  double speed = 1;
  for (CALayer *ancestor = layer; ancestor != nil; ancestor = ancestor.superlayer) {
    speed *= ancestor.speed;
  }
  return speed;
}

static void FBIdleAddAnimation(CALayer *layer, SEL selector, CAAnimation *animation, NSString *key)
{
  sOriginalAddAnimation(layer, selector, animation, key);
  if (animation == nil) {
    return;
  }
  double duration = animation.duration > 0 ? animation.duration : [CATransaction animationDuration];
  if (duration <= 0) {
    duration = 0.25;
  }
  double total = duration;
  if (animation.repeatDuration > 0) {
    total = animation.repeatDuration;
  } else if (animation.repeatCount > 1) {
    total = duration * animation.repeatCount;
  }
  if (animation.autoreverses) {
    total *= 2;
  }
  double delay = animation.beginTime > 0 ? MAX(0, animation.beginTime - CACurrentMediaTime()) : 0;
  // A negative speed plays backwards, which takes as long.
  double speed = fabs(FBIdleEffectiveSpeed(layer) * animation.speed);
  if (!(speed > 0)) {
    return;
  }
  double seconds = (total + delay) / speed;
  if (!isfinite(seconds) || seconds > FBIdleLongestTrackedAnimationSeconds) {
    return;
  }
  FBIdleExtendAnimations(FBIdleNowMs() + (uint64_t)(seconds * 1000));
}

static void FBIdleObserveAnimations(void)
{
  Method method = class_getInstanceMethod([CALayer class], @selector(addAnimation:forKey:));
  // Set before the swap, so a call that races it never reaches an unset original.
  sOriginalAddAnimation = (void *)method_getImplementation(method);
  method_setImplementation(method, (IMP)FBIdleAddAnimation);
}

 #pragma mark - Sampling

FBIdleSyncSample FBIdleSyncSampleNow(void)
{
  uint64_t now = FBIdleNowMs();
  uint64_t wakeAt = atomic_load(&sMainWakeAtMs);
  // The observer can record a wake that began after `now` was read; that wake has done no work yet.
  bool working = atomic_load(&sMainAwake) && now > wakeAt && now - wakeAt >= atomic_load(&sBusyThresholdMs);
  uint64_t lastWorkEnd = atomic_load(&sMainLastWorkEndMs);
  uint64_t animationsUntil = atomic_load(&sAnimationsUntilMs);
  // Work that ended after `now` was read counts as within the settle window.
  FBIdleSyncSample sample = {
    .mainBusy = working || lastWorkEnd + FBIdleQuietWindowMs > now,
    .animating = animationsUntil + FBIdleQuietWindowMs > now,
    .idleSince = MAX(lastWorkEnd, animationsUntil) + FBIdleQuietWindowMs,
    .at = now,
  };
  return sample;
}

void FBIdleSyncSetBusyThreshold(uint64_t milliseconds)
{
  atomic_store(&sBusyThresholdMs, milliseconds);
}

 #pragma mark - Load

// Load time is the point: the hooks must be in place before the app's first frame. Unarmed, it returns at once.
// patternlint-disable-next-line static-initializer-constructor-attribute
__attribute__((constructor)) static void FBIdleSyncLoad(void)
{
  const char *armed = getenv("IDB_IDLE_SYNC");
  if (armed == NULL || strcmp(armed, "1") != 0) {
    return;
  }
  // The launch itself is busy until the first time the main thread goes to sleep, which the observer then sees.
  uint64_t now = FBIdleNowMs();
  atomic_store(&sMainWakeAtMs, now);
  atomic_store(&sMainLastWorkEndMs, now);
  atomic_store(&sMainAwake, true);
  @autoreleasepool {
    FBIdleObserveAnimations();
    // The main run loop observer is installed on the main thread once the app's run loop exists.
    dispatch_async(dispatch_get_main_queue(), ^{
      FBIdleObserveMainRunLoop();
    });
    FBIdleSyncStartClient();
  }
}

#endif

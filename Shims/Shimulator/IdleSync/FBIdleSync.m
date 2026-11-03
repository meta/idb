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
 #import <pthread.h>
 #import <stdatomic.h>
 #import <sys/time.h>

 #import <Foundation/Foundation.h>
 #import <QuartzCore/QuartzCore.h>
 #import <UIKit/UIKit.h>

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
static _Atomic(uint64_t) sLastScrollMs = 0;
// When the app last finished handling the end of a touch sequence or a key press, so a host that
// sent input can tell it has been handled.
static _Atomic(uint64_t) sLastInputMs = 0;
// Main thread time spent answering the host's own reads of the UI in the current wake: a read must
// not make the app look busy to the question asked right after it.
static _Atomic(uint64_t) sReadMsInWake = 0;
static _Atomic(uint64_t) sReadingSinceMs = 0;

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
        // A read happens within one wake, so none is in progress as a new one begins.
        atomic_store(&sReadingSinceMs, 0);
        atomic_store(&sReadMsInWake, 0);
        atomic_store(&sMainWakeAtMs, now);
        atomic_store(&sMainAwake, true);
      } else {
        // A wall clock that stepped back reads as no work, rather than as work that never ends.
        uint64_t wakeAt = atomic_load(&sMainWakeAtMs);
        uint64_t work = now > wakeAt ? now - wakeAt : 0;
        uint64_t read = atomic_load(&sReadMsInWake);
        work = work > read ? work - read : 0;
        atomic_store(&sReadMsInWake, 0);
        if (work >= atomic_load(&sBusyThresholdMs)) {
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

 #pragma mark - Host reads

// A host that reads the UI through the accessibility label of one of the app's own classes, built on the main
// thread, names it in `IDB_IDLE_SYNC_HOST_READ_CLASS`; that time is the host's, not the app's.
static id (*sOriginalDumpLabel)(id, SEL);

static id FBIdleDumpLabel(id dump, SEL selector)
{
  // Only a read on the main thread takes time from the main run loop's wake.
  if (pthread_main_np() == 0) {
    return sOriginalDumpLabel(dump, selector);
  }
  uint64_t start = FBIdleNowMs();
  atomic_store(&sReadingSinceMs, start);
  id label = nil;
  @try {
    label = sOriginalDumpLabel(dump, selector);
  } @finally {
    // A wall clock that stepped back during the read counts it as taking no time, which leaves the wake's work
    // counted. In progress is cleared before the read is added as finished, so a sample never counts it as both, and
    // it is cleared however the read ends.
    uint64_t end = FBIdleNowMs();
    atomic_store(&sReadingSinceMs, 0);
    atomic_fetch_add(&sReadMsInWake, end > start ? end - start : 0);
  }
  return label;
}

static void FBIdleObserveHostReads(void)
{
  const char *name = getenv("IDB_IDLE_SYNC_HOST_READ_CLASS");
  if (name == NULL || name[0] == '\0') {
    return;
  }
  // An app class the host names; the shim cannot link it.
  // patternlint-disable-next-line fb-link-class-from-string
  Class dumpClass = NSClassFromString(@(name));
  Method method = dumpClass == Nil ? NULL : class_getInstanceMethod(dumpClass, @selector(accessibilityLabel));
  if (method != NULL) {
    sOriginalDumpLabel = (void *)method_getImplementation(method);
    method_setImplementation(method, (IMP)FBIdleDumpLabel);
  }
}

 #pragma mark - Input

static void (*sOriginalSendEvent)(id, SEL, UIEvent *);

// Whether `event` ends a touch sequence or a key press: every touch or press in it has ended or been cancelled.
static bool FBIdleIsInputEnd(UIEvent *event)
{
  if (event.type == UIEventTypeTouches) {
    NSSet<UITouch *> *touches = event.allTouches;
    if (touches.count == 0) {
      return false;
    }
    for (UITouch *touch in touches) {
      if (touch.phase != UITouchPhaseEnded && touch.phase != UITouchPhaseCancelled) {
        return false;
      }
    }
    return true;
  }
  if (event.type == UIEventTypePresses && [event isKindOfClass:[UIPressesEvent class]]) {
    NSSet<UIPress *> *presses = ((UIPressesEvent *)event).allPresses;
    if (presses.count == 0) {
      return false;
    }
    for (UIPress *press in presses) {
      if (press.phase != UIPressPhaseEnded && press.phase != UIPressPhaseCancelled) {
        return false;
      }
    }
    return true;
  }
  return false;
}

static void FBIdleSendEvent(UIApplication *application, SEL selector, UIEvent *event)
{
  bool end = FBIdleIsInputEnd(event);
  sOriginalSendEvent(application, selector, event);
  if (end) {
    atomic_store(&sLastInputMs, FBIdleNowMs());
  }
}

static void FBIdleObserveInput(void)
{
  Method method = class_getInstanceMethod([UIApplication class], @selector(sendEvent:));
  if (method == NULL) {
    return;
  }
  sOriginalSendEvent = (void *)method_getImplementation(method);
  method_setImplementation(method, (IMP)FBIdleSendEvent);
}

 #pragma mark - Scrolling

static void (*sOriginalSetContentOffset)(id, SEL, CGPoint);

static void FBIdleSetContentOffset(id scrollView, SEL selector, CGPoint offset)
{
  CGPoint previous = [(UIScrollView *)scrollView contentOffset];
  sOriginalSetContentOffset(scrollView, selector, offset);
  // The offset the setter settled on, which may differ from the one asked for.
  CGPoint updated = [(UIScrollView *)scrollView contentOffset];
  if (!CGPointEqualToPoint(previous, updated) && [(UIScrollView *)scrollView window] != nil) {
    atomic_store(&sLastScrollMs, FBIdleNowMs());
  }
}

static void FBIdleObserveScrolling(void)
{
  Method method = class_getInstanceMethod([UIScrollView class], @selector(setContentOffset:));
  if (method == NULL) {
    return;
  }
  sOriginalSetContentOffset = (void *)method_getImplementation(method);
  method_setImplementation(method, (IMP)FBIdleSetContentOffset);
}

 #pragma mark - Sampling

FBIdleSyncSample FBIdleSyncSampleNow(void)
{
  uint64_t now = FBIdleNowMs();
  uint64_t wakeAt = atomic_load(&sMainWakeAtMs);
  // Main thread time in this wake, less the part spent serving a host read (finished or in progress).
  // Finished reads first: a read that finishes in between is counted at most once (`FBIdleDumpLabel` clears the
  // in-progress mark before adding it), and at worst not at all, which leaves its time counted as work.
  uint64_t finished = atomic_load(&sReadMsInWake);
  uint64_t readingSince = atomic_load(&sReadingSinceMs);
  uint64_t read = finished + (readingSince != 0 && now > readingSince ? now - readingSince : 0);
  // The observer can record a wake that began after `now` was read; that wake has done no work yet.
  uint64_t elapsed = now > wakeAt ? now - wakeAt : 0;
  bool working = atomic_load(&sMainAwake) && elapsed > read && elapsed - read >= atomic_load(&sBusyThresholdMs);
  uint64_t lastWorkEnd = atomic_load(&sMainLastWorkEndMs);
  uint64_t animationsUntil = atomic_load(&sAnimationsUntilMs);
  uint64_t lastScroll = atomic_load(&sLastScrollMs);
  // Each condition holds through the settle window after it last held; one that ended after `now` was read holds.
  FBIdleSyncSample sample = {
    .mainBusy = working || lastWorkEnd + FBIdleQuietWindowMs > now,
    .animating = animationsUntil + FBIdleQuietWindowMs > now,
    .scrolling = lastScroll + FBIdleQuietWindowMs > now,
    .lastInputAt = atomic_load(&sLastInputMs),
    .at = now,
  };
  sample.idleSince = MAX(MAX(lastWorkEnd, animationsUntil), lastScroll) + FBIdleQuietWindowMs;
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
    FBIdleObserveScrolling();
    FBIdleObserveInput();
    // The main run loop observer is installed on the main thread once the app's run loop exists.
    dispatch_async(dispatch_get_main_queue(), ^{
      FBIdleObserveHostReads();
      FBIdleObserveMainRunLoop();
    });
    FBIdleSyncStartClient();
  }
}

#endif

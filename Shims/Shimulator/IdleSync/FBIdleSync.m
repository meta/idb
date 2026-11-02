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

 #import <dlfcn.h>
 #import <mach/mach_time.h>
 #import <objc/runtime.h>
 #import <os/lock.h>
 #import <pthread.h>
 #import <stdatomic.h>
 #import <sys/time.h>

 #import <Foundation/Foundation.h>
 #import <QuartzCore/QuartzCore.h>
 #import <UIKit/UIKit.h>

 #import <dispatch/dispatch.h>
 #import <mach-o/dyld.h>
 #import <mach-o/getsect.h>

const uint64_t FBIdleSyncDefaultBusyThresholdMs = 8;

// How long every condition must have stopped holding before the process counts as idle.
static const uint64_t FBIdleQuietWindowMs = 100;
// An animation longer than this is a spinner or a loop, which never ends while the UI waits.
static const double FBIdleLongestTrackedAnimationSeconds = 2.0;
// Work scheduled on the main thread at most this far ahead (`dispatch_after`, `performSelector:afterDelay:`, a
// one-shot timer) is how an app shows something "shortly after"; the app stays busy until it has run.
static const double FBIdleLongestTrackedDelaySeconds = 1.5;
// One call site scheduling delayed work this many times within the window is a loop (a poll, a ticking label),
// which never ends while the UI waits, so it is no longer tracked.
static const uint32_t FBIdlePeriodicCount = 3;
static const uint64_t FBIdlePeriodicWindowMs = 5000;

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

 #pragma mark - Delayed work

static _Atomic(bool) sArmed = false;
static _Atomic(uint64_t) sDelayedWorkUntilMs = 0;

typedef struct {
  uintptr_t site;
  uint64_t windowStartMs;
  uint32_t count;
  // The last whole window showed a loop.
  bool periodic;
} FBIdleCallSite;

static os_unfair_lock sCallSitesLock = OS_UNFAIR_LOCK_INIT;
static FBIdleCallSite sCallSites[128];

// A site is a loop while its current window, or the whole window before it, holds more than the loop count, so a
// loop is not tracked again each time a window starts, and a site that slows down is tracked from its next window.
static bool FBIdleIsPeriodic(uintptr_t site, uint64_t now)
{
  os_unfair_lock_lock(&sCallSitesLock);
  FBIdleCallSite *entry = &sCallSites[(site >> 2) % (sizeof(sCallSites) / sizeof(sCallSites[0]))];
  if (entry->site != site || now < entry->windowStartMs) {
    entry->site = site;
    entry->windowStartMs = now;
    entry->count = 0;
    entry->periodic = false;
  } else if (now - entry->windowStartMs > FBIdlePeriodicWindowMs) {
    // A gap of a whole window after the last one means that window held nothing.
    entry->periodic = entry->count > FBIdlePeriodicCount && now - entry->windowStartMs <= 2 * FBIdlePeriodicWindowMs;
    entry->windowStartMs = now;
    entry->count = 0;
  }
  entry->count++;
  bool periodic = entry->periodic || entry->count > FBIdlePeriodicCount;
  os_unfair_lock_unlock(&sCallSitesLock);
  return periodic;
}

static void FBIdleNoteDelayedWork(double delaySeconds, uintptr_t site)
{
  if (!atomic_load(&sArmed) || !(delaySeconds > 0) || delaySeconds > FBIdleLongestTrackedDelaySeconds) {
    return;
  }
  uint64_t now = FBIdleNowMs();
  if (FBIdleIsPeriodic(site, now)) {
    return;
  }
  // A timer may fire up to a tenth of its delay late (libdispatch's default leeway).
  uint64_t until = now + (uint64_t)(delaySeconds * 1100) + 1;
  uint64_t current = atomic_load(&sDelayedWorkUntilMs);
  while (until > current && !atomic_compare_exchange_weak(&sDelayedWorkUntilMs, &current, until)) {}
}

// Set at load, before any delayed work is noted.
static mach_timebase_info_data_t sTimebase = {1, 1};

// Seconds until `when`, or -1 for a time on another clock (wall time) or never.
static double FBIdleSecondsUntil(dispatch_time_t when)
{
  if (when == DISPATCH_TIME_FOREVER) {
    return -1;
  }
  dispatch_time_t now = dispatch_time(DISPATCH_TIME_NOW, 0);
  // The top two bits name the clock (wall, monotonic, uptime); only compare like with like.
  const uint64_t clockBits = 3ULL << 62;
  if ((when & clockBits) != (now & clockBits) || when <= now) {
    return -1;
  }
  uint64_t ticks = (when & ~clockBits) - (now & ~clockBits);
  return (double)ticks * sTimebase.numer / sTimebase.denom / NSEC_PER_SEC;
}

typedef void (*FBIdleDispatchAfterFunction)(dispatch_time_t, dispatch_queue_t, dispatch_block_t);
typedef void (*FBIdleDispatchAfterFFunction)(dispatch_time_t, dispatch_queue_t, void *, dispatch_function_t);

static void FBIdleDispatchAfter(dispatch_time_t when, dispatch_queue_t queue, dispatch_block_t block);
static void FBIdleDispatchAfterF(dispatch_time_t when, dispatch_queue_t queue, void *context, dispatch_function_t work);

// libdispatch's implementations. dyld points every other image's references at the wrappers, and rewrites `dlsym`
// results the same way, but leaves the shim's own references to libdispatch: a lookup that returns a wrapper is
// discarded, and the direct symbols stand in for it and until `FBIdleResolveDispatchAfter` runs.
static _Atomic(FBIdleDispatchAfterFunction) sOriginalDispatchAfter = dispatch_after;
static _Atomic(FBIdleDispatchAfterFFunction) sOriginalDispatchAfterF = dispatch_after_f;

static void FBIdleResolveDispatchAfter(void)
{
  FBIdleDispatchAfterFunction after = (FBIdleDispatchAfterFunction)dlsym(RTLD_NEXT, "dispatch_after");
  if (after != NULL && after != FBIdleDispatchAfter) {
    atomic_store(&sOriginalDispatchAfter, after);
  }
  FBIdleDispatchAfterFFunction afterF = (FBIdleDispatchAfterFFunction)dlsym(RTLD_NEXT, "dispatch_after_f");
  if (afterF != NULL && afterF != FBIdleDispatchAfterF) {
    atomic_store(&sOriginalDispatchAfterF, afterF);
  }
}

// A call site is where the work was scheduled and what it runs, so callers that share one scheduling helper (a
// wrapper, a reactive scheduler) are told apart by their work.
struct FBIdleBlockLayout {
  void *isa;
  int32_t flags;
  int32_t reserved;
  void *invoke;
};

static uintptr_t FBIdleSite(uintptr_t caller, uintptr_t work)
{
  return caller ^ (work * 0x9E3779B97F4A7C15ULL);
}

static uintptr_t FBIdleBlockWork(const void *block)
{
  return block == NULL ? 0 : (uintptr_t)((const struct FBIdleBlockLayout *)block)->invoke;
}

static uintptr_t FBIdleSelectorWork(id target, SEL action)
{
  return (uintptr_t)object_getClass(target) ^ (uintptr_t)sel_getName(action);
}

// Swift's `DispatchQueue.asyncAfter` calls `dispatch_after` from the Swift Dispatch library, so every Swift caller
// would share one return address there; the call site is that function's caller.
static _Atomic(uintptr_t) sSwiftDispatchTextStart = 0;
static _Atomic(uintptr_t) sSwiftDispatchTextEnd = 0;

static void FBIdleNoteImage(const struct mach_header *header, intptr_t slide)
{
  Dl_info info;
  if (atomic_load(&sSwiftDispatchTextEnd) != 0 || dladdr(header, &info) == 0 || info.dli_fname == NULL) {
    return;
  }
  const char *name = strrchr(info.dli_fname, '/');
  if (name == NULL || strcmp(name + 1, "libswiftDispatch.dylib") != 0) {
    return;
  }
  unsigned long size = 0;
  uint8_t *text = getsegmentdata((const struct mach_header_64 *)header, "__TEXT", &size);
  if (text != NULL) {
    atomic_store(&sSwiftDispatchTextStart, (uintptr_t)text);
    atomic_store(&sSwiftDispatchTextEnd, (uintptr_t)text + size);
  }
}

static bool FBIdleIsInSwiftDispatch(uintptr_t address)
{
  return address >= atomic_load(&sSwiftDispatchTextStart) && address < atomic_load(&sSwiftDispatchTextEnd);
}

// The caller's caller is read only when the caller is the Swift Dispatch library, whose frames keep a frame pointer.
 #pragma clang diagnostic push
 #pragma clang diagnostic ignored "-Wframe-address"

static void FBIdleDispatchAfter(dispatch_time_t when, dispatch_queue_t queue, dispatch_block_t block)
{
  if (atomic_load(&sArmed) && queue == dispatch_get_main_queue()) {
    uintptr_t site = (uintptr_t)__builtin_return_address(0);
    if (FBIdleIsInSwiftDispatch(site)) {
      site = (uintptr_t)__builtin_return_address(1);
    }
    FBIdleNoteDelayedWork(FBIdleSecondsUntil(when), FBIdleSite(site, FBIdleBlockWork((const void *)block)));
  }
  atomic_load(&sOriginalDispatchAfter)(when, queue, block);
}

static void FBIdleDispatchAfterF(dispatch_time_t when, dispatch_queue_t queue, void *context, dispatch_function_t work)
{
  if (atomic_load(&sArmed) && queue == dispatch_get_main_queue()) {
    uintptr_t site = (uintptr_t)__builtin_return_address(0);
    if (FBIdleIsInSwiftDispatch(site)) {
      site = (uintptr_t)__builtin_return_address(1);
    }
    FBIdleNoteDelayedWork(FBIdleSecondsUntil(when), FBIdleSite(site, (uintptr_t)work));
  }
  atomic_load(&sOriginalDispatchAfterF)(when, queue, context, work);
}

 #pragma clang diagnostic pop

// Calls from the app reach these.
__attribute__((used, section("__DATA,__interpose"))) static const void *const FBIdleInterposeDispatchAfter[2] = {
  (const void *)FBIdleDispatchAfter, (const void *)dispatch_after
};
__attribute__((used, section("__DATA,__interpose"))) static const void *const FBIdleInterposeDispatchAfterF[2] = {
  (const void *)FBIdleDispatchAfterF, (const void *)dispatch_after_f
};

static void (*sOriginalPerformAfterDelay)(id, SEL, SEL, id, NSTimeInterval);
static void (*sOriginalPerformAfterDelayInModes)(id, SEL, SEL, id, NSTimeInterval, NSArray *);

static void FBIdlePerformAfterDelay(id target, SEL selector, SEL action, id argument, NSTimeInterval delay)
{
  if ([NSThread isMainThread]) {
    FBIdleNoteDelayedWork(delay, FBIdleSite((uintptr_t)__builtin_return_address(0), FBIdleSelectorWork(target, action)));
  }
  sOriginalPerformAfterDelay(target, selector, action, argument, delay);
}

static void FBIdlePerformAfterDelayInModes(id target, SEL selector, SEL action, id argument, NSTimeInterval delay, NSArray *modes)
{
  if ([NSThread isMainThread]) {
    FBIdleNoteDelayedWork(delay, FBIdleSite((uintptr_t)__builtin_return_address(0), FBIdleSelectorWork(target, action)));
  }
  sOriginalPerformAfterDelayInModes(target, selector, action, argument, delay, modes);
}

static NSTimer *(*sOriginalScheduledTimerWithBlock)(id, SEL, NSTimeInterval, BOOL, void (^)(NSTimer *));
static NSTimer *(*sOriginalScheduledTimerWithTarget)(id, SEL, NSTimeInterval, id, SEL, id, BOOL);

static NSTimer *FBIdleScheduledTimerWithBlock(id cls, SEL selector, NSTimeInterval interval, BOOL repeats, void (^block)(NSTimer *))
{
  if (!repeats && [NSThread isMainThread]) {
    FBIdleNoteDelayedWork(interval, FBIdleSite((uintptr_t)__builtin_return_address(0), FBIdleBlockWork((const void *)block)));
  }
  return sOriginalScheduledTimerWithBlock(cls, selector, interval, repeats, block);
}

static NSTimer *FBIdleScheduledTimerWithTarget(id cls, SEL selector, NSTimeInterval interval, id target, SEL action, id userInfo, BOOL repeats)
{
  if (!repeats && [NSThread isMainThread]) {
    FBIdleNoteDelayedWork(interval, FBIdleSite((uintptr_t)__builtin_return_address(0), FBIdleSelectorWork(target, action)));
  }
  return sOriginalScheduledTimerWithTarget(cls, selector, interval, target, action, userInfo, repeats);
}

static void FBIdleObserveDelayedWork(void)
{
  // Each original is stored before its replacement is installed, and a method that is missing is left alone.
  Method perform = class_getInstanceMethod([NSObject class], @selector(performSelector:withObject:afterDelay:));
  if (perform != NULL) {
    sOriginalPerformAfterDelay = (void *)method_getImplementation(perform);
    method_setImplementation(perform, (IMP)FBIdlePerformAfterDelay);
  }
  Method performInModes = class_getInstanceMethod([NSObject class], @selector(performSelector:withObject:afterDelay:inModes:));
  if (performInModes != NULL) {
    sOriginalPerformAfterDelayInModes = (void *)method_getImplementation(performInModes);
    method_setImplementation(performInModes, (IMP)FBIdlePerformAfterDelayInModes);
  }
  Method blockTimer = class_getClassMethod([NSTimer class], @selector(scheduledTimerWithTimeInterval:repeats:block:));
  if (blockTimer != NULL) {
    sOriginalScheduledTimerWithBlock = (void *)method_getImplementation(blockTimer);
    method_setImplementation(blockTimer, (IMP)FBIdleScheduledTimerWithBlock);
  }
  Method targetTimer = class_getClassMethod([NSTimer class], @selector(scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:));
  if (targetTimer != NULL) {
    sOriginalScheduledTimerWithTarget = (void *)method_getImplementation(targetTimer);
    method_setImplementation(targetTimer, (IMP)FBIdleScheduledTimerWithTarget);
  }
  // Called at once for every image already loaded, then for each one loaded later.
  _dyld_register_func_for_add_image(FBIdleNoteImage);
  atomic_store(&sArmed, true);
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
  uint64_t delayedUntil = atomic_load(&sDelayedWorkUntilMs);
  // Each condition holds through the settle window after it last held; one that ended after `now` was read holds.
  FBIdleSyncSample sample = {
    .mainBusy = working || lastWorkEnd + FBIdleQuietWindowMs > now,
    .animating = animationsUntil + FBIdleQuietWindowMs > now,
    .scrolling = lastScroll + FBIdleQuietWindowMs > now,
    .delayed = delayedUntil + FBIdleQuietWindowMs > now,
    .lastInputAt = atomic_load(&sLastInputMs),
    .at = now,
  };
  sample.idleSince = MAX(MAX(lastWorkEnd, animationsUntil), MAX(lastScroll, delayedUntil)) + FBIdleQuietWindowMs;
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
  // The interposed wrappers are live in every process the shim is loaded into, armed or not.
  FBIdleResolveDispatchAfter();
  const char *armed = getenv("IDB_IDLE_SYNC");
  if (armed == NULL || strcmp(armed, "1") != 0) {
    return;
  }
  // The launch itself is busy until the first time the main thread goes to sleep, which the observer then sees.
  uint64_t now = FBIdleNowMs();
  atomic_store(&sMainWakeAtMs, now);
  atomic_store(&sMainLastWorkEndMs, now);
  atomic_store(&sMainAwake, true);
  mach_timebase_info(&sTimebase);
  @autoreleasepool {
    FBIdleObserveAnimations();
    FBIdleObserveScrolling();
    FBIdleObserveInput();
    FBIdleObserveDelayedWork();
    // The main run loop observer is installed on the main thread once the app's run loop exists.
    dispatch_async(dispatch_get_main_queue(), ^{
      FBIdleObserveHostReads();
      FBIdleObserveMainRunLoop();
    });
    FBIdleSyncStartClient();
  }
}

#endif

/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <stdbool.h>
#import <stdint.h>

// The trackers behind the Shimulator `idle` capability: what keeps this process busy. README.md has the rules.

typedef struct {
  // The main thread is in, or has finished within the settle window, work longer than the busy threshold.
  bool mainBusy;
  // A tracked Core Animation animation is running, or ended within the settle window.
  bool animating;
  // A scroll view in a window moved its content within the settle window.
  bool scrolling;
  // Main-thread work the app scheduled to run shortly (`dispatch_after`, `performSelector:afterDelay:`, a one-shot
  // timer) is pending.
  bool delayed;
  // Wall-clock milliseconds when the process last finished handling the end of a touch sequence or a key press, or 0
  // if it never has.
  uint64_t lastInputAt;
  // Wall-clock milliseconds when the settle window after the last of these ended: when the current idle period
  // began, as observed from load. Meaningful only while none holds.
  uint64_t idleSince;
  // Wall-clock milliseconds when the sample was taken.
  uint64_t at;
} FBIdleSyncSample;

// What keeps the process busy now. Everything reads idle in a process that was not armed.
FBIdleSyncSample FBIdleSyncSampleNow(void);

// Main-thread work shorter than this does not make the process busy; `FBIdleSyncDefaultBusyThresholdMs` until set.
void FBIdleSyncSetBusyThreshold(uint64_t milliseconds);

extern const uint64_t FBIdleSyncDefaultBusyThresholdMs;

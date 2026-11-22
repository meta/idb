/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

// The accessibility runtime as one interface. `FBAXRuntime` states everything the reader needs from the
// four private frameworks (XCTAutomationSupport, AXRuntime, AccessibilityPlatformTranslation,
// RunningBoardServices); `FBAXLiveRuntime` is the only conformer that touches them. Above the seam is
// policy; below it are the dlopens, class lookups, C entry points and reference counting.
//
// Results are tagged unions built only through their factories, so a status and its payload cannot
// disagree, and a `switch` over the status warns on an unhandled case.

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * How long the live runtime waits for an application to reply to any one accessibility message before
 * reporting it as not responding. Set once for this process, so it bounds reads, hit-tests and writes alike.
 */
extern const float FBAXMessagingTimeoutSeconds;

#pragma mark - Reads

/** How a read of an element's attributes turned out. */
typedef NS_ENUM(NSUInteger, FBAXReadStatus) {
  /** The element was read; `attributes` holds what it said. */
  FBAXReadStatusRead,
  /** The owning process has no accessibility server to answer the read. */
  FBAXReadStatusApplicationUnavailable,
  /** The owning process has an accessibility server that did not answer in time. */
  FBAXReadStatusApplicationNotResponding,
  /** The read went wrong; `error` holds why, if the runtime said. */
  FBAXReadStatusFailed,
};

/**
 * The result of reading an element.
 *
 * A read names an element that already exists, so there is no "nothing there" case — an element that
 * cannot be read either belongs to an unreadable application or failed outright.
 */
@interface FBAXReadOutcome : NSObject

@property (nonatomic, readonly) FBAXReadStatus status;
/** The attributes read, with children nested under the children key. Non-nil iff `Read`. */
@property (nullable, nonatomic, readonly, copy) NSDictionary<NSString *, id> *attributes;
/** Why the read failed. Only meaningful when `Failed`, and nil when the runtime reported no error. */
@property (nullable, nonatomic, readonly) NSError *error;
/** The AXError `error` carries, when it carries one. */
@property (nullable, nonatomic, readonly) NSNumber *axError;

+ (instancetype)read:(NSDictionary<NSString *, id> *)attributes;
+ (instancetype)applicationUnavailable;
+ (instancetype)applicationNotResponding;
+ (instancetype)failed:(nullable NSError *)error;

/**
 * Classifies a failed `-[XCTAccessibilityFramework attributesForElement:attributes:error:]` into
 * `ApplicationUnavailable`, `ApplicationNotResponding` or `Failed`, from the FBAXError the reader
 * reported under FBAXAccessibilityErrorKey.
 */
+ (instancetype)failureForAttributeError:(nullable NSError *)error;

@end

#pragma mark - Hit-tests

/** How a hit-test at a point turned out. */
/**
 * XCTest's public `XCUIElementType`, restated for the cases the bridge names because the guest does not
 * link XCTest. The values are copied from `XCUIAutomation.framework/Headers/XCUIElementTypes.h` in the
 * simulator platform's `Developer/Library/Frameworks` (XCTest's own `XCUIElementTypes.h` forwards there),
 * which states every case's value explicitly.
 */
typedef NS_ENUM(NSUInteger, FBXCUIElementType) {
  FBXCUIElementTypeAny = 0,
  FBXCUIElementTypeOther = 1,
  FBXCUIElementTypeButton = 9,
  FBXCUIElementTypeRadioButton = 10,
  FBXCUIElementTypeCheckBox = 12,
  FBXCUIElementTypeDisclosureTriangle = 13,
  FBXCUIElementTypePopUpButton = 14,
  FBXCUIElementTypeKey = 20,
  FBXCUIElementTypeSlider = 33,
  FBXCUIElementTypeSegmentedControl = 37,
  FBXCUIElementTypePicker = 38,
  FBXCUIElementTypePickerWheel = 39,
  FBXCUIElementTypeSwitch = 40,
  FBXCUIElementTypeToggle = 41,
  FBXCUIElementTypeLink = 42,
  FBXCUIElementTypeSearchField = 45,
  FBXCUIElementTypeTextField = 49,
  FBXCUIElementTypeSecureTextField = 50,
  FBXCUIElementTypeTextView = 52,
  FBXCUIElementTypeMenuItem = 54,
  FBXCUIElementTypeStepper = 79,
  FBXCUIElementTypeTab = 80,
};

typedef NS_ENUM(NSUInteger, FBAXHitTestStatus) {
  /** An element owns the point; `element` and `owningProcessIdentifier` describe it. */
  FBAXHitTestStatusHit,
  /** Nothing is at the point — a valid result, distinct from the hit-test having gone wrong. */
  FBAXHitTestStatusEmpty,
  /** Nothing answered the hit-test: the process has no accessibility server. */
  FBAXHitTestStatusApplicationUnavailable,
  /**
   * The process has an accessibility server that did not answer in time. Distinct from `Empty`: a busy or
   * suspended app reads as blank space, which is what a caller sees after a tap it is still processing.
   */
  FBAXHitTestStatusApplicationNotResponding,
  /** The hit-test went wrong; `failureReason` says how. */
  FBAXHitTestStatusFailed,
};

/**
 * The result of hit-testing a point.
 *
 * The hit element is vended already wrapped: the raw +1 AXUIElementRef the AX runtime copies out never
 * escapes the runtime that asked for it, so no caller can outlive or over-release it.
 */
@interface FBAXHitTestOutcome : NSObject

@property (nonatomic, readonly) FBAXHitTestStatus status;
/** An opaque handle to the element at the point, readable only through the runtime. Non-nil iff `Hit`. */
@property (nullable, nonatomic, readonly) id element;
/** The process owning `element`, always positive when `Hit`. */
@property (nonatomic, readonly) pid_t owningProcessIdentifier;
/** A diagnostic for the caller. Non-nil iff `Failed`. */
@property (nullable, nonatomic, readonly, copy) NSString *failureReason;
/** The AXError the runtime failed with, when `Failed` came from one. */
@property (nullable, nonatomic, readonly) NSNumber *axError;

+ (instancetype)hit:(id)element owningProcessIdentifier:(pid_t)pid;
+ (instancetype)empty;
+ (instancetype)applicationUnavailable;
+ (instancetype)applicationNotResponding;
+ (instancetype)failed:(NSString *)failureReason;
+ (instancetype)failedWithAXError:(int32_t)axError;

/**
 * Classifies the AXError from `AXUIElementCopyElementAtPosition`, given whether it also produced an
 * element, into the outcome that error implies. The wording of what the caller is eventually told is
 * the caller's — this decides only which of the four things happened.
 *
 * Returns nil — and only then — when the point resolved to an element the caller should go on to
 * attribute and wrap. Every other answer is complete, so a caller that gets non-nil is done.
 */
+ (nullable instancetype)outcomeForHitTestError:(int32_t)axError hasElement:(BOOL)hasElement;

@end

#pragma mark - Writes

/**
 * A semantic action, independent of the AX runtime's numbering (mapped once in `FBAXLiveRuntime`).
 * Only actions with a caller are listed.
 */
typedef NS_ENUM(NSUInteger, FBAXAction) {
  /** Activate the element — the semantic equivalent of tapping it. */
  FBAXActionPress,
  FBAXActionScrollUp,
  FBAXActionScrollDown,
  FBAXActionScrollLeft,
  FBAXActionScrollRight,
  /** Bring the element into its scroll container's viewport. */
  FBAXActionScrollToVisible,
};

/** How a write to an element turned out. */
typedef NS_ENUM(NSUInteger, FBAXWriteStatus) {
  /** The application accepted the write. */
  FBAXWriteStatusWritten,
  /** Nothing was at the point, so there was nothing to write to — a valid result, not a failure. */
  FBAXWriteStatusEmpty,
  /** The element at the point is not the one the caller named; `failureReason` says how it differed. */
  FBAXWriteStatusAssertionFailed,
  /** The owning process has no accessibility server to accept the write. */
  FBAXWriteStatusApplicationUnavailable,
  /** It has one and did not answer in time, so whether the write ran is unknown. */
  FBAXWriteStatusApplicationNotResponding,
  /** The write went wrong; `failureReason` says how. */
  FBAXWriteStatusFailed,
};

/**
 * The result of a write. `Empty` and `AssertionFailed` are decided before the runtime is asked; the
 * other four are what an AXError from the runtime can mean.
 */
@interface FBAXWriteOutcome : NSObject

@property (nonatomic, readonly) FBAXWriteStatus status;
/** A diagnostic for the caller. Non-nil iff `AssertionFailed` or `Failed`. */
@property (nullable, nonatomic, readonly, copy) NSString *failureReason;
/** The AXError the runtime failed with, when `Failed` came from one. */
@property (nullable, nonatomic, readonly) NSNumber *axError;

+ (instancetype)written;
+ (instancetype)empty;
+ (instancetype)assertionFailed:(NSString *)failureReason;
+ (instancetype)applicationUnavailable;
+ (instancetype)applicationNotResponding;
+ (instancetype)failed:(NSString *)failureReason;
+ (instancetype)failed:(NSString *)failureReason axError:(nullable NSNumber *)axError;
+ (instancetype)failedWithAXError:(int32_t)axError;

/**
 * Classifies the AXError from `AXUIElementPerformAction` or `AXUIElementSetAttributeValue`, including
 * success. Total: a write either happened or it did not.
 *
 * There is no "element does not accept this action" outcome. The runtime never emits its code for it and
 * `XC_kAXXCAttributeUserTestingActions` is never populated, so an ignored action reports as a success.
 */
+ (instancetype)outcomeForWriteError:(int32_t)axError;

/** Uses native element activation only after an explicit refusal; never retries a timed-out press. */
+ (instancetype)outcomeForPressError:(int32_t)axError fallback:(FBAXWriteOutcome *(^)(void))fallback;

@end

#pragma mark - Frontmost

/** How a frontmost-application query turned out. */
typedef NS_ENUM(NSUInteger, FBAXFrontmostStatus) {
  /** The frontmost application is `processIdentifier`. */
  FBAXFrontmostStatusResolved,
  /** Whatever is frontmost has no accessibility server, so the query could not name it. */
  FBAXFrontmostStatusApplicationUnavailable,
  /** Whatever is frontmost has an accessibility server that did not answer in time. */
  FBAXFrontmostStatusApplicationNotResponding,
  /** The frontmost application could not be determined; `failureReason` says why. */
  FBAXFrontmostStatusUnresolved,
};

/**
 * The result of asking which application is frontmost. It does not record which strategy answered — the
 * caller that chose the resolver names it on the wire. `ApplicationUnavailable` ("nothing on screen has
 * an accessibility server") and `Unresolved` ("the strategy could not answer") need opposite remedies.
 */
@interface FBAXFrontmostOutcome : NSObject

@property (nonatomic, readonly) FBAXFrontmostStatus status;
/** The frontmost application's process. Always positive when `Resolved`. */
@property (nonatomic, readonly) pid_t processIdentifier;
/** A diagnostic for the caller. Non-nil unless `Resolved`. */
@property (nullable, nonatomic, readonly, copy) NSString *failureReason;

+ (instancetype)resolved:(pid_t)pid;
+ (instancetype)applicationUnavailable:(NSString *)failureReason;
+ (instancetype)applicationNotResponding:(NSString *)failureReason;
+ (instancetype)unresolved:(NSString *)failureReason;

@end

#pragma mark - Bound signatures

/**
 * A method type encoding with its frame size and argument offsets dropped, leaving only the types.
 *
 * `method_getTypeEncoding` returns the types interleaved with byte offsets — `Q16@0:8` is a `Q` return,
 * `@` self at 0, `:` selector at 8, in a 16-byte frame. The numbers are derived from the types by the
 * ABI, so they add no detection power and differ between architectures; comparing them would make the
 * signature check fire where nothing had actually changed.
 *
 * Digits *inside* a struct, union or array encoding are part of the type and are kept: `{Q=[4i]}` and
 * `{Q=[8i]}` are different types, and collapsing them would let a bound API taking one compare equal to
 * one taking the other.
 */
extern NSString *FBAXTypesOnly(const char *encoding);

/**
 * Checks a private API's signature against the one this code was written for.
 *
 * Returns nil when they agree, and otherwise a diagnostic naming both — including when the class or the
 * selector is not in the runtime at all, which is the same problem arriving a different way.
 *
 * A private API can change shape under a new Xcode or a new OS with nothing to say so. The declaration or
 * the `objc_msgSend` cast at the call site keeps compiling, and the process goes on reading arguments and
 * return values off offsets that are no longer where the runtime puts them. `method_getTypeEncoding` is
 * the runtime's own record of the real signature, so comparing it against a written-down constant is what
 * turns that into something with a name.
 *
 * `expected` may be written either verbatim from `method_getTypeEncoding` or with the numbers already
 * dropped.
 */
extern NSString *_Nullable FBAXSignatureMismatch(
  const char *className,
  const char *selectorName,
  BOOL isClassMethod,
  const char *expected);

/**
 * Every bound private API whose runtime signature disagrees with the one this code assumes, named.
 *
 * Empty on a runtime the reader agrees with. The product itself calls this only when a bind has already
 * failed, to say alongside the missing class what else about the runtime moved. A process that bound
 * cleanly never sweeps.
 */
extern NSArray<NSString *> *FBAXSignatureWarnings(void);

#pragma mark - Device settings

/** Device-wide simulator accessibility settings with authoritative getters and setters. */
typedef NS_ENUM(NSUInteger, FBAXDeviceSetting) {
  FBAXDeviceSettingReduceMotion,
  FBAXDeviceSettingReduceTransparency,
  FBAXDeviceSettingButtonShapes,
  FBAXDeviceSettingVoiceOver,
  FBAXDeviceSettingIncreaseContrast,
};

/** How a device-setting read or write-readback turned out. */
typedef NS_ENUM(NSUInteger, FBAXDeviceSettingStatus) {
  /** `enabled` is the authoritative value. */
  FBAXDeviceSettingStatusResolved,
  /** This runtime does not expose every API needed to represent the operation truthfully. */
  FBAXDeviceSettingStatusUnavailable,
  /** A private API raised while performing the operation; `failureReason` says why. */
  FBAXDeviceSettingStatusFailed,
};

@interface FBAXDeviceSettingOutcome : NSObject

@property (nonatomic, readonly) FBAXDeviceSettingStatus status;
/** Meaningful iff `Resolved`. */
@property (nonatomic, readonly, getter = isEnabled) BOOL enabled;
/** Non-nil iff `Unavailable` or `Failed`. */
@property (nullable, nonatomic, readonly, copy) NSString *failureReason;

+ (instancetype)resolved:(BOOL)enabled;
+ (instancetype)unavailable:(NSString *)failureReason;
+ (instancetype)failed:(NSString *)failureReason;

@end

/** A registration confined to the creating thread and its run loop. */
@protocol FBAXDeviceSettingMonitor <NSObject>
- (void)invalidate;
@end

@interface FBAXDeviceSettingMonitorOutcome : NSObject
@property (nonatomic, readonly) FBAXDeviceSettingStatus status;
@property (nullable, nonatomic, readonly) id<FBAXDeviceSettingMonitor> monitor;
@property (nullable, nonatomic, readonly, copy) NSString *failureReason;
+ (instancetype)resolved:(id<FBAXDeviceSettingMonitor>)monitor;
+ (instancetype)unavailable:(NSString *)failureReason;
+ (instancetype)failed:(NSString *)failureReason;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

#pragma mark - Display inventory

@interface FBAXDisplayIdentity : NSObject
@property (nonatomic, readonly, copy) NSString *uniqueID;
@property (nonatomic, readonly) uint32_t displayID;
- (instancetype)initWithUniqueID:(NSString *)uniqueID displayID:(uint32_t)displayID;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

typedef NS_ENUM(NSUInteger, FBAXDisplayInventoryStatus) {
  FBAXDisplayInventoryStatusAvailable,
  FBAXDisplayInventoryStatusUnavailable,
  FBAXDisplayInventoryStatusFailed,
};

@interface FBAXDisplayInventoryOutcome : NSObject
@property (nonatomic, readonly) FBAXDisplayInventoryStatus status;
/** Owned identities, meaningful only when available. */
@property (nonatomic, readonly, copy) NSArray<FBAXDisplayIdentity *> *displays;
@property (nullable, nonatomic, readonly, copy) NSString *failureReason;
+ (instancetype)available:(NSArray<FBAXDisplayIdentity *> *)displays;
+ (instancetype)unavailable:(NSString *)failureReason;
+ (instancetype)failed:(NSString *)failureReason;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

#pragma mark - Quiescence

/** A condition an application can be asked to report once it holds. */
typedef NS_ENUM(NSUInteger, FBAXQuiescenceSignal) {
  /** The application's main run loop has gone idle. */
  FBAXQuiescenceSignalRunLoopIdle,
  /** No animation is running in the application. */
  FBAXQuiescenceSignalAnimationsInactive,
};

/** Something a quiescence monitor heard. */
typedef NS_ENUM(NSUInteger, FBAXQuiescenceReport) {
  /** An answer to a `RunLoopIdle` request. */
  FBAXQuiescenceReportRunLoopIdle,
  /** An answer to an `AnimationsInactive` request. */
  FBAXQuiescenceReportAnimationsInactive,
  /** A touch sequence finished. Unrequested, and posted by any application that handled one. */
  FBAXQuiescenceReportTouchesCompleted,
  /** An application was resumed or suspended, so which application is frontmost may have changed. */
  FBAXQuiescenceReportApplicationStateChanged,
};

/**
 * Classifies an observer notification into the report it means. NO for a notification or event that
 * reports nothing a monitor distinguishes (for instance a `ViewDidAppear` user-testing event).
 */
extern BOOL FBAXQuiescenceReportForNotification(uint32_t notification, id _Nullable info, FBAXQuiescenceReport *report);

/**
 * `pid` is the application the report is about: the poster for an answer or a touch, and the application
 * named in the notification for a state change. 0 when the runtime could not say.
 */
typedef void (^FBAXQuiescenceHandler)(FBAXQuiescenceReport report, pid_t pid);

/**
 * A live registration for quiescence reports. Reports arrive on the run loop of the thread that created
 * it, which must keep running for any to arrive, and that thread is the only one that may use it.
 */
@protocol FBAXQuiescenceMonitor <NSObject>

/**
 * Asks an application element for one report of `signal`. Returns as soon as the request is delivered;
 * the answer arrives later through the handler, and only once the condition holds. An application only
 * answers while the device is in automation mode, and accepts the request without answering otherwise.
 */
- (FBAXWriteOutcome *)requestSignal:(FBAXQuiescenceSignal)signal fromApplication:(id)element;

/** Stops delivery. Idempotent; the handler is never called afterwards. */
- (void)invalidate;

@end

#pragma mark - The runtime

/**
 * Everything the reader needs from the accessibility runtime. Each method is a whole interaction (a
 * hit-test is one call, not seed + copy + pid), and no raw AXUIElementRef crosses the interface —
 * elements are opaque handles only the runtime interprets.
 */
@protocol FBAXRuntime <NSObject>

/** Maps stable display identities to the accessibility display namespace. */
- (FBAXDisplayInventoryOutcome *)displayInventory;

/**
 * An opaque handle to a process's application element, to be read with `-readAttributes:ofElement:`.
 *
 * Non-nil for any pid: the runtime vends an element for a dead pid, a non-application process and pid 0
 * alike. Whether the pid names something readable is knowable only from reading it.
 */
- (nullable id)applicationElementForProcessIdentifier:(pid_t)pid;

/** Reads `attributes` off an element handle in one round trip. */
- (FBAXReadOutcome *)readAttributes:(NSArray<NSString *> *)attributes ofElement:(id)element;

/**
 * The process that draws an element handle, answered locally without messaging it. A walk crosses into
 * other processes wherever they draw part of the tree. 0 means unknown, never a process.
 */
- (pid_t)owningProcessIdentifierOfElement:(id)element;

/**
 * XCTest's element type for an automation type read from `XC_kAXXCAttributeAutomationType`, converted
 * the way XCUITest converts it. `FBXCUIElementTypeAny` when the runtime lacks the conversion.
 */
- (FBXCUIElementType)elementTypeForAutomationType:(NSUInteger)automationType;

/**
 * A whole bounded subtree in one round trip, via the call XCUITest walks hierarchies with. Nil means the
 * read could not be performed (including a runtime without the selector; `*error` says which).
 *
 * `names` are the same `XC_kAXXCAttribute*` names `-readAttributes:ofElement:` takes, but the snapshot
 * answers keyed by the numbers they convert to, so `namesByNumber` carries that mapping back. The
 * options are built here: the server answers nothing (not an error) to a dictionary not derived from its
 * own defaults.
 */
- (nullable id)snapshotOfElement:(id)element
                  attributeNames:(NSArray<NSString *> *)names
                   namesByNumber:(NSDictionary<NSNumber *, NSString *> *_Nullable *_Nonnull)namesByNumber
                           error:(NSError **)error;

/**
 * The owning process of the element under a snapshot node's element key. A snapshot cannot serialize a
 * subtree another process draws, so ownership changing marks a process boundary. 0 means unknown, never
 * a process.
 */
- (pid_t)owningProcessIdentifierForSnapshotElement:(nullable id)element;

/**
 * One more fetch rooted at a snapshot node's element, answered by the process that owns it — what
 * continues a snapshot across a process boundary. Ask, options and `namesByNumber` are exactly
 * `-snapshotOfElement:…`'s.
 */
- (nullable id)snapshotOfSnapshotElement:(nullable id)element
                          attributeNames:(NSArray<NSString *> *)names
                           namesByNumber:(NSDictionary<NSNumber *, NSString *> *_Nullable *_Nonnull)namesByNumber
                                   error:(NSError **)error;

/**
 * Unwraps the `CGRect` an `AXValue` wraps, which is the form a snapshot answers frames in.
 *
 * An `AXValue` is a CFType with its own accessor rather than an `NSValue`, so a caller that only knows
 * about `NSValue` sees `__NSCFType` and drops the frame.
 *
 * NO when the value does not hold a rect, leaving `*rect` untouched. Unwrapping is type-checked here
 * because the runtime does not check it: a point read as a rect answers with a frame rather than failing.
 */
- (BOOL)getRect:(CGRect *)rect fromValue:(id)value;

/**
 * Unwraps the `CGPoint` an `AXValue` wraps, which is the form a snapshot answers the reachability hit
 * points in. The counterpart to `-getRect:fromValue:` for `kAXValueCGPointType`.
 *
 * NO when the value does not hold a point, leaving `*point` untouched. Unwrapping is type-checked here
 * because the runtime does not check it: a rect read as a point answers with a coordinate rather than
 * failing, and the host taps the points this method unwraps.
 */
- (BOOL)getPoint:(CGPoint *)point fromValue:(id)value;

/**
 * The element at a point, in one round trip.
 *
 * A positive `pid` scopes the hit-test to that application; a non-positive one makes it display-wide, so
 * the point is resolved against whichever application owns it without the caller knowing that in advance.
 * Either way the owning process comes back on the outcome.
 */
- (FBAXHitTestOutcome *)hitTestAtPoint:(CGPoint)point processIdentifier:(pid_t)pid;

/**
 * Resolves unrotated points on one discovered accessibility display; a mismatched pid is empty. The
 * translator's requests claim `clientType` (a `BridgeAXClientType` raw value), which can change the element
 * the application reports at the point.
 */
- (FBAXHitTestOutcome *)hitTestAtPoint:(CGPoint)point
                     processIdentifier:(pid_t)pid
                     displayIdentifier:(uint32_t)displayID
                            clientType:(NSUInteger)clientType;

/**
 * Performs a semantic action on an element handle, in one round trip. Whether the element advertises the
 * action is not checked: the runtime reports an unadvertised action as a success.
 */
- (FBAXWriteOutcome *)performAction:(FBAXAction)action onElement:(id)element;

/** Writes an element handle's value attribute, in one round trip. */
- (FBAXWriteOutcome *)setValue:(id)value onElement:(id)element;

/** The frontmost application according to the window server, via the in-guest AXPTranslator. */
- (FBAXFrontmostOutcome *)windowServerFrontmost;
- (FBAXFrontmostOutcome *)windowServerFrontmostOnDisplay:(uint32_t)displayID;

/** The frontmost application according to RunningBoard's on-screen visibility endowment. */
- (FBAXFrontmostOutcome *)runningBoardFrontmost;

/**
 * Reads translator attributes (`BridgeAXTranslatorAttribute` raw values) off `element` through the in-guest translator, in one round trip. A separate
 * vocabulary from XCTest's `XC_kAXXCAttribute*` names with its own server-side handlers; the two
 * disagree on some screens. `element` may be an element handle or a translation object from an earlier
 * translator read. The result omits attributes the server did not answer; nil means the read could not
 * be performed at all. The request claims `clientType` (a `BridgeAXClientType` raw value): an application
 * answers a client that deserves automation with its `automationElements`, which nothing invalidates, so
 * zero — no client — is what keeps a read on the live traversal.
 */
- (nullable NSDictionary<NSNumber *, id> *)translatorAttributes:(NSArray<NSNumber *> *)attributes
                                                      ofElement:(id)element
                                                     clientType:(NSUInteger)clientType;

/**
 * Whether the device is in accessibility automation mode.
 *
 * This is `_AXSAutomationEnabled()` — a device-wide setting, not a property of this process or of the
 * target. With it off, UIKit collapses subtrees behind opaque element providers and caches a container's
 * children; with it on, the full structure is exposed and children are recomputed per read.
 *
 * Read in the *guest*, which is not the target application. The value is the same device-wide setting
 * either way, but the target caches its own view of it behind a notification observer, so a read here
 * says what the device is set to and not that the target has already observed it.
 */
- (BOOL)automationModeEnabled;

/**
 * Asks the device for automation mode, and reports what the flag reads back as afterwards.
 *
 * Returns the read-back state rather than whether the write was attempted, because the two differ: this
 * writes a preference through `AXSettings`, and a preference write can fail silently. A caller that
 * assumed success would report a mode the device is not in.
 *
 * Device-wide and persistent. It is not restored when this process exits, and `AXRuntime` clears it
 * unconditionally when an accessibility observer client dies — so a caller must not assume a value it set
 * earlier is still in force.
 */
- (BOOL)setAutomationModeEnabled:(BOOL)enabled;

/** Registers before the first read; notifications carry no authoritative value. */
- (FBAXDeviceSettingMonitorOutcome *)monitorDeviceSettings:(NSArray<NSNumber *> *)settings handler:(void (^)(void))handler;

/** Reads a device-wide setting. */
- (FBAXDeviceSettingOutcome *)enabledStateForDeviceSetting:(FBAXDeviceSetting)setting;

/** Writes a device-wide setting and returns its authoritative read-back outcome. */
- (FBAXDeviceSettingOutcome *)setEnabled:(BOOL)enabled forDeviceSetting:(FBAXDeviceSetting)setting;

/**
 * Starts observing the device for quiescence reports, delivered on the calling thread's run loop. Leaves
 * automation mode as it is. Nil when this runtime cannot observe, with `*error` saying why.
 */
- (nullable id<FBAXQuiescenceMonitor>)quiescenceMonitorWithHandler:(FBAXQuiescenceHandler)handler
                                                             error:(NSString *_Nullable *_Nullable)error;

@end

typedef id<FBAXRuntime> _Nullable (^FBAXRuntimeFactory)(NSString *_Nullable *_Nullable error);

/** The one conformer in the product. Constructing one is the whole bind; failure is a named setup error. */
@interface FBAXLiveRuntime : NSObject <FBAXRuntime>

/** Binds the private frameworks, or returns nil with `*error` set to what was missing. */
- (nullable instancetype)initWithError:(NSString *_Nullable *_Nullable)error NS_DESIGNATED_INITIALIZER;

+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END

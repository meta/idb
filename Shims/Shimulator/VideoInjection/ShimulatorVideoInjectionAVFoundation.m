/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

/*
 * The Objective-C half of the virtual camera: the AVFoundation subclasses it hands to apps, which
 * adopt private state and so cannot be written in Swift, and the two swizzled initialisers that have
 * to stay in the `init` family. Swift owns virtual state.
 */

#import "ShimulatorVideoInjectionAVFoundation.h"

#import <objc/runtime.h>

@interface ShimulatorVirtualCamera : NSObject
+ (void)install;
+ (BOOL)isConnectionActive:(ShimulatorCaptureConnection *)connection;
@end

/**
 * A synthesised AVFoundation object is allocated but never initialised by the
 * framework, so the private state holder its -dealloc releases is missing and
 * the object cannot be freed. Give it an empty one of the right class.
 */
static void AdoptAVFoundationInternals(id object, Class superclass)
{
  unsigned count = 0;
  Ivar *ivars = class_copyIvarList(superclass, &count);
  for (unsigned index = 0; index < count; index++) {
    const char *encoding = ivar_getTypeEncoding(ivars[index]);
    if (!encoding || encoding[0] != '@' || encoding[1] != '"') {
      continue;
    }
    NSString *name = [NSString stringWithUTF8String:encoding + 2];
    if (name.length == 0 || ![name hasSuffix:@"\""]) {
      continue;
    }
    name = [name substringToIndex:name.length - 1];
    Class internalClass = NSClassFromString(name);
    if (internalClass) {
      // An ivar keeps its declared ownership, weak included; only one without ARC layout, as in the
      // framework's manually retained classes, is assigned strong, which is what their -dealloc expects.
      object_setIvarWithStrongDefault(object, ivars[index], [internalClass new]);
    }
  }
  free(ivars);
  Class parent = class_getSuperclass(superclass);
  if (parent && parent != [NSObject class]) {
    AdoptAVFoundationInternals(object, parent);
  }
}

/** Indexed by AVCaptureVideoOrientation: Portrait = 1, PortraitUpsideDown, LandscapeRight, LandscapeLeft. */
static const CGFloat OrientationAngles[] = {0, 90, 270, 0, 180};

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-designated-initializers"

@implementation ShimulatorFrameRateRange

- (instancetype)init
{
  AdoptAVFoundationInternals(self, [AVFrameRateRange class]);
  _rate = 30;
  return self;
}

- (Float64)minFrameRate { return 1; }

- (Float64)maxFrameRate { return MAX(self.rate, 1); }

- (CMTime)minFrameDuration
{
  return CMTimeMakeWithSeconds(1.0 / self.maxFrameRate, 60000);
}

- (CMTime)maxFrameDuration { return CMTimeMake(1, 1); }

- (NSString *)description
{
  return [NSString stringWithFormat:@"<ShimulatorFrameRateRange 1-%.0f fps>", self.maxFrameRate];
}

@end

@implementation ShimulatorCaptureDeviceFormat

- (instancetype)init
{
  AdoptAVFoundationInternals(self, [AVCaptureDeviceFormat class]);
  _range = [[ShimulatorFrameRateRange alloc] init];
  return self;
}

// AVFoundation declares this nonnull; the virtual format returns the description it was given, nil until one is set.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullable-to-nonnull-conversion"
- (CMFormatDescriptionRef)formatDescription { return self.formatDescriptionRef; }

#pragma clang diagnostic pop

- (NSString *)mediaType { return AVMediaTypeVideo; }

- (NSArray<AVFrameRateRange *> *)videoSupportedFrameRateRanges { return @[self.range]; }

- (float)videoFieldOfView { return 60; }

- (BOOL)isVideoBinned { return NO; }

- (BOOL)isVideoHDRSupported { return NO; }

- (CGFloat)videoMaxZoomFactor { return 1; }

- (CGFloat)videoZoomFactorUpscaleThreshold { return 1; }

- (AVCaptureAutoFocusSystem)autoFocusSystem { return AVCaptureAutoFocusSystemNone; }

- (NSArray<NSNumber *> *)supportedColorSpaces { return @[@(AVCaptureColorSpace_sRGB)]; }

- (BOOL)isMultiCamSupported { return NO; }

- (BOOL)isHighestPhotoQualitySupported { return NO; }

- (BOOL)isPortraitEffectSupported { return NO; }

- (BOOL)isVideoStabilizationModeSupported:(AVCaptureVideoStabilizationMode)mode
{
  return mode == AVCaptureVideoStabilizationModeOff;
}

- (NSString *)description
{
  CMVideoFormatDescriptionRef format = self.formatDescriptionRef;
  CMVideoDimensions dimensions = format ? CMVideoFormatDescriptionGetDimensions(format) : (CMVideoDimensions) {0, 0};
  return [NSString stringWithFormat:@"<ShimulatorCaptureDeviceFormat %dx%d>", dimensions.width,
          dimensions.height];
}

@end

@implementation ShimulatorCaptureDevice

- (instancetype)init
{
  AdoptAVFoundationInternals(self, [AVCaptureDevice class]);
  return self;
}

- (NSString *)uniqueID { return self.virtualUniqueID ?: @"idb-injected-camera"; }

- (NSString *)modelID { return @"idb-virtual-camera"; }

- (NSString *)localizedName
{
  return self.virtualPosition == AVCaptureDevicePositionFront ? @"idb Injected Camera (Front)"
  : @"idb Injected Camera (Back)";
}

- (NSString *)manufacturer { return @"idb"; }

- (AVCaptureDeviceType)deviceType { return AVCaptureDeviceTypeBuiltInWideAngleCamera; }

- (AVCaptureDevicePosition)position { return self.virtualPosition; }

- (BOOL)isConnected { return YES; }

- (BOOL)isInUseByAnotherApplication { return NO; }

- (BOOL)isSuspended { return NO; }

- (BOOL)hasMediaType:(AVMediaType)mediaType { return [mediaType isEqualToString:AVMediaTypeVideo]; }

- (BOOL)supportsAVCaptureSessionPreset:(AVCaptureSessionPreset)preset { return YES; }

- (NSArray<AVCaptureDeviceFormat *> *)formats { return self.virtualFormat ? @[self.virtualFormat] : @[]; }

- (AVCaptureDeviceFormat *)activeFormat { return self.virtualFormat; }

- (void)setActiveFormat:(AVCaptureDeviceFormat *)format {}

- (AVCaptureDeviceFormat *)activeDepthDataFormat { return nil; }

- (CMTime)activeVideoMinFrameDuration { return self.virtualFormat ? self.virtualFormat.range.minFrameDuration : CMTimeMake(1, 30); }

- (void)setActiveVideoMinFrameDuration:(CMTime)duration {}

- (CMTime)activeVideoMaxFrameDuration { return CMTimeMake(1, 1); }

- (void)setActiveVideoMaxFrameDuration:(CMTime)duration {}

- (BOOL)lockForConfiguration:(NSError **)error { return YES; }

- (void)unlockForConfiguration {}

- (BOOL)hasTorch { return NO; }

- (BOOL)isTorchAvailable { return NO; }

- (BOOL)isTorchActive { return NO; }

- (BOOL)isTorchModeSupported:(AVCaptureTorchMode)mode { return mode == AVCaptureTorchModeOff; }

- (BOOL)hasFlash { return NO; }

- (BOOL)isFlashAvailable { return NO; }

- (BOOL)isFocusModeSupported:(AVCaptureFocusMode)mode { return NO; }

- (BOOL)isExposureModeSupported:(AVCaptureExposureMode)mode { return NO; }

- (BOOL)isWhiteBalanceModeSupported:(AVCaptureWhiteBalanceMode)mode { return NO; }

- (BOOL)isFocusPointOfInterestSupported { return NO; }

- (BOOL)isExposurePointOfInterestSupported { return NO; }

- (BOOL)isSmoothAutoFocusSupported { return NO; }

- (BOOL)isLowLightBoostSupported { return NO; }

- (BOOL)isRampingVideoZoom { return NO; }

- (CGFloat)videoZoomFactor { return 1; }

- (void)setVideoZoomFactor:(CGFloat)factor {}

- (CGFloat)minAvailableVideoZoomFactor { return 1; }

- (CGFloat)maxAvailableVideoZoomFactor { return 1; }

- (NSArray<NSNumber *> *)virtualDeviceSwitchOverVideoZoomFactors { return @[]; }

- (NSArray<AVCaptureDevice *> *)constituentDevices { return @[]; }

- (NSArray<AVCaptureDevice *> *)linkedDevices { return @[]; }

- (NSString *)description
{
  return [NSString stringWithFormat:@"<ShimulatorCaptureDevice: %p [%@]>", self, self.localizedName];
}

@end

@implementation ShimulatorCaptureInputPort

- (instancetype)init
{
  AdoptAVFoundationInternals(self, [AVCaptureInputPort class]);
  _storedEnabled = YES;
  return self;
}

- (AVMediaType)mediaType { return AVMediaTypeVideo; }

// AVFoundation declares this nonnull; the port holds its input weakly, so it returns nil once the input is gone.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullable-to-nonnull-conversion"
- (AVCaptureInput *)input { return self.owningInput; }

#pragma clang diagnostic pop

- (CMFormatDescriptionRef)formatDescription
{
  AVCaptureDeviceInput *input = (AVCaptureDeviceInput *)self.owningInput;
  return input.device.activeFormat.formatDescription;
}

- (BOOL)isEnabled { return self.storedEnabled; }

- (void)setEnabled:(BOOL)enabled { self.storedEnabled = enabled; }

- (CMClockRef)clock { return CMClockGetHostTimeClock(); }

- (AVCaptureDeviceType)sourceDeviceType { return AVCaptureDeviceTypeBuiltInWideAngleCamera; }

- (AVCaptureDevicePosition)sourceDevicePosition
{
  AVCaptureDeviceInput *input = (AVCaptureDeviceInput *)self.owningInput;
  return input.device.position;
}

- (NSString *)description { return [NSString stringWithFormat:@"<ShimulatorCaptureInputPort: %p>", self]; }

@end

@implementation ShimulatorCaptureDeviceInput

- (instancetype)init
{
  AdoptAVFoundationInternals(self, [AVCaptureDeviceInput class]);
  return self;
}

- (AVCaptureDevice *)device { return self.virtualDevice; }

- (NSArray<AVCaptureInputPort *> *)ports { return self.virtualPorts; }

- (BOOL)unifiedAutoExposureDefaultsEnabled { return NO; }

- (void)setUnifiedAutoExposureDefaultsEnabled:(BOOL)enabled {}

- (NSString *)description { return [NSString stringWithFormat:@"<ShimulatorCaptureDeviceInput: %p>", self]; }

@end

@implementation ShimulatorCaptureConnection

- (instancetype)init
{
  AdoptAVFoundationInternals(self, [AVCaptureConnection class]);
  _storedEnabled = YES;
  _storedAutomaticallyAdjustsMirroring = YES;
  _storedRotationAngle = -1;
  return self;
}

- (BOOL)isFrontCamera
{
  for (AVCaptureInputPort *port in self.virtualPorts) {
    AVCaptureInput *input = [port isKindOfClass:[ShimulatorCaptureInputPort class]] ? ((ShimulatorCaptureInputPort *)port).owningInput : nil;
    if ([input isKindOfClass:[ShimulatorCaptureDeviceInput class]]) {
      return ((ShimulatorCaptureDeviceInput *)input).virtualDevice.virtualPosition == AVCaptureDevicePositionFront;
    }
  }
  return NO;
}

- (CGFloat)rotationAngle
{
  if (self.storedRotationAngle >= 0) {
    return self.storedRotationAngle;
  }
  return self.isFrontCamera ? 180 : 0;
}

- (CGFloat)frameRotationAngle
{
  return self.isFrontCamera ? fmod(540 - self.rotationAngle, 360) : self.rotationAngle;
}

- (NSArray<AVCaptureInputPort *> *)inputPorts { return self.virtualPorts ?: @[]; }

- (AVCaptureOutput *)output { return self.virtualOutput; }

- (BOOL)isEnabled { return self.storedEnabled; }

- (void)setEnabled:(BOOL)enabled { self.storedEnabled = enabled; }

- (BOOL)isActive { return [ShimulatorVirtualCamera isConnectionActive:self]; }

- (AVMediaType)mediaType { return AVMediaTypeVideo; }

- (BOOL)isVideoOrientationSupported { return YES; }

- (AVCaptureVideoOrientation)videoOrientation
{
  for (AVCaptureVideoOrientation orientation = AVCaptureVideoOrientationPortrait;
       orientation <= AVCaptureVideoOrientationLandscapeLeft; orientation++) {
    if (OrientationAngles[orientation] == self.rotationAngle) {
      return orientation;
    }
  }
  return AVCaptureVideoOrientationLandscapeRight;
}

- (void)setVideoOrientation:(AVCaptureVideoOrientation)orientation
{
  if (orientation < AVCaptureVideoOrientationPortrait
      || orientation > AVCaptureVideoOrientationLandscapeLeft) {
    return;
  }
  self.storedRotationAngle = OrientationAngles[orientation];
}

- (BOOL)isVideoMirroringSupported { return YES; }

/** A preview layer's connection is the one without an output. */
- (BOOL)isVideoMirrored
{
  if (!self.storedAutomaticallyAdjustsMirroring) {
    return self.storedMirrored;
  }
  return self.virtualOutput == nil && self.isFrontCamera;
}

- (void)setVideoMirrored:(BOOL)mirrored
{
  if (self.storedAutomaticallyAdjustsMirroring) {
    [NSException raise:NSInvalidArgumentException
                format:@"Cannot set videoMirrored while automaticallyAdjustsVideoMirroring is YES"];
  }
  self.storedMirrored = mirrored;
}

- (BOOL)automaticallyAdjustsVideoMirroring { return self.storedAutomaticallyAdjustsMirroring; }

/** Turning automatic mirroring off keeps the connection's current mirroring until the app sets it. */
- (void)setAutomaticallyAdjustsVideoMirroring:(BOOL)automatic
{
  if (!automatic && self.storedAutomaticallyAdjustsMirroring) {
    self.storedMirrored = self.isVideoMirrored;
  }
  self.storedAutomaticallyAdjustsMirroring = automatic;
}

- (BOOL)isVideoRotationAngleSupported:(CGFloat)angle { return fmod(angle, 90) == 0; }

- (CGFloat)videoRotationAngle { return self.rotationAngle; }

- (void)setVideoRotationAngle:(CGFloat)angle
{
  if ([self isVideoRotationAngleSupported:angle]) {
    self.storedRotationAngle = fmod(fmod(angle, 360) + 360, 360);
  }
}

- (BOOL)isVideoStabilizationSupported { return NO; }

- (AVCaptureVideoStabilizationMode)activeVideoStabilizationMode
{
  return AVCaptureVideoStabilizationModeOff;
}

- (AVCaptureVideoStabilizationMode)preferredVideoStabilizationMode
{
  return AVCaptureVideoStabilizationModeOff;
}

- (void)setPreferredVideoStabilizationMode:(AVCaptureVideoStabilizationMode)mode {}

- (BOOL)isCameraIntrinsicMatrixDeliverySupported { return NO; }

- (BOOL)isCameraIntrinsicMatrixDeliveryEnabled { return NO; }

- (void)setCameraIntrinsicMatrixDeliveryEnabled:(BOOL)enabled {}

- (CGFloat)videoScaleAndCropFactor { return 1; }

- (void)setVideoScaleAndCropFactor:(CGFloat)factor {}

- (NSString *)description { return [NSString stringWithFormat:@"<ShimulatorCaptureConnection: %p>", self]; }

@end

@implementation ShimulatorCaptureDiscoverySession

- (instancetype)init
{
  AdoptAVFoundationInternals(self, [AVCaptureDeviceDiscoverySession class]);
  return self;
}

- (NSArray<AVCaptureDevice *> *)devices { return self.virtualDevices ?: @[]; }

- (NSArray<NSSet<AVCaptureDevice *> *> *)supportedMultiCamDeviceSets { return @[]; }

- (NSString *)description
{
  return [NSString stringWithFormat:@"<ShimulatorCaptureDiscoverySession: %@>", self.virtualDevices];
}

@end

@implementation ShimulatorCaptureResolvedPhotoSettings

- (instancetype)init
{
  AdoptAVFoundationInternals(self, [AVCaptureResolvedPhotoSettings class]);
  return self;
}

- (int64_t)uniqueID { return self.storedUniqueID; }

- (CMVideoDimensions)photoDimensions { return self.storedPhotoDimensions; }

@end

@implementation ShimulatorCapturePhoto

- (instancetype)init
{
  AdoptAVFoundationInternals(self, [AVCapturePhoto class]);
  return self;
}

- (NSData *)fileDataRepresentation { return self.jpeg; }

- (CVPixelBufferRef)pixelBuffer { return self.storedPixelBuffer; }

- (CMTime)timestamp { return self.storedTimestamp; }

- (NSInteger)photoCount { return 1; }

- (BOOL)isRawPhoto { return NO; }

- (NSDictionary *)metadata { return @{}; }

// AVFoundation declares this nonnull; the virtual photo returns the settings it was given, nil until they are set.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullable-to-nonnull-conversion"
- (AVCaptureResolvedPhotoSettings *)resolvedSettings { return self.storedResolvedSettings; }

#pragma clang diagnostic pop

- (CGImageRef)CGImageRepresentation { return self.storedImage; }

- (NSString *)description
{
  return [NSString stringWithFormat:@"<ShimulatorCapturePhoto: %p %lu bytes>", self,
          (unsigned long)self.jpeg.length];
}

@end

#pragma clang diagnostic pop

@implementation AVCaptureDeviceInput (ShimulatorVideoInjection)

- (nullable instancetype)initShimulatorWithDevice:(AVCaptureDevice *)device error:(NSError **)error
{
  if (![device isKindOfClass:[ShimulatorCaptureDevice class]]) {
    return [self initShimulatorWithDevice:device error:error];
  }
  if (error) {
    *error = nil;
  }
  AdoptAVFoundationInternals(self, [AVCaptureDeviceInput class]);
  ShimulatorCaptureDeviceInput *input = [[ShimulatorCaptureDeviceInput alloc] init];
  input.virtualDevice = (ShimulatorCaptureDevice *)device;
  ShimulatorCaptureInputPort *port = [[ShimulatorCaptureInputPort alloc] init];
  port.owningInput = input;
  input.virtualPorts = @[port];
  self = (id)input;
  return self;
}

@end

@implementation AVCaptureVideoPreviewLayer (ShimulatorVideoInjection)

- (instancetype)initShimulatorWithSession:(AVCaptureSession *)session
{
  self = [self initShimulatorWithSession:nil];
  [self setSession:session];
  return self;
}

@end

// A swizzle installed after load would miss an app that opens its camera on launch.
// Matches `ShimulatorVideoInjection.armedEnvironmentVariable`.
// patternlint-disable-next-line static-initializer-constructor-attribute
__attribute__((constructor)) static void ShimulatorVideoInjectionLoad(void)
{
  const char *armed = getenv("IDB_VIDEO_INJECTION");
  if (armed == NULL || strcmp(armed, "1") != 0) {
    return;
  }
  [ShimulatorVirtualCamera install];
}

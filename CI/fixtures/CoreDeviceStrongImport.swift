/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreDevice

// This deliberately strong import is compiled only, never linked or executed.
public func strongCoreDeviceMetadata() -> Any.Type {
  DigitizerHIDCapability.self
}

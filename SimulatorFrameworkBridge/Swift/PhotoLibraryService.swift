/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#if !os(watchOS)
import Foundation
import Photos

#if canImport(SimulatorFrameworkBridgeRuntime)
internal import SimulatorFrameworkBridgeRuntime
#endif
private func clearPhotoLibrary(client: FBPhotoLibraryClient, output: BridgeOutput? = nil) -> Int {
  do {
    if try client.readAssetCount().uintValue == 0 {
      NSLog("No photos to delete")
      return 0
    }
    NSLog("Found %lu photos to delete", try client.readAssetCount().uintValue)
    return client.deleteAssets() ? 0 : (output?.failure("Photo library deletion transaction failed") ?? 1)
  } catch {
    return output?.failure("Could not read photo assets: \(error.localizedDescription)") ?? 1
  }
}

public enum PhotoLibraryService {

  public static func handlePhotoLibraryAction(action: String) -> Int {
    handlePhotoLibraryAction(action: action, output: nil)
  }

  static func handlePhotoLibraryAction(action: String, output: BridgeOutput?) -> Int {
    if action == "clear" {
      let library = PHPhotoLibrary.shared()
      let options = PHFetchOptions()
      guard let client = FBPhotoLibraryClient.make(library: library, assets: PHAsset.fetchAssets(with: options)) else {
        return output?.failure("The photo library private API is unavailable") ?? 1
      }
      return clearPhotoLibrary(client: client, output: output)
    } else {
      NSLog("Unknown action: %@", action)
      return 1
    }
  }

  public static func clear(client: Any) -> Int {
    guard let client = client as? FBPhotoLibraryClient else {
      return 1
    }
    return clearPhotoLibrary(client: client)
  }
}
#endif

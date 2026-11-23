/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

enum OToolDynamicLibsError: Error {
  case directoryListFailed(path: String, underlying: any Error)
  case clangVersionNotFound(path: String)
}

extension OToolDynamicLibsError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case let .directoryListFailed(path, _):
      return "Failed to list files in directory \(path)"
    case let .clangVersionNotFound(path):
      return "No clang version found in \(path)"
    }
  }
}

enum OToolDynamicLibs {

  public static func findFullPath(forSanitiserDyldInBundle bundlePath: String) async throws -> [String] {
    let libsList = try await OToolOperation.listSanitiserDylibsRequired(byBundle: bundlePath)

    let clangLocation = (XcodeConfiguration.developerDirectory as NSString).appendingPathComponent("Toolchains/XcodeDefault.xctoolchain/usr/lib/clang")
    let fileList: [URL]
    do {
      fileList = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: clangLocation), includingPropertiesForKeys: [.isDirectoryKey], options: [])
    } catch {
      throw OToolDynamicLibsError.directoryListFailed(path: clangLocation, underlying: error)
    }

    if fileList.isEmpty {
      throw OToolDynamicLibsError.clangVersionNotFound(path: clangLocation)
    }

    let libsFolder = NSString.path(withComponents: [fileList[0].path, "lib/darwin/"])

    var bundleFrameworksFolder = (bundlePath as NSString).appendingPathComponent("Frameworks")
    if !FileManager.default.fileExists(atPath: bundleFrameworksFolder) {
      bundleFrameworksFolder = (bundlePath as NSString).appendingPathComponent("Contents/Frameworks")
    }

    var bundleLibsNames: Set<String>?
    if let bundleLibs = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: bundleFrameworksFolder), includingPropertiesForKeys: [.isDirectoryKey], options: []) {
      var names = Set<String>()
      for libURL in bundleLibs {
        if let libName = libURL.pathComponents.last {
          names.insert(libName)
        }
      }
      bundleLibsNames = names
    }

    var libraries: [String] = []
    for lib in libsList {
      let libPath: String
      if bundleLibsNames?.contains(lib) == true {
        libPath = (bundleFrameworksFolder as NSString).appendingPathComponent(lib)
      } else {
        libPath = (libsFolder as NSString).appendingPathComponent(lib)
      }
      libraries.append(libPath)
    }

    return libraries
  }
}

enum OToolError: Error {
  case bundleInaccessible(path: String)
  case bundleMissingExecutable(path: String)
}

extension OToolError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case let .bundleInaccessible(path):
      return "Bundle '\(path)' does not identify an accessible bundle directory."
    case let .bundleMissingExecutable(path):
      return "The bundle at \(path) does not contain an executable."
    }
  }
}

enum OToolOperation {

  public static func listSanitiserDylibsRequired(byBundle testBundlePath: String) async throws -> [String] {
    guard let bundle = Bundle(path: testBundlePath) else {
      throw OToolError.bundleInaccessible(path: testBundlePath)
    }
    guard let executablePath = bundle.executablePath else {
      throw OToolError.bundleMissingExecutable(path: testBundlePath)
    }

    let result = try await Subprocess(executable: "/usr/bin/otool", arguments: ["-L", executablePath])
      .run()
    return extractSanitiserDylibs(fromOtoolOutput: result.standardOutput)
  }

  private static func extractSanitiserDylibs(fromOtoolOutput otoolOutput: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: "@rpath/(libclang_rt\\..*san_.*_dynamic.dylib)", options: .caseInsensitive) else {
      return []
    }
    var libs: [String] = []
    let nsString = otoolOutput as NSString
    unsafe regex.enumerateMatches(in: otoolOutput, options: [], range: NSRange(location: 0, length: nsString.length)) { result, _, _ in
      guard let result else { return }
      let range = result.range(at: 1)
      libs.append(nsString.substring(with: range))
    }
    return libs
  }
}

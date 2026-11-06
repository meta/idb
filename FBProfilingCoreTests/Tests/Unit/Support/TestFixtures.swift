/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

private class BundleFinder {}

enum TestFixtures {

  static let probeLeaksPath = Bundle(for: BundleFinder.self)
    .path(forResource: "probe_leaks", ofType: "txt")!

  static let replhostLeaksUntypedPath = Bundle(for: BundleFinder.self)
    .path(forResource: "replhost_leaks_untyped", ofType: "txt")!

  static let probeHeapPath = Bundle(for: BundleFinder.self)
    .path(forResource: "probe_heap", ofType: "txt")!

  static let probeSamplePath = Bundle(for: BundleFinder.self)
    .path(forResource: "probe_sample", ofType: "txt")!

  static let probeVmmapPath = Bundle(for: BundleFinder.self)
    .path(forResource: "probe_vmmap", ofType: "txt")!

  static let probeXctraceTableOfContentsPath = Bundle(for: BundleFinder.self)
    .path(forResource: "probe_xctrace_toc", ofType: "xml")!

  static let probeXctraceTimeProfilePath = Bundle(for: BundleFinder.self)
    .path(forResource: "probe_xctrace_time_profile", ofType: "xml")!

  static let probeXctracePotentialHangsPath = Bundle(for: BundleFinder.self)
    .path(forResource: "probe_xctrace_potential_hangs", ofType: "xml")!
}

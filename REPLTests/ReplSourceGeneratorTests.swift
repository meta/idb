/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import ReplCompiler
import Testing

/// Tests `ReplSourceGenerator`: extracting imports, detecting async, and generating the
/// wrapped source.
@Suite
struct ReplSourceGeneratorTests {

  // MARK: - extractImports

  @Test
  func extractsSingleImport() {
    let (imports, stripped) = ReplSourceGenerator.extractImports(from: "import UIKit; let x = 1")
    #expect(imports == ["UIKit"])
    #expect(!stripped.contains("import"))
    #expect(stripped.contains("let x = 1"))
  }

  @Test
  func extractsMultipleImportsInOrder() {
    let (imports, _) = ReplSourceGenerator.extractImports(from: "import UIKit; import Photos; let x = 1")
    #expect(imports == ["UIKit", "Photos"])
  }

  @Test
  func noImportsReturnsEmptyAndUnchangedCode() {
    let code = "let x = 1; return x"
    let (imports, stripped) = ReplSourceGenerator.extractImports(from: code)
    #expect(imports.isEmpty)
    #expect(stripped == code)
  }

  @Test
  func extractsSubmoduleImport() {
    let (imports, _) = ReplSourceGenerator.extractImports(from: "import os.log; foo()")
    #expect(imports == ["os.log"])
  }

  @Test
  func extractsModuleNameFromAttributedImport() {
    // The leading attribute (e.g. `@testable`) is dropped; only the module name is captured.
    let (imports, _) = ReplSourceGenerator.extractImports(from: "@testable import MyModule; run()")
    #expect(imports == ["MyModule"])
  }

  @Test
  func extractsImportsSeparatedByNewlines() {
    let (imports, _) = ReplSourceGenerator.extractImports(from: "import UIKit\nimport Photos\nreturn 1")
    #expect(imports == ["UIKit", "Photos"])
  }

  // MARK: - containsAsync

  @Test
  func detectsAwait() {
    #expect(ReplSourceGenerator.containsAsync("let x = await foo()"))
  }

  @Test
  func detectsAsync() {
    #expect(ReplSourceGenerator.containsAsync("func f() async { }"))
  }

  @Test
  func plainCodeIsNotAsync() {
    #expect(!ReplSourceGenerator.containsAsync("let x = 1; return x"))
  }

  @Test
  func wordBoundaryAvoidsFalseAsyncMatch() {
    #expect(!ReplSourceGenerator.containsAsync("let awaited = true"))
    #expect(!ReplSourceGenerator.containsAsync("let asynchronously = 1"))
  }

  // MARK: - generateSource

  @Test
  func reappliesUserImportsAtFileScope() {
    let source = ReplSourceGenerator.generateSource(for: "import Photos; return PHAsset.self", index: 0)
    #expect(source.contains("import Photos"))
    #expect(source.contains("return PHAsset.self"))
  }

  @Test
  func alwaysImportsFoundation() {
    let source = ReplSourceGenerator.generateSource(for: "return 1", index: 0)
    #expect(source.contains("import Foundation"))
  }

  @Test
  func deduplicatesFoundationImport() {
    let source = ReplSourceGenerator.generateSource(for: "import Foundation; return 1", index: 0)
    let occurrences = source.components(separatedBy: "import Foundation").count - 1
    #expect(occurrences == 1)
  }

  @Test
  func usesAsyncWrapperForAwaitingCode() {
    let source = ReplSourceGenerator.generateSource(for: "let x = await foo()", index: 0)
    #expect(source.contains("() async throws -> Any"))
    #expect(source.contains("DispatchSemaphore"))
  }

  @Test
  func usesSyncWrapperForPlainCode() {
    let source = ReplSourceGenerator.generateSource(for: "return 1", index: 0)
    #expect(source.contains("() throws -> Any"))
    #expect(!source.contains("DispatchSemaphore"))
  }

  @Test
  func embedsIndexInGeneratedSymbols() {
    let source = ReplSourceGenerator.generateSource(for: "return 1", index: 7)
    #expect(source.contains("idb_repl_7"))
    #expect(source.contains("userCode_7"))
  }
}

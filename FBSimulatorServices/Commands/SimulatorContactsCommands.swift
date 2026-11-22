/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@preconcurrency import FBControlCore
import FBSimulatorBridgeProtocol
import FBSimulatorControl
@preconcurrency import Foundation

public enum SimulatorContactsError: Error {
  case noDataDirectoryForPlists
  case addressBookDirectoryMissing(path: String)
  case contactsDirectoryEnumerationFailed(path: String)
  case noContactsDatabases
}

extension SimulatorContactsError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .noDataDirectoryForPlists:
      return "The Simulator has no data directory, so its plists cannot be located"
    case let .addressBookDirectoryMissing(path):
      return "Expected Address Book path to exist at \(path) but it was not there"
    case let .contactsDirectoryEnumerationFailed(path):
      return "Could not enumerate directory at \(path)"
    case .noContactsDatabases:
      return "Could not update Address Book DBs when no databases are provided"
    }
  }
}

/// Replaces and clears the simulated device's Address Book.
public struct SimulatorContactsCommands {

  private let simulator: Simulator

  // MARK: - Initializers

  public init(simulator: Simulator) {
    self.simulator = simulator
  }

  // MARK: - Address Book

  public func update(_ databaseDirectory: String) async throws {
    guard let dataDirectory = simulator.dataDirectory else {
      throw SimulatorContactsError.noDataDirectoryForPlists
    }
    let destinationDirectory = (dataDirectory as NSString).appendingPathComponent("Library/AddressBook")
    if !FileManager.default.fileExists(atPath: destinationDirectory) {
      throw SimulatorContactsError.addressBookDirectoryMissing(path: destinationDirectory)
    }

    let sourceFilePaths = try Self.contactsDatabaseFilePaths(fromContainingDirectory: databaseDirectory)

    for sourceFilePath in sourceFilePaths {
      let destinationFilePath = (destinationDirectory as NSString).appendingPathComponent((sourceFilePath as NSString).lastPathComponent)
      if FileManager.default.fileExists(atPath: destinationFilePath) {
        try FileManager.default.removeItem(atPath: destinationFilePath)
      }
      try FileManager.default.copyItem(atPath: sourceFilePath, toPath: destinationFilePath)
    }
  }

  public func clear() async throws {
    try await simulator.runSimulatorFrameworkBridge(.clearContacts)
  }

  // MARK: - Private

  private static let permissibleAddressBookDBFilenames: Set<String> = [
    "AddressBook.sqlitedb",
    "AddressBook.sqlitedb-shm",
    "AddressBook.sqlitedb-wal",
    "AddressBookImages.sqlitedb",
    "AddressBookImages.sqlitedb-shm",
    "AddressBookImages.sqlitedb-wal",
  ]

  private static func contactsDatabaseFilePaths(fromContainingDirectory databaseDirectory: String) throws -> [String] {
    var filePaths: [String] = []
    guard let enumerator = FileManager.default.enumerator(atPath: databaseDirectory) else {
      throw SimulatorContactsError.contactsDirectoryEnumerationFailed(path: databaseDirectory)
    }

    for case let path as String in enumerator {
      if !permissibleAddressBookDBFilenames.contains((path as NSString).lastPathComponent) {
        continue
      }
      let fullPath = (databaseDirectory as NSString).appendingPathComponent(path)
      filePaths.append(fullPath)
    }

    if filePaths.isEmpty {
      throw SimulatorContactsError.noContactsDatabases
    }

    return filePaths
  }
}

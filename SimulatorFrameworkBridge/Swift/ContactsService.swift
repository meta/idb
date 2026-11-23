/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#if !os(tvOS) && !os(watchOS)
import Contacts
import Foundation

#if canImport(SimulatorFrameworkBridgeRuntime)
internal import SimulatorFrameworkBridgeRuntime
#endif

private func FBContactsClearWithStore(contactStore: CNContactStore, makeSaveRequest: () -> CNSaveRequest, output: BridgeOutput? = nil) -> Int {
  let client = FBContactsStoreClient(store: contactStore)
  var fetchError: NSError?
  let allContacts = unsafe client.fetchContacts(error: &fetchError)

  guard let allContacts else {
    NSLog("Failed to fetch contacts: %@", fetchError?.localizedDescription ?? "(null)")
    return output?.failure("Failed to fetch contacts: \(fetchError?.localizedDescription ?? "unknown error")") ?? 1
  }

  NSLog("Found %lu contacts to delete", UInt(allContacts.count))

  if allContacts.isEmpty {
    NSLog("No contacts to delete")
    return 0
  }

  let saveRequest = makeSaveRequest()
  for contact in allContacts {
    guard let mutableContact = contact.mutableCopy() as? CNMutableContact else {
      return output?.failure("Could not create a mutable contact for deletion") ?? 1
    }
    saveRequest.delete(mutableContact)
  }

  var deleteError: NSError?
  let success = unsafe client.execute(saveRequest, error: &deleteError)

  guard success else {
    NSLog("Failed to delete contacts: %@", deleteError?.localizedDescription ?? "(null)")
    return output?.failure("Failed to delete contacts: \(deleteError?.localizedDescription ?? "unknown error")") ?? 1
  }

  NSLog("Successfully deleted all contacts")
  return 0
}

public enum ContactsService {
  public static func clear(with store: CNContactStore, makeSaveRequest: () -> CNSaveRequest) -> Int {
    FBContactsClearWithStore(contactStore: store, makeSaveRequest: makeSaveRequest)
  }

  public static func handleContactsAction(action: String) -> Int {
    handleContactsAction(action: action, output: nil)
  }

  static func handleContactsAction(action: String, output: BridgeOutput?) -> Int {
    if action == "clear" {
      return FBContactsClearWithStore(
        contactStore: CNContactStore(),
        makeSaveRequest: {
          CNSaveRequest()
        },
        output: output
      )
    } else {
      NSLog("Unknown action: %@", action)
      return 1
    }
  }
}
#endif

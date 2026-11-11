/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

/// How long a response may be reused without asking the server again, read from its caching headers as RFC 9111
/// §4.2 describes: an explicit freshness lifetime from `Cache-Control: max-age` or `Expires`, less the response's
/// `Age`. A response that says nothing about its lifetime, or forbids reuse, has none: heuristic freshness is not used.
public struct HTTPFreshness: Sendable, Equatable {

  /// How long after it was received the response stays fresh. Nil when it may not be reused.
  public let lifetime: TimeInterval?

  public init(lifetime: TimeInterval?) {
    self.lifetime = lifetime
  }

  /// Reads the freshness of a response whose header named, case-insensitively, by its argument is what `header`
  /// returns.
  public init(header: (String) -> String?) {
    let directives = Self.directives(header("Cache-Control"))
    guard directives["no-store"] == nil, directives["no-cache"] == nil else {
      self.init(lifetime: nil)
      return
    }
    // Repeated `Age` headers arrive joined into a list; the largest age is the one that cannot overstate freshness, and a
    // value that does not parse leaves the response's age unknown.
    let ages = header("Age")?.split(separator: ",").map { TimeInterval($0.trimmingCharacters(in: .whitespaces)) } ?? []
    guard !ages.contains(nil) else {
      self.init(lifetime: nil)
      return
    }
    let age = max(0, ages.compactMap { $0 }.max() ?? 0)
    let explicit: TimeInterval?
    if let maxAge = directives["max-age"].flatMap({ TimeInterval($0) }) {
      explicit = maxAge
    } else if let expires = header("Expires").flatMap(Self.date(from:)) {
      // `Expires` is relative to the server's `Date`, which a response without one is taken to have sent now.
      explicit = expires.timeIntervalSince(header("Date").flatMap(Self.date(from:)) ?? Date())
    } else {
      explicit = nil
    }
    guard let explicit, explicit - age > 0 else {
      self.init(lifetime: nil)
      return
    }
    self.init(lifetime: explicit - age)
  }

  /// The `Cache-Control` directives, by lowercased name, each with its argument or an empty string. A repeated directive
  /// keeps its first occurrence, as RFC 9111 §4.2.1 allows.
  static func directives(_ value: String?) -> [String: String] {
    var directives: [String: String] = [:]
    for part in (value ?? "").split(separator: ",") {
      let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
      guard let name = pair.first?.lowercased(), !name.isEmpty, directives[name] == nil else {
        continue
      }
      directives[name] = pair.count > 1 ? pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) : ""
    }
    return directives
  }

  /// An HTTP-date in the preferred IMF-fixdate form, such as `Sun, 06 Nov 1994 08:49:37 GMT`.
  static func date(from value: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter.date(from: value.trimmingCharacters(in: .whitespaces))
  }
}

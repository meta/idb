/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation
import Security

/// What a download learned about the connection that served it, beyond the bytes it delivered.
public struct DownloadReport: Sendable, Equatable {

  /// A certificate the server presented.
  public struct Certificate: Sendable, Equatable {
    public let subject: String?
    public let issuer: String?
    public let notAfter: Date?

    public init(subject: String?, issuer: String?, notAfter: Date?) {
      self.subject = subject
      self.issuer = issuer
      self.notAfter = notAfter
    }
  }

  /// Why the server's certificate chain was not trusted, and the chain itself.
  public struct Trust: Sendable, Equatable {
    /// Nil when the chain evaluates as trusted now, as it can once a host's trust settings change.
    public let error: String?
    public let chain: [Certificate]

    public init(error: String?, chain: [Certificate]) {
      self.error = error
      self.chain = chain
    }
  }

  public var receivedBytes: Int64
  /// From starting the request to its final response arriving, redirects included. Nil when no response arrived.
  public var timeToFirstByte: TimeInterval?
  /// The address of the server, or of the proxy when `proxied`.
  public var remoteAddress: String?
  /// Nil when the download never got as far as a transaction.
  public var proxied: Bool?
  public var trust: Trust?
  /// How long the response may be reused, from its caching headers. Nil when no response arrived.
  public var freshness: HTTPFreshness?

  public init(
    receivedBytes: Int64 = 0, timeToFirstByte: TimeInterval? = nil, remoteAddress: String? = nil, proxied: Bool? = nil, trust: Trust? = nil
  ) {
    self.receivedBytes = receivedBytes
    self.timeToFirstByte = timeToFirstByte
    self.remoteAddress = remoteAddress
    self.proxied = proxied
    self.trust = trust
  }

  /// The last transaction is the one that failed or delivered the response; earlier ones were redirects.
  /// A transaction that failed before connecting, including a failed TLS handshake, reports no address
  /// and a false `isProxyConnection`, which says nothing about the path, so it is not recorded.
  mutating func observe(_ metrics: URLSessionTaskMetrics) {
    guard let transaction = metrics.transactionMetrics.last, transaction.connectStartDate != nil || transaction.remoteAddress != nil else {
      return
    }
    remoteAddress = transaction.remoteAddress
    proxied = transaction.isProxyConnection
  }
}

extension DownloadReport.Trust {

  /// Evaluates `trust` again, which may reach the network for revocation or missing intermediates, so this
  /// is only for a download that has already failed.
  public init(evaluating trust: SecTrust) {
    var error: CFError?
    let trusted = SecTrustEvaluateWithError(trust, &error)
    let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? []
    self.init(
      error: trusted ? nil : error.map { ($0 as Error).localizedDescription } ?? "untrusted",
      chain: certificates.map(DownloadReport.Certificate.init(certificate:)))
  }

  /// The trust a TLS failure's error carries, or nil when it carries none.
  init?(failure error: Error) {
    let nsError = error as NSError
    let value = nsError.userInfo[NSURLErrorFailingURLPeerTrustErrorKey] as CFTypeRef?
    guard let value, CFGetTypeID(value) == SecTrustGetTypeID() else {
      return nil
    }
    self.init(evaluating: unsafeDowncast(value, to: SecTrust.self))
  }
}

extension DownloadReport.Certificate {

  init(certificate: SecCertificate) {
    var commonName: CFString?
    SecCertificateCopyCommonName(certificate, &commonName)
    let keys = [kSecOIDX509V1IssuerName, kSecOIDX509V1ValidityNotAfter] as CFArray
    let values = SecCertificateCopyValues(certificate, keys, nil) as? [String: [String: Any]] ?? [:]
    let issuer =
      (values[kSecOIDX509V1IssuerName as String]?[kSecPropertyKeyValue as String] as? [[String: Any]])?
      .first { $0[kSecPropertyKeyLabel as String] as? String == kSecOIDCommonName as String }?[kSecPropertyKeyValue as String] as? String
    let notAfter = (values[kSecOIDX509V1ValidityNotAfter as String]?[kSecPropertyKeyValue as String] as? NSNumber)
      .map { Date(timeIntervalSinceReferenceDate: $0.doubleValue) }
    self.init(subject: commonName as String?, issuer: issuer, notAfter: notAfter)
  }
}

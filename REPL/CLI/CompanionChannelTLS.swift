/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CompanionDiscovery

/// Whether TLS to a companion is supported on this platform.
#if os(macOS)
let companionTLSSupported = true
#else
let companionTLSSupported = false
#endif

/// Chooses how a companion connection sources its TLS identity: `--plaintext` forces
/// plaintext, and so does a platform where TLS is not supported. `tlsSupported`
/// defaults to the platform capability but can be overridden in tests.
func planCompanionClientTLS(
  plaintext: Bool,
  tlsSupported: Bool = companionTLSSupported
) -> CompanionClientTLS {
  plaintext || !tlsSupported ? .disabled : .metaIdentity
}

/// Selects the client TLS identity to present when connecting to a companion, or
/// nil when the connection should be plaintext.
///
/// TLS applies only to a TCP companion whose `tls` mode is `.metaIdentity` and for
/// which the registered `CompanionTLSProvider` supplies a client identity. A Unix
/// domain socket, `.disabled`, or a missing provider/identity is plaintext. This
/// mirrors the choice `CompanionClient` makes for the JSON-RPC transport (present
/// the identity; the peer is not verified), keeping the two transports consistent.
func replClientTLSIdentity(
  for address: CompanionAddress,
  tls: CompanionClientTLS,
  provider: (any CompanionTLSProvider)?
) -> CompanionTLSIdentity? {
  guard case .tcp = address, tls == .metaIdentity else {
    return nil
  }
  return provider?.clientIdentity()
}

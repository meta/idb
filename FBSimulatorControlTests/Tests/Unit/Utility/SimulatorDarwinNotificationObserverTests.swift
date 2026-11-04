/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import FBSimulatorControl
import Foundation
import Testing

@Suite
struct SimulatorDarwinNotificationObserverTests {
  @Test func unavailableStateSelectorDoesNotInvokeTheGetter() throws {
    let fixture = try SimulatorNotificationFixture(supportsStateRead: false)
    do {
      _ = try SimulatorDarwinNotificationObserver.state(on: fixture.simulator, name: "com.example.settings")
      Issue.record("Expected unsupported state reading")
    } catch {
      guard case SimulatorNotificationObservationError.unsupported = error else {
        Issue.record("Unexpected error: \(error)")
        return
      }
    }
    #expect(fixture.device.stateReads == 0)
  }

  @Test(arguments: [UInt64(0), UInt64(60)])
  func supportedStateSelectorReturnsNativeValue(value: UInt64) throws {
    let fixture = try SimulatorNotificationFixture()
    fixture.device.change(state: value)
    #expect(try SimulatorDarwinNotificationObserver.state(on: fixture.simulator, name: "com.example.settings") == value)
    #expect(fixture.device.stateReads == 1)
  }

  @Test(arguments: [UInt64(1), UInt64.max])
  func stateTransitionsRequireBootedAndCleanUpOnce(rawState: UInt64) async throws {
    let fixture = try SimulatorNotificationFixture()
    let subscription = try await SimulatorDarwinNotificationObserver.subscribe(on: fixture.simulator, name: "com.example.settings")
    defer { subscription.cancel() }
    fixture.device.changeDeviceState(3)
    #expect(subscription.failure() == nil)
    #expect(fixture.device.stateRemovals == 0)
    #expect(fixture.device.tokenInvalidations == 0)
    fixture.device.change(state: 60)
    var iterator = subscription.changes.makeAsyncIterator()
    guard (try await iterator.next()) != nil else {
      Issue.record("Booted state ended the observation")
      return
    }
    fixture.device.changeDeviceState(rawState)
    do {
      while (try await iterator.next()) != nil { Issue.record("Unexpected change after leaving booted") }
      Issue.record("Expected not-booted failure")
    } catch {
      guard case SimulatorNotificationObservationError.notBooted = error else {
        Issue.record("Unexpected error: \(error)")
        return
      }
      #expect(SimulatorFailureKind(error) == .notReady)
    }
    fixture.device.changeDeviceState(rawState)
    subscription.cancel()
    #expect(fixture.device.stateRemovals == 1)
    #expect(fixture.device.tokenInvalidations == 1)
  }

  @Test func registrationPrecedesTheInitialRead() async throws {
    let fixture = NotificationRegistrationFixture()
    let subscription = try await SimulatorDarwinNotificationObserver.subscribe(register: fixture.register)
    let values = SimulatorDarwinNotificationObserver.values(subscription: subscription) { initial in
      #expect(fixture.isRegistered)
      return initial ? 60 : 30
    }
    var iterator = values.makeAsyncIterator()
    #expect(try await iterator.next() == 60)
    fixture.changed()
    #expect(try await iterator.next() == 30)
    subscription.cancel()
    #expect(fixture.cancellations == 1)
  }

  @Test func cancellationInvalidatesTheRegistrationOnce() async throws {
    let fixture = NotificationRegistrationFixture()
    let subscription = try await SimulatorDarwinNotificationObserver.subscribe(register: fixture.register)
    let consumer = Task { for try await _ in subscription.changes {} }
    consumer.cancel()
    _ = await consumer.result
    subscription.cancel()
    #expect(fixture.cancellations == 1)
  }

  @Test func cancellationDuringRegistrationInvalidatesALateToken() async {
    let fixture = NotificationRegistrationFixture(deferred: true)
    let registration = Task { try await SimulatorDarwinNotificationObserver.subscribe(register: fixture.register) }
    await fixture.waitForRegistration()
    registration.cancel()
    if case .success = await registration.result { Issue.record("Expected cancelled registration") }
    fixture.complete()
    #expect(fixture.cancellations == 1)
  }

  @Test func registrationFailurePropagates() async {
    do {
      _ = try await SimulatorDarwinNotificationObserver.subscribe { _, registered, _ in
        registered(.failure(NotificationFixtureError.failed))
      }
      Issue.record("Expected registration failure")
    } catch {
      #expect(error is NotificationFixtureError)
    }
  }

  @Test func sourceFailureDuringRegistrationPreservesItsError() async {
    let fixture = NotificationRegistrationFixture(deferred: true)
    let registration = Task { try await SimulatorDarwinNotificationObserver.subscribe(register: fixture.register) }
    await fixture.waitForRegistration()
    fixture.fail()
    switch await registration.result {
    case .success: Issue.record("Expected registration to fail")
    case let .failure(error): #expect(error is NotificationFixtureError)
    }
    fixture.complete()
    #expect(fixture.cancellations == 1)
  }

  @Test func sourceFailurePropagatesAndReleasesTheToken() async throws {
    let fixture = NotificationRegistrationFixture()
    let subscription = try await SimulatorDarwinNotificationObserver.subscribe(register: fixture.register)
    fixture.fail()
    do {
      for try await _ in subscription.changes {}
      Issue.record("Expected source failure")
    } catch {
      #expect(error is NotificationFixtureError)
    }
    #expect(fixture.cancellations == 1)
  }

  @Test func sourceFailureBeforeInitialReadPreventsTheRead() async throws {
    let fixture = NotificationRegistrationFixture()
    let subscription = try await SimulatorDarwinNotificationObserver.subscribe(register: fixture.register)
    fixture.fail()
    let values: AsyncThrowingStream<Int, Error> = SimulatorDarwinNotificationObserver.values(subscription: subscription) { _ in
      Issue.record("Read started after the source failed")
      throw NotificationFixtureError.readFailed
    }
    do {
      for try await _ in values { Issue.record("Value emitted after the source failed") }
      Issue.record("Expected source failure")
    } catch {
      #expect(error as? NotificationFixtureError == .failed)
    }
    subscription.cancel()
    #expect(fixture.cancellations == 1)
  }

  @Test(arguments: [false, true])
  func sourceFailureDuringReadRemainsAuthoritative(readSucceeds: Bool) async throws {
    let fixture = NotificationRegistrationFixture()
    let subscription = try await SimulatorDarwinNotificationObserver.subscribe(register: fixture.register)
    let (started, start) = AsyncStream.makeStream(of: Void.self)
    let (release, resume) = AsyncStream.makeStream(of: Void.self)
    let values: AsyncThrowingStream<Int, Error> = SimulatorDarwinNotificationObserver.values(subscription: subscription) { _ in
      start.yield(())
      start.finish()
      for await _ in release {}
      if readSucceeds { return 60 }
      throw NotificationFixtureError.readFailed
    }
    var iterator = started.makeAsyncIterator()
    _ = await iterator.next()
    fixture.fail()
    resume.finish()
    do {
      for try await _ in values { Issue.record("Value emitted after the source failed") }
      Issue.record("Expected source failure")
    } catch {
      #expect(error as? NotificationFixtureError == .failed)
    }
    subscription.cancel()
    #expect(fixture.cancellations == 1)
  }

  @Test func readFailureReleasesTheSubscription() async throws {
    let fixture = NotificationRegistrationFixture()
    let subscription = try await SimulatorDarwinNotificationObserver.subscribe(register: fixture.register)
    let values: AsyncThrowingStream<Int, Error> = SimulatorDarwinNotificationObserver.values(subscription: subscription) { _ in
      throw NotificationFixtureError.failed
    }
    do {
      for try await _ in values {}
      Issue.record("Expected read failure")
    } catch {
      #expect(error is NotificationFixtureError)
    }
    #expect(fixture.cancellations == 1)
  }
}

private enum NotificationFixtureError: Error, Equatable { case failed, readFailed }

// SAFETY: `lock` guards callbacks, registration readiness and cancellation counts.
private final class NotificationRegistrationFixture: @unchecked Sendable {
  private let lock = NSLock()
  private let deferred: Bool
  private var onChange: (@Sendable () -> Void)?
  private var onFailure: (@Sendable (Error) -> Void)?
  private var onRegistered: (@Sendable (Result<SimulatorDarwinNotificationObserver.Cancel, Error>) -> Void)?
  private var ready: CheckedContinuation<Void, Never>?
  private var count = 0

  init(deferred: Bool = false) { self.deferred = deferred }

  var isRegistered: Bool { lock.withLock { onRegistered != nil } }
  var cancellations: Int { lock.withLock { count } }

  func register(
    changed: @escaping @Sendable () -> Void,
    registered: @escaping @Sendable (Result<SimulatorDarwinNotificationObserver.Cancel, Error>) -> Void,
    failed: @escaping @Sendable (Error) -> Void
  ) {
    let ready = lock.withLock {
      onChange = changed
      onFailure = failed
      onRegistered = registered
      let ready = self.ready
      self.ready = nil
      return ready
    }
    ready?.resume()
    if !deferred { complete() }
  }

  func waitForRegistration() async {
    await withCheckedContinuation { ready in
      let registered = lock.withLock {
        if onRegistered != nil { return true }
        self.ready = ready
        return false
      }
      if registered { ready.resume() }
    }
  }

  func complete() {
    let registered = lock.withLock { onRegistered }
    registered?(.success { self.lock.withLock { self.count += 1 } })
  }

  func changed() { lock.withLock { onChange }?() }
  func fail() { lock.withLock { onFailure }?(NotificationFixtureError.failed) }
}

/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import XPC

/// The `streamhingeangle` feature: the stream it asks for and the samples it pushes back.
enum SimulatorHingeProtocol {
  static let service = "com.apple.coredevice.feature.monitormotion"
  static let action = "com.apple.coredevice.action.streamhingeangle"

  /// A CoreDevice duration: signed high bits and unsigned low bits, in attoseconds.
  struct Duration: Encodable {
    let attoseconds: UInt64

    static let hundredMilliseconds = Duration(attoseconds: 100_000_000_000_000_000)

    func encode(to encoder: any Encoder) throws {
      var container = encoder.unkeyedContainer()
      try container.encode(Int64(0))
      try container.encode(attoseconds)
    }
  }

  /// A CoreDevice measurement unit; the hinge angle is requested and reported in plain degrees.
  struct Unit: Codable, Equatable {
    struct Converter: Codable, Equatable {
      let coefficient: Double
      let constant: Double
    }
    let symbol: String
    let converter: Converter

    static let degrees = Unit(symbol: "°", converter: Converter(coefficient: 1, constant: 0))
  }

  struct Measurement: Codable {
    let value: Double
    let unit: Unit
  }

  /// The input of `streamhingeangle`: how often and on what change to push samples, and the side
  /// channel they are pushed on.
  struct StreamInput: Encodable {
    struct ActualInput: Encodable {
      let changeThreshold: Measurement
      let updateInterval: Duration
    }
    struct StreamProxy: Encodable {
      let sideChannel: UUID
    }
    let actualInput: ActualInput
    let streamProxy: StreamProxy

    init(channel: UUID) {
      actualInput = ActualInput(changeThreshold: Measurement(value: 0.1, unit: .degrees), updateInterval: .hundredMilliseconds)
      streamProxy = StreamProxy(sideChannel: channel)
    }
  }

  /// One pushed event: the side channel it belongs to and a batch of samples.
  struct StreamEvent: Decodable {
    /// A sample the provider marks invalid is not read further, and a valid one's angle is only
    /// read if the sample is fresh enough to be used, so junk in a skipped sample is ignored.
    enum Sample: Decodable {
      case invalid
      case valid(timestamp: Double, angle: Result<Measurement, DecodingError>)

      private enum CodingKeys: String, CodingKey {
        case isAngleValid, timestamp, angle
      }

      init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Bool.self, forKey: .isAngleValid) else {
          self = .invalid
          return
        }
        let timestamp = try container.decode(Double.self, forKey: .timestamp)
        do {
          self = .valid(timestamp: timestamp, angle: .success(try container.decode(Measurement.self, forKey: .angle)))
        } catch let error as DecodingError {
          self = .valid(timestamp: timestamp, angle: .failure(error))
        }
      }
    }
    struct Pushing: Decodable {
      let elements: [Sample]
    }
    struct Status: Decodable {
      let pushing: Pushing
    }

    let channel: String
    let status: Status

    private enum CodingKeys: String, CodingKey {
      case channel = "XPCSideChannel.uniqueIdentifier"
      case status = "CoreDevice.XPCMessageKey.sideChannelStatus"
    }
  }

  private static let maximumSamples = 64

  /// The freshest valid angle in `event` measured at or after `notBefore`, or nil when the batch
  /// holds none. A sample from the future, in a unit other than degrees, or on another channel is
  /// malformed.
  static func sample(
    _ event: xpc_object_t, channel: UUID, notBefore: TimeInterval, now: TimeInterval
  ) throws -> SimulatorHingeAngle? {
    let event = try SimulatorCoreDevice.decode(StreamEvent.self, from: event)
    guard event.channel == channel.uuidString else { throw SimulatorCoreDeviceError.malformed("Unexpected side channel") }
    let samples = event.status.pushing.elements
    guard samples.count <= maximumSamples else { throw SimulatorCoreDeviceError.malformed("Oversized sample batch") }
    var latest: (timestamp: Double, angle: SimulatorHingeAngle)?
    for case let .valid(timestamp, angle) in samples {
      guard timestamp.isFinite else { throw SimulatorCoreDeviceError.malformed("timestamp") }
      guard timestamp <= now else { throw SimulatorCoreDeviceError.malformed("Sample timestamp is in the future") }
      guard timestamp >= notBefore else { continue }
      let measurement: Measurement
      do { measurement = try angle.get() } catch { throw SimulatorCoreDeviceError(decoding: error) }
      guard measurement.value.isFinite else { throw SimulatorCoreDeviceError.malformed("angle") }
      guard measurement.unit == .degrees else { throw SimulatorCoreDeviceError.malformed("Angle is not in degrees") }
      let angle = try SimulatorHingeAngle(degrees: measurement.value)
      if let latest, timestamp < latest.timestamp { continue }
      latest = (timestamp, angle)
    }
    return latest?.angle
  }
}

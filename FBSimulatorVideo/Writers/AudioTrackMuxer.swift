/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import AVFoundation
import CoreMedia
import FBControlCore
import FBVideoCore
import Foundation
import UniformTypeIdentifiers

enum AudioTrackMuxerError: Error, LocalizedError {
  case unreadableAudio(path: String, reason: String)
  case unsupportedRecording(path: String, reason: String)
  case cannotWrite(String)

  var errorDescription: String? {
    switch self {
    case let .unreadableAudio(path, reason):
      return "Cannot read the audio in \(path): \(reason)"
    case let .unsupportedRecording(path, reason):
      return "Cannot add audio to \(path): \(reason)"
    case let .cannotWrite(reason):
      return "Cannot write the recording with its audio: \(reason)"
    }
  }
}

/// Adds an AAC track to a finished MP4 or MOV recording. Like chapters, audio is written afterwards:
/// the video is copied through a passthrough writer with the audio alongside, and the copy replaces
/// the original.
enum AudioTrackMuxer {

  /// High enough that speech and music are transparent.
  static let bitRate = 256_000

  /// One source track copied into the new file, and how its samples move on the way.
  private struct Copy {
    let output: AVAssetReaderTrackOutput
    let input: AVAssetWriterInput
    let reader: AVAssetReader
    /// Added to every sample's timestamps.
    let shift: CMTime
    let isAudio: Bool
  }

  /// Rewrites the recording at `outputURL` with the audio in `wavURL` as its own track, the WAV's
  /// first frame `offset` seconds after the recording's start. The part of the audio a negative
  /// offset puts before the start is cut. On success the file at `outputURL` is replaced atomically.
  static func addAudio(
    fromWAV wavURL: URL, offset: Double, to outputURL: URL, fileType: AVFileType, logger: any ControlCoreLogger
  ) async throws -> AudioTrackPlacement {
    let audioAsset = AVURLAsset(url: wavURL)
    let audioTrack: AVAssetTrack
    let sampleRate: Double
    let channels: Int
    do {
      guard let track = try await audioAsset.loadTracks(withMediaType: .audio).first,
        let format = try await track.load(.formatDescriptions).first,
        let description = unsafe CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
      else {
        throw AudioTrackMuxerError.unreadableAudio(path: wavURL.path, reason: "it holds no audio track")
      }
      // Both become the AAC encoder's settings, and the rate the `CMTimeScale` every audio time is counted in.
      guard (1...Double(CMTimeScale.max)).contains(description.mSampleRate), description.mChannelsPerFrame > 0 else {
        throw AudioTrackMuxerError.unreadableAudio(
          path: wavURL.path,
          reason: "it reports \(description.mChannelsPerFrame) channels at \(description.mSampleRate) Hz")
      }
      audioTrack = track
      sampleRate = description.mSampleRate
      channels = Int(description.mChannelsPerFrame)
    } catch let error as AudioTrackMuxerError {
      throw error
    } catch {
      throw AudioTrackMuxerError.unreadableAudio(path: wavURL.path, reason: error.localizedDescription)
    }

    // The recording is the container `fileType` names, whatever its file name says.
    guard let filenameExtension = UTType(fileType.rawValue)?.preferredFilenameExtension else {
      throw AudioTrackMuxerError.unsupportedRecording(path: outputURL.path, reason: "unknown container type")
    }
    let videoURL = outputURL.appendingPathExtension("video-\(UUID().uuidString)").appendingPathExtension(filenameExtension)
    try FileManager.default.linkItem(at: outputURL, to: videoURL)
    defer { try? FileManager.default.removeItem(at: videoURL) }
    let videoAsset = AVURLAsset(url: videoURL)
    let tracks: [AVAssetTrack]
    do {
      tracks = try await videoAsset.load(.tracks)
    } catch {
      throw AudioTrackMuxerError.unsupportedRecording(path: outputURL.path, reason: error.localizedDescription)
    }
    let videoTracks = tracks.filter { $0.mediaType == .video }
    guard !videoTracks.isEmpty, videoTracks.count == tracks.count else {
      throw AudioTrackMuxerError.unsupportedRecording(
        path: outputURL.path, reason: "audio is added only to a recording of video alone")
    }

    let temporaryURL = outputURL.appendingPathExtension("audio-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temporaryURL) }
    let videoReader = try AVAssetReader(asset: videoAsset)
    let audioReader = try AVAssetReader(asset: audioAsset)
    let writer = try AVAssetWriter(outputURL: temporaryURL, fileType: fileType)
    writer.shouldOptimizeForNetworkUse = true

    var copies: [Copy] = []
    for track in videoTracks {
      let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
      videoReader.add(output)
      let input = AVAssetWriterInput(
        mediaType: .video, outputSettings: nil, sourceFormatHint: try await track.load(.formatDescriptions).first)
      input.transform = try await track.load(.preferredTransform)
      guard writer.canAdd(input) else {
        throw AudioTrackMuxerError.cannotWrite("AVAssetWriter cannot add the video input")
      }
      writer.add(input)
      copies.append(Copy(output: output, input: input, reader: videoReader, shift: .zero, isAudio: false))
    }

    let cut = max(0, -offset)
    let timescale = CMTimeScale(sampleRate.rounded())
    audioReader.timeRange = CMTimeRange(
      start: CMTime(seconds: cut, preferredTimescale: timescale), duration: .positiveInfinity)
    let audioOutput = AVAssetReaderTrackOutput(
      track: audioTrack,
      outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsNonInterleaved: false,
        AVLinearPCMIsBigEndianKey: false,
      ])
    audioReader.add(audioOutput)
    let audioInput = AVAssetWriterInput(
      mediaType: .audio,
      outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: channels,
        AVEncoderBitRateKey: bitRate,
      ])
    audioInput.expectsMediaDataInRealTime = false
    guard writer.canAdd(audioInput) else {
      throw AudioTrackMuxerError.cannotWrite("AVAssetWriter cannot add an AAC input at \(sampleRate) Hz")
    }
    writer.add(audioInput)
    copies.append(
      Copy(
        output: audioOutput, input: audioInput, reader: audioReader,
        shift: CMTime(seconds: offset, preferredTimescale: timescale), isAudio: true))

    guard writer.startWriting(), videoReader.startReading(), audioReader.startReading() else {
      throw AudioTrackMuxerError.cannotWrite(
        "cannot start: \(String(describing: writer.error ?? videoReader.error ?? audioReader.error))")
    }
    defer {
      for reader in [videoReader, audioReader] where reader.status == .reading {
        reader.cancelReading()
      }
      if writer.status == .writing {
        writer.cancelWriting()
      }
    }
    writer.startSession(atSourceTime: .zero)
    let frames = try await copySamples(copies, writer: writer)
    await writer.finishWriting()
    guard writer.status == .completed else {
      throw AudioTrackMuxerError.cannotWrite(String(describing: writer.error))
    }
    _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: temporaryURL)
    logger.log("Added \(frames) frames of audio to \(outputURL.path), starting \(offset) s into the video")
    return AudioTrackPlacement(offset: offset, frames: frames)
  }

  /// Feeds whichever inputs are ready until every copy is done, and returns the audio frames written.
  /// Waiting on one input alone can keep another from draining.
  private static func copySamples(_ copies: [Copy], writer: AVAssetWriter) async throws -> Int {
    var finished = Array(repeating: false, count: copies.count)
    var frames = 0
    var progressDeadline = ContinuousClock.now + .seconds(10)
    while finished.contains(false) {
      try Task.checkCancellation()
      var madeProgress = false
      for (index, copy) in copies.enumerated() where !finished[index] && copy.input.isReadyForMoreMediaData {
        madeProgress = true
        guard let sample = copy.output.copyNextSampleBuffer() else {
          guard copy.reader.status == .completed else {
            throw AudioTrackMuxerError.cannotWrite(String(describing: copy.reader.error))
          }
          copy.input.markAsFinished()
          finished[index] = true
          continue
        }
        let count = CMSampleBufferGetNumSamples(sample)
        guard count > 0 else {
          continue
        }
        guard copy.input.append(try shifted(sample, by: copy.shift)) else {
          throw AudioTrackMuxerError.cannotWrite(String(describing: writer.error))
        }
        if copy.isAudio {
          frames += count
        }
      }
      if madeProgress {
        progressDeadline = ContinuousClock.now + .seconds(10)
      } else {
        guard writer.status == .writing, ContinuousClock.now < progressDeadline else {
          throw AudioTrackMuxerError.cannotWrite("stopped making progress: \(String(describing: writer.error))")
        }
        try await Task.sleep(for: .milliseconds(1))
      }
    }
    return frames
  }

  private static func shifted(_ sample: CMSampleBuffer, by shift: CMTime) throws -> CMSampleBuffer {
    guard shift != .zero else {
      return sample
    }
    var count: CMItemCount = 0
    unsafe CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
    var timing = Array(repeating: CMSampleTimingInfo(), count: count)
    unsafe CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
    for index in timing.indices {
      timing[index].presentationTimeStamp = CMTimeAdd(timing[index].presentationTimeStamp, shift)
      if timing[index].decodeTimeStamp.isValid {
        timing[index].decodeTimeStamp = CMTimeAdd(timing[index].decodeTimeStamp, shift)
      }
    }
    var copy: CMSampleBuffer?
    let status = unsafe CMSampleBufferCreateCopyWithNewTiming(
      allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: count, sampleTimingArray: &timing,
      sampleBufferOut: &copy)
    guard status == noErr, let copy else {
      throw AudioTrackMuxerError.cannotWrite("cannot retime an audio sample: OSStatus \(status)")
    }
    return copy
  }
}

/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import AVFoundation
import CoreMedia
import FBControlCore
import FBSimulatorControl
import Foundation

enum ChapterTrackMuxerError: Error, LocalizedError {
  case cannotAddVideoInput
  case cannotWriteChapter(String)
  case cannotWriteVideo(String)
  case assetWriterFailedToFinish(errorDescription: String)

  var errorDescription: String? {
    switch self {
    case .cannotAddVideoInput:
      return "AVAssetWriter cannot add the video input"
    case let .cannotWriteChapter(reason):
      return "Cannot write chapter: \(reason)"
    case let .cannotWriteVideo(reason):
      return "Cannot write video: \(reason)"
    case let .assetWriterFailedToFinish(errorDescription):
      return "AVAssetWriter failed to finish writing: \(errorDescription)"
    }
  }
}

/// Adds a QuickTime chapter track to a finished recording. `AVAssetWriter` cannot append a track to a
/// file it has closed, and a live chapter input on the recording writer blocks video writes while it
/// waits for chapter samples across long frame gaps, so chapters are written afterwards: the video is
/// copied through a second passthrough writer with the chapter track alongside, and the copy replaces
/// the original.
enum ChapterTrackMuxer {
  /// A chapter marker: the title and the absolute presentation time it starts at. An invalid time
  /// means "before the first frame" and resolves to the start of the movie.
  struct Marker: Sendable {
    let time: CMTime
    let text: String
  }

  /// Chapter durations use 32-bit ticks; nanosecond precision overflows after 4.3 seconds.
  private static let chapterTimeScale: CMTimeScale = 600

  /// Rewrites the recording at `outputURL` with a chapter track carrying `markers`, each running until
  /// the next and the last until `videoEnd`. Marker times are absolute presentation times; `sessionStart`
  /// is the time the movie's timeline starts at. Throws if the file has no video track or the remux
  /// fails; on success the file at `outputURL` is replaced atomically.
  static func addChapters(_ markers: [Marker], sessionStart: CMTime, videoEnd: CMTime, to outputURL: URL, fileType: AVFileType, logger: any ControlCoreLogger) async throws {
    let temporaryURL = outputURL.appendingPathExtension("chapters-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temporaryURL) }
    let asset = AVURLAsset(url: outputURL)
    guard let track = try await asset.loadTracks(withMediaType: .video).first,
      let format = try await track.load(.formatDescriptions).first
    else { throw ChapterTrackMuxerError.cannotWriteVideo("recording has no video track") }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    reader.add(output)
    let writer = try AVAssetWriter(outputURL: temporaryURL, fileType: fileType)
    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
    guard writer.canAdd(videoInput) else { throw ChapterTrackMuxerError.cannotAddVideoInput }
    writer.add(videoInput)
    guard let (chapterInput, chapterFormatDescription) = addChapterTrack(to: writer, associatedWith: videoInput, logger: logger) else { return }
    guard writer.startWriting(), reader.startReading() else {
      throw ChapterTrackMuxerError.cannotWriteVideo("cannot start chapter mux: \(String(describing: writer.error ?? reader.error))")
    }
    defer {
      if reader.status == .reading { reader.cancelReading() }
      if writer.status == .writing { writer.cancelWriting() }
    }
    writer.startSession(atSourceTime: .zero)
    var chapters = makeChapterSamples(markers, sessionStart: sessionStart, videoEnd: videoEnd, formatDescription: chapterFormatDescription, logger: logger).makeIterator()
    var chapter = chapters.next()
    if chapter == nil { chapterInput.markAsFinished() }
    var videoFinished = false
    var progressDeadline = ContinuousClock.now + .seconds(10)
    // Feed whichever input is ready: waiting on one track alone can prevent the other from draining.
    while !videoFinished || chapter != nil {
      try Task.checkCancellation()
      var madeProgress = false
      if !videoFinished && videoInput.isReadyForMoreMediaData {
        if let sample = output.copyNextSampleBuffer() {
          if CMSampleBufferGetNumSamples(sample) > 0, !videoInput.append(sample) {
            throw ChapterTrackMuxerError.cannotWriteVideo(String(describing: writer.error))
          }
        } else {
          guard reader.status == .completed else {
            throw ChapterTrackMuxerError.cannotWriteVideo(String(describing: reader.error))
          }
          videoInput.markAsFinished()
          videoFinished = true
        }
        madeProgress = true
      }
      if let sample = chapter, chapterInput.isReadyForMoreMediaData {
        guard chapterInput.append(sample) else {
          throw ChapterTrackMuxerError.cannotWriteChapter(String(describing: writer.error))
        }
        chapter = chapters.next()
        if chapter == nil { chapterInput.markAsFinished() }
        madeProgress = true
      }
      if madeProgress {
        progressDeadline = ContinuousClock.now + .seconds(10)
      } else {
        guard writer.status == .writing, ContinuousClock.now < progressDeadline else {
          throw ChapterTrackMuxerError.cannotWriteVideo("chapter mux stopped making progress: \(String(describing: writer.error))")
        }
        try await Task.sleep(for: .milliseconds(1))
      }
    }
    await writer.finishWriting()
    guard writer.status == .completed else {
      throw ChapterTrackMuxerError.assetWriterFailedToFinish(errorDescription: String(describing: writer.error))
    }
    _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: temporaryURL)
  }

  /// Adds a QuickTime text input to `assetWriter`, associated with `videoInput` as its chapter list.
  /// Returns nil, having logged why, if the writer will not take one; the recording then goes out
  /// without chapters.
  private static func addChapterTrack(to assetWriter: AVAssetWriter, associatedWith videoInput: AVAssetWriterInput, logger: any ControlCoreLogger) -> (AVAssetWriterInput, CMFormatDescription)? {
    guard let formatDescription = makeChapterTextFormatDescription() else {
      logger.log("Failed to build chapter text format description; recording without chapters")
      return nil
    }
    let chapterInput = AVAssetWriterInput(mediaType: .text, outputSettings: nil, sourceFormatHint: formatDescription)
    chapterInput.expectsMediaDataInRealTime = false
    chapterInput.mediaTimeScale = chapterTimeScale
    // Tag the chapter titles as language-undetermined; players and `ffprobe -show_chapters` group
    // chapters by language, and an untagged track is skipped by AVFoundation's language-filtered reader.
    chapterInput.languageCode = "und"
    guard assetWriter.canAdd(chapterInput) else {
      logger.log("AVAssetWriter cannot add the chapter text input; recording without chapters")
      return nil
    }
    assetWriter.add(chapterInput)
    videoInput.addTrackAssociation(withTrackOf: chapterInput, type: AVAssetTrack.AssociationType.chapterList.rawValue)
    return (chapterInput, formatDescription)
  }

  /// Converts markers to text samples with contiguous time ranges: each chapter runs until the next
  /// one, and the last until the end of the recorded video.
  static func makeChapterSamples(_ markers: [Marker], sessionStart: CMTime, videoEnd: CMTime, formatDescription: CMFormatDescription, logger: any ControlCoreLogger) -> [CMSampleBuffer] {
    guard !markers.isEmpty else {
      return []
    }
    var resolved: [(time: CMTime, text: String)] = []
    for chapter in markers {
      let relativeTime = chapter.time.isValid ? CMTimeSubtract(chapter.time, sessionStart) : .zero
      let time = CMTimeConvertScale(relativeTime, timescale: chapterTimeScale, method: .roundHalfAwayFromZero)
      // QuickTime text samples cannot overlap. Updates within one video frame keep the latest title.
      if resolved.last?.time == time {
        resolved[resolved.count - 1] = (time, chapter.text)
      } else {
        resolved.append((time, chapter.text))
      }
    }
    let minDuration = CMTimeMake(value: 1, timescale: chapterTimeScale)
    let end = CMTimeConvertScale(CMTimeSubtract(videoEnd, sessionStart), timescale: chapterTimeScale, method: .roundHalfAwayFromZero)
    var samples: [CMSampleBuffer] = []
    for (index, chapter) in resolved.enumerated() {
      let start = chapter.time
      let rawEnd = index + 1 < resolved.count ? resolved[index + 1].time : end
      var duration = CMTimeSubtract(rawEnd, start)
      if !duration.isValid || duration <= .zero {
        duration = minDuration
      }
      guard let sample = makeChapterSampleBuffer(text: chapter.text, formatDescription: formatDescription, time: start, duration: duration) else {
        logger.log("Failed to build chapter sample for '\(chapter.text)', skipping")
        continue
      }
      samples.append(sample)
    }
    return samples
  }

  // MARK: - QuickTime Text Track Construction

  /// Build a QuickTime `'text'` sample description (the layout of the classic `TextDescription` struct
  /// from `Movies.h`, big-endian) and wrap it in a `CMTextFormatDescription`. The visual style fields
  /// are inert — chapter titles surface in player chapter menus, not as rendered captions.
  private static func makeChapterTextFormatDescription() -> CMFormatDescription? {
    var data = [UInt8]()
    func appendBE32(_ value: UInt32) {
      data.append(contentsOf: [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }
    func appendBE16(_ value: UInt16) {
      data.append(contentsOf: [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    appendBE32(0) // descSize, backfilled below
    data.append(contentsOf: Array("text".utf8)) // dataFormat
    appendBE32(0) // resvd1
    appendBE16(0) // resvd2
    appendBE16(1) // dataRefIndex
    appendBE32(0) // displayFlags
    appendBE32(0) // textJustification (left)
    appendBE16(0)
    appendBE16(0)
    appendBE16(0) // bgColor RGB
    appendBE16(0)
    appendBE16(0)
    appendBE16(0)
    appendBE16(0) // defaultTextBox (top,left,bottom,right)
    // defaultStyle (ScrpSTElement)
    appendBE32(0) // scrpStartChar
    appendBE16(0) // scrpHeight
    appendBE16(0) // scrpAscent
    appendBE16(0) // scrpFont
    appendBE16(0) // scrpFace
    appendBE16(12) // scrpSize
    appendBE16(0)
    appendBE16(0)
    appendBE16(0) // scrpColor RGB
    data.append(0) // textName: empty Pascal string

    let size = UInt32(data.count)
    data[0] = UInt8(size >> 24 & 0xFF)
    data[1] = UInt8(size >> 16 & 0xFF)
    data[2] = UInt8(size >> 8 & 0xFF)
    data[3] = UInt8(size & 0xFF)

    var formatDescription: CMFormatDescription?
    let created: Bool = data.withUnsafeBufferPointer { pointer in
      guard let baseAddress = pointer.baseAddress else { return false }
      return unsafe CMTextFormatDescriptionCreateFromBigEndianTextDescriptionData(
        allocator: kCFAllocatorDefault,
        bigEndianTextDescriptionData: baseAddress,
        size: pointer.count,
        flavor: nil,
        mediaType: kCMMediaType_Text,
        formatDescriptionOut: &formatDescription) == noErr
    }
    return created ? formatDescription : nil
  }

  /// Build a QuickTime text sample for one chapter: a `UInt16` big-endian length prefix followed by the
  /// UTF-8 title, timed to the chapter's `[time, time + duration)` range.
  private static func makeChapterSampleBuffer(text: String, formatDescription: CMFormatDescription, time: CMTime, duration: CMTime) -> CMSampleBuffer? {
    let utf8 = Array(text.utf8.prefix(0xFFFF))
    var payload = [UInt8(utf8.count >> 8 & 0xFF), UInt8(utf8.count & 0xFF)]
    payload.append(contentsOf: utf8)

    var blockBuffer: CMBlockBuffer?
    let blockStatus = unsafe CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault,
      memoryBlock: nil,
      blockLength: payload.count,
      blockAllocator: kCFAllocatorDefault,
      customBlockSource: nil,
      offsetToData: 0,
      dataLength: payload.count,
      flags: 0,
      blockBufferOut: &blockBuffer)
    guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else {
      return nil
    }
    let copied: Bool = payload.withUnsafeBytes { pointer in
      guard let baseAddress = pointer.baseAddress else { return false }
      return unsafe CMBlockBufferReplaceDataBytes(with: baseAddress, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: payload.count) == kCMBlockBufferNoErr
    }
    guard copied else {
      return nil
    }

    var sampleBuffer: CMSampleBuffer?
    var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: time, decodeTimeStamp: .invalid)
    var sampleSize = payload.count
    let sampleStatus = unsafe CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault,
      dataBuffer: blockBuffer,
      formatDescription: formatDescription,
      sampleCount: 1,
      sampleTimingEntryCount: 1,
      sampleTimingArray: &timing,
      sampleSizeEntryCount: 1,
      sampleSizeArray: &sampleSize,
      sampleBufferOut: &sampleBuffer)
    return sampleStatus == noErr ? sampleBuffer : nil
  }
}

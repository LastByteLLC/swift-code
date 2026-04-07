// SpeechService.swift — On-device speech transcription for /speak command
//
// Uses SpeechTranscriber + SpeechAnalyzer (macOS 26+) for on-device speech recognition.
// Listens for a configurable duration, then returns the transcript.

#if canImport(Speech)
import Foundation
@preconcurrency import Speech
@preconcurrency import AVFoundation

/// Accumulates volatile and finalized speech transcription results.
struct TranscriptAccumulator: Sendable {
  private(set) var finalizedTranscript: String = ""
  private(set) var volatileTranscript: String = ""

  var combined: String {
    (finalizedTranscript + volatileTranscript).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  mutating func apply(text: String, isFinal: Bool) {
    if isFinal {
      volatileTranscript = ""
      finalizedTranscript += text
    } else {
      volatileTranscript = text
    }
  }
}

/// On-device speech transcription service.
public actor SpeechService {
  private let locale: Locale
  private var audioConverter: AVAudioConverter?

  public init(locale: Locale = Locale(identifier: "en-US")) {
    self.locale = locale
  }

  /// Whether speech recognition is available on this device.
  public var isAvailable: Bool {
    get async {
      guard #available(macOS 26.0, iOS 26.0, *) else { return false }
      guard SpeechTranscriber.isAvailable else { return false }
      let supported = await SpeechTranscriber.supportedLocales
      return supported.contains { $0.identifier.hasPrefix(locale.identifier.prefix(2)) }
    }
  }

  /// Transcribe from the default audio input for `duration` seconds.
  /// Returns the transcribed text.
  public func transcribe(duration: TimeInterval = 10) async throws -> String {
    guard #available(macOS 26.0, iOS 26.0, *) else {
      throw SpeechError.unavailable
    }
    guard SpeechTranscriber.isAvailable else {
      throw SpeechError.unavailable
    }

    let transcriber = SpeechTranscriber(
      locale: locale,
      transcriptionOptions: [],
      reportingOptions: [.volatileResults, .fastResults],
      attributeOptions: []
    )

    // Download speech model if needed (first run only)
    if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
      try await downloader.downloadAndInstall()
    }

    let analyzer = SpeechAnalyzer(modules: [transcriber])

    guard let requiredFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
      compatibleWith: [transcriber]
    ) else {
      throw SpeechError.transcriptionFailed("No compatible audio format available")
    }

    let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)

    // Collect results in background
    let resultsTask = Task.detached { () -> String in
      var accumulator = TranscriptAccumulator()
      for try await result in transcriber.results {
        accumulator.apply(text: String(result.text.characters), isFinal: result.isFinal)
      }
      return accumulator.combined
    }

    // Start the analyzer
    let analyzerTask = Task.detached {
      try await analyzer.start(inputSequence: stream)
    }

    // Set up audio engine with format conversion
    let audioEngine = AVAudioEngine()
    let inputNode = audioEngine.inputNode
    let micFormat = inputNode.outputFormat(forBus: 0)
    let converter = AVAudioConverter(from: micFormat, to: requiredFormat)

    inputNode.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { @Sendable buffer, _ in
      guard let converter else { return }
      let frameCount = AVAudioFrameCount(
        Double(buffer.frameLength) * requiredFormat.sampleRate / buffer.format.sampleRate
      )
      guard let converted = AVAudioPCMBuffer(pcmFormat: requiredFormat, frameCapacity: frameCount) else { return }

      var error: NSError?
      converter.convert(to: converted, error: &error) { _, status in
        status.pointee = .haveData
        return buffer
      }
      if error == nil {
        continuation.yield(AnalyzerInput(buffer: converted))
      }
    }

    audioEngine.prepare()
    try audioEngine.start()

    // Record for duration
    try await Task.sleep(for: .seconds(duration))

    // Stop and finalize
    audioEngine.stop()
    inputNode.removeTap(onBus: 0)
    continuation.finish()

    try await analyzer.finalizeAndFinishThroughEndOfInput()
    _ = try await analyzerTask.value

    let transcript = try await resultsTask.value
    return transcript
  }
}

public enum SpeechError: Error, Sendable {
  case unavailable
  case notAuthorized
  case transcriptionFailed(String)
}
#endif

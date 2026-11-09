import AVFoundation
import Foundation
#if arch(arm64)
@preconcurrency import CoreML
import FluidAudio

// FORK(live-captions-multilingual): see FORK.md, feature "Live captions in German and Auto".
//
// Live captions upstream use the English-only Parakeet realtime EOU model. This recognizer
// drives the multilingual Nemotron Speech 3.5 streaming model (the same files the dictation
// "Nemotron Speech 3.5 - Ultra Fast Low Latency" engine downloads) with a language prompt.
// Nemotron has no end-of-utterance head, so an utterance ends when the transcript has not
// changed for `endpointSilenceSeconds` of audio, or grows past `maxUtteranceSeconds`.
actor MeetingNemotronLiveRecognizer: MeetingLiveRecognizer {
    static let folderName = "nemotron-3.5-asr-streaming320-int8-CoreML"
    private static let repositoryOwner = "BarathwajAnandan"
    private static let sampleRate = 16_000.0
    private static let endpointSilenceSeconds = 0.9
    private static let pollIntervalSeconds = 0.1
    private static let maxUtteranceSeconds = 20.0
    private static let sentenceEndings: Set<Character> = [".", "?", "!", "…"]

    private let prompt: String
    private var manager: NemotronStreamingAsrManager?
    private var eouCallback: (@Sendable (String) -> Void)?
    private var partialCallback: (@Sendable (String) -> Void)?
    private var lastText = ""
    private var unprocessedSeconds = 0.0
    private var secondsSinceTextChange = 0.0
    private var utteranceSeconds = 0.0
    private var endpointSent = false

    init(prompt: String) {
        self.prompt = prompt
    }

    func prepareModels() async throws {
        guard self.manager == nil else { return }
        let directory = try await Self.ensureModelFiles()
        let manager: NemotronStreamingAsrManager
        do {
            manager = try await Self.loadManager(directory: directory, computeUnits: .cpuAndNeuralEngine)
        } catch {
            manager = try await Self.loadManager(directory: directory, computeUnits: .cpuAndGPU)
        }
        try await manager.setTargetLanguage(self.prompt)
        self.manager = manager
    }

    func appendAudio(_ buffer: AVAudioPCMBuffer) async throws {
        guard let manager else { throw ASRError.notInitialized }
        try await manager.appendAudio(buffer)
        self.unprocessedSeconds += Double(buffer.frameLength) / buffer.format.sampleRate
    }

    func processBufferedAudio() async throws {
        guard let manager else { throw ASRError.notInitialized }
        try await manager.processBufferedAudio()
        // The engine feeds ~10 ms buffers; decoding the transcript for each would be wasted work.
        guard self.unprocessedSeconds >= Self.pollIntervalSeconds else { return }
        let elapsed = self.unprocessedSeconds
        self.unprocessedSeconds = 0
        let text = await manager.getPartialTranscript()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            self.secondsSinceTextChange = 0
            self.utteranceSeconds = 0
            return
        }
        self.utteranceSeconds += elapsed
        if trimmed != self.lastText {
            self.lastText = trimmed
            self.secondsSinceTextChange = 0
            self.partialCallback?(trimmed)
        } else {
            self.secondsSinceTextChange += elapsed
        }

        guard !self.endpointSent else { return }
        let paused = self.secondsSinceTextChange >= Self.endpointSilenceSeconds
        let tooLong = self.utteranceSeconds >= Self.maxUtteranceSeconds
            && (self.lastText.last.map { Self.sentenceEndings.contains($0) } ?? false
                || self.utteranceSeconds >= Self.maxUtteranceSeconds * 1.5)
        if paused || tooLong {
            // The engine resets this recognizer after handling the end of the utterance.
            self.endpointSent = true
            self.eouCallback?(self.lastText)
        }
    }

    func finish() async throws -> String {
        guard let manager else { return self.lastText }
        let finished = try await manager.finish().trimmingCharacters(in: .whitespacesAndNewlines)
        return finished.isEmpty ? self.lastText : finished
    }

    func reset() async {
        await self.manager?.reset()
        self.lastText = ""
        self.unprocessedSeconds = 0
        self.secondsSinceTextChange = 0
        self.utteranceSeconds = 0
        self.endpointSent = false
    }

    func setEouCallback(_ callback: @escaping @Sendable (String) -> Void) async {
        self.eouCallback = callback
    }

    func setPartialTranscriptCallback(_ callback: @escaping @Sendable (String) -> Void) async {
        self.partialCallback = callback
    }

    private static func loadManager(directory: URL, computeUnits: MLComputeUnits) async throws -> NemotronStreamingAsrManager {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        configuration.allowLowPrecisionAccumulationOnGPU = true
        let manager = NemotronStreamingAsrManager(configuration: configuration)
        try await manager.loadModels(modelDir: directory)
        return manager
    }

    @MainActor private static var download: Task<URL, Error>?

    /// Shares the dictation engine's cache folder, so a model downloaded for either is reused.
    /// Concurrent callers (prefetch, microphone and app engines) share one download.
    @MainActor
    static func ensureModelFiles() async throws -> URL {
        if let download { return try await download.value }
        let task = Task { @MainActor in try await Self.downloadModelFiles() }
        self.download = task
        defer { self.download = nil }
        return try await task.value
    }

    @MainActor
    private static func downloadModelFiles() async throws -> URL {
        guard let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Self.folderName, isDirectory: true)
        else { throw ASRError.processingFailed("No cache directory for live caption model") }
        if NemotronProvider.artifactsAreComplete(at: directory) { return directory }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        DebugLogger.shared.info("Live captions: downloading \(Self.folderName)", source: "MeetingLive")
        let downloader = HuggingFaceModelDownloader(
            owner: Self.repositoryOwner,
            repo: Self.folderName,
            revision: "main",
            requiredItems: NemotronProvider.requiredFiles.map {
                .init(path: $0, isDirectory: $0.hasSuffix(".mlpackage"))
            }
        )
        try await downloader.ensureModelsPresent(at: directory)
        guard NemotronProvider.artifactsAreComplete(at: directory) else {
            throw ASRError.processingFailed("Live caption model download is incomplete")
        }
        return directory
    }
}
#endif

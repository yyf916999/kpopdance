import Foundation
import AVFoundation
import UIKit

enum ComposerError: LocalizedError {
    case noVideoTrack
    case exportSetupFailed
    case exportFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "That file has no video track."
        case .exportSetupFailed: return "Couldn't set up the export."
        case .exportFailed(let detail): return "Export failed: \(detail)"
        case .cancelled: return "Export cancelled."
        }
    }
}

/// Post-processing for practice takes.
///
/// Everything here operates on files the user owns: the take they just recorded, and — only if
/// they imported it themselves — the audio track to lay under it. The embedded YouTube player's
/// audio is never available to this class, which is the point: there is no code path in the app
/// that can turn a stream into a file.
struct RecordingComposer {

    struct MixOptions {
        /// Audio the user owns, to lay under the take. Nil leaves the take's own audio alone.
        var musicURL: URL?
        /// Where in the music the take started, so the mix lines up with the section drilled.
        var musicStartTime: Double = 0
        /// Keep the microphone track alongside the music.
        var keepMicAudio: Bool = false
        var micVolume: Float = 0.35
        var musicVolume: Float = 1.0
        /// If the take was danced at 0.5x, setting this to 0.5 speeds it back to real tempo so it
        /// can be shared at the speed the song actually runs.
        var normalizeFromRate: Double = 1.0
        /// Trim to this window of the take (seconds), used to drop the count-in and the tail.
        var trim: ClosedRange<Double>?
    }

    /// Builds the composition and exports it. Returns the URL of the new file.
    static func export(take takeURL: URL,
                       options: MixOptions,
                       to destination: URL,
                       progress: ((Double) -> Void)? = nil) async throws -> URL {

        let takeAsset = AVURLAsset(url: takeURL)
        guard let sourceVideo = try await takeAsset.loadTracks(withMediaType: .video).first else {
            throw ComposerError.noVideoTrack
        }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw ComposerError.exportSetupFailed }

        let fullDuration = try await takeAsset.load(.duration)
        let window: CMTimeRange
        if let trim = options.trim {
            let start = CMTime(seconds: max(0, trim.lowerBound), preferredTimescale: 600)
            let end = CMTime(seconds: min(trim.upperBound, CMTimeGetSeconds(fullDuration)),
                             preferredTimescale: 600)
            window = CMTimeRange(start: start, end: end)
        } else {
            window = CMTimeRange(start: .zero, duration: fullDuration)
        }

        try videoTrack.insertTimeRange(window, of: sourceVideo, at: .zero)
        videoTrack.preferredTransform = try await sourceVideo.load(.preferredTransform)

        // Microphone audio, if we are keeping it.
        var micTrack: AVMutableCompositionTrack?
        if options.keepMicAudio,
           let sourceAudio = try await takeAsset.loadTracks(withMediaType: .audio).first,
           let track = composition.addMutableTrack(withMediaType: .audio,
                                                   preferredTrackID: kCMPersistentTrackID_Invalid) {
            try? track.insertTimeRange(window, of: sourceAudio, at: .zero)
            micTrack = track
        }

        // Retiming happens before the music is laid in, so the music never gets pitch-shifted by
        // the speed correction — it is inserted at its own natural rate afterwards.
        if options.normalizeFromRate > 0, abs(options.normalizeFromRate - 1.0) > 0.01 {
            let scaled = CMTimeMultiplyByFloat64(window.duration, multiplier: options.normalizeFromRate)
            let scaleRange = CMTimeRange(start: .zero, duration: window.duration)
            videoTrack.scaleTimeRange(scaleRange, toDuration: scaled)
            micTrack?.scaleTimeRange(scaleRange, toDuration: scaled)
        }

        let composedDuration = composition.duration

        var musicTrack: AVMutableCompositionTrack?
        if let musicURL = options.musicURL {
            let musicAsset = AVURLAsset(url: musicURL)
            if let sourceMusic = try await musicAsset.loadTracks(withMediaType: .audio).first,
               let track = composition.addMutableTrack(withMediaType: .audio,
                                                       preferredTrackID: kCMPersistentTrackID_Invalid) {
                let musicDuration = try await musicAsset.load(.duration)
                let start = CMTime(seconds: max(0, options.musicStartTime), preferredTimescale: 600)
                let available = CMTimeSubtract(musicDuration, start)
                let length = CMTimeMinimum(available, composedDuration)
                if length.seconds > 0.1 {
                    try? track.insertTimeRange(
                        CMTimeRange(start: start, duration: length), of: sourceMusic, at: .zero
                    )
                    musicTrack = track
                }
            }
        }

        // Levels: the music should sit on top, the mic underneath as a reference for your own
        // counts and breathing.
        let audioMix = AVMutableAudioMix()
        var parameters: [AVMutableAudioMixInputParameters] = []
        if let micTrack {
            let p = AVMutableAudioMixInputParameters(track: micTrack)
            p.setVolume(options.musicURL == nil ? 1.0 : options.micVolume, at: .zero)
            parameters.append(p)
        }
        if let musicTrack {
            let p = AVMutableAudioMixInputParameters(track: musicTrack)
            p.setVolume(options.musicVolume, at: .zero)
            parameters.append(p)
        }
        audioMix.inputParameters = parameters

        guard let session = AVAssetExportSession(asset: composition,
                                                 presetName: AVAssetExportPresetHighestQuality) else {
            throw ComposerError.exportSetupFailed
        }
        MediaStore.delete(destination)
        session.outputURL = destination
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        if !parameters.isEmpty { session.audioMix = audioMix }

        let reporter = progress.map { callback -> Timer in
            let timer = Timer(timeInterval: 0.2, repeats: true) { [weak session] _ in
                guard let session else { return }
                DispatchQueue.main.async { callback(Double(session.progress)) }
            }
            RunLoop.main.add(timer, forMode: .common)
            return timer
        }

        await session.runExport()
        reporter?.invalidate()

        switch session.status {
        case .completed:
            return destination
        case .cancelled:
            throw ComposerError.cancelled
        default:
            throw ComposerError.exportFailed(session.error?.localizedDescription ?? "unknown")
        }
    }

    /// Generates a poster frame for a take, used by the takes grid.
    static func thumbnail(for url: URL, at seconds: Double = 0.6) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 600, height: 600)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        guard let cgImage = try? await generator.image(at: time).image else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// The async export shape on iOS 16, where only the callback form ships. Named `runExport` rather
/// than `export` so it can never collide with the variants Apple has added since.
private extension AVAssetExportSession {
    func runExport() async {
        await withCheckedContinuation { continuation in
            self.exportAsynchronously {
                continuation.resume()
            }
        }
    }
}

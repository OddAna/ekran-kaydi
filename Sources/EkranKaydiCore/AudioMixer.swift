import AVFoundation
import CoreMedia
import Foundation

/// Kayıttaki ayrı ses izlerini (sistem sesi + mikrofon) tek bir ses izine karıştırır.
/// Görüntü yeniden sıkıştırılmaz (passthrough), yalnız ses yeniden kodlanır; bu yüzden hızlıdır.
/// Böylece her oynatıcıda ve yüklendiği her sitede iki ses birlikte duyulur.
public enum AudioMixer {
    public static func mixAudioTracks(
        of inputURL: URL,
        into outputURL: URL,
        completion: @escaping (Error?) -> Void
    ) {
        let asset = AVURLAsset(url: inputURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        asset.loadValuesAsynchronously(forKeys: ["tracks", "duration"]) {
            var loadError: NSError?
            guard asset.statusOfValue(forKey: "tracks", error: &loadError) == .loaded else {
                completion(RecordingError.writeFailed(loadError?.localizedDescription ?? "Kayıt okunamadı."))
                return
            }
            do {
                let job = try MixJob(asset: asset, outputURL: outputURL)
                job.run(completion: completion)
            } catch {
                completion(error)
            }
        }
    }

    private final class MixJob {
        private let reader: AVAssetReader
        private let writer: AVAssetWriter
        private let videoOutput: AVAssetReaderTrackOutput
        private let audioOutput: AVAssetReaderAudioMixOutput
        private let videoInput: AVAssetWriterInput
        private let audioInput: AVAssetWriterInput
        private let outputURL: URL
        private var retainedSelf: MixJob?

        init(asset: AVAsset, outputURL: URL) throws {
            self.outputURL = outputURL
            let videoTracks = asset.tracks(withMediaType: .video)
            let audioTracks = asset.tracks(withMediaType: .audio)
            guard let videoTrack = videoTracks.first, !audioTracks.isEmpty else {
                throw RecordingError.writeFailed("Kayıtta görüntü ya da ses izi yok.")
            }
            guard let formatHint = videoTrack.formatDescriptions.first else {
                throw RecordingError.writeFailed("Görüntü biçimi okunamadı.")
            }

            reader = try AVAssetReader(asset: asset)
            videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
            videoOutput.alwaysCopiesSampleData = false
            audioOutput = AVAssetReaderAudioMixOutput(
                audioTracks: audioTracks,
                audioSettings: MovieWriter.linearPCMSettings
            )
            audioOutput.alwaysCopiesSampleData = false
            guard reader.canAdd(videoOutput), reader.canAdd(audioOutput) else {
                throw RecordingError.writeFailed("Kayıt okunamadı.")
            }
            reader.add(videoOutput)
            reader.add(audioOutput)

            try? FileManager.default.removeItem(at: outputURL)
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
            // swiftlint:disable:next force_cast
            videoInput = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: nil,
                sourceFormatHint: (formatHint as! CMFormatDescription)
            )
            videoInput.transform = videoTrack.preferredTransform
            audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: MovieWriter.aacSettings(bitRate: 192_000))
            guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
                throw RecordingError.writeFailed("Birleşik kayıt hazırlanamadı.")
            }
            writer.add(videoInput)
            writer.add(audioInput)
        }

        func run(completion: @escaping (Error?) -> Void) {
            guard reader.startReading() else {
                completion(RecordingError.writeFailed(reader.error?.localizedDescription ?? "Kayıt okunamadı."))
                return
            }
            guard writer.startWriting() else {
                reader.cancelReading()
                completion(RecordingError.writeFailed(writer.error?.localizedDescription ?? "Birleşik kayıt açılamadı."))
                return
            }
            writer.startSession(atSourceTime: .zero)
            retainedSelf = self

            let group = DispatchGroup()
            pump(output: videoOutput, into: videoInput, label: "ekrankaydi.mix.video", group: group)
            pump(output: audioOutput, into: audioInput, label: "ekrankaydi.mix.audio", group: group)

            group.notify(queue: .global(qos: .userInitiated)) { [self] in
                defer { retainedSelf = nil }
                if reader.status == .failed || writer.status == .failed {
                    let detail = reader.error?.localizedDescription ?? writer.error?.localizedDescription ?? "Birleştirme başarısız."
                    reader.cancelReading()
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: outputURL)
                    completion(RecordingError.writeFailed(detail))
                    return
                }
                writer.finishWriting { [writer, outputURL] in
                    if writer.status == .completed {
                        completion(nil)
                    } else {
                        try? FileManager.default.removeItem(at: outputURL)
                        completion(RecordingError.writeFailed(writer.error?.localizedDescription ?? "Birleşik kayıt kapatılamadı."))
                    }
                }
            }
        }

        private func pump(output: AVAssetReaderOutput, into input: AVAssetWriterInput, label: String, group: DispatchGroup) {
            group.enter()
            var finished = false
            let reader = self.reader
            let writer = self.writer
            input.requestMediaDataWhenReady(on: DispatchQueue(label: label)) {
                guard !finished else { return }
                while input.isReadyForMoreMediaData {
                    if reader.status != .reading || writer.status != .writing {
                        finished = true
                        input.markAsFinished()
                        group.leave()
                        return
                    }
                    guard let buffer = output.copyNextSampleBuffer() else {
                        finished = true
                        input.markAsFinished()
                        group.leave()
                        return
                    }
                    if !input.append(buffer) {
                        finished = true
                        input.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }
        }
    }
}

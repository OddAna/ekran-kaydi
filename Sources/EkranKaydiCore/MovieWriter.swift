import AVFoundation
import CoreMedia
import Foundation

/// Ekran görüntüsünü (H.264), sistem sesini ve mikrofonu (AAC, ayrı izler) tek .mov dosyasına yazar.
///
/// İş parçacığı güvenli değildir: tüm çağrılar aynı seri kuyruktan yapılmalıdır.
/// Zaman damgaları ana saat (host time) cinsindendir; oturum ilk görüntü karesiyle başlar.
final class MovieWriter {
    struct Configuration {
        var width: Int
        var height: Int
        var framesPerSecond: Int
        var includesSystemAudio: Bool
        var includesMicrophone: Bool
    }

    static let audioSampleRate: Double = 48_000
    static let audioChannelCount = 2

    let url: URL
    private let configuration: Configuration
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let systemAudioInput: AVAssetWriterInput?
    private let microphoneInput: AVAssetWriterInput?

    private(set) var sessionStartTime: CMTime?
    private(set) var lastVideoTime: CMTime = .invalid
    private var lastVideoBuffer: CMSampleBuffer?
    private(set) var appendedVideoFrames = 0
    private(set) var appendedSystemAudioBuffers = 0
    private(set) var appendedMicrophoneBuffers = 0
    private(set) var failureDescription: String?
    private var isFinishing = false

    init(url: URL, configuration: Configuration) throws {
        self.url = url
        self.configuration = configuration
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        self.writer = writer

        let fps = max(1, configuration.framesPerSecond)
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: CaptureSize.averageBitRate(width: configuration.width, height: configuration.height),
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: fps * 2,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoAllowFrameReorderingKey: false,
        ]
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: configuration.width,
            AVVideoHeightKey: configuration.height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            throw RecordingError.writeFailed("Görüntü izi eklenemedi.")
        }
        writer.add(videoInput)
        self.videoInput = videoInput

        func makeAudioInput(bitRate: Int) throws -> AVAssetWriterInput {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: MovieWriter.aacSettings(bitRate: bitRate))
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                throw RecordingError.writeFailed("Ses izi eklenemedi.")
            }
            writer.add(input)
            return input
        }

        systemAudioInput = configuration.includesSystemAudio ? try makeAudioInput(bitRate: 192_000) : nil
        microphoneInput = configuration.includesMicrophone ? try makeAudioInput(bitRate: 160_000) : nil

        guard writer.startWriting() else {
            throw RecordingError.writeFailed(writer.error?.localizedDescription ?? "Dosya açılamadı.")
        }
    }

    /// 48 kHz stereo 32 bit float, araya karışık (interleaved) ham ses: mikrofon çıkışı ve karıştırıcı bu biçimi kullanır.
    static let linearPCMSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: audioSampleRate,
        AVNumberOfChannelsKey: audioChannelCount,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false,
        AVLinearPCMIsBigEndianKey: false,
    ]

    static func aacSettings(bitRate: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: audioSampleRate,
            AVNumberOfChannelsKey: audioChannelCount,
            AVEncoderBitRateKey: bitRate,
        ]
    }

    var hasStarted: Bool { sessionStartTime != nil }

    /// Tam bir ekran karesi ekler. İlk kare oturumu başlatır.
    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard !isFinishing, checkWriter() else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard time.isValid else { return }

        if sessionStartTime == nil {
            writer.startSession(atSourceTime: time)
            sessionStartTime = time
        }
        // Zaman geriye gidemez; aynı ya da eski damgalı kare atlanır.
        if lastVideoTime.isValid, CMTimeCompare(time, lastVideoTime) <= 0 {
            return
        }
        guard videoInput.isReadyForMoreMediaData else { return }
        if videoInput.append(sampleBuffer) {
            lastVideoTime = time
            lastVideoBuffer = sampleBuffer
            appendedVideoFrames += 1
        } else {
            _ = checkWriter()
        }
    }

    func appendSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let input = systemAudioInput else { return }
        if appendAudio(sampleBuffer, to: input) {
            appendedSystemAudioBuffers += 1
        }
    }

    func appendMicrophone(_ sampleBuffer: CMSampleBuffer) {
        guard let input = microphoneInput else { return }
        if appendAudio(sampleBuffer, to: input) {
            appendedMicrophoneBuffers += 1
        }
    }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput) -> Bool {
        guard !isFinishing, checkWriter(), let start = sessionStartTime else { return false }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard time.isValid, CMTimeCompare(time, start) >= 0 else { return false }
        guard input.isReadyForMoreMediaData else { return false }
        if input.append(sampleBuffer) {
            return true
        }
        _ = checkWriter()
        return false
    }

    /// Kaydı `endTime` anında kapatır. Ekran son kareden sonra değişmediyse son kare bitişe kadar uzatılır,
    /// böylece görüntü izi sesle aynı uzunlukta olur.
    func finish(at endTime: CMTime, completion: @escaping (Error?) -> Void) {
        guard !isFinishing else { return }
        isFinishing = true

        guard let start = sessionStartTime, appendedVideoFrames > 0 else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            completion(RecordingError.noFileCreated)
            return
        }
        guard writer.status == .writing else {
            let detail = failureDescription ?? writer.error?.localizedDescription ?? "Yazıcı durdu."
            writer.cancelWriting()
            completion(RecordingError.writeFailed(detail))
            return
        }

        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, configuration.framesPerSecond)))
        var end = endTime.isValid ? endTime : lastVideoTime
        let minimumEnd = CMTimeAdd(lastVideoTime, frameDuration)
        if CMTimeCompare(end, minimumEnd) < 0 {
            end = minimumEnd
        }
        if CMTimeCompare(end, start) <= 0 {
            end = CMTimeAdd(start, frameDuration)
        }

        if let last = lastVideoBuffer,
           CMTimeCompare(end, minimumEnd) > 0,
           let held = SampleTiming.copy(last, presentationTime: end),
           videoInput.isReadyForMoreMediaData
        {
            if videoInput.append(held) {
                appendedVideoFrames += 1
            }
        }
        lastVideoBuffer = nil

        videoInput.markAsFinished()
        systemAudioInput?.markAsFinished()
        microphoneInput?.markAsFinished()
        writer.endSession(atSourceTime: end)

        let writer = self.writer
        writer.finishWriting {
            if writer.status == .completed {
                completion(nil)
            } else {
                completion(RecordingError.writeFailed(writer.error?.localizedDescription ?? "Dosya kapatılamadı."))
            }
        }
    }

    /// Kaydı dosya bırakmadan iptal eder.
    func cancel() {
        guard !isFinishing else { return }
        isFinishing = true
        lastVideoBuffer = nil
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    private func checkWriter() -> Bool {
        if writer.status == .failed {
            if failureDescription == nil {
                failureDescription = writer.error?.localizedDescription ?? "Yazıcı hata verdi."
            }
            return false
        }
        return writer.status == .writing
    }
}

/// Örnek arabelleklerinin zamanlamasını değiştiren yardımcılar.
enum SampleTiming {
    /// Tek kareyi yeni bir sunum zamanıyla kopyalar (görüntü verisi kopyalanmaz).
    static func copy(_ sampleBuffer: CMSampleBuffer, presentationTime: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &copy
        )
        return status == noErr ? copy : nil
    }

    /// Tüm zamanlama girdilerini `delta` kadar kaydırır (ör. mikrofon saatini ana saate çevirmek için).
    static func shifted(_ sampleBuffer: CMSampleBuffer, by delta: CMTime) -> CMSampleBuffer? {
        if CMTimeCompare(delta, .zero) == 0 {
            return sampleBuffer
        }
        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr,
              count > 0
        else {
            return nil
        }
        var timings = Array(repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count) == noErr else {
            return nil
        }
        for index in timings.indices {
            if timings[index].presentationTimeStamp.isValid {
                timings[index].presentationTimeStamp = CMTimeAdd(timings[index].presentationTimeStamp, delta)
            }
            if timings[index].decodeTimeStamp.isValid {
                timings[index].decodeTimeStamp = CMTimeAdd(timings[index].decodeTimeStamp, delta)
            }
        }
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: count,
            sampleTimingArray: &timings,
            sampleBufferOut: &copy
        )
        return status == noErr ? copy : nil
    }
}

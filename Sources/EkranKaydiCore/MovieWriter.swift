import AVFoundation
import CoreMedia
import Foundation

/// Ekran görüntüsünü (H.264), sistem sesini ve mikrofonu (AAC, ayrı izler) tek .mov dosyasına yazar.
///
/// İş parçacığı güvenli değildir: tüm çağrılar aynı seri kuyruktan yapılmalıdır.
/// Zaman damgaları ana saat (host time) cinsindendir; oturum ilk görüntü karesiyle başlar.
///
/// Ses izleri kesintisizdir: mikrofon kapatıldığında, aygıt değişirken (kulaklık takılıp çıkarılırken) ya da
/// bir kaynak bir süre ses vermediğinde aradaki boşluk sessizlikle doldurulur. Böylece iz zamanda kaymaz,
/// mikrofon yeniden açılınca ses görüntüyle aynı yere düşer.
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
    /// Bu kadar küçük zaman farkları boşluk ya da çakışma sayılmaz (saat dönüşümü titremesi).
    static let audioTimingTolerance = CMTime(value: 5, timescale: 1000)
    /// Sessizlik en çok bu uzunlukta parçalarla yazılır (0,1 sn).
    static let silenceChunkFrames = 4800

    let url: URL
    private let configuration: Configuration
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let systemAudio: AudioTrack?
    private let microphone: AudioTrack?

    private(set) var sessionStartTime: CMTime?
    private(set) var lastVideoTime: CMTime = .invalid
    private var lastVideoBuffer: CMSampleBuffer?
    private(set) var appendedVideoFrames = 0
    var appendedSystemAudioBuffers: Int { systemAudio?.realBuffers ?? 0 }
    var appendedMicrophoneBuffers: Int { microphone?.realBuffers ?? 0 }
    var appendedMicrophoneSilenceBuffers: Int { microphone?.silenceBuffers ?? 0 }
    var appendedSystemAudioSilenceBuffers: Int { systemAudio?.silenceBuffers ?? 0 }
    /// Mikrofon izinin şu ana kadar yazılmış bitişi (gerçek ses ya da sessizlik).
    var microphoneCursor: CMTime { microphone?.cursor ?? .invalid }
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

        // Sistem sesinin biçimini ScreenCaptureKit belirler; sessizlik ancak ilk gerçek ses geldikten sonra
        // aynı biçimde yazılır. Mikrofonun biçimi sabittir (`linearPCMSettings`), sessizlik baştan yazılabilir.
        systemAudio = configuration.includesSystemAudio
            ? AudioTrack(input: try makeAudioInput(bitRate: 192_000), fallbackFormat: nil)
            : nil
        microphone = configuration.includesMicrophone
            ? AudioTrack(input: try makeAudioInput(bitRate: 160_000), fallbackFormat: MovieWriter.interleavedFloatFormat)
            : nil

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

    /// `linearPCMSettings` ile aynı biçimin CoreMedia tanımı (mikrofon izine sessizlik yazmak için).
    static let interleavedFloatFormat: CMAudioFormatDescription? = {
        var description = AudioStreamBasicDescription(
            mSampleRate: audioSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * audioChannelCount),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * audioChannelCount),
            mChannelsPerFrame: UInt32(audioChannelCount),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &description,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        )
        return status == noErr ? format : nil
    }()

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
        guard let systemAudio else { return }
        appendAudio(sampleBuffer, to: systemAudio)
    }

    func appendMicrophone(_ sampleBuffer: CMSampleBuffer) {
        guard let microphone else { return }
        appendAudio(sampleBuffer, to: microphone)
    }

    /// Ses gelmeyen izleri (mikrofon kapalı, aygıt değişiyor, kaynak sustu) `time` anına kadar sessizlikle doldurur.
    /// Gerçek ses `time`dan sonrası için gelmeye devam ederse aynen yazılır; `time`dan eski gerçek ses atlanır.
    func fillAudioGaps(upTo time: CMTime) {
        guard !isFinishing, checkWriter(), sessionStartTime != nil, time.isValid else { return }
        for track in [systemAudio, microphone].compactMap({ $0 }) {
            fillSilence(in: track, upTo: time)
        }
    }

    @discardableResult
    private func appendAudio(_ sampleBuffer: CMSampleBuffer, to track: AudioTrack) -> Bool {
        guard !isFinishing, checkWriter(), let start = sessionStartTime else { return false }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard time.isValid else { return false }
        let end = CMTimeAdd(time, Self.audioDuration(of: sampleBuffer))
        if !track.cursor.isValid {
            track.cursor = start
        }
        let tolerance = Self.audioTimingTolerance
        // Oturumdan önceki ya da zaten (sessizlikle) yazılmış ana düşen ses atlanır: iz geriye gidemez.
        if CMTimeCompare(time, CMTimeSubtract(track.cursor, tolerance)) < 0 {
            return false
        }
        if let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            track.format = format
        }
        if CMTimeCompare(time, CMTimeAdd(track.cursor, tolerance)) > 0 {
            fillSilence(in: track, upTo: time)
        }
        guard track.input.isReadyForMoreMediaData else { return false }
        if track.input.append(sampleBuffer) {
            track.cursor = end
            track.realBuffers += 1
            return true
        }
        _ = checkWriter()
        return false
    }

    private func fillSilence(in track: AudioTrack, upTo target: CMTime) {
        guard let start = sessionStartTime, let format = track.format ?? track.fallbackFormat,
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              description.mSampleRate > 0
        else {
            return
        }
        if !track.cursor.isValid {
            track.cursor = start
        }
        let rate = CMTimeScale(description.mSampleRate.rounded())
        while CMTimeCompare(target, CMTimeAdd(track.cursor, Self.audioTimingTolerance)) > 0 {
            let remaining = CMTimeSubtract(target, track.cursor)
            let frames = min(Self.silenceChunkFrames, Int((remaining.seconds * Double(rate)).rounded()))
            guard frames > 0, track.input.isReadyForMoreMediaData,
                  let silence = SilenceBuffer.make(format: format, description: description, frames: frames, at: track.cursor)
            else {
                return
            }
            guard track.input.append(silence) else {
                _ = checkWriter()
                return
            }
            track.cursor = CMTimeAdd(track.cursor, CMTime(value: CMTimeValue(frames), timescale: rate))
            track.silenceBuffers += 1
        }
    }

    private static func audioDuration(of sampleBuffer: CMSampleBuffer) -> CMTime {
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        if duration.isValid, duration.isNumeric, CMTimeCompare(duration, .zero) > 0 {
            return duration
        }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        if let format = CMSampleBufferGetFormatDescription(sampleBuffer),
           let rate = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee.mSampleRate, rate > 0
        {
            return CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(rate.rounded()))
        }
        return CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(audioSampleRate))
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

        // Ses izleri de bitişe kadar uzar (ör. mikrofon sonda kapalıydı).
        // Hiç ses gelmemiş sistem sesi izi boş kalır (biçimi bilinmiyor; karıştırıcı bunu kaldırır).
        for track in [systemAudio, microphone].compactMap({ $0 }) {
            fillSilence(in: track, upTo: end)
        }

        videoInput.markAsFinished()
        systemAudio?.input.markAsFinished()
        microphone?.input.markAsFinished()
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

/// Bir ses izinin yazıcı tarafı: giriş, şu ana kadar yazılan bitiş ve sessizlik için biçim.
private final class AudioTrack {
    let input: AVAssetWriterInput
    let fallbackFormat: CMAudioFormatDescription?
    var format: CMAudioFormatDescription?
    var cursor: CMTime = .invalid
    var realBuffers = 0
    var silenceBuffers = 0

    init(input: AVAssetWriterInput, fallbackFormat: CMAudioFormatDescription?) {
        self.input = input
        self.fallbackFormat = fallbackFormat
    }
}

/// Verilen ham ses (LPCM) biçiminde sıfırlarla dolu bir ses arabelleği.
enum SilenceBuffer {
    static func make(format: CMAudioFormatDescription, description: AudioStreamBasicDescription, frames: Int, at time: CMTime) -> CMSampleBuffer? {
        guard description.mFormatID == kAudioFormatLinearPCM, description.mBytesPerFrame > 0, frames > 0 else {
            return nil
        }
        let nonInterleaved = description.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let planes = nonInterleaved ? Int(max(1, description.mChannelsPerFrame)) : 1
        let byteCount = frames * Int(description.mBytesPerFrame) * planes
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block
        ) == noErr, let block, CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount) == noErr else {
            return nil
        }
        let rate = CMTimeScale(description.mSampleRate.rounded())
        var sample: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: frames,
            presentationTimeStamp: CMTimeConvertScale(time, timescale: rate, method: .roundHalfAwayFromZero),
            packetDescriptions: nil,
            sampleBufferOut: &sample
        )
        return status == noErr ? sample : nil
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

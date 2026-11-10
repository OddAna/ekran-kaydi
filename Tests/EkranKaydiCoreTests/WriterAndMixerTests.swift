import AVFoundation
import CoreMedia
import XCTest
@testable import EkranKaydiCore

/// Kayıt hattının izin gerektirmeyen kısmı: ScreenCaptureKit'in vereceği türde yapay kareler ve sesler
/// `MovieWriter`a yazılır, sonra `AudioMixer` sistem sesi ile mikrofonu tek ize karıştırır.
/// Gerçek ekran/sistem sesi yakalama (izin penceresi açtığı için) bu testlerde yoktur.
final class WriterAndMixerTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ekrankaydi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Zamanlama yardımcıları

    func testShiftedMovesAllTimestamps() throws {
        let buffer = try Synthetic.audioBuffer(at: CMTime(seconds: 5000, preferredTimescale: 48_000), frequency: 0)
        let shifted = try XCTUnwrap(SampleTiming.shifted(buffer, by: CMTime(seconds: -3999.5, preferredTimescale: 48_000)))
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(shifted).seconds, 1000.5, accuracy: 0.0001)
        XCTAssertEqual(CMSampleBufferGetNumSamples(shifted), CMSampleBufferGetNumSamples(buffer))
        XCTAssertTrue(SampleTiming.shifted(buffer, by: .zero) === buffer)
    }

    func testCopyWithPresentationTime() throws {
        let frame = try Synthetic.videoFrame(at: CMTime(seconds: 10, preferredTimescale: 600))
        let copy = try XCTUnwrap(SampleTiming.copy(frame, presentationTime: CMTime(seconds: 12, preferredTimescale: 600)))
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(copy).seconds, 12, accuracy: 0.0001)
        XCTAssertNotNil(CMSampleBufferGetImageBuffer(copy))
    }

    // MARK: Yazıcı

    func testWriterWithoutFramesLeavesNoFile() throws {
        let url = folder.appendingPathComponent("bos.mov")
        let writer = try MovieWriter(url: url, configuration: .init(width: 64, height: 64, framesPerSecond: 30, includesSystemAudio: true, includesMicrophone: false))
        // Görüntü gelmeden gelen ses yazılmaz (oturum ilk kareyle başlar).
        writer.appendSystemAudio(try Synthetic.audioBuffer(at: CMTime(seconds: 1, preferredTimescale: 48_000), frequency: 440))
        XCTAssertEqual(writer.appendedSystemAudioBuffers, 0)

        let done = expectation(description: "finish")
        var result: Error?
        writer.finish(at: CMTime(seconds: 2, preferredTimescale: 600)) { error in
            result = error
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(result as? RecordingError, .noFileCreated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// Ekran 1 sn değişip sonra durağan kalsa da görüntü izi sesle birlikte 3 sn sürer (son kare uzatılır).
    func testWriterKeepsVideoAsLongAsAudioAndWritesSeparateTracks() throws {
        let url = folder.appendingPathComponent("ham.mov")
        try writeSample(to: url, systemFrequency: 440, microphoneFrequency: 660, includeMicrophone: true)

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        XCTAssertEqual(asset.tracks(withMediaType: .video).count, 1)
        XCTAssertEqual(asset.tracks(withMediaType: .audio).count, 2, "sistem sesi + mikrofon ayrı izler")
        XCTAssertEqual(asset.duration.seconds, 3.0, accuracy: 0.15)
        let video = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
        XCTAssertEqual(video.timeRange.duration.seconds, 3.0, accuracy: 0.15)
        XCTAssertEqual(video.naturalSize, CGSize(width: 64, height: 64))
    }

    func testWriterWithSystemAudioOnly() throws {
        let url = folder.appendingPathComponent("sistem.mov")
        try writeSample(to: url, systemFrequency: 440, microphoneFrequency: 0, includeMicrophone: false)
        let asset = AVURLAsset(url: url)
        XCTAssertEqual(asset.tracks(withMediaType: .audio).count, 1)
        XCTAssertGreaterThan(try Synthetic.rms(of: url), 0.05)
    }

    // MARK: Karıştırıcı

    /// Sistem sesi sessiz, mikrofon dolu: çıktıda ses duyuluyorsa ikinci iz gerçekten karışmıştır.
    func testMixerMergesMicrophoneIntoSingleTrack() throws {
        let raw = folder.appendingPathComponent("ham.mov")
        try writeSample(to: raw, systemFrequency: 0, microphoneFrequency: 660, includeMicrophone: true)
        let mixed = folder.appendingPathComponent("son.mov")
        try mix(raw, into: mixed)

        let asset = AVURLAsset(url: mixed, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        XCTAssertEqual(asset.tracks(withMediaType: .video).count, 1)
        XCTAssertEqual(asset.tracks(withMediaType: .audio).count, 1, "tek ses izi")
        XCTAssertEqual(asset.duration.seconds, 3.0, accuracy: 0.2)
        XCTAssertGreaterThan(try Synthetic.rms(of: mixed), 0.05)
    }

    func testMixerKeepsSystemAudio() throws {
        let raw = folder.appendingPathComponent("ham.mov")
        try writeSample(to: raw, systemFrequency: 440, microphoneFrequency: 0, includeMicrophone: true)
        let mixed = folder.appendingPathComponent("son.mov")
        try mix(raw, into: mixed)
        XCTAssertGreaterThan(try Synthetic.rms(of: mixed), 0.05)
        // Görüntü yeniden sıkıştırılmaz: kare sayısı aynı kalır.
        XCTAssertEqual(try Synthetic.videoSampleCount(of: mixed), try Synthetic.videoSampleCount(of: raw))
    }

    /// Sessiz bir Mac'te sistem sesi hiç gelmeyebilir; dosya yine kaydedilir ve mikrofon duyulur.
    func testMixerWhenSystemAudioTrackIsEmpty() throws {
        let raw = folder.appendingPathComponent("ham.mov")
        try writeSample(to: raw, systemFrequency: 440, microphoneFrequency: 660, includeMicrophone: true, skipSystemAudio: true)
        let mixed = folder.appendingPathComponent("son.mov")
        try mix(raw, into: mixed)
        let asset = AVURLAsset(url: mixed)
        XCTAssertEqual(asset.tracks(withMediaType: .audio).count, 1)
        XCTAssertGreaterThan(try Synthetic.rms(of: mixed), 0.05)
    }

    /// Mikrofon çıkışına verilen biçim AVFoundation tarafından kabul edilir (izin gerektirmez, oturum açılmaz).
    func testMicrophoneOutputAcceptsSettings() {
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = MovieWriter.linearPCMSettings
        // Bağlantı yokken AVFoundation yalnız biçim kimliğini geri verir; ayarın reddedilmemesi (istisna yok) yeterli.
        XCTAssertEqual((output.audioSettings?[AVFormatIDKey] as? NSNumber)?.uint32Value, kAudioFormatLinearPCM)
    }

    func testMixerFailsCleanlyOnMissingInput() {
        let done = expectation(description: "mix")
        var result: Error?
        AudioMixer.mixAudioTracks(of: folder.appendingPathComponent("yok.mov"), into: folder.appendingPathComponent("son.mov")) { error in
            result = error
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertNotNil(result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("son.mov").path))
    }

    // MARK: Yardımcılar

    /// Ana saatte 1000. saniyeden başlayan 3 sn'lik kayıt: 1 sn hareketli görüntü (30 kare) + sabit ekran,
    /// 3 sn sistem sesi, mikrofon ayrı bir saatten (5000. sn) gelip ana saate kaydırılarak eklenir.
    private func writeSample(
        to url: URL,
        systemFrequency: Double,
        microphoneFrequency: Double,
        includeMicrophone: Bool,
        skipSystemAudio: Bool = false
    ) throws {
        let start = CMTime(seconds: 1000, preferredTimescale: 48_000)
        let writer = try MovieWriter(
            url: url,
            configuration: .init(width: 64, height: 64, framesPerSecond: 30, includesSystemAudio: true, includesMicrophone: includeMicrophone)
        )

        enum Event { case video(CMTime), system(CMTime), microphone(CMTime) }
        var events: [(Double, Event)] = []
        for index in 0..<30 {
            let time = CMTimeAdd(start, CMTime(value: CMTimeValue(index), timescale: 30))
            events.append((time.seconds, .video(time)))
        }
        let frames = Synthetic.framesPerAudioBuffer
        let audioBuffers = Int((3.0 * 48_000) / Double(frames))
        for index in 0..<audioBuffers {
            let time = CMTimeAdd(start, CMTime(value: CMTimeValue(index * frames), timescale: 48_000))
            if !skipSystemAudio {
                events.append((time.seconds, .system(time)))
            }
            if includeMicrophone {
                events.append((time.seconds + 0.0001, .microphone(time)))
            }
        }
        events.sort { $0.0 < $1.0 }

        let microphoneClockOffset = CMTime(seconds: 4000, preferredTimescale: 48_000)
        for (_, event) in events {
            switch event {
            case let .video(time):
                writer.appendVideo(try Synthetic.videoFrame(at: time))
            case let .system(time):
                writer.appendSystemAudio(try Synthetic.audioBuffer(at: time, frequency: systemFrequency))
            case let .microphone(time):
                let own = try Synthetic.audioBuffer(at: CMTimeAdd(time, microphoneClockOffset), frequency: microphoneFrequency)
                writer.appendMicrophone(try XCTUnwrap(SampleTiming.shifted(own, by: CMTimeMultiply(microphoneClockOffset, multiplier: -1))))
            }
            // Gerçek zamanlı girişlerin kodlayıcıya yetişmesi için kısa nefes.
            Thread.sleep(forTimeInterval: 0.0005)
        }

        XCTAssertEqual(writer.appendedVideoFrames, 30)
        if !skipSystemAudio {
            XCTAssertGreaterThan(writer.appendedSystemAudioBuffers, audioBuffers * 9 / 10)
        }
        if includeMicrophone {
            XCTAssertGreaterThan(writer.appendedMicrophoneBuffers, audioBuffers * 9 / 10)
        }

        let done = expectation(description: "finish")
        var result: Error?
        writer.finish(at: CMTimeAdd(start, CMTime(seconds: 3, preferredTimescale: 48_000))) { error in
            result = error
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
        XCTAssertNil(result)
        XCTAssertEqual(writer.appendedVideoFrames, 31, "son kare bitişe uzatıldı")
    }

    private func mix(_ input: URL, into output: URL) throws {
        let done = expectation(description: "mix")
        var result: Error?
        AudioMixer.mixAudioTracks(of: input, into: output) { error in
            result = error
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
        if let result {
            throw result
        }
    }
}

enum Synthetic {
    static let framesPerAudioBuffer = 1024

    static func videoFrame(at time: CMTime) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        guard CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes as CFDictionary, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer
        else {
            throw RecordingError.writeFailed("pixel buffer")
        }
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &format) == noErr,
              let format
        else {
            throw RecordingError.writeFailed("format")
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        ) == noErr, let sample else {
            throw RecordingError.writeFailed("sample")
        }
        return sample
    }

    /// 48 kHz stereo float ses arabelleği; `frequency` 0 ise sessizlik.
    static func audioBuffer(at time: CMTime, frequency: Double) throws -> CMSampleBuffer {
        let frames = framesPerAudioBuffer
        let startFrame = Double(time.value) * 48_000 / Double(time.timescale)
        var samples = [Float](repeating: 0, count: frames * 2)
        if frequency > 0 {
            for frame in 0..<frames {
                let value = Float(0.3 * sin(2 * .pi * frequency * (startFrame + Double(frame)) / 48_000))
                samples[frame * 2] = value
                samples[frame * 2 + 1] = value
            }
        }

        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr,
              let format
        else {
            throw RecordingError.writeFailed("audio format")
        }

        let byteCount = samples.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block
        else {
            throw RecordingError.writeFailed("block")
        }
        let copyStatus = samples.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard copyStatus == noErr else {
            throw RecordingError.writeFailed("copy")
        }

        var sample: CMSampleBuffer?
        let pts = CMTimeConvertScale(time, timescale: 48_000, method: .roundHalfAwayFromZero)
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: frames, presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &sample) == noErr,
              let sample
        else {
            throw RecordingError.writeFailed("audio sample")
        }
        return sample
    }

    /// Dosyadaki tüm ses izlerinin karışık RMS değeri.
    static func rms(of url: URL) throws -> Double {
        let asset = AVURLAsset(url: url)
        let tracks = asset.tracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        reader.startReading()
        var sum = 0.0
        var count = 0
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var data = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            _ = data.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            for value in data {
                sum += Double(value * value)
            }
            count += data.count
        }
        return count > 0 ? (sum / Double(count)).squareRoot() : 0
    }

    static func videoSampleCount(of url: URL) throws -> Int {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else { return 0 }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var count = 0
        while let buffer = output.copyNextSampleBuffer() {
            count += CMSampleBufferGetNumSamples(buffer)
        }
        return count
    }
}

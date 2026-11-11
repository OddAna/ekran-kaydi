import AVFoundation
import CoreMedia
import XCTest
@testable import EkranKaydiCore

/// v1.1: kayıt sürerken mikrofon aç/kapa ve aygıt değişimi (kulaklık takıp çıkarma) sırasında ses izlerinin
/// kesintisiz ve zamanında kalması. Gerçek aygıt kullanılmaz; yapay arabelleklerle yazıcı denenir.
final class LiveAudioTests: XCTestCase {
    private var folder: URL!
    private let start = CMTime(seconds: 1000, preferredTimescale: 48_000)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ekrankaydi-canli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Mikrofon 1. ile 2. saniye arası kapalı (ya da aygıt değişiyor): boşluk sessizlikle dolar,
    /// 2. saniyeden sonraki ses kaymadan 2. saniyede duyulur, iz 3 sn sürer.
    func testMicrophoneGapIsFilledAndLaterAudioStaysInPlace() throws {
        let url = folder.appendingPathComponent("bosluk.mov")
        let writer = try makeWriter(url, systemAudio: false)
        try feed(writer, seconds: 3, microphone: { time in time < 1 || time >= 2 }, frequency: 660)
        try finish(writer, at: 3)

        XCTAssertGreaterThan(writer.appendedMicrophoneSilenceBuffers, 0)
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let track = try XCTUnwrap(asset.tracks(withMediaType: .audio).first)
        XCTAssertEqual(track.timeRange.duration.seconds, 3.0, accuracy: 0.1)
        XCTAssertTrue(track.segments.allSatisfy { !$0.isEmpty }, "iz boş düzenleme (gap) içermez")
        XCTAssertGreaterThan(try rms(of: url, from: 0.2, to: 0.8), 0.1)
        XCTAssertLessThan(try rms(of: url, from: 1.2, to: 1.8), 0.001, "kapalıyken sessiz")
        XCTAssertGreaterThan(try rms(of: url, from: 2.2, to: 2.8), 0.1, "yeniden açılınca ses yerinde")
    }

    /// Kayıt mikrofon kapalı başlar, hiç açılmaz: iz yine baştan sona (sessiz) vardır; sonradan açmaya hazır.
    func testMicrophoneTrackExistsWhenNeverEnabled() throws {
        let url = folder.appendingPathComponent("hic.mov")
        let writer = try makeWriter(url, systemAudio: true)
        try feed(writer, seconds: 3, microphone: { _ in false }, frequency: 440, fillGapsEvery: 0.5)
        try finish(writer, at: 3)

        XCTAssertEqual(writer.appendedMicrophoneBuffers, 0)
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let audio = asset.tracks(withMediaType: .audio)
        XCTAssertEqual(audio.count, 2)
        for track in audio {
            XCTAssertEqual(track.timeRange.duration.seconds, 3.0, accuracy: 0.1)
        }
    }

    /// Bekçi sessizliği bir ana kadar doldurduktan sonra gecikmeli gelen eski ses atlanır, yenisi yazılır.
    func testLateAudioBehindFilledSilenceIsDropped() throws {
        let url = folder.appendingPathComponent("gec.mov")
        let writer = try makeWriter(url, systemAudio: false)
        writer.appendVideo(try Synthetic.videoFrame(at: start))
        writer.fillAudioGaps(upTo: at(2))
        XCTAssertEqual(writer.microphoneCursor.seconds, at(2).seconds, accuracy: 0.001)

        writer.appendMicrophone(try Synthetic.audioBuffer(at: at(1.5), frequency: 660))
        XCTAssertEqual(writer.appendedMicrophoneBuffers, 0, "doldurulmuş ana düşen ses yazılmaz")
        writer.appendMicrophone(try Synthetic.audioBuffer(at: at(2.0), frequency: 660))
        XCTAssertEqual(writer.appendedMicrophoneBuffers, 1)
        writer.appendMicrophone(try Synthetic.audioBuffer(at: at(2.5), frequency: 660))
        XCTAssertEqual(writer.appendedMicrophoneBuffers, 2, "aradaki boşluk doldurulup yazılır")
        XCTAssertEqual(writer.microphoneCursor.seconds, at(2.5).seconds + 1024.0 / 48_000, accuracy: 0.001)
        try finish(writer, at: 3)
    }

    /// Mikrofonu açıp kapatınca karıştırılmış son dosya da kesintisiz ve doğru zamanlı olur.
    func testMixedOutputAfterMicrophoneToggle() throws {
        let raw = folder.appendingPathComponent("ham.mov")
        let writer = try makeWriter(raw, systemAudio: true)
        try feed(writer, seconds: 3, microphone: { time in time >= 1.5 }, frequency: 660, systemFrequency: 0, fillGapsEvery: 0.5)
        try finish(writer, at: 3)
        let mixed = folder.appendingPathComponent("son.mov")
        let done = expectation(description: "mix")
        var mixError: Error?
        AudioMixer.mixAudioTracks(of: raw, into: mixed) { error in
            mixError = error
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
        XCTAssertNil(mixError)
        XCTAssertEqual(AVURLAsset(url: mixed).tracks(withMediaType: .audio).count, 1)
        XCTAssertLessThan(try rms(of: mixed, from: 0.2, to: 1.3), 0.001)
        XCTAssertGreaterThan(try rms(of: mixed, from: 1.7, to: 2.8), 0.05)
    }

    /// ScreenCaptureKit sistem sesini ayrık kanallı (non-interleaved) verir; sessizlik o biçimde de kurulur.
    func testSilenceBufferForNonInterleavedFormat() throws {
        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format), noErr)
        let buffer = try XCTUnwrap(SilenceBuffer.make(format: try XCTUnwrap(format), description: description, frames: 480, at: at(1)))
        XCTAssertEqual(CMSampleBufferGetNumSamples(buffer), 480)
        XCTAssertEqual(CMBlockBufferGetDataLength(try XCTUnwrap(CMSampleBufferGetDataBuffer(buffer))), 480 * 4 * 2)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(buffer).seconds, at(1).seconds, accuracy: 0.0001)
    }

    func testOnlyScreenCaptureKitEngineTogglesMicrophoneLive() {
        XCTAssertFalse(SystemScreencaptureRecorder().supportsLiveMicrophoneToggle)
        if #available(macOS 13.0, *) {
            XCTAssertTrue(ScreenCaptureKitRecorder().supportsLiveMicrophoneToggle)
        }
    }

    /// Varsayılan aygıt okunabiliyor (bu Mac'te ses aygıtı varsa); AVFoundation aynı kimliği tanır.
    func testDefaultDeviceUIDMatchesCaptureDevice() throws {
        guard let uid = AudioDevices.defaultDeviceUID(.input) else {
            throw XCTSkip("Bu Mac'te ses girişi yok")
        }
        XCTAssertFalse(uid.isEmpty)
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            XCTAssertNotNil(AVCaptureDevice(uniqueID: uid))
        }
    }

    // MARK: Yardımcılar

    private func at(_ seconds: Double) -> CMTime {
        CMTimeAdd(start, CMTime(seconds: seconds, preferredTimescale: 48_000))
    }

    private func makeWriter(_ url: URL, systemAudio: Bool) throws -> MovieWriter {
        try MovieWriter(url: url, configuration: .init(width: 64, height: 64, framesPerSecond: 30, includesSystemAudio: systemAudio, includesMicrophone: true))
    }

    /// Gerçek zamanlı akışı taklit eder: 30 fps görüntü, 1024 örneklik ses arabellekleri sırayla.
    private func feed(
        _ writer: MovieWriter,
        seconds: Double,
        microphone: (Double) -> Bool,
        frequency: Double,
        systemFrequency: Double = 440,
        fillGapsEvery: Double? = nil
    ) throws {
        let frames = Synthetic.framesPerAudioBuffer
        let audioBuffers = Int(seconds * 48_000) / frames
        let videoFrames = Int(seconds * 30)
        var nextVideo = 0
        var nextFill = fillGapsEvery ?? .infinity
        for index in 0..<audioBuffers {
            let offset = Double(index * frames) / 48_000
            while nextVideo < videoFrames, Double(nextVideo) / 30 <= offset {
                writer.appendVideo(try Synthetic.videoFrame(at: CMTimeAdd(start, CMTime(value: CMTimeValue(nextVideo), timescale: 30))))
                nextVideo += 1
            }
            let time = CMTimeAdd(start, CMTime(value: CMTimeValue(index * frames), timescale: 48_000))
            writer.appendSystemAudio(try Synthetic.audioBuffer(at: time, frequency: systemFrequency))
            if microphone(offset) {
                writer.appendMicrophone(try Synthetic.audioBuffer(at: time, frequency: frequency))
            }
            if offset >= nextFill, let every = fillGapsEvery {
                // Bekçi bir saniye geriden doldurur (gerçek kayıttaki gibi).
                writer.fillAudioGaps(upTo: at(max(0, offset - 1)))
                nextFill += every
            }
            Thread.sleep(forTimeInterval: 0.0005)
        }
    }

    private func finish(_ writer: MovieWriter, at seconds: Double) throws {
        let done = expectation(description: "finish")
        var result: Error?
        writer.finish(at: at(seconds)) { error in
            result = error
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
        XCTAssertNil(result)
    }

    /// Dosyadaki seslerin belirli bir zaman aralığındaki RMS değeri.
    private func rms(of url: URL, from: Double, to: Double) throws -> Double {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 48_000), end: CMTime(seconds: to, preferredTimescale: 48_000))
        let output = AVAssetReaderAudioMixOutput(audioTracks: asset.tracks(withMediaType: .audio), audioSettings: [
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
}

import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

/// macOS 13+ kayıt yolu: ScreenCaptureKit ile ekran + sistem sesi, AVFoundation ile isteğe bağlı mikrofon.
/// Görüntü, sistem sesi ve mikrofon aynı seri kuyrukta tek bir `MovieWriter`a yazılır; ikisi birden
/// kaydedildiyse durdurunca `AudioMixer` sesleri tek ize karıştırır.
@available(macOS 13.0, *)
public final class ScreenCaptureKitRecorder: NSObject, ScreenRecorder {
    public var onUnexpectedStop: ((Result<URL, Error>) -> Void)?

    private enum State {
        case idle
        case starting
        case recording
        case stopping
    }

    private let sampleQueue = DispatchQueue(label: "ekrankaydi.samples", qos: .userInitiated)
    private var state: State = .idle
    private var request: RecordingRequest?
    private var stream: SCStream?
    private var sink: CaptureSink?
    private var microphoneSession: AVCaptureSession?

    public override init() {
        super.init()
    }

    // MARK: Başlat

    public func start(_ request: RecordingRequest, completion: @escaping (Error?) -> Void) {
        guard state == .idle else {
            completion(RecordingError.alreadyRecording)
            return
        }
        state = .starting

        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            DispatchQueue.main.async {
                guard let self else { return }
                do {
                    guard let content else {
                        throw Self.mapStartError(error)
                    }
                    guard let display = content.displays.first(where: { $0.displayID == request.display.displayID }) else {
                        throw RecordingError.displayNotFound
                    }
                    try self.beginCapture(on: display, request: request, completion: completion)
                } catch {
                    self.cleanUp()
                    completion(error)
                }
            }
        }
    }

    private func beginCapture(on display: SCDisplay, request: RecordingRequest, completion: @escaping (Error?) -> Void) throws {
        let size = CaptureSize.pixelSize(
            pointSize: CGSize(width: display.width, height: display.height),
            backingScale: request.display.backingScale
        )
        let fps = max(1, min(60, request.framesPerSecond))
        let needsMix = request.recordsSystemAudio && request.recordsMicrophone
        let writeURL = needsMix ? RecordingFileNamer.intermediateURL(for: request.outputURL) : request.outputURL

        let writer = try MovieWriter(
            url: writeURL,
            configuration: .init(
                width: size.width,
                height: size.height,
                framesPerSecond: fps,
                includesSystemAudio: request.recordsSystemAudio,
                includesMicrophone: request.recordsMicrophone
            )
        )
        do {
            try configureStream(on: display, request: request, size: size, fps: fps, writer: writer, completion: completion)
        } catch {
            sampleQueue.async { writer.cancel() }
            throw error
        }
    }

    private func configureStream(
        on display: SCDisplay,
        request: RecordingRequest,
        size: (width: Int, height: Int),
        fps: Int,
        writer: MovieWriter,
        completion: @escaping (Error?) -> Void
    ) throws {
        let sink = CaptureSink(writer: writer, queue: sampleQueue)
        sink.onStreamError = { [weak self] error in
            DispatchQueue.main.async { self?.handleStreamFailure(error) }
        }

        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        configuration.queueDepth = 6
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = true
        configuration.capturesAudio = request.recordsSystemAudio
        configuration.sampleRate = Int(MovieWriter.audioSampleRate)
        configuration.channelCount = MovieWriter.audioChannelCount
        // Uygulamanın kendi sesi yok; yine de kendi uyarı seslerini kayda katmaz.
        configuration.excludesCurrentProcessAudio = true

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: sink)
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sampleQueue)
        if request.recordsSystemAudio {
            try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sampleQueue)
        }

        var microphoneSession: AVCaptureSession?
        if request.recordsMicrophone {
            microphoneSession = try makeMicrophoneSession(sink: sink)
        }

        self.request = request
        self.stream = stream
        self.sink = sink
        self.microphoneSession = microphoneSession

        stream.startCapture { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.sampleQueue.async { writer.cancel() }
                    self.cleanUp()
                    completion(Self.mapStartError(error))
                    return
                }
                if let microphoneSession {
                    DispatchQueue.global(qos: .userInitiated).async {
                        microphoneSession.startRunning()
                    }
                }
                self.state = .recording
                completion(nil)
            }
        }
    }

    private func makeMicrophoneSession(sink: CaptureSink) throws -> AVCaptureSession {
        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw RecordingError.microphoneUnavailable
        }
        let session = AVCaptureSession()
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw RecordingError.microphoneUnavailable
        }
        let output = AVCaptureAudioDataOutput()
        // Mikrofon da 48 kHz stereo gelir; sistem sesiyle aynı biçim karıştırmayı sorunsuz yapar.
        output.audioSettings = MovieWriter.linearPCMSettings
        output.setSampleBufferDelegate(sink, queue: sampleQueue)

        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw RecordingError.microphoneUnavailable
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        sink.microphoneSession = session
        return session
    }

    // MARK: Durdur

    public func stop(completion: @escaping (Result<URL, Error>) -> Void) {
        guard state == .recording, let stream else {
            completion(.failure(RecordingError.notRecording))
            return
        }
        state = .stopping
        stopMicrophone()
        stream.stopCapture { [weak self] _ in
            // Hata olsa bile o ana kadar yazılanı kapatıp kaydederiz.
            self?.finalize(completion: completion)
        }
    }

    private func handleStreamFailure(_ error: Error) {
        // Ekran çıkarıldı ya da macOS paylaşımı durdurdu: o ana kadarki kaydı sakla.
        guard state == .recording else { return }
        state = .stopping
        stopMicrophone()
        finalize { [weak self] result in
            self?.onUnexpectedStop?(result)
        }
    }

    private func stopMicrophone() {
        guard let microphoneSession else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            microphoneSession.stopRunning()
        }
    }

    /// Yazıcıyı kapatır, gerekirse sesleri karıştırır; sonucu ana kuyrukta bildirir.
    private func finalize(completion: @escaping (Result<URL, Error>) -> Void) {
        guard let sink, let request else {
            DispatchQueue.main.async { completion(.failure(RecordingError.notRecording)) }
            return
        }
        sampleQueue.async {
            sink.isClosed = true
            let endTime = CMClockGetTime(CMClockGetHostTimeClock())
            sink.writer.finish(at: endTime) { error in
                if let error {
                    DispatchQueue.main.async {
                        self.cleanUp()
                        completion(.failure(error))
                    }
                    return
                }
                let writtenURL = sink.writer.url
                guard writtenURL != request.outputURL else {
                    DispatchQueue.main.async {
                        self.cleanUp()
                        completion(Self.verified(request.outputURL))
                    }
                    return
                }
                AudioMixer.mixAudioTracks(of: writtenURL, into: request.outputURL) { mixError in
                    let fileManager = FileManager.default
                    if mixError == nil {
                        try? fileManager.removeItem(at: writtenURL)
                    } else {
                        // Karıştırma olmazsa iki ses izli dosya korunur (QuickTime ikisini birlikte çalar).
                        try? fileManager.removeItem(at: request.outputURL)
                        try? fileManager.moveItem(at: writtenURL, to: request.outputURL)
                    }
                    DispatchQueue.main.async {
                        self.cleanUp()
                        completion(Self.verified(request.outputURL))
                    }
                }
            }
        }
    }

    private func cleanUp() {
        stream = nil
        sink = nil
        microphoneSession = nil
        request = nil
        state = .idle
    }

    private static func verified(_ url: URL) -> Result<URL, Error> {
        SystemScreencaptureRecorder.fileHasContent(url) ? .success(url) : .failure(RecordingError.noFileCreated)
    }

    static func mapStartError(_ error: Error?) -> Error {
        guard let error else {
            return RecordingError.startFailed("Ekran listesi alınamadı.")
        }
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain, nsError.code == SCStreamError.Code.userDeclined.rawValue {
            return RecordingError.screenPermissionMissing
        }
        if !CGPreflightScreenCaptureAccess() {
            return RecordingError.screenPermissionMissing
        }
        return RecordingError.startFailed(error.localizedDescription)
    }
}

/// ScreenCaptureKit ve mikrofon örneklerini yazıcıya taşır. Tüm çağrılar `queue` üzerinde gelir.
@available(macOS 13.0, *)
private final class CaptureSink: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    let writer: MovieWriter
    let queue: DispatchQueue
    weak var microphoneSession: AVCaptureSession?
    var onStreamError: ((Error) -> Void)?
    /// Durdurma başladıktan sonra gelen örnekler yazılmaz (yalnız `queue` üzerinde değişir).
    var isClosed = false

    init(writer: MovieWriter, queue: DispatchQueue) {
        self.writer = writer
        self.queue = queue
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !isClosed, sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            guard Self.isCompleteFrame(sampleBuffer) else { return }
            writer.appendVideo(sampleBuffer)
        case .audio:
            writer.appendSystemAudio(sampleBuffer)
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStreamError?(error)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !isClosed, sampleBuffer.isValid else { return }
        // Mikrofon kendi saatine göre damgalanabilir; ekranla aynı (ana) saate çevrilir.
        let hostClock = CMClockGetHostTimeClock()
        var buffer: CMSampleBuffer? = sampleBuffer
        if let clock = microphoneSession?.synchronizationClock, !CFEqual(clock, hostClock) {
            let original = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let converted = CMSyncConvertTime(original, from: clock, to: hostClock)
            if original.isValid, converted.isValid {
                buffer = SampleTiming.shifted(sampleBuffer, by: CMTimeSubtract(converted, original))
            }
        }
        if let buffer {
            writer.appendMicrophone(buffer)
        }
    }

    /// ScreenCaptureKit değişmeyen ekran için "boşta" kareler de gönderir; yalnız tam kareler yazılır.
    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let rawStatus = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: rawStatus)
        else {
            return false
        }
        return status == .complete && CMSampleBufferGetImageBuffer(sampleBuffer) != nil
    }
}

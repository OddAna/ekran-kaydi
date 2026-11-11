import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

/// macOS 13+ kayıt yolu: ScreenCaptureKit ile ekran + sistem sesi, AVFoundation ile mikrofon.
/// Görüntü, sistem sesi ve mikrofon aynı seri kuyrukta tek bir `MovieWriter`a yazılır; sistem sesi de
/// kaydedildiyse durdurunca `AudioMixer` sesleri tek ize karıştırır.
///
/// Mikrofon izi her kayıtta vardır; mikrofon kayıt sürerken açılıp kapatılabilir (`setMicrophoneEnabled`).
/// Kapalı kaldığı ya da aygıt değişirken (kulaklık takılıp çıkarılırken) ses gelmeyen süre sessizlikle
/// doldurulur, kayıt kesilmez. Sistem sesi akışı durursa ScreenCaptureKit'in ses yakalaması yenilenir.
@available(macOS 13.0, *)
public final class ScreenCaptureKitRecorder: NSObject, ScreenRecorder {
    public var onUnexpectedStop: ((Result<URL, Error>) -> Void)?
    /// Teşhis için kısa olay satırları (aygıt değişimi, yeniden bağlanma). Ana kuyrukta gelmez.
    public var onEvent: ((String) -> Void)?
    public var supportsLiveMicrophoneToggle: Bool { true }

    /// Ses gelmeyen izler en çok bu kadar geriden sessizlikle doldurulur (gecikmeli gelen gerçek sese yer kalsın).
    static let gapFillDelay = CMTime(value: 1, timescale: 1)
    /// Sistem sesi bu kadar süre gelmezse ScreenCaptureKit'in ses yakalaması yenilenir.
    static let systemAudioStaleAfter: TimeInterval = 3

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
    private var microphone: MicrophoneCapture?
    private var configuration: SCStreamConfiguration?
    private var maintenanceTimer: DispatchSourceTimer?
    private var lastSystemAudioRestartUptime: TimeInterval = 0
    private var isRestartingSystemAudio = false

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
        // Mikrofon izi her zaman açılır: kayıt sürerken mikrofon sonradan da açılabilsin.
        let needsMix = request.recordsSystemAudio
        let writeURL = needsMix ? RecordingFileNamer.intermediateURL(for: request.outputURL) : request.outputURL

        let writer = try MovieWriter(
            url: writeURL,
            configuration: .init(
                width: size.width,
                height: size.height,
                framesPerSecond: fps,
                includesSystemAudio: request.recordsSystemAudio,
                includesMicrophone: true
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
        #if DEBUG
        // Geliştirici testi: uygulama kabuktan açılınca aynı kabuktan çalınan test sesi de "kendi sesi" sayılıp
        // dışlanır. Uçtan uca denemede bu anahtarla dışlama kapatılır (yayın derlemesinde yok).
        if ProcessInfo.processInfo.environment["EKRANKAYDI_KENDI_SESI"] == "1" {
            configuration.excludesCurrentProcessAudio = false
        }
        #endif

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: sink)
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sampleQueue)
        if request.recordsSystemAudio {
            try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sampleQueue)
        }

        let microphone = try MicrophoneCapture(delegate: sink, sampleQueue: sampleQueue)
        microphone.onEvent = { [weak self] message in self?.onEvent?(message) }
        sink.microphone = microphone
        sink.microphoneEnabled = request.recordsMicrophone
        #if DEBUG
        sink.onDebug = { [weak self] message in self?.onEvent?(message) }
        #endif

        self.request = request
        self.stream = stream
        self.sink = sink
        self.microphone = microphone
        self.configuration = configuration

        stream.startCapture { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.sampleQueue.async { writer.cancel() }
                    microphone.invalidate()
                    self.cleanUp()
                    completion(Self.mapStartError(error))
                    return
                }
                if request.recordsMicrophone {
                    microphone.setEnabled(true)
                }
                self.startMaintenance()
                self.state = .recording
                completion(nil)
            }
        }
    }

    // MARK: Kayıt sürerken

    /// Mikrofonu kayıt sürerken açar ya da kapatır; kayıt kesilmez. İzin denetimi çağıranın işidir.
    public func setMicrophoneEnabled(_ enabled: Bool) {
        guard state == .recording, let sink, let microphone else { return }
        sampleQueue.async { sink.microphoneEnabled = enabled }
        microphone.setEnabled(enabled)
        onEvent?(enabled ? "mikrofon açılıyor" : "mikrofon kapanıyor")
    }

    /// Sessizlik doldurma ve sistem sesi bekçisi: yarım saniyede bir, örnek kuyruğunda.
    private func startMaintenance() {
        guard let sink else { return }
        let timer = DispatchSource.makeTimerSource(queue: sampleQueue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        let recordsSystemAudio = request?.recordsSystemAudio ?? false
        timer.setEventHandler { [weak self] in
            guard !sink.isClosed else { return }
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            sink.writer.fillAudioGaps(upTo: CMTimeSubtract(now, Self.gapFillDelay))
            if recordsSystemAudio, sink.writer.hasStarted,
               ProcessInfo.processInfo.systemUptime - sink.lastSystemAudioUptime > Self.systemAudioStaleAfter
            {
                DispatchQueue.main.async { self?.restartSystemAudio(reason: "sistem sesi gelmiyor") }
            }
        }
        timer.resume()
        maintenanceTimer = timer
    }

    /// ScreenCaptureKit'in ses yakalamasını kapatıp açar; görüntü akışı sürer.
    public func restartSystemAudio(reason: String) {
        guard state == .recording, let stream, let configuration, let sink, !isRestartingSystemAudio else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastSystemAudioRestartUptime > Self.systemAudioStaleAfter else { return }
        lastSystemAudioRestartUptime = now
        isRestartingSystemAudio = true
        onEvent?("sistem sesi yeniden bağlanıyor (\(reason))")
        // Yeniden denemeden önce sayaç sıfırlanır: bekçi aynı anda ikinci kez tetiklemesin.
        sampleQueue.async { sink.lastSystemAudioUptime = ProcessInfo.processInfo.systemUptime }
        configuration.capturesAudio = false
        stream.updateConfiguration(configuration) { [weak self] _ in
            configuration.capturesAudio = true
            stream.updateConfiguration(configuration) { error in
                DispatchQueue.main.async {
                    self?.isRestartingSystemAudio = false
                    self?.onEvent?(error == nil ? "sistem sesi yeniden bağlandı" : "sistem sesi yeniden bağlanamadı: \(error!.localizedDescription)")
                }
            }
        }
    }

    // MARK: Durdur

    public func stop(completion: @escaping (Result<URL, Error>) -> Void) {
        guard state == .recording, let stream else {
            completion(.failure(RecordingError.notRecording))
            return
        }
        state = .stopping
        stopAuxiliaryCapture()
        stream.stopCapture { [weak self] _ in
            // Hata olsa bile o ana kadar yazılanı kapatıp kaydederiz.
            self?.finalize(completion: completion)
        }
    }

    private func handleStreamFailure(_ error: Error) {
        // Ekran çıkarıldı ya da macOS paylaşımı durdurdu: o ana kadarki kaydı sakla.
        guard state == .recording else { return }
        state = .stopping
        stopAuxiliaryCapture()
        finalize { [weak self] result in
            self?.onUnexpectedStop?(result)
        }
    }

    private func stopAuxiliaryCapture() {
        maintenanceTimer?.cancel()
        maintenanceTimer = nil
        if let microphone {
            DispatchQueue.global(qos: .userInitiated).async {
                microphone.invalidate()
            }
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
            let writer = sink.writer
            self.onEvent?("yazıcı: kare=\(writer.appendedVideoFrames) sistem sesi=\(writer.appendedSystemAudioBuffers)+\(writer.appendedSystemAudioSilenceBuffers) sessiz, mikrofon=\(writer.appendedMicrophoneBuffers)+\(writer.appendedMicrophoneSilenceBuffers) sessiz")
            sink.writer.finish(at: endTime) { error in
                if let error {
                    DispatchQueue.main.async {
                        self.cleanUp()
                        completion(.failure(error))
                    }
                    return
                }
                let writtenURL = sink.writer.url
                #if DEBUG
                // Geliştirici testi: karıştırmadan önceki iki ses izli ara dosyanın kopyası saklanır.
                if ProcessInfo.processInfo.environment["EKRANKAYDI_ARA_DOSYA"] == "1", writtenURL != request.outputURL {
                    let copy = request.outputURL.deletingPathExtension().appendingPathExtension("iki-iz.mov")
                    try? FileManager.default.removeItem(at: copy)
                    try? FileManager.default.copyItem(at: writtenURL, to: copy)
                }
                #endif
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
        maintenanceTimer?.cancel()
        maintenanceTimer = nil
        stream = nil
        sink = nil
        microphone = nil
        configuration = nil
        request = nil
        isRestartingSystemAudio = false
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
    var microphone: MicrophoneCapture?
    var onStreamError: ((Error) -> Void)?
    /// Durdurma başladıktan sonra gelen örnekler yazılmaz (yalnız `queue` üzerinde değişir).
    var isClosed = false
    /// Mikrofon kapalıyken yolda kalan son arabellekler yazılmaz (yalnız `queue` üzerinde değişir).
    var microphoneEnabled = false
    #if DEBUG
    var debugAudioCount = 0
    var onDebug: ((String) -> Void)?
    #endif
    /// Son sistem sesi arabelleğinin geldiği an (yalnız `queue` üzerinde değişir).
    var lastSystemAudioUptime = ProcessInfo.processInfo.systemUptime

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
            lastSystemAudioUptime = ProcessInfo.processInfo.systemUptime
            #if DEBUG
            if debugAudioCount < 3 {
                debugAudioCount += 1
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
                let host = CMClockGetTime(CMClockGetHostTimeClock()).seconds
                let start = writer.sessionStartTime?.seconds ?? -1
                onDebug?(String(format: "sistem sesi pts=%.3f ana saat=%.3f oturum=%.3f örnek=%d", pts, host, start, CMSampleBufferGetNumSamples(sampleBuffer)))
            }
            #endif
            writer.appendSystemAudio(sampleBuffer)
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStreamError?(error)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        microphone?.noteSample()
        guard !isClosed, microphoneEnabled, sampleBuffer.isValid else { return }
        // Mikrofon kendi saatine göre damgalanabilir; ekranla aynı (ana) saate çevrilir.
        let hostClock = CMClockGetHostTimeClock()
        var buffer: CMSampleBuffer? = sampleBuffer
        if let clock = microphone?.session.synchronizationClock, !CFEqual(clock, hostClock) {
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

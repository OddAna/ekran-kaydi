import AVFoundation
import CoreMedia
import Foundation

/// Kayıt boyunca yaşayan mikrofon yakalayıcısı.
///
/// - Kayıt sürerken açılıp kapatılabilir (`setEnabled`). Kapalıyken oturum durur, macOS'un mikrofon
///   göstergesi söner; kayıt dosyasındaki mikrofon izi `MovieWriter` tarafından sessizlikle sürdürülür.
/// - Her zaman macOS'un varsayılan girişini dinler. Kulaklık/AirPods takılınca ya da çıkarılınca, aygıt
///   koparsa ya da ses gelmeyi keserse yeni varsayılan aygıta yeniden bağlanır; kayıt durmaz.
@available(macOS 13.0, *)
final class MicrophoneCapture: NSObject {
    let session = AVCaptureSession()
    var onEvent: ((String) -> Void)?

    private let output = AVCaptureAudioDataOutput()
    private let controlQueue = DispatchQueue(label: "ekrankaydi.microphone", qos: .userInitiated)
    private let sampleLock = NSLock()
    private var lastSampleUptime: TimeInterval = 0

    // Yalnız `controlQueue` üzerinde değişir.
    private var wanted = false
    private var input: AVCaptureDeviceInput?
    private var lastAttemptUptime: TimeInterval = 0
    private var healthTimer: DispatchSourceTimer?
    private var deviceObservation: DefaultDeviceObservation?
    private var notificationTokens: [NSObjectProtocol] = []
    private var isInvalidated = false

    /// Ses bu kadar süre gelmezse bağlantı yenilenir.
    static let staleAfter: TimeInterval = 2
    /// Yeniden bağlanma denemeleri arasında en az bu kadar beklenir.
    static let retryInterval: TimeInterval = 1

    init(delegate: AVCaptureAudioDataOutputSampleBufferDelegate, sampleQueue: DispatchQueue) throws {
        super.init()
        // Mikrofon 48 kHz stereo float gelir; aygıt (ör. AirPods'un 16/24 kHz'i) değişse de biçim aynı kalır.
        output.audioSettings = MovieWriter.linearPCMSettings
        output.setSampleBufferDelegate(delegate, queue: sampleQueue)
        session.beginConfiguration()
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw RecordingError.microphoneUnavailable
        }
        session.addOutput(output)
        session.commitConfiguration()
    }

    /// Örnek kuyruğundan, her mikrofon arabelleğinde çağrılır.
    func noteSample() {
        sampleLock.lock()
        lastSampleUptime = ProcessInfo.processInfo.systemUptime
        sampleLock.unlock()
    }

    func setEnabled(_ enabled: Bool) {
        controlQueue.async { [self] in
            guard !isInvalidated, wanted != enabled else { return }
            wanted = enabled
            if enabled {
                startWatching()
                connect(force: false, reason: "açıldı")
            } else {
                stopWatching()
                disconnect()
                onEvent?("mikrofon kapatıldı")
            }
        }
    }

    /// Kayıt bitince çağrılır; oturumu durdurur, dinleyicileri kaldırır. Döndüğünde mikrofon kapalıdır.
    func invalidate() {
        controlQueue.sync {
            isInvalidated = true
            wanted = false
            stopWatching()
            disconnect()
        }
    }

    // MARK: Bağlantı (controlQueue)

    private func connect(force: Bool, reason: String) {
        guard wanted, !isInvalidated else { return }
        lastAttemptUptime = ProcessInfo.processInfo.systemUptime
        guard let device = Self.currentDefaultDevice() else {
            if input != nil {
                disconnect()
            }
            onEvent?("mikrofon aygıtı yok (\(reason)); bağlanınca devam edecek")
            return
        }
        if !force, let input, input.device.uniqueID == device.uniqueID, session.isRunning {
            return
        }

        if session.isRunning {
            session.stopRunning()
        }
        session.beginConfiguration()
        if let input {
            session.removeInput(input)
        }
        input = nil
        if let newInput = try? AVCaptureDeviceInput(device: device), session.canAddInput(newInput) {
            session.addInput(newInput)
            input = newInput
        }
        session.commitConfiguration()

        guard input != nil else {
            onEvent?("mikrofon bağlanamadı: \(device.localizedName) (\(reason)); yeniden denenecek")
            return
        }
        // Yeni aygıta ses gelmesi için süre tanı: sayaç bağlantı anından başlar.
        sampleLock.lock()
        lastSampleUptime = ProcessInfo.processInfo.systemUptime
        sampleLock.unlock()
        session.startRunning()
        onEvent?("mikrofon → \(device.localizedName) (\(reason))")
    }

    private func disconnect() {
        if session.isRunning {
            session.stopRunning()
        }
        if let input {
            session.beginConfiguration()
            session.removeInput(input)
            session.commitConfiguration()
        }
        input = nil
    }

    private func checkHealth() {
        guard wanted, !isInvalidated else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastAttemptUptime >= Self.retryInterval else { return }
        sampleLock.lock()
        let silentFor = now - lastSampleUptime
        sampleLock.unlock()

        let defaultUID = AudioDevices.defaultDeviceUID(.input)
        if input == nil {
            connect(force: true, reason: "aygıt bekleniyor")
        } else if let input, !input.device.isConnected {
            connect(force: true, reason: "aygıt çıkarıldı")
        } else if let defaultUID, defaultUID != input?.device.uniqueID {
            connect(force: false, reason: "varsayılan giriş değişti")
        } else if !session.isRunning || silentFor > Self.staleAfter {
            connect(force: true, reason: "ses gelmiyor")
        }
    }

    private func scheduleCheck(after delay: TimeInterval, reason: String) {
        controlQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.wanted, !self.isInvalidated else { return }
            // Bildirimden hemen sonra macOS varsayılanı henüz güncellememiş olabilir; ana denetim aynısını yapar.
            self.lastAttemptUptime = 0
            self.checkHealth()
        }
    }

    private func startWatching() {
        guard healthTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: controlQueue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.checkHealth() }
        timer.resume()
        healthTimer = timer

        deviceObservation = AudioDevices.observeDefaultDevices(on: controlQueue) { [weak self] direction in
            guard direction == .input else { return }
            self?.scheduleCheck(after: 0.2, reason: "varsayılan giriş değişti")
        }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            AVCaptureDevice.wasConnectedNotification,
            AVCaptureDevice.wasDisconnectedNotification,
            .AVCaptureSessionRuntimeError,
        ]
        for name in names {
            notificationTokens.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.scheduleCheck(after: 0.3, reason: name.rawValue)
            })
        }
    }

    private func stopWatching() {
        healthTimer?.cancel()
        healthTimer = nil
        deviceObservation?.invalidate()
        deviceObservation = nil
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        notificationTokens.removeAll()
    }

    /// macOS'un varsayılan girişi; AVFoundation henüz tanımıyorsa sistemin önerdiği ses aygıtı.
    static func currentDefaultDevice() -> AVCaptureDevice? {
        if let uid = AudioDevices.defaultDeviceUID(.input), let device = AVCaptureDevice(uniqueID: uid), device.hasMediaType(.audio) {
            return device
        }
        return AVCaptureDevice.default(for: .audio)
    }
}

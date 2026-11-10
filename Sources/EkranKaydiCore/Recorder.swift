import Foundation

/// Bir kaydın isteği. Ekran, kayıt anında bu Mac'ten okunan listeden gelir.
public struct RecordingRequest {
    public let display: DisplayChoice
    public let recordsSystemAudio: Bool
    public let recordsMicrophone: Bool
    public let outputURL: URL
    public let framesPerSecond: Int

    public init(
        display: DisplayChoice,
        recordsSystemAudio: Bool,
        recordsMicrophone: Bool,
        outputURL: URL,
        framesPerSecond: Int = 30
    ) {
        self.display = display
        self.recordsSystemAudio = recordsSystemAudio
        self.recordsMicrophone = recordsMicrophone
        self.outputURL = outputURL
        self.framesPerSecond = framesPerSecond
    }
}

public enum RecordingError: LocalizedError, Equatable {
    case alreadyRecording
    case notRecording
    case displayNotFound
    case screenPermissionMissing
    case microphoneUnavailable
    case startFailed(String)
    case writeFailed(String)
    case noFileCreated

    public var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "Zaten bir kayıt sürüyor."
        case .notRecording:
            return "Şu an kayıt yok."
        case .displayNotFound:
            return "Seçilen ekran bulunamadı. Menüden ekranı yeniden seçin."
        case .screenPermissionMissing:
            return "Ekran kaydı izni yok. Sistem Ayarları › Gizlilik ve Güvenlik › Ekran Kaydı bölümünden izin verin."
        case .microphoneUnavailable:
            return "Mikrofon bulunamadı ya da açılamadı."
        case let .startFailed(detail):
            return "Kayıt başlatılamadı: \(detail)"
        case let .writeFailed(detail):
            return "Kayıt dosyası yazılamadı: \(detail)"
        case .noFileCreated:
            return "Kayıt dosyası oluşmadı."
        }
    }
}

/// Kayıt motoru. Tüm geri çağrılar ana kuyrukta gelir.
public protocol ScreenRecorder: AnyObject {
    /// Kayıt beklenmedik biçimde bittiğinde (ekran çıkarıldı, sistem paylaşımı durdurdu) çağrılır.
    var onUnexpectedStop: ((Result<URL, Error>) -> Void)? { get set }
    func start(_ request: RecordingRequest, completion: @escaping (Error?) -> Void)
    func stop(completion: @escaping (Result<URL, Error>) -> Void)
}

/// Çalıştığı macOS'a göre hangi kayıt yolunun kullanılacağı.
public struct RecorderCapabilities: Equatable {
    public enum Engine: Equatable {
        /// macOS 13+: ScreenCaptureKit, sistem sesi dahil.
        case screenCaptureKit
        /// macOS 12: macOS'un kendi `screencapture` aracı; sistem sesi yok.
        case systemScreencapture
    }

    public let engine: Engine

    public init(operatingSystem: OperatingSystemVersion) {
        engine = operatingSystem.majorVersion >= 13 ? .screenCaptureKit : .systemScreencapture
    }

    public static var current: RecorderCapabilities {
        RecorderCapabilities(operatingSystem: ProcessInfo.processInfo.operatingSystemVersion)
    }

    public var supportsSystemAudio: Bool { engine == .screenCaptureKit }

    public static func makeRecorder() -> ScreenRecorder {
        if #available(macOS 13.0, *) {
            return ScreenCaptureKitRecorder()
        }
        return SystemScreencaptureRecorder()
    }
}

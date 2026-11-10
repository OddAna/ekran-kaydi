import Foundation

/// macOS 12 için kayıt yolu: macOS'un kendi `/usr/sbin/screencapture -v` aracı.
/// Bu sürümlerde macOS sistem sesini uygulamalara vermez; yalnız görüntü ve istenirse mikrofon kaydedilir.
public final class SystemScreencaptureRecorder: ScreenRecorder {
    public static let toolPath = "/usr/sbin/screencapture"

    public var onUnexpectedStop: ((Result<URL, Error>) -> Void)?

    private var process: Process?
    private var outputURL: URL?
    private var stopCompletion: ((Result<URL, Error>) -> Void)?
    /// Başlangıç denetimi sürerken araç kapanırsa sonucu `start` bildirir, `onUnexpectedStop` çağrılmaz.
    private var isStarting = false

    public init() {}

    /// `screencapture` argümanları: sessiz (-x), video (-v), ekran (-D n), mikrofon (-g, varsayılan giriş).
    public static func arguments(displayNumber: Int, recordsMicrophone: Bool, outputPath: String) -> [String] {
        var arguments = ["-x", "-v", "-D", String(displayNumber)]
        if recordsMicrophone {
            arguments.append("-g")
        }
        arguments.append(outputPath)
        return arguments
    }

    public func start(_ request: RecordingRequest, completion: @escaping (Error?) -> Void) {
        guard process == nil else {
            completion(RecordingError.alreadyRecording)
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.toolPath)
        process.arguments = Self.arguments(
            displayNumber: request.display.number,
            recordsMicrophone: request.recordsMicrophone,
            outputPath: request.outputURL.path
        )
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.handleTermination() }
        }

        do {
            try process.run()
        } catch {
            completion(RecordingError.startFailed(error.localizedDescription))
            return
        }

        self.process = process
        outputURL = request.outputURL
        isStarting = true

        // Araç izin yoksa ya da ekran yoksa hemen kapanır; bir saniye sonra hala çalışıyorsa kayıt başlamıştır.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.isStarting = false
            if let running = self.process, running.isRunning {
                completion(nil)
            } else {
                self.process = nil
                self.outputURL = nil
                completion(RecordingError.startFailed("macOS ekran kaydı aracı açılamadı. Ekran Kaydı iznini kontrol edin."))
            }
        }
    }

    public func stop(completion: @escaping (Result<URL, Error>) -> Void) {
        guard let process, process.isRunning else {
            completion(.failure(RecordingError.notRecording))
            return
        }
        stopCompletion = completion
        // `screencapture -v` Ctrl-C (SIGINT) ile dosyayı kapatıp çıkar.
        kill(process.processIdentifier, SIGINT)
    }

    private func handleTermination() {
        guard process != nil else { return }
        if isStarting {
            // `start` içindeki denetim hatayı bildirir.
            process = nil
            return
        }
        let url = outputURL
        process = nil
        outputURL = nil

        let result: Result<URL, Error>
        if let url, Self.fileHasContent(url) {
            result = .success(url)
        } else {
            result = .failure(RecordingError.noFileCreated)
        }

        if let completion = stopCompletion {
            stopCompletion = nil
            completion(result)
        } else {
            onUnexpectedStop?(result)
        }
    }

    static func fileHasContent(_ url: URL) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        return size > 0
    }
}

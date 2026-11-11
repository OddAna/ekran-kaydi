import AppKit
import AVFoundation
import EkranKaydiCore
import os

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum Phase {
        case idle
        case starting
        case recording(startedAt: Date)
        case saving
    }

    private static let screenPermissionAskedKey = "ekranIzniIstendi"
    private let settings = RecordingSettings()
    private let capabilities = RecorderCapabilities.current
    private lazy var recorder: ScreenRecorder = RecorderCapabilities.makeRecorder()
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var phase: Phase = .idle
    private var timer: Timer?
    private var lastRecordingURL: URL?
    private var terminateAfterSaving = false
    /// Kayıt sürerken mikrofonun gerçekte açık olup olmadığı (ayar açık olsa da izin yoksa kapalı başlar).
    private var liveMicrophone = false
    private let log = Logger(subsystem: "app.ekrankaydi.menubar", category: "kayit")

    // MARK: Yaşam döngüsü

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        recorder.onUnexpectedStop = { [weak self] result in
            self?.finishSaving(result, unexpected: true)
        }
        recorder.onEvent = { [log] message in
            log.notice("\(message, privacy: .public)")
            #if DEBUG
            DebugAutotest.print(message)
            #endif
        }
        updateStatusButton()
        #if DEBUG
        DebugAutotest.runIfRequested(
            statusItem: statusItem,
            start: { [weak self] in self?.startRecording() },
            toggleMicrophone: { [weak self] in self?.toggleMicrophone() },
            restartSystemAudio: { [weak self] in
                if #available(macOS 13.0, *) {
                    (self?.recorder as? ScreenCaptureKitRecorder)?.restartSystemAudio(reason: "ototest")
                }
            },
            stop: { [weak self] in self?.stopRecording() }
        )
        #endif
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch phase {
        case .recording:
            terminateAfterSaving = true
            stopRecording()
            return .terminateLater
        case .saving, .starting:
            terminateAfterSaving = true
            return .terminateLater
        case .idle:
            return .terminateNow
        }
    }

    // MARK: Menü

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Menü her açılışta yeniden kurulur: ekran listesi her seferinde bu Mac'ten okunur.
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        let isIdle: Bool
        if case .idle = phase { isIdle = true } else { isIdle = false }

        switch phase {
        case .idle:
            menu.addItem(item("Kaydı Başlat", action: #selector(startRecordingAction), key: "r"))
        case .starting:
            menu.addItem(disabled("Kayıt başlıyor…"))
        case let .recording(startedAt):
            menu.addItem(disabled("Kayıt sürüyor · \(ElapsedFormatter.string(from: Date().timeIntervalSince(startedAt)))"))
            menu.addItem(item("Kaydı Durdur", action: #selector(stopRecordingAction), key: "r"))
        case .saving:
            menu.addItem(disabled("Kaydediliyor…"))
        }

        menu.addItem(.separator())
        menu.addItem(disabled("Ekran"))
        let choices = DisplayCatalog.choices(from: DisplayCatalog.currentScreens())
        let selected = DisplayCatalog.resolve(preferredID: settings.preferredDisplayID, in: choices)
        if choices.isEmpty {
            menu.addItem(disabled("Ekran bulunamadı"))
        }
        for choice in choices {
            let entry = item(choice.title, action: #selector(selectDisplay(_:)))
            entry.representedObject = NSNumber(value: choice.displayID)
            entry.state = choice.displayID == selected?.displayID ? .on : .off
            entry.isEnabled = isIdle
            entry.indentationLevel = 1
            menu.addItem(entry)
        }

        menu.addItem(.separator())
        menu.addItem(disabled("Ses"))
        let systemAudio: NSMenuItem
        if capabilities.supportsSystemAudio {
            systemAudio = item("Bilgisayarın sesi", action: #selector(toggleSystemAudio))
            systemAudio.state = settings.recordsSystemAudio ? .on : .off
            systemAudio.isEnabled = isIdle
        } else {
            systemAudio = disabled("Bilgisayarın sesi (macOS 13 ve üstü gerekir)")
        }
        systemAudio.indentationLevel = 1
        menu.addItem(systemAudio)
        let microphone: NSMenuItem
        if case .recording = phase {
            if recorder.supportsLiveMicrophoneToggle {
                // Kayıt sürerken mikrofon açılıp kapatılabilir; kayıt kesilmez.
                microphone = item("Mikrofon", action: #selector(toggleMicrophone), key: "m")
                microphone.state = liveMicrophone ? .on : .off
            } else {
                microphone = disabled("Mikrofon (kayıt sürerken değiştirmek macOS 13 ve üstü gerekir)")
                microphone.state = liveMicrophone ? .on : .off
            }
        } else {
            microphone = item("Mikrofon", action: #selector(toggleMicrophone))
            microphone.state = settings.recordsMicrophone ? .on : .off
            microphone.isEnabled = isIdle
        }
        microphone.indentationLevel = 1
        menu.addItem(microphone)

        menu.addItem(.separator())
        menu.addItem(disabled("Kayıt yeri"))
        for location in SaveLocation.allCases {
            let entry = item(location.menuTitle, action: #selector(selectSaveLocation(_:)))
            entry.representedObject = location.rawValue
            entry.state = settings.saveLocation == location ? .on : .off
            entry.isEnabled = isIdle
            entry.indentationLevel = 1
            menu.addItem(entry)
        }
        menu.addItem(item("Kayıt Klasörünü Aç", action: #selector(openSaveFolder)))
        if let lastRecordingURL, FileManager.default.fileExists(atPath: lastRecordingURL.path) {
            menu.addItem(item("Son Kaydı Göster", action: #selector(revealLastRecording)))
        }

        menu.addItem(.separator())
        menu.addItem(item("Çıkış", action: #selector(quit), key: "q"))
    }

    private func item(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        return entry
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        return entry
    }

    // MARK: Menü eylemleri

    @objc private func selectDisplay(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        settings.preferredDisplayID = number.uint32Value
    }

    @objc private func toggleSystemAudio() {
        settings.recordsSystemAudio.toggle()
    }

    @objc private func toggleMicrophone() {
        guard case .recording = phase, recorder.supportsLiveMicrophoneToggle else {
            settings.recordsMicrophone.toggle()
            return
        }
        if liveMicrophone {
            setLiveMicrophone(false)
            return
        }
        withLiveMicrophonePermission { [weak self] granted in
            guard let self, granted, case .recording = self.phase else { return }
            self.setLiveMicrophone(true)
        }
    }

    /// Kayıt sürerken mikrofonu açar/kapatır; seçim bir sonraki kayıt için de saklanır.
    private func setLiveMicrophone(_ enabled: Bool) {
        liveMicrophone = enabled
        settings.recordsMicrophone = enabled
        recorder.setMicrophoneEnabled(enabled)
        updateStatusButton()
    }

    @objc private func selectSaveLocation(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let location = SaveLocation(rawValue: raw) else { return }
        settings.saveLocation = location
    }

    @objc private func openSaveFolder() {
        do {
            NSWorkspace.shared.open(try settings.saveLocation.resolveFolder())
        } catch {
            showError("Kayıt klasörü açılamadı.", detail: error.localizedDescription)
        }
    }

    @objc private func revealLastRecording() {
        guard let lastRecordingURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastRecordingURL])
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func startRecordingAction() {
        startRecording()
    }

    @objc private func stopRecordingAction() {
        stopRecording()
    }

    // MARK: Kayıt

    private func startRecording() {
        guard case .idle = phase else { return }

        let choices = DisplayCatalog.choices(from: DisplayCatalog.currentScreens())
        guard let display = DisplayCatalog.resolve(preferredID: settings.preferredDisplayID, in: choices) else {
            showError("Kaydedilecek ekran bulunamadı.", detail: nil)
            return
        }
        guard ensureScreenPermission() else { return }

        phase = .starting
        updateStatusButton()

        withMicrophoneDecision { [weak self] useMicrophone in
            guard let self else { return }
            guard let useMicrophone else {
                self.phase = .idle
                self.updateStatusButton()
                self.completePendingTermination()
                return
            }
            let folder: URL
            do {
                folder = try self.settings.saveLocation.resolveFolder()
            } catch {
                self.phase = .idle
                self.updateStatusButton()
                self.showError("Kayıt klasörü hazırlanamadı.", detail: error.localizedDescription)
                self.completePendingTermination()
                return
            }
            let request = RecordingRequest(
                display: display,
                recordsSystemAudio: self.capabilities.supportsSystemAudio && self.settings.recordsSystemAudio,
                recordsMicrophone: useMicrophone,
                outputURL: RecordingFileNamer.uniqueURL(in: folder, date: Date())
            )
            self.recorder.start(request) { [weak self] error in
                guard let self else { return }
                if let error {
                    self.phase = .idle
                    self.updateStatusButton()
                    self.showStartError(error)
                    self.completePendingTermination()
                    return
                }
                self.liveMicrophone = useMicrophone
                self.phase = .recording(startedAt: Date())
                self.startTimer()
                self.updateStatusButton()
                if self.terminateAfterSaving {
                    self.stopRecording()
                }
            }
        }
    }

    private func stopRecording() {
        guard case .recording = phase else { return }
        phase = .saving
        stopTimer()
        updateStatusButton()
        recorder.stop { [weak self] result in
            self?.finishSaving(result, unexpected: false)
        }
    }

    private func finishSaving(_ result: Result<URL, Error>, unexpected: Bool) {
        phase = .idle
        stopTimer()
        updateStatusButton()
        switch result {
        case let .success(url):
            lastRecordingURL = url
            if !terminateAfterSaving {
                // Kaydın nereye düştüğü hemen görünsün: Finder dosyayı seçili açar.
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            if unexpected {
                showInfo("Kayıt durdu ve kaydedildi.", detail: "Ekran bağlantısı değişti ya da macOS paylaşımı durdurdu. Dosya: \(url.lastPathComponent)")
            }
        case let .failure(error):
            showError("Kayıt kaydedilemedi.", detail: error.localizedDescription)
        }
        completePendingTermination()
    }

    private func completePendingTermination() {
        guard terminateAfterSaving else { return }
        terminateAfterSaving = false
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    // MARK: İzinler

    /// Ekran Kaydı izni: yoksa macOS'un izin isteğini açar ve kullanıcıya nereden açacağını söyler.
    private func ensureScreenPermission() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        // İlk seferde yalnız macOS'un kendi izin isteği görünür; sonraki denemelerde nereden açılacağı anlatılır.
        let askedBefore = UserDefaults.standard.bool(forKey: Self.screenPermissionAskedKey)
        UserDefaults.standard.set(true, forKey: Self.screenPermissionAskedKey)
        if CGRequestScreenCaptureAccess() {
            return true
        }
        guard askedBefore else {
            return false
        }
        let alert = NSAlert()
        alert.messageText = "Ekran kaydı izni gerekiyor"
        alert.informativeText = """
        Sistem Ayarları › Gizlilik ve Güvenlik › \(PermissionText.screenSectionName) bölümünde \
        "Ekran Kaydı" uygulamasını açın. macOS isterse uygulamayı kapatıp yeniden açın, sonra kaydı tekrar başlatın.
        """
        alert.addButton(withTitle: "Ayarları Aç")
        alert.addButton(withTitle: "Vazgeç")
        if runAlert(alert) == .alertFirstButtonReturn {
            PermissionText.openScreenRecordingSettings()
        }
        return false
    }

    /// Mikrofon açıksa izni sorar. Sonuç: true = mikrofonla, false = mikrofonsuz, nil = vazgeçildi.
    private func withMicrophoneDecision(_ decide: @escaping (Bool?) -> Void) {
        guard settings.recordsMicrophone else {
            decide(false)
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            decide(AVCaptureDevice.default(for: .audio) != nil ? true : askToContinueWithoutMicrophone(reason: "Bu Mac'te mikrofon bulunamadı."))
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    decide(granted ? true : self.askToContinueWithoutMicrophone(reason: "Mikrofon izni verilmedi."))
                }
            }
        default:
            decide(askToContinueWithoutMicrophone(reason: "Mikrofon izni kapalı."))
        }
    }

    /// Kayıt sürerken mikrofonu açmadan önce izin. İzin yoksa kayıt mikrofonsuz sürer, nereden açılacağı söylenir.
    private func withLiveMicrophonePermission(_ decide: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            decide(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { decide(granted) }
            }
        default:
            let alert = NSAlert()
            alert.messageText = "Mikrofon izni kapalı."
            alert.informativeText = "Kayıt mikrofonsuz sürüyor. Sistem Ayarları › Gizlilik ve Güvenlik › Mikrofon bölümünden \"Ekran Kaydı\"nı açabilirsiniz."
            alert.addButton(withTitle: "Ayarları Aç")
            alert.addButton(withTitle: "Tamam")
            if runAlert(alert) == .alertFirstButtonReturn {
                PermissionText.openMicrophoneSettings()
            }
            decide(false)
        }
    }

    private func askToContinueWithoutMicrophone(reason: String) -> Bool? {
        let alert = NSAlert()
        alert.messageText = reason
        alert.informativeText = "Sistem Ayarları › Gizlilik ve Güvenlik › Mikrofon bölümünden \"Ekran Kaydı\"nı açabilirsiniz. Şimdilik mikrofonsuz kaydedebilirsiniz."
        alert.addButton(withTitle: "Mikrofonsuz Başlat")
        alert.addButton(withTitle: "Ayarları Aç")
        alert.addButton(withTitle: "Vazgeç")
        switch runAlert(alert) {
        case .alertFirstButtonReturn:
            return false
        case .alertSecondButtonReturn:
            PermissionText.openMicrophoneSettings()
            return nil
        default:
            return nil
        }
    }

    // MARK: Görünüm

    private func updateStatusButton() {
        guard let button = statusItem?.button else { return }
        let isActive: Bool
        var title = ""
        switch phase {
        case .idle:
            isActive = false
        case .starting:
            isActive = true
        case let .recording(startedAt):
            isActive = true
            title = " " + ElapsedFormatter.string(from: Date().timeIntervalSince(startedAt))
        case .saving:
            isActive = true
            title = " Kaydediliyor…"
        }

        // Simge her durumda şablon (template) görüntüdür: macOS onu menü çubuğunun öteki simgeleri gibi
        // (koyu çubukta beyaz, açık çubukta siyah) çizer. Kayıtta renk verilmez; renkli (tint) simge yeni
        // macOS menü çubuğunda siyaha dönüp kayboluyordu. Kayıt dolu daire ve yanındaki süreyle anlaşılır.
        if let image = NSImage(systemSymbolName: isActive ? "record.circle.fill" : "record.circle", accessibilityDescription: "Ekran Kaydı")
        {
            image.isTemplate = true
            button.image = image
            button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
            button.title = title
        } else {
            button.image = nil
            button.title = (isActive ? "●" : "○") + title
        }
        button.contentTintColor = nil
        #if DEBUG
        // Karşılaştırma için 1.0.0'ın davranışı (kayıtta kırmızı tint): yalnız geliştirici derlemesi.
        if ProcessInfo.processInfo.environment["EKRANKAYDI_ESKI_RENK"] == "1" {
            button.contentTintColor = isActive ? .systemRed : nil
        }
        #endif
        button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        if case .recording = phase {
            button.toolTip = "Ekran Kaydı · kayıt sürüyor · mikrofon " + (liveMicrophone ? "açık" : "kapalı")
        } else {
            button.toolTip = isActive ? "Ekran Kaydı · kayıt sürüyor" : "Ekran Kaydı"
        }
    }

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateStatusButton()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func showStartError(_ error: Error) {
        if let recordingError = error as? RecordingError, recordingError == .screenPermissionMissing {
            let alert = NSAlert()
            alert.messageText = "Ekran kaydı izni gerekiyor"
            alert.informativeText = recordingError.localizedDescription
            alert.addButton(withTitle: "Ayarları Aç")
            alert.addButton(withTitle: "Tamam")
            if runAlert(alert) == .alertFirstButtonReturn {
                PermissionText.openScreenRecordingSettings()
            }
            return
        }
        showError("Kayıt başlatılamadı.", detail: error.localizedDescription)
    }

    private func showError(_ message: String, detail: String?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail ?? ""
        alert.addButton(withTitle: "Tamam")
        runAlert(alert)
    }

    private func showInfo(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "Tamam")
        runAlert(alert)
    }

    @discardableResult
    private func runAlert(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }
}

enum PermissionText {
    /// macOS 15'ten itibaren bölümün adı "Ekran ve Sistem Sesi Kaydı".
    static var screenSectionName: String {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15 ? "Ekran ve Sistem Sesi Kaydı" : "Ekran Kaydı"
    }

    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) {
            NSWorkspace.shared.open(url)
        }
    }
}

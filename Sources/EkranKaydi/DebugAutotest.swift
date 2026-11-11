#if DEBUG
import AppKit
import Foundation

/// Yalnız geliştirici derlemesinde (debug): menüye tıklamadan uçtan uca deneme.
/// `EKRANKAYDI_OTOTEST="0:baslat,4:mikrofon,8:mikrofon,20:sesyenile,30:durdur,34:cik"` saniye:eylem listesi.
/// `EKRANKAYDI_GORUNUM=aqua|darkAqua` simgeyi açık/koyu menü çubuğu görünümünde çizer (ekran görüntüsü için).
/// Yayın (release) derlemesine girmez.
enum DebugAutotest {
    static let started = Date()

    static func print(_ message: String) {
        let line = String(format: "[%6.2f] %@\n", Date().timeIntervalSince(started), message)
        FileHandle.standardError.write(line.data(using: .utf8)!)
    }

    static func runIfRequested(
        statusItem: NSStatusItem,
        start: @escaping () -> Void,
        toggleMicrophone: @escaping () -> Void,
        restartSystemAudio: @escaping () -> Void,
        stop: @escaping () -> Void
    ) {
        let environment = ProcessInfo.processInfo.environment
        if let name = environment["EKRANKAYDI_GORUNUM"] {
            statusItem.button?.appearance = NSAppearance(named: name == "aqua" ? .aqua : .darkAqua)
        }
        guard let script = environment["EKRANKAYDI_OTOTEST"] else { return }
        for step in script.split(separator: ",") {
            let parts = step.split(separator: ":")
            guard parts.count == 2, let seconds = Double(parts[0]) else { continue }
            let action = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                print("ototest: \(action)")
                switch action {
                case "baslat": start()
                case "mikrofon": toggleMicrophone()
                case "sesyenile": restartSystemAudio()
                case "durdur": stop()
                case "cik": NSApp.terminate(nil)
                default: print("ototest: bilinmeyen eylem \(action)")
                }
            }
        }
    }
}
#endif

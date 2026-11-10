import Foundation

/// Kaydın düşeceği yer. Klasörler çalıştığı Mac'in kullanıcı klasörlerinden okunur; sabit yol yoktur.
public enum SaveLocation: String, CaseIterable {
    /// Filmler › Ekran Kayıtları
    case movies
    /// Doğrudan Masaüstü
    case desktop

    public var menuTitle: String {
        switch self {
        case .movies: return "Filmler"
        case .desktop: return "Masaüstü"
        }
    }

    /// Filmler altında açılan alt klasörün adı.
    public static let moviesSubfolderName = "Ekran Kayıtları"

    /// Kayıt klasörünü verilen kullanıcı klasörlerinden çözer (testte geçici klasörler verilir).
    public func folder(moviesDirectory: URL, desktopDirectory: URL) -> URL {
        switch self {
        case .movies:
            return moviesDirectory.appendingPathComponent(Self.moviesSubfolderName, isDirectory: true)
        case .desktop:
            return desktopDirectory
        }
    }

    /// Çalıştığı Mac'te kayıt klasörünü bulur ve yoksa oluşturur.
    public func resolveFolder(fileManager: FileManager = .default) throws -> URL {
        let movies = try fileManager.url(for: .moviesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let desktop = try fileManager.url(for: .desktopDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let folder = self.folder(moviesDirectory: movies, desktopDirectory: desktop)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

/// Menüden seçilen ayarlar; UserDefaults'ta saklanır.
public final class RecordingSettings {
    private enum Key {
        static let saveLocation = "kayitYeri"
        static let systemAudio = "sistemSesi"
        static let microphone = "mikrofon"
        static let displayID = "secilenEkranKimligi"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var saveLocation: SaveLocation {
        get { defaults.string(forKey: Key.saveLocation).flatMap(SaveLocation.init(rawValue:)) ?? .movies }
        set { defaults.set(newValue.rawValue, forKey: Key.saveLocation) }
    }

    /// Varsayılan: açık (uygulamanın asıl amacı sistem sesiyle kayıt).
    public var recordsSystemAudio: Bool {
        get { defaults.object(forKey: Key.systemAudio) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.systemAudio) }
    }

    /// Varsayılan: kapalı (isteğe bağlı).
    public var recordsMicrophone: Bool {
        get { defaults.object(forKey: Key.microphone) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.microphone) }
    }

    /// Son seçilen ekranın bu Mac'teki kimliği. Kayıtlı ekran artık bağlı değilse ana ekrana düşülür.
    public var preferredDisplayID: UInt32? {
        get { (defaults.object(forKey: Key.displayID) as? NSNumber)?.uint32Value }
        set {
            if let newValue {
                defaults.set(NSNumber(value: newValue), forKey: Key.displayID)
            } else {
                defaults.removeObject(forKey: Key.displayID)
            }
        }
    }
}

/// Dosya adı: "Ekran Kaydı 2026-11-10 18.40.12.mov" (macOS'un kendi adlandırmasına benzer).
public enum RecordingFileNamer {
    public static let baseName = "Ekran Kaydı"

    public static func fileName(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "\(baseName) \(formatter.string(from: date)).mov"
    }

    /// Aynı adda dosya varsa " (2)", " (3)" … ekler; var olan dosyanın üzerine yazılmaz.
    public static func uniqueURL(in folder: URL, date: Date, timeZone: TimeZone = .current, fileManager: FileManager = .default) -> URL {
        let name = fileName(for: date, timeZone: timeZone)
        let stem = (name as NSString).deletingPathExtension
        var candidate = folder.appendingPathComponent(name, isDirectory: false)
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(stem) (\(counter)).mov", isDirectory: false)
            counter += 1
        }
        return candidate
    }

    /// Mikrofon ve sistem sesi birleşmeden önceki ara dosya (aynı klasörde, gizli).
    public static func intermediateURL(for finalURL: URL) -> URL {
        let stem = finalURL.deletingPathExtension().lastPathComponent
        return finalURL.deletingLastPathComponent().appendingPathComponent(".\(stem).ham.mov", isDirectory: false)
    }
}

/// Menü çubuğundaki süre: "00:42", "12:05", "1:02:03".
public enum ElapsedFormatter {
    public static func string(from interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

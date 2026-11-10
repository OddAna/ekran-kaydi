import AppKit
import Foundation

/// Bir ekranın, çalıştığı Mac'ten okunan ham bilgisi.
/// Cihaza sabit ekran adı ya da kimliği yoktur: liste her seferinde `NSScreen.screens`ten kurulur.
public struct ScreenDescription: Equatable {
    public let displayID: UInt32
    public let localizedName: String
    /// Nokta cinsinden boyut.
    public let pointSize: CGSize
    public let backingScale: CGFloat

    public init(displayID: UInt32, localizedName: String, pointSize: CGSize, backingScale: CGFloat) {
        self.displayID = displayID
        self.localizedName = localizedName
        self.pointSize = pointSize
        self.backingScale = backingScale
    }
}

/// Menüde gösterilen ekran seçeneği.
public struct DisplayChoice: Equatable {
    public let displayID: UInt32
    /// `screencapture -D` için 1'den başlayan sıra (1 = ana ekran).
    public let number: Int
    /// Menüde görünen, aynı adlı ekranlar için numaralanmış ad.
    public let title: String
    public let isMain: Bool
    public let pointSize: CGSize
    public let backingScale: CGFloat
}

public enum DisplayCatalog {
    /// Bu Mac'e şu an bağlı ekranlar (ilk sıradaki ana ekrandır).
    public static func currentScreens() -> [ScreenDescription] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return ScreenDescription(
                displayID: number.uint32Value,
                localizedName: screen.localizedName,
                pointSize: screen.frame.size,
                backingScale: screen.backingScaleFactor
            )
        }
    }

    /// Ham ekran listesinden menü seçeneklerini üretir. Aynı adlı ekranlar "(2)", "(3)" ile ayrılır.
    public static func choices(from screens: [ScreenDescription]) -> [DisplayChoice] {
        var nameCounts: [String: Int] = [:]
        for screen in screens {
            nameCounts[normalizedName(screen.localizedName), default: 0] += 1
        }

        var seen: [String: Int] = [:]
        return screens.enumerated().map { index, screen in
            let name = normalizedName(screen.localizedName)
            seen[name, default: 0] += 1
            let title: String
            if nameCounts[name, default: 0] > 1 {
                title = "\(name) (\(seen[name, default: 1]))"
            } else {
                title = name
            }
            return DisplayChoice(
                displayID: screen.displayID,
                number: index + 1,
                title: title,
                isMain: index == 0,
                pointSize: screen.pointSize,
                backingScale: screen.backingScale
            )
        }
    }

    /// Kayıtlı tercih hala bağlıysa onu, değilse ana ekranı seçer.
    public static func resolve(preferredID: UInt32?, in choices: [DisplayChoice]) -> DisplayChoice? {
        if let preferredID, let match = choices.first(where: { $0.displayID == preferredID }) {
            return match
        }
        return choices.first
    }

    private static func normalizedName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Ekran" : trimmed
    }
}

/// H.264 için güvenli piksel boyutu: retina ölçeği korunur, uzun kenar 4096'yı geçmez, kenarlar çift sayıdır.
public enum CaptureSize {
    public static let maximumLongEdge: CGFloat = 4096

    public static func pixelSize(pointSize: CGSize, backingScale: CGFloat) -> (width: Int, height: Int) {
        let longEdge = max(pointSize.width, pointSize.height, 1)
        let scale = max(1, min(backingScale, maximumLongEdge / longEdge))
        return (even(pointSize.width * scale), even(pointSize.height * scale))
    }

    /// Ekran kaydı için ortalama bit hızı: piksel başına ~3 bit/sn, 4–24 Mbit/sn aralığında.
    public static func averageBitRate(width: Int, height: Int) -> Int {
        let raw = width * height * 3
        return min(24_000_000, max(4_000_000, raw))
    }

    private static func even(_ value: CGFloat) -> Int {
        max(2, Int(value.rounded(.down)) / 2 * 2)
    }
}

import XCTest
@testable import EkranKaydiCore

final class SettingsAndDisplayTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ekrankaydi.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDefaultsAreMoviesWithSystemAudioAndNoMicrophone() {
        let settings = RecordingSettings(defaults: defaults)
        XCTAssertEqual(settings.saveLocation, .movies)
        XCTAssertTrue(settings.recordsSystemAudio)
        XCTAssertFalse(settings.recordsMicrophone)
        XCTAssertNil(settings.preferredDisplayID)
    }

    func testSettingsPersist() {
        let settings = RecordingSettings(defaults: defaults)
        settings.saveLocation = .desktop
        settings.recordsSystemAudio = false
        settings.recordsMicrophone = true
        settings.preferredDisplayID = 724_042_646

        let reloaded = RecordingSettings(defaults: defaults)
        XCTAssertEqual(reloaded.saveLocation, .desktop)
        XCTAssertFalse(reloaded.recordsSystemAudio)
        XCTAssertTrue(reloaded.recordsMicrophone)
        XCTAssertEqual(reloaded.preferredDisplayID, 724_042_646)

        reloaded.preferredDisplayID = nil
        XCTAssertNil(RecordingSettings(defaults: defaults).preferredDisplayID)
    }

    func testSaveLocationFolders() {
        let movies = URL(fileURLWithPath: "/tmp/kullanici/Movies", isDirectory: true)
        let desktop = URL(fileURLWithPath: "/tmp/kullanici/Desktop", isDirectory: true)
        XCTAssertEqual(SaveLocation.movies.folder(moviesDirectory: movies, desktopDirectory: desktop).lastPathComponent, "Ekran Kayıtları")
        XCTAssertEqual(SaveLocation.movies.folder(moviesDirectory: movies, desktopDirectory: desktop).deletingLastPathComponent().path, movies.path)
        XCTAssertEqual(SaveLocation.desktop.folder(moviesDirectory: movies, desktopDirectory: desktop).path, desktop.path)
    }

    func testFileNameAndUniqueness() throws {
        let date = Date(timeIntervalSince1970: 1_794_325_212) // 2026-11-10 15:40:12 UTC
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(RecordingFileNamer.fileName(for: date, timeZone: utc), "Ekran Kaydı 2026-11-10 15.40.12.mov")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let first = RecordingFileNamer.uniqueURL(in: folder, date: date, timeZone: utc)
        XCTAssertEqual(first.lastPathComponent, "Ekran Kaydı 2026-11-10 15.40.12.mov")
        try Data([1]).write(to: first)
        let second = RecordingFileNamer.uniqueURL(in: folder, date: date, timeZone: utc)
        XCTAssertEqual(second.lastPathComponent, "Ekran Kaydı 2026-11-10 15.40.12 (2).mov")
        try Data([1]).write(to: second)
        XCTAssertEqual(RecordingFileNamer.uniqueURL(in: folder, date: date, timeZone: utc).lastPathComponent, "Ekran Kaydı 2026-11-10 15.40.12 (3).mov")

        let intermediate = RecordingFileNamer.intermediateURL(for: first)
        XCTAssertEqual(intermediate.lastPathComponent, ".Ekran Kaydı 2026-11-10 15.40.12.ham.mov")
        XCTAssertEqual(intermediate.deletingLastPathComponent().path, folder.path)
    }

    func testElapsedFormatter() {
        XCTAssertEqual(ElapsedFormatter.string(from: 0), "00:00")
        XCTAssertEqual(ElapsedFormatter.string(from: 42.9), "00:42")
        XCTAssertEqual(ElapsedFormatter.string(from: 725), "12:05")
        XCTAssertEqual(ElapsedFormatter.string(from: 3723), "1:02:03")
        XCTAssertEqual(ElapsedFormatter.string(from: -5), "00:00")
    }

    // MARK: Ekranlar: liste çalıştığı Mac'ten gelir, sabit ad yok

    func testSingleScreenChoice() {
        let choices = DisplayCatalog.choices(from: [
            ScreenDescription(displayID: 1, localizedName: "Yerleşik Retina Ekran", pointSize: CGSize(width: 1440, height: 900), backingScale: 2),
        ])
        XCTAssertEqual(choices.count, 1)
        XCTAssertEqual(choices[0].title, "Yerleşik Retina Ekran")
        XCTAssertEqual(choices[0].number, 1)
        XCTAssertTrue(choices[0].isMain)
    }

    func testDuplicateNamesAreNumberedAndOrderKept() {
        let choices = DisplayCatalog.choices(from: [
            ScreenDescription(displayID: 10, localizedName: "Built-in Retina Display", pointSize: CGSize(width: 1512, height: 982), backingScale: 2),
            ScreenDescription(displayID: 20, localizedName: "DELL P2419H", pointSize: CGSize(width: 1920, height: 1080), backingScale: 1),
            ScreenDescription(displayID: 30, localizedName: "DELL P2419H", pointSize: CGSize(width: 1920, height: 1080), backingScale: 1),
            ScreenDescription(displayID: 40, localizedName: "  ", pointSize: CGSize(width: 800, height: 600), backingScale: 1),
        ])
        XCTAssertEqual(choices.map(\.title), ["Built-in Retina Display", "DELL P2419H (1)", "DELL P2419H (2)", "Ekran"])
        XCTAssertEqual(choices.map(\.number), [1, 2, 3, 4])
        XCTAssertEqual(choices.map(\.isMain), [true, false, false, false])
    }

    func testResolveFallsBackToMainWhenSavedScreenIsGone() {
        let choices = DisplayCatalog.choices(from: [
            ScreenDescription(displayID: 5, localizedName: "A", pointSize: CGSize(width: 100, height: 100), backingScale: 1),
            ScreenDescription(displayID: 6, localizedName: "B", pointSize: CGSize(width: 100, height: 100), backingScale: 1),
        ])
        XCTAssertEqual(DisplayCatalog.resolve(preferredID: 6, in: choices)?.displayID, 6)
        XCTAssertEqual(DisplayCatalog.resolve(preferredID: 99, in: choices)?.displayID, 5)
        XCTAssertEqual(DisplayCatalog.resolve(preferredID: nil, in: choices)?.displayID, 5)
        XCTAssertNil(DisplayCatalog.resolve(preferredID: 5, in: []))
    }

    func testCurrentScreensComeFromThisMac() {
        // Bu Mac'in gerçek ekranları; sayısı ve adları makineye göre değişir, yalnız tutarlılık denetlenir.
        let screens = DisplayCatalog.currentScreens()
        let choices = DisplayCatalog.choices(from: screens)
        XCTAssertEqual(screens.count, choices.count)
        XCTAssertEqual(Set(choices.map(\.displayID)).count, choices.count)
    }

    func testSourceHasNoFixedScreenNamesOrUserPaths() throws {
        // Önceki hata (MiniLauncher 1.1.21): cihaza sabit ekran adları. Kaynakta böyle bir şey olmamalı.
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        var checked = 0
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for forbidden in ["DELL", "VG2448", "/Users/"] {
                XCTAssertFalse(text.contains(forbidden), "\(url.lastPathComponent) içinde \(forbidden)")
            }
            checked += 1
        }
        XCTAssertGreaterThan(checked, 3)
    }

    // MARK: Boyut, sürüm, eski macOS yolu

    func testCaptureSizeKeepsRetinaAndCapsLongEdge() {
        let retina = CaptureSize.pixelSize(pointSize: CGSize(width: 1440, height: 900), backingScale: 2)
        XCTAssertEqual(retina.width, 2880)
        XCTAssertEqual(retina.height, 1800)

        let big = CaptureSize.pixelSize(pointSize: CGSize(width: 3008, height: 1692), backingScale: 2)
        XCTAssertLessThanOrEqual(big.width, 4096)
        XCTAssertEqual(big.width % 2, 0)
        XCTAssertEqual(big.height % 2, 0)

        let odd = CaptureSize.pixelSize(pointSize: CGSize(width: 1367, height: 769), backingScale: 1)
        XCTAssertEqual(odd.width, 1366)
        XCTAssertEqual(odd.height, 768)

        XCTAssertEqual(CaptureSize.averageBitRate(width: 100, height: 100), 4_000_000)
        XCTAssertEqual(CaptureSize.averageBitRate(width: 2880, height: 1800), 15_552_000)
        XCTAssertEqual(CaptureSize.averageBitRate(width: 4096, height: 4096), 24_000_000)
    }

    func testEngineChoiceByMacOSVersion() {
        XCTAssertEqual(RecorderCapabilities(operatingSystem: .init(majorVersion: 12, minorVersion: 7, patchVersion: 0)).engine, .systemScreencapture)
        XCTAssertFalse(RecorderCapabilities(operatingSystem: .init(majorVersion: 12, minorVersion: 7, patchVersion: 0)).supportsSystemAudio)
        XCTAssertEqual(RecorderCapabilities(operatingSystem: .init(majorVersion: 13, minorVersion: 0, patchVersion: 0)).engine, .screenCaptureKit)
        XCTAssertTrue(RecorderCapabilities(operatingSystem: .init(majorVersion: 15, minorVersion: 1, patchVersion: 0)).supportsSystemAudio)
        XCTAssertTrue(RecorderCapabilities.current.supportsSystemAudio, "Bu Mac macOS 13+")
    }

    func testLegacyScreencaptureArguments() {
        XCTAssertEqual(
            SystemScreencaptureRecorder.arguments(displayNumber: 2, recordsMicrophone: false, outputPath: "/tmp/a.mov"),
            ["-x", "-v", "-D", "2", "/tmp/a.mov"]
        )
        XCTAssertEqual(
            SystemScreencaptureRecorder.arguments(displayNumber: 1, recordsMicrophone: true, outputPath: "/tmp/b.mov"),
            ["-x", "-v", "-D", "1", "-g", "/tmp/b.mov"]
        )
    }

    func testErrorMessagesAreTurkish() {
        XCTAssertEqual(RecordingError.alreadyRecording.localizedDescription, "Zaten bir kayıt sürüyor.")
        XCTAssertTrue(RecordingError.screenPermissionMissing.localizedDescription.contains("Gizlilik ve Güvenlik"))
    }
}

import AppKit

// Menü çubuğu uygulaması: Dock simgesi yok (Info.plist › LSUIElement), tek pencere de yok.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()

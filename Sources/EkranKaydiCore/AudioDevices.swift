import CoreAudio
import Foundation

/// macOS'un varsayılan ses giriş/çıkış aygıtı (CoreAudio). Kulaklık ya da AirPods takılıp çıkarılınca
/// macOS varsayılanı değiştirir; kayıt bu değişikliği dinleyip mikrofonu yeni aygıta bağlar.
public enum AudioDevices {
    public enum Direction {
        case input
        case output

        var selector: AudioObjectPropertySelector {
            switch self {
            case .input: return kAudioHardwarePropertyDefaultInputDevice
            case .output: return kAudioHardwarePropertyDefaultOutputDevice
            }
        }
    }

    /// Varsayılan aygıtın kalıcı kimliği (UID). AVFoundation'da `AVCaptureDevice.uniqueID` ile aynıdır.
    public static func defaultDeviceUID(_ direction: Direction) -> String? {
        guard let device = defaultDeviceID(direction) else { return nil }
        return stringProperty(kAudioDevicePropertyDeviceUID, of: device)
    }

    public static func defaultDeviceName(_ direction: Direction) -> String? {
        guard let device = defaultDeviceID(direction) else { return nil }
        return stringProperty(kAudioObjectPropertyName, of: device)
    }

    static func defaultDeviceID(_ direction: Direction) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: direction.selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, of device: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// Varsayılan giriş ya da çıkış değişince `handler`ı `queue` üzerinde çağırır. Dönen nesne yaşadıkça dinlenir.
    public static func observeDefaultDevices(on queue: DispatchQueue, handler: @escaping (Direction) -> Void) -> DefaultDeviceObservation {
        DefaultDeviceObservation(queue: queue, handler: handler)
    }
}

/// `AudioDevices.observeDefaultDevices` dinleyicisi; `invalidate()` ya da serbest bırakılınca dinleme biter.
public final class DefaultDeviceObservation {
    private let queue: DispatchQueue
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init(queue: DispatchQueue, handler: @escaping (AudioDevices.Direction) -> Void) {
        self.queue = queue
        for direction in [AudioDevices.Direction.input, .output] {
            var address = AudioObjectPropertyAddress(
                mSelector: direction.selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { _, _ in handler(direction) }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block) == noErr {
                listeners.append((address, block))
            }
        }
    }

    public func invalidate() {
        for (address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        }
        listeners.removeAll()
    }

    deinit {
        invalidate()
    }
}

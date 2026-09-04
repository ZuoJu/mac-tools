import AppKit
import CoreAudio
import Darwin

enum LevelError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? { if case let .unavailable(message) = self { return message }; return nil }
}

/// No synthetic media keys: read and write the actual display/output device level.
final class SystemLevels {
    private typealias GetBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (UInt32, Float) -> Int32
    private let displayLibrary = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW | RTLD_LOCAL)

    func adjustBrightness(by delta: Double) throws -> Double {
        guard let displayLibrary,
              let getSymbol = dlsym(displayLibrary, "DisplayServicesGetBrightness"),
              let setSymbol = dlsym(displayLibrary, "DisplayServicesSetBrightness") else {
            throw LevelError.unavailable("当前系统不支持屏幕亮度调节")
        }
        let get = unsafeBitCast(getSymbol, to: GetBrightness.self)
        let set = unsafeBitCast(setSymbol, to: SetBrightness.self)
        let displays: [UInt32] = NSScreen.screens.compactMap { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value }
        guard let display = displays.first(where: { CGDisplayIsBuiltin($0) != 0 }) ?? displays.first else {
            throw LevelError.unavailable("未找到可调节的屏幕")
        }
        var value: Float = 0
        guard get(display, &value) == 0, value.isFinite else {
            throw LevelError.unavailable("此屏幕不支持系统亮度调节（普通外接显示器暂不支持）")
        }
        // Keep a visible minimum to avoid accidentally blacking out the screen.
        value = Float(min(1, max(0.05, Double(value) + delta)))
        guard set(display, value) == 0 else { throw LevelError.unavailable("屏幕亮度调整失败") }
        return Double(value)
    }

    private func address(_ selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
    }
    private func read<T>(_ object: AudioObjectID, _ property: AudioObjectPropertyAddress, into value: inout T) -> Bool {
        var property = property
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutableBytes(of: &value) { bytes in
            AudioObjectGetPropertyData(object, &property, 0, nil, &size, bytes.baseAddress!) == noErr
        }
    }
    private func writable(_ object: AudioObjectID, _ property: AudioObjectPropertyAddress) -> Bool {
        var property = property
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(object, &property) && AudioObjectIsPropertySettable(object, &property, &settable) == noErr && settable.boolValue
    }
    private func write<T>(_ object: AudioObjectID, _ property: AudioObjectPropertyAddress, value: T) -> Bool {
        var property = property
        var value = value
        return withUnsafeBytes(of: &value) { bytes in
            AudioObjectSetPropertyData(object, &property, 0, nil, UInt32(MemoryLayout<T>.size), bytes.baseAddress!) == noErr
        }
    }

    func adjustVolume(by delta: Double) throws -> Double {
        var output = AudioDeviceID(kAudioObjectUnknown)
        let defaultOutput = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard read(AudioObjectID(kAudioObjectSystemObject), defaultOutput, into: &output), output != kAudioObjectUnknown else {
            throw LevelError.unavailable("未找到音频输出设备")
        }
        var properties = [address(kAudioDevicePropertyVolumeScalar)]
        if !writable(output, properties[0]) {
            properties = [1, 2].map { address(kAudioDevicePropertyVolumeScalar, element: $0) }.filter { writable(output, $0) }
        }
        guard !properties.isEmpty else { throw LevelError.unavailable("当前输出设备不支持系统音量调节，请使用设备自身的音量控制") }
        var old: [Float32] = []
        for property in properties {
            var value: Float32 = 0
            guard read(output, property, into: &value), value.isFinite else { throw LevelError.unavailable("读取音量失败") }
            old.append(value)
        }
        let muteProperty = address(kAudioDevicePropertyMute)
        var muted: UInt32 = 0
        _ = read(output, muteProperty, into: &muted)
        let values = old.map { Float32(min(1, max(0, (muted == 0 ? Double($0) : 0) + delta))) }
        for (index, property) in properties.enumerated() {
            guard write(output, property, value: values[index]) else {
                for previous in 0..<index { _ = write(output, properties[previous], value: old[previous]) }
                throw LevelError.unavailable("调整音量失败")
            }
        }
        if muted != 0, delta > 0 {
            guard writable(output, muteProperty), write(output, muteProperty, value: UInt32(0)) else {
                for index in properties.indices { _ = write(output, properties[index], value: old[index]) }
                throw LevelError.unavailable("请先解除输出设备静音")
            }
        }
        return values.map(Double.init).reduce(0, +) / Double(values.count)
    }
}

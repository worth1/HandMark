import Foundation
import CoreAudio
import HandMarkCore

/// 公开 Core Audio API 的系统输出音量控制器。
/// 每次操作都重新解析默认输出设备，因此耳机/扬声器切换后不会继续写旧设备。
final class SystemVolumeController {
    enum VolumeError: Error, CustomStringConvertible {
        case noDefaultOutput(OSStatus)
        case unsupported
        case readFailed(OSStatus)
        case writeFailed(OSStatus)

        var description: String {
            switch self {
            case .noDefaultOutput(let status): return "无法获取默认输出设备（OSStatus \(status)）"
            case .unsupported: return "当前默认输出设备不支持直接调节系统音量"
            case .readFailed(let status): return "读取系统音量失败（OSStatus \(status)）"
            case .writeFailed(let status): return "设置系统音量失败（OSStatus \(status)）"
            }
        }
    }

    struct ChangeResult {
        let percent: Int
        let changed: Bool
        let wasMuted: Bool
    }

    /// 读取当前默认输出设备音量，范围 0...1。
    func currentVolume() -> Result<Float32, VolumeError> {
        do {
            let device = try defaultOutputDevice()
            let addresses = volumeAddresses(for: device)
            guard !addresses.isEmpty else { throw VolumeError.unsupported }
            return .success(try readVolume(device: device, addresses: addresses))
        } catch let error as VolumeError {
            return .failure(error)
        } catch {
            return .failure(.unsupported)
        }
    }

    /// 按 10 个百分点调节一次。只有 Core Audio 写入成功才返回 success。
    func adjustOneStep(_ direction: VolumeGestureDirection) -> Result<ChangeResult, VolumeError> {
        do {
            let device = try defaultOutputDevice()
            let addresses = volumeAddresses(for: device)
            guard !addresses.isEmpty else { throw VolumeError.unsupported }

            let current = try readVolume(device: device, addresses: addresses)
            let delta: Float32 = Float32(VOLUME_STEP_PERCENT) / 100 * (direction == .up ? 1 : -1)
            let target = min(1, max(0, current + delta))
            let wasMuted = readMute(device: device) ?? false
            let changed = abs(target - current) > 0.0001

            if changed {
                for var address in addresses {
                    var value = target
                    let size = UInt32(MemoryLayout<Float32>.size)
                    let status = AudioObjectSetPropertyData(device, &address, 0, nil, size, &value)
                    guard status == noErr else { throw VolumeError.writeFailed(status) }
                }
            }

            // 调高/调低到非零后解除静音；降到 0 时同步静音。设备无静音属性时音量写入仍有效。
            setMuteIfSupported(device: device, muted: target <= 0.0001)

            // 回读确认实际系统值；回读失败时不伪造成功。
            let actual = try readVolume(device: device, addresses: addresses)
            let percent = Int((Double(actual) * 100).rounded())
            return .success(ChangeResult(percent: min(100, max(0, percent)),
                                         changed: changed,
                                         wasMuted: wasMuted))
        } catch let error as VolumeError {
            return .failure(error)
        } catch {
            return .failure(.unsupported)
        }
    }

    private func defaultOutputDevice() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else {
            throw VolumeError.noDefaultOutput(status)
        }
        return device
    }

    /// 优先主音量元素；不支持时回退到可写的独立输出声道。
    private func volumeAddresses(for device: AudioObjectID) -> [AudioObjectPropertyAddress] {
        let main = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if isReadableAndSettable(device: device, address: main) { return [main] }

        var channels: [AudioObjectPropertyAddress] = []
        for element in 1...32 {
            let address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: AudioObjectPropertyElement(element)
            )
            if isReadableAndSettable(device: device, address: address) {
                channels.append(address)
            }
        }
        return channels
    }

    private func isReadableAndSettable(device: AudioObjectID,
                                       address: AudioObjectPropertyAddress) -> Bool {
        var mutableAddress = address
        guard AudioObjectHasProperty(device, &mutableAddress) else { return false }
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &mutableAddress, &settable) == noErr,
              settable.boolValue else { return false }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &mutableAddress, 0, nil, &size, &value) == noErr
    }

    private func readVolume(device: AudioObjectID,
                            addresses: [AudioObjectPropertyAddress]) throws -> Float32 {
        var values: [Float32] = []
        for address in addresses {
            var mutableAddress = address
            var value = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            let status = AudioObjectGetPropertyData(device, &mutableAddress, 0, nil, &size, &value)
            guard status == noErr else { throw VolumeError.readFailed(status) }
            values.append(min(1, max(0, value)))
        }
        guard !values.isEmpty else { throw VolumeError.unsupported }
        return values.reduce(0, +) / Float32(values.count)
    }

    private func readMute(device: AudioObjectID) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    private func setMuteIfSupported(device: AudioObjectID, muted: Bool) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else { return }
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
              settable.boolValue else { return }
        var value: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, size, &value)
        if status != noErr {
            log("音量已设置，但静音状态同步失败（OSStatus \(status)）")
        }
    }
}

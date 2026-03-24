import AVFoundation
import UIKit

/// 设备能力检测工具
enum DeviceCapability {
    /// 检查设备是否支持多摄像头同时录制
    static var isMultiCamSupported: Bool {
        AVCaptureMultiCamSession.isMultiCamSupported
    }

    /// 获取设备型号
    static var modelName: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        return machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
    }

    /// 检查可用存储空间（字节）
    static var availableStorage: Int64 {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        guard let path = paths.first else { return 0 }
        let values = try? path.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    /// 检查存储空间是否充足（至少 500MB）
    static var hasAdequateStorage: Bool {
        availableStorage > 500_000_000
    }
}

/// 温度监控 — 在高温时自动降级分辨率
final class ThermalMonitor: ObservableObject {
    @Published var shouldDowngrade = false

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(thermalStateChanged),
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: nil
        )
    }

    @objc private func thermalStateChanged() {
        let state = ProcessInfo.processInfo.thermalState
        DispatchQueue.main.async {
            self.shouldDowngrade = (state == .serious || state == .critical)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

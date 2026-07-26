import Foundation
import UIKit
import MachO

/// 评测监控：记录一次转写期间的峰值内存、峰值热状态、电池变化。
/// actor 保证多线程（thermal 通知、采样 Task）访问安全。
actor BenchMonitor {
    private var peakMemoryMB: Double = 0
    private var peakThermal: ThermalLevel = .nominal
    private var startBatteryPct: Double = -1
    private var observer: (any NSObjectProtocol)?

    func start() {
        peakMemoryMB = 0
        peakThermal = Self.currentThermal()
        UIDevice.current.isBatteryMonitoringEnabled = true
        startBatteryPct = Self.batteryPct()
        // thermal 跨线程通知，转发回 actor 串行更新峰值
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: nil) { [weak self] _ in
                Task { await self?.noteThermal() }
            }
    }

    /// 由 BenchRunner 的采样 Task 周期调用。
    func sampleMemory() {
        let mb = Double(Self.residentBytes()) / 1024.0 / 1024.0
        if mb > peakMemoryMB { peakMemoryMB = mb }
    }

    private func noteThermal() {
        let t = Self.currentThermal()
        if t.rawValue > peakThermal.rawValue { peakThermal = t }
    }

    /// 返回 (峰值内存MB, 峰值热档, 掉电%)。电池未知时 delta 为 -1。
    func stop() -> (peakMemoryMB: Double, peakThermal: ThermalLevel, batteryDeltaPct: Double) {
        if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
        UIDevice.current.isBatteryMonitoringEnabled = false
        let end = Self.batteryPct()
        let delta = (startBatteryPct >= 0 && end >= 0) ? (startBatteryPct - end) : -1
        return (peakMemoryMB, peakThermal, delta)
    }

    // MARK: - 静态读取
    static func currentThermal() -> ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return .nominal
        case .fair:     return .fair
        case .serious:  return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }

    static func batteryPct() -> Double {
        let lvl = UIDevice.current.batteryLevel   // Float 0...1, -1 unknown
        return lvl >= 0 ? Double(lvl) * 100 : -1
    }

    /// 当前进程驻留内存（字节）。用 mach_task_basic_info。
    static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kerr == KERN_SUCCESS ? info.resident_size : 0
    }
}

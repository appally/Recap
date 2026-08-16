import Foundation
import CoreLocation
import MapKit
import RecapModels

/// 开录时自动采集会议地点（GPS 一次性定位 + 反地理编码）。
///
/// 设计要点：
/// - **提示性、非精确**：街区/楼宇级即可，不追求会议室精度。
/// - **纯本地**：坐标与地址仅写入 SwiftData，不上云、不进任何 prompt。
/// - **静默失败**：权限拒绝 / 定位超时 / 反编码失败 / 无可读地址 均放弃，`location` 保持 nil，绝不阻塞录音、绝不抛错。
/// - **首采一次**：仅在该场会议尚无地点（`meeting.location == nil`）时采集；暂停后续录不覆盖。
@MainActor
public final class LocationCaptureService {
    public static let shared = LocationCaptureService()

    /// 一次性定位超时：拿不到有效坐标即放弃（不阻录音）。
    private static let locationTimeout: Duration = .seconds(8)

    private init() {}

    /// 若 `meeting` 尚无地点，后台静默采集一次；成功后调 `saver` 持久化。
    public func captureIfAbsent(for meeting: Meeting, saver: @escaping @MainActor () -> Void) {
        guard meeting.location == nil else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let coordinate = await self.currentCoordinate() else { return }
            let item = await self.reverseGeocode(
                CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            )
            // 反编码失败 / 无可读地址 → 不落库（location 保持 nil，UI 不展示地点行）。
            // MKMapItem 没有 locality/thoroughfare 细分字段：POI 名仍优先；
            // 回退串用 shortAddress（缺则 fullAddress）整体充当原「区 + 街道」角色。
            guard let item,
                  let label = MeetingLocation.composeLabel(
                      .init(name: item.name,
                            locality: item.address?.shortAddress ?? item.address?.fullAddress,
                            thoroughfare: nil)
                  ) else { return }
            // 删除竞态（C1）：定位 8s + 反编码 await 期间会议可能已删除——写已销毁模型会崩溃
            guard !meeting.isDeleted, meeting.modelContext != nil else { return }
            meeting.location = MeetingLocation(
                label: label,
                coordinate: .init(latitude: coordinate.latitude, longitude: coordinate.longitude),
                source: .gps,
                capturedAt: .now
            )
            saver()
        }
    }

    // MARK: - 定位

    /// 取一次有效坐标；权限拒绝 / 超时返回 nil。
    private func currentCoordinate() async -> CLLocationCoordinate2D? {
        // 首次创建 session 会触发系统位置权限弹窗（文案见 Info.plist）。
        let session = CLServiceSession(authorization: .whenInUse)
        defer { session.invalidate() }
        return await withTaskGroup(of: CLLocationCoordinate2D?.self) { group in
            group.addTask {
                do {
                    for try await update in CLLocationUpdate.liveUpdates() {
                        if update.authorizationDenied { return nil }
                        if let loc = update.location { return loc.coordinate }
                    }
                } catch {
                    return nil
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: Self.locationTimeout)
                return nil
            }
            let first = await group.next()
            group.cancelAll()
            return first ?? nil
        }
    }

    /// 单次、串行反地理编码（开录仅调一次；失败返回 nil 不落库）。
    /// iOS 26 起弃用 CLGeocoder，改用 MapKit `MKReverseGeocodingRequest`（结果为 MKMapItem）。
    private func reverseGeocode(_ location: CLLocation) async -> MKMapItem? {
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        let items = try? await request.mapItems
        return items?.first
    }
}

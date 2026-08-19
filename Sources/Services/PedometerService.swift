import Foundation
import CoreMotion

/// CMPedometer のラッパ。**歩調(1 秒あたりの歩数)だけ**を取り出す。
///
/// 用途はビーコンを歩調に同期させること(docs/03「ビーコンの距離・方向キュー」)。
/// 歩数そのものや移動距離は使わない — 距離は位置情報から取るほうが確かで、
/// 端末に余計な情報を持たないため。
///
/// 端末の内蔵センサーで完結し、通信は行わない(docs/04 プライバシー)。
/// AirPods のモーションとは別系統なので、**外していても歩調は取れる**。
final class PedometerService {
    private let pedometer = CMPedometer()
    private var wantsUpdates = false

    /// メインスレッドで呼ばれる。歩調 [歩/秒]
    var onCadence: ((Double) -> Void)?

    /// 直近に受け取った歩調。立ち止まると更新が止まるので、鮮度も持つ
    private(set) var cadenceStepsPerSec: Double?
    private(set) var updatedAt: Date?

    static var isAvailable: Bool { CMPedometer.isCadenceAvailable() }

    var authorizationLabel: String {
        switch CMPedometer.authorizationStatus() {
        case .authorized: "許可"
        case .denied: "拒否"
        case .restricted: "制限"
        case .notDetermined: "未確認"
        @unknown default: "不明"
        }
    }

    func start() {
        guard !wantsUpdates, Self.isAvailable else { return }
        wantsUpdates = true
        pedometer.startUpdates(from: Date()) { [weak self] data, _ in
            // 任意のキューで呼ばれる。以降はメインで扱う
            guard let c = data?.currentCadence?.doubleValue, c > 0 else { return }
            Task { @MainActor [weak self] in
                guard let self, self.wantsUpdates else { return }
                self.cadenceStepsPerSec = c
                self.updatedAt = Date()
                self.onCadence?(c)
            }
        }
    }

    func stop() {
        guard wantsUpdates else { return }
        wantsUpdates = false
        pedometer.stopUpdates()
        cadenceStepsPerSec = nil
        updatedAt = nil
    }

    /// `maxAgeSec` 以内に受け取った歩調。古ければ nil(立ち止まると更新が来なくなるため)
    func cadence(maxAgeSec: Double, now: Date = Date()) -> Double? {
        guard let c = cadenceStepsPerSec, let at = updatedAt,
              now.timeIntervalSince(at) <= maxAgeSec else { return nil }
        return c
    }
}

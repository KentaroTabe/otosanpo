import Foundation
import CoreMotion

/// スマホ本体の CMMotionManager のラッパ(→ docs/13 頭部固定)。
///
/// 頭に固定したスマホの**真北基準の方位**(`deviceMotion.heading`)を流す。
/// AirPods の `CMHeadphoneMotionManager`(HeadphoneMotionService)とは別物:
/// あちらは磁力計が無くヨーを絶対化できない。スマホにはあるので、頭に載せれば
/// 「頭の絶対方位」が取れる — これが docs/13 の骨子。
///
/// - `attitude` の軸ではなく `heading` を読む。装着の向き(縦・横・多少の傾き)に
///   依存させないため。取り付けのずれは定数 1 つ(`head_mount.offset_deg`)で引く
/// - 参照枠は `.xTrueNorthZVertical`。位置情報は常に取っているので真北基準が使える
/// - 磁気が乱れて信じてよいかは、ここでは判定しない(Core の `HeadingQuarantine` の仕事)
final class HeadMotionService {
    private let manager = CMMotionManager()

    /// メインスレッドで呼ばれる。(真北基準の方位 0〜360°, センサ時刻)
    var onHeading: ((Double, TimeInterval) -> Void)?

    var isAvailable: Bool { manager.isDeviceMotionAvailable }
    var isActive: Bool { manager.isDeviceMotionActive }

    func start(updateHz: Double) {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / updateHz
        manager.startDeviceMotionUpdates(using: .xTrueNorthZVertical, to: .main) { [weak self] motion, _ in
            guard let m = motion else { return }
            // CoreMotion は「無効」を負値で表す(較正が済んでいない立ち上がりに来る)
            guard m.heading >= 0 else { return }
            self?.onHeading?(m.heading, m.timestamp)
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }
}

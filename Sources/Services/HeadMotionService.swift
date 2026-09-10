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
///   依存させないため。取り付けのずれは `MountOffset` が歩きながら学習する
/// - 参照枠は `.xTrueNorthZVertical`。位置情報は常に取っているので真北基準が使える
/// - 磁気が乱れて信じてよいかは、ここでは判定しない(Core の `HeadingQuarantine` の仕事)
final class HeadMotionService {
    private let manager = CMMotionManager()

    /// 1 標本ぶんの device-motion。**方位以外は記録専用**(2026-09-10)。
    ///
    /// 角速度との突き合わせで「方位が回転に応答しているか」を検疫できる可能性があるが、
    /// **スマホの角速度をまだ一度も測っていない**。軸・符号・遅れ・背景時の間引きは
    /// 実機でしか決まらないので、まず記録して次の案件で設計する。
    /// **この値をどの判定にも渡さないこと**(→ 受け入れ条件 E5)
    struct Sample {
        /// 真北基準の方位 [deg] 0..360
        var headingDeg: Double
        /// センサ時刻 [sec](端末起動からの単調時計)
        var sensorTime: TimeInterval
        /// バイアス補正済みの端末三軸角速度 [rad/s]
        var rotationRate: (x: Double, y: Double, z: Double)
        /// 端末座標系の重力ベクトル(単位 g)
        var gravity: (x: Double, y: Double, z: Double)
        /// 磁場の較正状態(-1 = 未較正 / 0 = 低 / 1 = 中 / 2 = 高)
        var magneticAccuracy: Int

        /// 三軸角速度の大きさ [rad/s]。「どれだけ動いたか」の総量
        var absoluteRateRadPerSec: Double {
            let r = rotationRate
            return (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot()
        }

        /// 角速度を**鉛直軸へ射影**した値 [rad/s]。
        /// 端末の取り付け向きが縦でも横でも同じ量になる(`rotationRate.z` 決め打ちを避ける)
        var verticalRateRadPerSec: Double {
            let g = gravity
            let norm = (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot()
            guard norm > 1e-9 else { return 0 }
            let r = rotationRate
            // 重力は「下向き」なので、上向きの回転を正にするため符号を反転する
            return -(r.x * g.x + r.y * g.y + r.z * g.z) / norm
        }
    }

    /// メインスレッドで呼ばれる
    var onSample: ((Sample) -> Void)?

    var isAvailable: Bool { manager.isDeviceMotionAvailable }
    var isActive: Bool { manager.isDeviceMotionActive }

    func start(updateHz: Double) {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / updateHz
        manager.startDeviceMotionUpdates(using: .xTrueNorthZVertical, to: .main) { [weak self] motion, _ in
            guard let m = motion else { return }
            // CoreMotion は「無効」を負値で表す(較正が済んでいない立ち上がりに来る)
            guard m.heading >= 0 else { return }
            self?.onSample?(Sample(
                headingDeg: m.heading,
                sensorTime: m.timestamp,
                rotationRate: (m.rotationRate.x, m.rotationRate.y, m.rotationRate.z),
                gravity: (m.gravity.x, m.gravity.y, m.gravity.z),
                magneticAccuracy: Int(m.magneticField.accuracy.rawValue)))
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }
}

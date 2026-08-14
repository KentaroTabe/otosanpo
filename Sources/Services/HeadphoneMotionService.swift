import Foundation
import CoreMotion

/// CMHeadphoneMotionManager のラッパ。
/// AirPods(第3世代 / Pro / Max 等、モーションセンサー搭載モデル)装着時のみ有効。
/// シミュレータおよび非対応イヤホンでは isAvailable = false になるため、
/// ContentView のデバッグボタンで nod / shake を代替発火できる。
final class HeadphoneMotionService {
    private let manager = CMHeadphoneMotionManager()

    /// メインスレッドで呼ばれる
    var onSample: ((HeadSample) -> Void)?

    var isAvailable: Bool {
        manager.isDeviceMotionAvailable
    }

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let m = motion else { return }
            let sample = HeadSample(
                time: m.timestamp,
                pitchDeg: m.attitude.pitch * 180 / .pi,
                yawDeg: m.attitude.yaw * 180 / .pi
            )
            self?.onSample?(sample)
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }
}

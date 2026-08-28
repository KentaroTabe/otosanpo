import Foundation
import CoreMotion

/// CMHeadphoneMotionManager のラッパ。
/// AirPods(第3世代 / Pro / Max 等、モーションセンサー搭載モデル)装着時のみ有効。
/// シミュレータおよび非対応イヤホンでは isAvailable = false になるため、
/// ContentView のデバッグボタンで nod / shake を代替発火できる。
///
/// セッション開始時に未接続でも、後から AirPods を装着した時点で更新を開始する
/// (デリゲートの接続通知で再試行する)。
final class HeadphoneMotionService: NSObject, CMHeadphoneMotionManagerDelegate {
    private let manager = CMHeadphoneMotionManager()
    private var wantsUpdates = false

    /// メインスレッドで呼ばれる
    var onSample: ((HeadSample) -> Void)?
    /// 接続状態が変わったとき(true = 装着・接続)
    var onConnectionChange: ((Bool) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
    }

    var isAvailable: Bool {
        manager.isDeviceMotionAvailable
    }

    var isActive: Bool {
        manager.isDeviceMotionActive
    }

    /// モーション利用の許可状態(未許可だと更新が一切届かない)
    var authorizationLabel: String {
        switch CMHeadphoneMotionManager.authorizationStatus() {
        case .authorized: "許可"
        case .denied: "拒否"
        case .restricted: "制限"
        case .notDetermined: "未確認"
        @unknown default: "不明"
        }
    }

    func start() {
        wantsUpdates = true
        startIfPossible()
    }

    func stop() {
        wantsUpdates = false
        manager.stopDeviceMotionUpdates()
    }

    private func startIfPossible() {
        guard wantsUpdates, manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let m = motion else { return }
            // 姿勢に加えて**角速度(ジャイロの生値)**も渡す。姿勢の yaw は旋回を追えて
            // いなかった(2026-08-19 実測)一方、角速度は基準を持たないので飛びに強い。
            // heading は参照枠を選べない都合で有効値が来ないかもしれないため、
            // 負値(CoreMotion の「無効」表現)は nil にして記録側で見分けられるようにする
            let heading = m.heading
            let sample = HeadSample(
                time: m.timestamp,
                pitchDeg: m.attitude.pitch * 180 / .pi,
                yawDeg: m.attitude.yaw * 180 / .pi,
                yawRateDegPerSec: m.rotationRate.z * 180 / .pi,
                headingDeg: heading >= 0 ? heading : nil
            )
            self?.onSample?(sample)
        }
    }

    // MARK: - CMHeadphoneMotionManagerDelegate

    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        onConnectionChange?(true)
        startIfPossible()
    }

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        // こちらから停止した場合も通知が来るため、セッション終了時に
        // 「ヘッドフォンが外れました」と誤記録しないよう抑制する
        guard wantsUpdates else { return }
        onConnectionChange?(false)
    }
}

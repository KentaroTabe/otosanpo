import Foundation
import CoreLocation
import Combine

/// CoreLocation のラッパ。ポケットに入れたままのバックグラウンド追跡を前提とする。
/// - UIBackgroundModes: location を Info.plist に設定済み(project.yml 参照)
/// - showsBackgroundLocationIndicator = true(利用中であることをユーザーに明示)
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var position: GeoPoint?
    @Published private(set) var headingDeg: Double?
    @Published private(set) var authorized = false

    private let manager = CLLocationManager()

    // 進行方向の推定材料(判定は Core の TravelDirection が行う。ここは値の運搬のみ)
    private var courseDeg: Double?
    private var courseAccuracyDeg: Double?
    private var speedMps: Double?
    private var lastFixDate: Date?

    /// 現時点の推定材料をまとめて返す(経過秒は読み出し時に計算する)
    func motionFix(now: Date = Date()) -> MotionFix {
        MotionFix(courseDeg: courseDeg,
                  courseAccuracyDeg: courseAccuracyDeg,
                  speedMps: speedMps,
                  compassHeadingDeg: headingDeg,
                  ageSec: lastFixDate.map { now.timeIntervalSince($0) })
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .fitness
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    /// 画面を開いている間だけの取得。起動直後に呼び、自宅設定や状態表示に使う fix を先に用意する。
    /// バックグラウンド更新は有効にしない(散歩していない間は前面にいる時だけ位置を使う)。
    func startForeground() {
        manager.startUpdatingLocation()
        manager.startUpdatingHeading()
    }

    /// 散歩セッション用。ポケットに入れたままの追跡のためバックグラウンド更新を有効にする。
    func start() {
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        manager.startUpdatingHeading()
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        manager.allowsBackgroundLocationUpdates = false
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        let s = m.authorizationStatus
        authorized = (s == .authorizedWhenInUse || s == .authorizedAlways)
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let l = locs.last else { return }
        courseDeg = l.course
        courseAccuracyDeg = l.courseAccuracy
        speedMps = l.speed
        lastFixDate = l.timestamp
        position = GeoPoint(latitude: l.coordinate.latitude, longitude: l.coordinate.longitude)
    }

    func locationManager(_ m: CLLocationManager, didUpdateHeading h: CLHeading) {
        // trueHeading が無効(-1)のときは magneticHeading で代替
        headingDeg = h.trueHeading >= 0 ? h.trueHeading : h.magneticHeading
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        // プロトタイプでは黙って次の更新を待つ
    }
}

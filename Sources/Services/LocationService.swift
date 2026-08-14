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

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .fitness
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

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

import CoreLocation
import Combine

final class DeviceLocationProvider: NSObject, ObservableObject {
    @Published private(set) var coordinate: CLLocationCoordinate2D?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var currentSpeed: CLLocationSpeed?

    private let manager = CLLocationManager()
    private var isTracking = false

    override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func enableTracking() {
        guard CLLocationManager.locationServicesEnabled() else { return }
        if authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        guard !isTracking else { return }
        manager.startUpdatingLocation()
        isTracking = true
    }

    func disableTracking() {
        guard isTracking else { return }
        manager.stopUpdatingLocation()
        isTracking = false
    }
}

extension DeviceLocationProvider: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if !(manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse) {
            disableTracking()
        } else if isTracking {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        coordinate = latest.coordinate
        currentSpeed = latest.speed >= 0 ? latest.speed : nil
    }
}

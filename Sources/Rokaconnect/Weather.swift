import Foundation
import CoreLocation

final class Weather: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var temp: Int?
    @Published var symbol = "cloud"
    private let lm = CLLocationManager()
    private var timer: Timer?
    override init() {
        super.init()
        lm.delegate = self
        lm.desiredAccuracy = kCLLocationAccuracyKilometer
        lm.requestWhenInUseAuthorization()
        lm.requestLocation()
        timer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in self?.lm.requestLocation() }
    }
    func locationManager(_ m: CLLocationManager, didUpdateLocations l: [CLLocation]) {
        guard let c = l.last?.coordinate else { return }
        // Coarse (2 decimals ≈ 1 km) coordinates only.
        let url = URL(string: String(format: "https://api.open-meteo.com/v1/forecast?latitude=%.2f&longitude=%.2f&current_weather=true", c.latitude, c.longitude))!
        URLSession.shared.dataTask(with: url) { d, _, _ in
            guard let d, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let cw = j["current_weather"] as? [String: Any],
                  let t = cw["temperature"] as? Double, let code = cw["weathercode"] as? Int else { return }
            let day = (cw["is_day"] as? Int ?? 1) == 1
            let sym: String
            switch code {
            case 0: sym = day ? "sun.max.fill" : "moon.stars.fill"
            case 1, 2: sym = day ? "cloud.sun.fill" : "cloud.moon.fill"
            case 3: sym = "cloud.fill"
            case 45, 48: sym = "cloud.fog.fill"
            case 51...67, 80...82: sym = "cloud.rain.fill"
            case 71...77, 85, 86: sym = "snowflake"
            case 95...99: sym = "cloud.bolt.rain.fill"
            default: sym = "cloud.fill"
            }
            DispatchQueue.main.async { self.temp = Int(t.rounded()); self.symbol = sym }
        }.resume()
    }
    func locationManager(_ m: CLLocationManager, didFailWithError e: Error) {}
}

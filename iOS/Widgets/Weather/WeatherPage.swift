import CoreLocation
import SwiftUI

/// Current weather, the next 12 hours and 5 days for where the phone is.
/// Open-Meteo instead of WeatherKit: WeatherKit needs a paid developer account.
@MainActor
final class WeatherModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    struct Forecast {
        var place: String?
        var temperature: Double
        var feelsLike: Double
        var wind: Double
        var code: Int
        var isDay: Bool
        var hourly: [(time: Date, temp: Double, code: Int)]
        var daily: [(day: Date, min: Double, max: Double, code: Int)]
        var fetched: Date
    }

    @Published private(set) var forecast: Forecast?
    @Published private(set) var authorization: CLAuthorizationStatus
    @Published private(set) var error: String?

    private let manager = CLLocationManager()
    private var location: CLLocation?

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func start() {
        if authorization == .notDetermined { manager.requestWhenInUseAuthorization() }
        if let forecast, Date().timeIntervalSince(forecast.fetched) < 15 * 60 { return }
        manager.requestLocation()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            authorization = status
            if status == .authorizedWhenInUse || status == .authorizedAlways { manager.requestLocation() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        MainActor.assumeIsolated {
            self.location = location
            Task { await fetch(location) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated { self.error = "Не удалось определить место" }
    }

    private func fetch(_ location: CLLocation) async {
        let c = location.coordinate
        var url = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        url.queryItems = [
            .init(name: "latitude", value: String(c.latitude)),
            .init(name: "longitude", value: String(c.longitude)),
            .init(name: "current", value: "temperature_2m,apparent_temperature,weather_code,wind_speed_10m,is_day"),
            .init(name: "hourly", value: "temperature_2m,weather_code"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min"),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: "5"),
            .init(name: "wind_speed_unit", value: "ms"),
        ]
        do {
            let (data, _) = try await URLSession.shared.data(from: url.url!)
            let r = try JSONDecoder().decode(OpenMeteo.self, from: data)
            let hourFormatter = DateFormatter()
            hourFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
            hourFormatter.timeZone = TimeZone(identifier: r.timezone)
            let dayFormatter = DateFormatter()
            dayFormatter.dateFormat = "yyyy-MM-dd"
            dayFormatter.timeZone = hourFormatter.timeZone
            let now = Date()
            let hourly = zip(r.hourly.time, zip(r.hourly.temperature_2m, r.hourly.weather_code))
                .compactMap { t, v -> (Date, Double, Int)? in hourFormatter.date(from: t).map { ($0, v.0, v.1) } }
                .filter { $0.0 > now.addingTimeInterval(-3600) }
                .prefix(12)
            let daily = r.daily.time.indices.compactMap { i -> (Date, Double, Double, Int)? in
                dayFormatter.date(from: r.daily.time[i]).map {
                    ($0, r.daily.temperature_2m_min[i], r.daily.temperature_2m_max[i], r.daily.weather_code[i])
                }
            }
            let place = try? await CLGeocoder().reverseGeocodeLocation(location).first?.locality
            forecast = Forecast(place: place, temperature: r.current.temperature_2m, feelsLike: r.current.apparent_temperature,
                                wind: r.current.wind_speed_10m, code: r.current.weather_code, isDay: r.current.is_day == 1,
                                hourly: hourly.map { (time: $0.0, temp: $0.1, code: $0.2) },
                                daily: daily.map { (day: $0.0, min: $0.1, max: $0.2, code: $0.3) },
                                fetched: Date())
            error = nil
        } catch {
            self.error = "Нет данных о погоде"
        }
    }

    private struct OpenMeteo: Decodable {
        struct Current: Decodable {
            var temperature_2m: Double
            var apparent_temperature: Double
            var weather_code: Int
            var wind_speed_10m: Double
            var is_day: Int
        }
        struct Hourly: Decodable {
            var time: [String]
            var temperature_2m: [Double]
            var weather_code: [Int]
        }
        struct Daily: Decodable {
            var time: [String]
            var weather_code: [Int]
            var temperature_2m_max: [Double]
            var temperature_2m_min: [Double]
        }
        var timezone: String
        var current: Current
        var hourly: Hourly
        var daily: Daily
    }
}

/// WMO weather codes → SF Symbol + Russian description.
enum WeatherCode {
    static func symbol(_ code: Int, day: Bool = true) -> String {
        switch code {
        case 0: day ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: day ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51...57: "cloud.drizzle.fill"
        case 61...67, 80...82: "cloud.rain.fill"
        case 71...77, 85, 86: "cloud.snow.fill"
        case 95...99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }

    static func text(_ code: Int) -> String {
        switch code {
        case 0: "Ясно"
        case 1: "Преимущественно ясно"
        case 2: "Переменная облачность"
        case 3: "Пасмурно"
        case 45, 48: "Туман"
        case 51...57: "Морось"
        case 61...67: "Дождь"
        case 71...77: "Снег"
        case 80...82: "Ливень"
        case 85, 86: "Снегопад"
        case 95...99: "Гроза"
        default: "—"
        }
    }
}

struct WeatherPage: View {
    @StateObject private var model = WeatherModel()

    var body: some View {
        Group {
            if let f = model.forecast {
                content(f)
            } else if model.authorization == .denied || model.authorization == .restricted {
                VStack(spacing: 12) {
                    Image(systemName: "location.slash").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("Нет доступа к геопозиции").font(.headline)
                    Button("Открыть Настройки") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(model.error ?? "Загружаю погоду…").foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { model.start() }
    }

    private func content(_ f: WeatherModel.Forecast) -> some View {
        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 4) {
                    Text(f.place ?? "Здесь").font(.title3.weight(.medium))
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: WeatherCode.symbol(f.code, day: f.isDay))
                            .symbolRenderingMode(.multicolor).font(.system(size: 48))
                        Text("\(Int(f.temperature.rounded()))°").font(.system(size: 72, weight: .thin))
                    }
                    Text(WeatherCode.text(f.code)).font(.headline)
                    Text("Ощущается как \(Int(f.feelsLike.rounded()))° · ветер \(Int(f.wind.rounded())) м/с")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 18) {
                        ForEach(Array(f.hourly.enumerated()), id: \.offset) { i, h in
                            VStack(spacing: 6) {
                                Text(i == 0 ? "Сейчас" : h.time.formatted(.dateTime.hour(.twoDigits(amPM: .omitted))))
                                    .font(.caption).foregroundStyle(.secondary)
                                Image(systemName: WeatherCode.symbol(h.code)).symbolRenderingMode(.multicolor).font(.title3)
                                Text("\(Int(h.temp.rounded()))°").font(.callout.weight(.medium))
                            }
                        }
                    }
                    .padding(12)
                }
                .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.06)))
                DailyList(daily: f.daily)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 36)
        }
        .pointerScrollable()
    }
}

private struct DailyList: View {
    let daily: [(day: Date, min: Double, max: Double, code: Int)]

    var body: some View {
        let lo = daily.map(\.min).min() ?? 0, hi = daily.map(\.max).max() ?? 1
        VStack(spacing: 10) {
            ForEach(Array(daily.enumerated()), id: \.offset) { i, d in
                HStack(spacing: 10) {
                    Text(i == 0 ? "Сегодня" : d.day.formatted(.dateTime.weekday(.abbreviated)).capitalized)
                        .frame(width: 70, alignment: .leading)
                    Image(systemName: WeatherCode.symbol(d.code)).symbolRenderingMode(.multicolor).frame(width: 28)
                    Text("\(Int(d.min.rounded()))°").foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                    GeometryReader { geo in
                        let w = geo.size.width, span = max(hi - lo, 1)
                        Capsule().fill(.white.opacity(0.1))
                            .overlay(alignment: .leading) {
                                Capsule().fill(LinearGradient(colors: [.cyan, .orange], startPoint: .leading, endPoint: .trailing))
                                    .frame(width: max(6, w * (d.max - d.min) / span))
                                    .offset(x: w * (d.min - lo) / span)
                            }
                    }
                    .frame(height: 5)
                    Text("\(Int(d.max.rounded()))°").frame(width: 34, alignment: .trailing)
                }
                .font(.callout)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.06)))
    }
}

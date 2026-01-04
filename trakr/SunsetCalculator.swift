import Foundation

// swiftlint:disable identifier_name
// Short variable names follow standard NOAA solar position algorithm notation

/// Calculates sunset times using the NOAA solar position algorithm
class SunsetCalculator {

    // MARK: - Constants

    private enum Keys {
        static let latitude = "sunsetLatitude"
        static let longitude = "sunsetLongitude"
    }

    private enum Defaults {
        // San Francisco as default (user should set their own)
        static let latitude = 37.7749
        static let longitude = -122.4194
    }

    // MARK: - Singleton

    static let shared = SunsetCalculator()

    // MARK: - Properties

    var latitude: Double {
        didSet { UserDefaults.standard.set(latitude, forKey: Keys.latitude) }
    }

    var longitude: Double {
        didSet { UserDefaults.standard.set(longitude, forKey: Keys.longitude) }
    }

    var hasLocation: Bool {
        UserDefaults.standard.object(forKey: Keys.latitude) != nil
    }

    // MARK: - Initialization

    private init() {
        let savedLatitude = UserDefaults.standard.object(forKey: Keys.latitude) as? Double
        let savedLongitude = UserDefaults.standard.object(forKey: Keys.longitude) as? Double
        latitude = savedLatitude ?? Defaults.latitude
        longitude = savedLongitude ?? Defaults.longitude
    }

    // MARK: - Public Methods

    /// Returns the sunset time for the given date at the configured location
    func sunsetTime(for date: Date = Date()) -> Date? {
        return calculateSunset(for: date, latitude: latitude, longitude: longitude)
    }

    /// Returns minutes until sunset, or nil if sunset has passed or can't be calculated
    func minutesUntilSunset() -> Int? {
        guard let sunset = sunsetTime() else { return nil }
        let interval = sunset.timeIntervalSince(Date())
        guard interval > 0 else { return nil }
        return Int(interval / 60)
    }

    // MARK: - Solar Position Algorithm (NOAA)

    private func calculateSunset(for date: Date, latitude: Double, longitude: Double) -> Date? {
        let calendar = Calendar.current
        let year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)

        // Julian Day
        let jd = julianDay(year: year, month: month, day: day)

        // Julian Century
        let jc = (jd - 2451545.0) / 36525.0

        // Geometric Mean Longitude of Sun (degrees)
        let l0 = (280.46646 + jc * (36000.76983 + 0.0003032 * jc)).truncatingRemainder(
            dividingBy: 360)

        // Geometric Mean Anomaly of Sun (degrees)
        let m = 357.52911 + jc * (35999.05029 - 0.0001537 * jc)

        // Eccentricity of Earth's Orbit
        let e = 0.016708634 - jc * (0.000042037 + 0.0000001267 * jc)

        // Sun's Equation of Center
        let mRad = m * .pi / 180
        let c =
            sin(mRad) * (1.914602 - jc * (0.004817 + 0.000014 * jc)) + sin(2 * mRad)
            * (0.019993 - 0.000101 * jc) + sin(3 * mRad) * 0.000289

        // Sun's True Longitude
        let sunLong = l0 + c

        // Sun's Apparent Longitude
        let omega = 125.04 - 1934.136 * jc
        let lambda = sunLong - 0.00569 - 0.00478 * sin(omega * .pi / 180)

        // Mean Obliquity of the Ecliptic
        let obliq0 =
            23 + (26 + ((21.448 - jc * (46.8150 + jc * (0.00059 - jc * 0.001813)))) / 60) / 60

        // Corrected Obliquity
        let obliq = obliq0 + 0.00256 * cos(omega * .pi / 180)

        // Sun's Declination
        let declination = asin(sin(obliq * .pi / 180) * sin(lambda * .pi / 180)) * 180 / .pi

        // Equation of Time (minutes)
        let y = tan(obliq * .pi / 360) * tan(obliq * .pi / 360)
        let l0Rad = l0 * .pi / 180
        let eqTime =
            4
            * (y * sin(2 * l0Rad) - 2 * e * sin(mRad) + 4 * e * y * sin(mRad) * cos(2 * l0Rad) - 0.5
                * y * y * sin(4 * l0Rad) - 1.25 * e * e * sin(2 * mRad)) * 180 / .pi

        // Hour Angle at Sunset (degrees)
        // Using -0.833 degrees to account for atmospheric refraction
        let latRad = latitude * .pi / 180
        let decRad = declination * .pi / 180
        let zenith = 90.833 * .pi / 180  // Official sunset includes refraction

        let cosHA = (cos(zenith) / (cos(latRad) * cos(decRad))) - tan(latRad) * tan(decRad)

        // Check if sun never sets or never rises at this latitude
        guard cosHA >= -1 && cosHA <= 1 else { return nil }

        let ha = acos(cosHA) * 180 / .pi

        // Sunset time in minutes from midnight UTC
        let sunsetUTC = 720 - 4 * (longitude + ha) - eqTime

        // Convert to local time
        let timeZoneOffset = Double(TimeZone.current.secondsFromGMT(for: date)) / 60
        let sunsetLocal = sunsetUTC + timeZoneOffset

        // Create date from minutes since midnight
        let hours = Int(sunsetLocal / 60)
        let minutes = Int(sunsetLocal.truncatingRemainder(dividingBy: 60))

        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = hours
        components.minute = minutes
        components.second = 0

        return calendar.date(from: components)
    }

    private func julianDay(year: Int, month: Int, day: Int) -> Double {
        var y = year
        var m = month

        if m <= 2 {
            y -= 1
            m += 12
        }

        let a = Int(Double(y) / 100)
        let b = 2 - a + Int(Double(a) / 4)

        return Double(Int(365.25 * Double(y + 4716))) + Double(Int(30.6001 * Double(m + 1)))
            + Double(day) + Double(b) - 1524.5
    }
}

// swiftlint:enable identifier_name

import Foundation

/// Timestamps exchanged with the server are local time with a UTC offset, e.g. 2026-09-01T08:00:00-06:00.
enum LocalTime {
    static func iso8601(_ date: Date, timeZone: TimeZone = .current) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZoneSeparator: .colon, timeZone: timeZone))
    }

    /// Parses the server's timestamps, which may include microseconds ("…20.878824-06:00").
    static func parse(_ text: String) -> Date? {
        let style = Date.ISO8601FormatStyle(timeZoneSeparator: .colon)
        if let date = try? style.parse(text) {
            return date
        }
        guard let dot = text.firstIndex(of: "."),
              let zone = text[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }),
              let fraction = Double("0" + text[dot..<zone]),
              let whole = try? style.parse(String(text[..<dot] + text[zone...]))
        else { return nil }
        return whole.addingTimeInterval(fraction)
    }

    /// The calendar day containing `date`, as yyyy-MM-dd.
    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

extension JSONEncoder {
    static var api: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(LocalTime.iso8601(date))
        }
        return encoder
    }
}

extension JSONDecoder {
    static var api: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = LocalTime.parse(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognised date \(text)")
            }
            return date
        }
        return decoder
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

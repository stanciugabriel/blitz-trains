import Foundation
import zlib

nonisolated struct SharedJourney: Sendable, Codable, Equatable {
    struct Station: Sendable, Codable, Equatable {
        let id: String
        let name: String
        var latitude: Double? = nil
        var longitude: Double? = nil
    }
    struct Leg: Sendable, Codable, Equatable {
        let origin: Station
        let destination: Station
        let departure: Date
        let arrival: Date
        let service: String
    }
    let legs: [Leg]
}

/// Each submission is an atomic file. The extension never writes the app's trip
/// store, and the app acknowledges a submission only after persisting every leg.
nonisolated struct SharedJourneyInbox {
    static let appGroup = "group.ro.openlabs.blitz"
    let directory: URL

    enum StorageError: LocalizedError {
        case unavailable
        var errorDescription: String? {
            "Shared storage is unavailable. Both app targets need the group.ro.openlabs.blitz App Group enabled."
        }
    }

    init(directory: URL? = nil) throws {
        if let directory {
            self.directory = directory
        } else {
            guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup) else {
                throw StorageError.unavailable
            }
            self.directory = container.appendingPathComponent("PendingJourneys", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    func enqueue(_ journey: SharedJourney) throws {
        let data = try JSONEncoder().encode(journey)
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        try data.write(to: url, options: .atomic)
    }

    func pending() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func read(_ url: URL) throws -> SharedJourney {
        try JSONDecoder().decode(SharedJourney.self, from: Data(contentsOf: url))
    }

    func acknowledge(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

/// Decodes the journey carried by SBB's browser handoff. This is an observed,
/// undocumented format: reject unknown formats instead of importing a partial trip.
nonisolated enum SBBSharedJourneyResolver {
    enum Failure: LocalizedError {
        case unsupported, invalidResponse, invalidJourney
        var errorDescription: String? {
            switch self {
            case .unsupported: return "This is not a supported SBB Mobile link."
            case .invalidResponse: return "SBB did not return a readable shared journey."
            case .invalidJourney: return "This shared journey format could not be read completely."
            }
        }
    }

    static func resolve(_ url: URL) async throws -> SharedJourney {
        guard url.scheme == "https", url.host?.lowercased() == "a.sbbmobile.ch",
              url.pathComponents.count == 3, url.pathComponents[1] == "s" else { throw Failure.unsupported }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              data.count < 2_000_000, let html = String(data: data, encoding: .utf8) else { throw Failure.invalidResponse }
        return try parseLandingPage(html)
    }

    static func parseLandingPage(_ html: String) throws -> SharedJourney {
        let pattern = #"href\s*=\s*["'](https://www\.sbb\.ch/[^"']+)["']"#
        let regex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range(at: 1), in: html),
                  let components = URLComponents(string: String(html[range]).replacingOccurrences(of: "&amp;", with: "&")),
                  let token = components.queryItems?.first(where: { $0.name == "tripId" })?.value else { continue }
            return try decodeToken(token)
        }
        throw Failure.invalidResponse
    }

    static func decodeToken(_ token: String) throws -> SharedJourney {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "3HA" else { throw Failure.invalidJourney }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let compressed = Data(base64Encoded: base64) else { throw Failure.invalidJourney }
        let payload = try inflate(compressed)
        // The first protobuf message's field 2 contains the HAFAS reconstruction.
        let message = try lengthDelimitedField(1, in: payload)
        let reconstruction = try lengthDelimitedField(2, in: message)
        guard let text = String(data: reconstruction, encoding: .utf8), text.hasPrefix("¶HKI¶") else { throw Failure.invalidJourney }
        return try parseReconstruction(text)
    }

    static func parseReconstruction(_ text: String) throws -> SharedJourney {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Europe/Zurich")
        formatter.dateFormat = "yyyyMMddHHmm"
        formatter.isLenient = false
        var legs: [SharedJourney.Leg] = []
        for section in text.components(separatedBy: "§") {
            let segment = section.replacingOccurrences(of: "¶HKI¶", with: "")
            let fields = segment.components(separatedBy: "$")
            guard fields.count >= 6, fields[0] == "T",
                  let departure = formatter.date(from: fields[3]), formatter.string(from: departure) == fields[3],
                  let arrival = formatter.date(from: fields[4]), formatter.string(from: arrival) == fields[4],
                  arrival >= departure else { throw Failure.invalidJourney }
            let leg = SharedJourney.Leg(origin: try station(fields[1]), destination: try station(fields[2]),
                                        departure: departure, arrival: arrival, service: fields[5].trimmingCharacters(in: .whitespaces))
            if let previous = legs.last, previous.arrival > departure { throw Failure.invalidJourney }
            legs.append(leg)
        }
        guard !legs.isEmpty else { throw Failure.invalidJourney }
        return SharedJourney(legs: legs)
    }

    private static func station(_ text: String) throws -> SharedJourney.Station {
        let values = text.split(separator: "@").reduce(into: [String: String]()) { result, item in
            let pair = item.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { result[String(pair[0])] = String(pair[1]) }
        }
        guard let id = values["L"], let name = values["O"], !name.isEmpty else { throw Failure.invalidJourney }
        let latitude = values["Y"].flatMap(Double.init).map { $0 / 1_000_000 }
        let longitude = values["X"].flatMap(Double.init).map { $0 / 1_000_000 }
        let validCoordinates = latitude.map { $0.isFinite && abs($0) <= 90 } == true
            && longitude.map { $0.isFinite && abs($0) <= 180 } == true
        return .init(id: id, name: name,
                     latitude: validCoordinates ? latitude : nil,
                     longitude: validCoordinates ? longitude : nil)
    }

    private static func inflate(_ input: Data) throws -> Data {
        var capacity = 4096
        while capacity <= 4_194_304 {
            var output = [UInt8](repeating: 0, count: capacity)
            var count = uLongf(capacity)
            let status = input.withUnsafeBytes { bytes in
                uncompress(&output, &count, bytes.bindMemory(to: UInt8.self).baseAddress, uLong(input.count))
            }
            if status == Z_OK { return Data(output.prefix(Int(count))) }
            guard status == Z_BUF_ERROR else { throw Failure.invalidJourney }
            capacity *= 2
        }
        throw Failure.invalidJourney
    }

    private static func lengthDelimitedField(_ wanted: UInt64, in data: Data) throws -> Data {
        let bytes = Array(data)
        var index = 0
        func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard index < bytes.count else { throw Failure.invalidJourney }
                let byte = bytes[index]; index += 1
                guard shift < 63 || byte <= 1 else { throw Failure.invalidJourney }
                value |= UInt64(byte & 127) << shift
                if byte < 128 { return value }
            }
            throw Failure.invalidJourney
        }
        while index < bytes.count {
            let tag = try varint()
            switch tag & 7 {
            case 0: _ = try varint()
            case 1: index += 8
            case 5: index += 4
            case 2:
                let length = try varint()
                guard length <= UInt64(bytes.count - index) else { throw Failure.invalidJourney }
                let end = index + Int(length)
                if tag >> 3 == wanted { return Data(bytes[index..<end]) }
                index = end
            default: throw Failure.invalidJourney
            }
        }
        throw Failure.invalidJourney
    }
}

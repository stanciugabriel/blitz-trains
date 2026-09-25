import Foundation
import SwiftUI

enum FormationSettings {
    static let key = "blitz.formation.server"
    static let defaultServer = "192.168.0.14:3001"

    static func endpoint(_ server: String) -> URL? {
        let value = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              var parts = URLComponents(string: value.contains("://") ? value : "http://" + value),
              ["http", "https"].contains(parts.scheme), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil else { return nil }
        if parts.port == nil { parts.port = 3001 }
        parts.path = "/formation"
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }

    static func request(server: String, agency: String, number: String, date: Date?, now: Date = Date()) throws -> URL {
        guard !agency.isEmpty, !number.isEmpty, number.allSatisfy({ $0.isASCII && $0.isNumber }),
              let endpoint = endpoint(server) else { throw FormationFailure.invalidRequest }
        let calendar = GTFSDataSource.calendar
        let day = calendar.startOfDay(for: date ?? now)
        let today = calendar.startOfDay(for: now)
        guard day <= calendar.date(byAdding: .day, value: 3, to: today)! else { throw FormationFailure.tooEarly }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "evu", value: agency),
                            URLQueryItem(name: "date", value: formatter.string(from: day)),
                            URLQueryItem(name: "trainNumber", value: number)]
        return parts.url!
    }
}

enum FormationFailure: LocalizedError {
    case invalidRequest, tooEarly, invalidResponse, noBoardingFormation, server(String)
    var errorDescription: String? {
        switch self {
        case .invalidRequest: "The formation server address, operator, or train number is missing or invalid."
        case .tooEarly: "Formation becomes available up to three days before travel."
        case .invalidResponse: "The formation server returned an unreadable response."
        case .noBoardingFormation: "Formation is not available for your boarding station."
        case .server(let message): message
        }
    }
}

/// Requests for the same URL are coalesced while in flight.
@MainActor
final class FormationService {
    static let shared = FormationService()
    struct Result {
        let response: FormationResponse
        let fetchedAt: Date
        let isStale: Bool
    }
    private var pending: [URL: Task<Result, Error>] = [:]

    init() {}

    func load(url: URL) async throws -> Result {
        if let task = pending[url] { return try await task.value }
        let task = Task<Result, Error> {
            do {
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
                request.timeoutInterval = 15
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw FormationFailure.invalidResponse
                }
                let decoded = try JSONDecoder().decode(FormationResponse.self, from: data)
                if let error = decoded.error { throw FormationFailure.server(error) }
                return Result(response: decoded, fetchedAt: Date(), isStale: false)
            } catch {
                throw error
            }
        }
        pending[url] = task
        defer { pending[url] = nil }
        return try await task.value
    }
}

nonisolated struct FormationResponse: Codable, Sendable {
    let formations: [Consist]?
    let formationsAtScheduledStops: [ScheduledFormation]?
    let error: String?
    struct Station: Codable, Sendable { let name: String; let uic: Int }
    struct Stop: Codable, Sendable {
        let stopPoint: Station
        let sectors: String?
        let track: String?
    }
    struct FormationShort: Codable, Sendable { let formationShortString: String? }
    struct ScheduledFormation: Codable, Sendable {
        let scheduledStop: Stop
        let formationShort: FormationShort?
    }
    struct Consist: Codable, Sendable { let formationVehicles: [Vehicle] }
    struct Identifier: Codable, Sendable { let evn: String?; let typeCodeName: String? }
    struct Accessibility: Codable, Sendable {
        let numberWheelchairSpaces: Int?
        let wheelchairToilet: Bool?
    }
    struct Pictograms: Codable, Sendable {
        let bikePicto: Bool?
        let wheelchairPicto: Bool?
        let familyZonePicto: Bool?
        let businessZonePicto: Bool?
        let strollerPicto: Bool?
    }
    struct Properties: Codable, Sendable {
        let fromStop: Station?
        let toStop: Station?
        let length: Double?
        let climated: Bool?
        let closed: Bool?
        let number1class: Int?
        let number2class: Int?
        let numberRestaurantSpace: Int?
        let numberBikeHooks: Int?
        let bikePlatform: Bool?
        let lowFloorTrolley: Bool?
        let accessibilityProperties: Accessibility?
        let pictoProperties: Pictograms?
    }
    struct Vehicle: Codable, Sendable {
        let number: Int?
        let position: Int
        let vehicleIdentifier: Identifier?
        let vehicleProperties: Properties?
        let formationVehicleAtScheduledStops: [Stop]?
    }

    @MainActor func formation(boardingUIC: String?, boardingName: String?, operatorName: String) throws -> PlatformFormation? {
        guard let formations, !formations.isEmpty else { return nil }
        let stops = formationsAtScheduledStops?.map(\.scheduledStop.stopPoint) ?? []
        func matches(_ station: Station) -> Bool {
            let normalizedUIC = boardingUIC?.filter(\.isNumber)
            let uicMatches = normalizedUIC.map { String(station.uic) == $0 } ?? false
            let nameMatches = boardingName.map {
                station.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    == $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            } ?? false
            return uicMatches || nameMatches
        }
        let boarding = stops.firstIndex(where: matches)
        // Ranges are departure-inclusive and arrival-exclusive at reversals.
        let consist = formations.first { consist in
            guard let properties = consist.formationVehicles.first?.vehicleProperties,
                  let from = stops.firstIndex(where: { $0.uic == properties.fromStop?.uic }),
                  let to = stops.firstIndex(where: { $0.uic == properties.toStop?.uic }) else { return false }
            guard let boarding else { return false }
            return boarding >= from && boarding < to
        } ?? formations.first
        guard let consist else { return nil }
        let shortString = formationsAtScheduledStops?.first(where: { matches($0.scheduledStop.stopPoint) })?.formationShort?.formationShortString
        let shortAttributes = parseShortAttributes(shortString)
        var sectors: [Int: [FormationSectorSlice]] = [:]
        var track: String?
        let vehicles = consist.formationVehicles.sorted { $0.position < $1.position }.map { vehicle in
            let properties = vehicle.vehicleProperties
            let stop = vehicle.formationVehicleAtScheduledStops?.first { matches($0.stopPoint) }
            if track == nil { track = stop?.track }
            let labels = (stop?.sectors ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !labels.isEmpty {
                sectors[vehicle.position] = labels.map { FormationSectorSlice(label: $0, fraction: 1 / CGFloat(labels.count)) }
            }
            let typeName = vehicle.vehicleIdentifier?.typeCodeName ?? "Vehicle"
            var classes: [String] = []
            if (properties?.number1class ?? 0) > 0 { classes.append("1") }
            if (properties?.number2class ?? 0) > 0 { classes.append("2") }
            var features: [FormationFeature] = []
            if properties?.climated == true { features.append(.airConditioning) }
            if (properties?.numberRestaurantSpace ?? 0) > 0 { features.append(.restaurant) }
            if properties?.bikePlatform == true || (properties?.numberBikeHooks ?? 0) > 0 || properties?.pictoProperties?.bikePicto == true { features.append(.bicycle) }
            if (properties?.accessibilityProperties?.numberWheelchairSpaces ?? 0) > 0 || properties?.pictoProperties?.wheelchairPicto == true { features.append(.accessible) }
            if properties?.closed == true { features.append(.closed) }
            if properties?.lowFloorTrolley == true { features.append(.lowFloor) }
            if properties?.accessibilityProperties?.wheelchairToilet == true { features.append(.toilet) }
            if properties?.pictoProperties?.familyZonePicto == true { features.append(.family) }
            if properties?.pictoProperties?.businessZonePicto == true { features.append(.business) }
            if properties?.pictoProperties?.strollerPicto == true { features.append(.stroller) }
            // Type-code conventions fill in pictograms when the provider does
            // not populate the corresponding numeric/picto properties.
            if typeName.hasPrefix("A"), !classes.contains("1") { classes.append("1") }
            if typeName.hasPrefix("B"), !classes.contains("2") { classes.append("2") }
            if typeName.hasPrefix("AB") {
                if !classes.contains("1") { classes.append("1") }
                if !classes.contains("2") { classes.append("2") }
            }
            func addFeature(_ feature: FormationFeature) {
                if !features.contains(where: { $0.rawValue == feature.rawValue }) { features.append(feature) }
            }
            if typeName.hasPrefix("D") { addFeature(.baggage) }
            if typeName.hasPrefix("WR") || (typeName.hasPrefix("R") && !typeName.hasPrefix("Re")) { addFeature(.restaurant) }
            if typeName.localizedCaseInsensitiveContains("Fam") { addFeature(.family) }
            if let parsed = shortAttributes[vehicle.number ?? -1] ?? shortAttributes[-vehicle.position] {
                for value in parsed.classes where !classes.contains(value) { classes.append(value) }
                for feature in parsed.features { addFeature(feature) }
            }
            // Swiss type codes use a lower-case `t` for a driving/control cab
            // (for example Bt4-K, Bt(2E)Fam, and At). A `t` inside a parenthesized
            // suffix is part of that suffix and does not identify the cab.
            var parenthesisDepth = 0
            let hasControlCab = typeName.contains { character in
                if character == "(" { parenthesisDepth += 1; return false }
                if character == ")" { parenthesisDepth = max(0, parenthesisDepth - 1); return false }
                return character == "t" && parenthesisDepth == 0
            }
            // The API uses number 0 both for true locomotives and for
            // unnumbered passenger/control cars. The type code is therefore
            // the authoritative locomotive marker; `t` only marks a cab.
            let evnParts = vehicle.vehicleIdentifier?.evn?.split(separator: " ").map(String.init) ?? []
            let isRe460 = typeName == "Re460" || evnParts.contains("460")
            let isLocomotiveType = isRe460 || typeName.hasPrefix("Re") || typeName == "LK"
            let position: String
            if isLocomotiveType {
                position = "Loco"
            } else if let number = vehicle.number, number > 0 {
                position = "Car \(number)"
            } else {
                position = "Car \(vehicle.position)"
            }
            // In SBB EVNs the first digit of the vehicle series alternates the
            // cab orientation (150x/350x face right, 250x/450x face left).
            // Fall back to the consist's physical order when no EVN is given.
            let facesRight: Bool = {
                guard let evn = vehicle.vehicleIdentifier?.evn else { return vehicle.position % 2 == 0 }
                let parts = evn.split(separator: " ")
                guard parts.count > 2, let first = parts[2].first, let digit = first.wholeNumberValue else {
                    return vehicle.position % 2 == 0
                }
                return digit % 2 == 1
            }()
            return FormationVehicle(id: vehicle.position, position: position,
                classes: classes, type: typeName,
                evn: vehicle.vehicleIdentifier?.evn, isCab: hasControlCab || isLocomotiveType,
                artworkName: isRe460 ? "re460" : nil,
                mirrorsArtwork: !isRe460,
                facesRight: facesRight, isLocked: properties?.closed == true,
                features: features,
                firstClassSeats: properties?.number1class,
                secondClassSeats: properties?.number2class,
                bikeSeats: properties?.numberBikeHooks,
                wheelchairSeats: properties?.accessibilityProperties?.numberWheelchairSpaces,
                operatorName: "SBB")
        }
        return PlatformFormation(vehicles: vehicles, track: track, sectors: sectors.isEmpty ? nil : sectors)
    }

    /// The short formation string is the provider's authoritative pictogram
    /// and class source. Vehicle properties describe capacity, while tokens
    /// such as `2:17#VR;KW;FZ` describe what passengers see at this stop.
    private func parseShortAttributes(_ value: String?) -> [Int: (classes: [String], features: [FormationFeature])] {
        guard let value else { return [:] }
        var result: [Int: (classes: [String], features: [FormationFeature])] = [:]
        var implicitPosition = 1
        for raw in value.split(whereSeparator: { ",()[]\\@".contains($0) }) {
            let token = String(raw)
            let prefix: String
            let suffix: Substring
            let number: Int
            if let colon = token.lastIndex(of: ":") {
                prefix = token[..<colon].split(separator: "@").last.map(String.init) ?? ""
                suffix = token[token.index(after: colon)...]
                let numberText = suffix.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
                guard let explicitNumber = Int(numberText) else { continue }
                number = explicitNumber
            } else if token.contains("#") {
                // Some formations use positional tokens such as 2#NF rather
                // than attaching the vehicle number to every token.
                let hash = token.firstIndex(of: "#")!
                prefix = String(token[..<hash])
                suffix = token[hash...]
                // Negative keys represent positional tokens and cannot collide
                // with real vehicle numbers.
                number = -implicitPosition
                implicitPosition += 1
            } else {
                continue
            }
            let codes: [String] = suffix.firstIndex(of: "#").map { hash in
                suffix[suffix.index(after: hash)...]
                    .split(separator: ";")
                    .map(String.init)
            } ?? []
            var classes: [String] = []
            var features: [FormationFeature] = []
            func add(_ feature: FormationFeature) {
                if !features.contains(where: { $0.rawValue == feature.rawValue }) { features.append(feature) }
            }
            let normalizedPrefix = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "%"))
            if normalizedPrefix.contains("1") { classes.append("1") }
            if normalizedPrefix.contains("2") { classes.append("2") }
            if normalizedPrefix.hasPrefix("W") || normalizedPrefix == "R" { add(.restaurant) }
            if normalizedPrefix == "D" { add(.baggage) }
            for code in codes {
                switch code {
                case "VH": add(.bicycle)
                case "VR": add(.reservedBicycle)
                case "BHP": add(.accessible)
                case "BZ": add(.business)
                case "FZ": add(.family)
                case "KW": add(.stroller)
                case "NF": add(.lowFloor)
                case "LA": add(.luggage)
                case "WL": add(.sleeping)
                case "CC": add(.couchette)
                default: break
                }
            }
            result[number] = (classes, features)
        }
        return result
    }
}

struct TripFormationSection: View {
    let trip: Trip
    @AppStorage(FormationSettings.key) private var server = FormationSettings.defaultServer
    @State private var formation: PlatformFormation?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let formation {
                TrainFormationPreview(formation: formation, isSample: false)
            }
        }
        .task(id: "\(trip.id)|\(trip.travelDate?.timeIntervalSince1970 ?? 0)|\(server)") {
            formation = nil
            do {
                // A full numeric final token, never digits stripped from IC12.
                let sourceText = [trip.trainIdentifier, trip.sharedJourneyLeg?.service, trip.title]
                    .compactMap { $0 }.joined(separator: " ")
                let number = sourceText.split(whereSeparator: { !$0.isASCII || !$0.isNumber })
                    .map(String.init).reversed()
                    .first(where: { !$0.isEmpty })
                // Imported/shared journeys may not carry the GTFS agency row;
                // SBB formations use EVU 11.
                let agency = trip.agencyId ?? "11"
                guard let number else { throw FormationFailure.invalidRequest }
                let url = try FormationSettings.request(server: server, agency: agency, number: number, date: trip.travelDate)
                let result = try await FormationService.shared.load(url: url)
                try Task.checkCancellation()
                let uic = trip.sharedJourneyLeg?.origin.id ?? GTFSDataSource.shared.stationUIC(for: trip.originStopId)
                formation = try result.response.formation(boardingUIC: uic, boardingName: trip.originName,
                    operatorName: GTFSDataSource.shared.agencyInfo(for: agency)?.name ?? agency)
            } catch is CancellationError { return }
            catch { formation = nil }
        }
    }
}

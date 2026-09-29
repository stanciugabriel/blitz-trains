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
        let lastVehiclePosition = consist.formationVehicles.map(\.position).max()
        let unitVehicles = consist.formationVehicles.map { (position: $0.position, evn: $0.vehicleIdentifier?.evn) }
        let orderedVehicles = consist.formationVehicles.sorted { $0.position < $1.position }
        let artworks = orderedVehicles.map { vehicle in
            FormationArtworkCatalog.select(
                evn: vehicle.vehicleIdentifier?.evn,
                typeCodeName: vehicle.vehicleIdentifier?.typeCodeName,
                hasAsset: { _ in false }
            )
        }
        let vehicles = orderedVehicles.enumerated().map { index, vehicle in
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
            let artwork = artworks[index]
            let position: String
            if artwork.isLocomotive {
                position = "Loco"
            } else if let number = vehicle.number, number > 0 {
                position = "Car \(number)"
            } else {
                position = "Car \(vehicle.position)"
            }
            // End cabs face outward; interior adjacent cabs meet nose to nose.
            // Other EMU cabs face out of their unit.
            let facesRight: Bool = {
                if let layoutDirection = FormationArtworkCatalog.controlCabFacesRight(
                    at: index, among: artworks
                ) {
                    return layoutDirection
                }
                if artwork.isCab && !artwork.isLocomotive,
                   let unitDirection = FormationArtworkCatalog.unitCabFacesRight(
                       evn: vehicle.vehicleIdentifier?.evn,
                       position: vehicle.position,
                       among: unitVehicles
                   ) {
                    return unitDirection
                }
                let parts = vehicle.vehicleIdentifier?.evn?.split(whereSeparator: \.isWhitespace) ?? []
                if parts.count > 2, parts[2].count == 4,
                   let first = parts[2].first?.wholeNumberValue, (1...4).contains(first) {
                    return first % 2 == 1
                }
                return artwork.isCab && vehicle.position == lastVehiclePosition
            }()
            return FormationVehicle(id: vehicle.position, position: position,
                classes: classes, type: FormationArtworkCatalog.displayType(
                    evn: vehicle.vehicleIdentifier?.evn, typeCodeName: vehicle.vehicleIdentifier?.typeCodeName),
                evn: vehicle.vehicleIdentifier?.evn, isCab: artwork.isCab,
                isLocomotive: artwork.isLocomotive,
                facesRight: facesRight, isLocked: properties?.closed == true,
                features: features,
                firstClassSeats: properties?.number1class,
                secondClassSeats: properties?.number2class,
                bikeSeats: properties?.numberBikeHooks,
                wheelchairSeats: properties?.accessibilityProperties?.numberWheelchairSpaces,
                operatorName: operatorName)
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

enum FormationArtworkCatalog {
    struct Selection {
        let name: String
        let rightName: String?
        let isLocomotive: Bool
        let isCab: Bool
        let mirrorsArtwork: Bool

        init(name: String, rightName: String? = nil, isLocomotive: Bool, isCab: Bool, mirrorsArtwork: Bool) {
            self.name = name
            self.rightName = rightName
            self.isLocomotive = isLocomotive
            self.isCab = isCab
            self.mirrorsArtwork = mirrorsArtwork
        }

        func assetName(facesRight: Bool) -> String {
            facesRight ? rightName ?? name : name
        }
    }

    private static let electricLocomotives: Set<String> = [
        "610", "193", "420", "421", "430", "450", "460", "474", "482", "484", "494",
        "620", "465", "475", "485", "486", "187"
    ]
    private static let emus: Set<String> = [
        "550", "500", "510", "514", "501", "502", "503", "511", "512", "520", "521",
        "522", "523", "524", "526", "528", "531", "532", "533", "591", "560", "561", "562", "540"
    ]
    private static let flirtModels: Set<String> = ["521", "522", "523", "524", "526", "528"]
    private static let singleDeckCars: Set<String> = [
        "10-75", "10-90", "10-95", "19-90", "20-43", "20-90", "20-95", "21-73",
        "21-75", "21-95", "29-43", "50-91", "59-00", "81-95", "82-90", "88-94",
        "89-70", "93-61"
    ]
    private static let singleDeckControlCars: Set<String> = ["28-94", "80-33", "82-33"]
    private static let doubleDeckCars: Set<String> = ["16-94", "26-33", "26-73", "26-94", "36-33", "66-94", "86-94"]
    private static let doubleDeckControlCars: Set<String> = ["39-43", "86-33"]

    static func displayType(evn: String?, typeCodeName: String?) -> String {
        if let model = modelCode(from: evn), flirtModels.contains(model) {
            return "RABe \(model)"
        }
        guard let typeCodeName, !typeCodeName.isEmpty else { return "Vehicle" }
        var label = ""
        var parenthesisDepth = 0
        for character in typeCodeName {
            if character == "(" {
                parenthesisDepth += 1
            } else if character == ")" {
                parenthesisDepth = max(0, parenthesisDepth - 1)
            } else if parenthesisDepth == 0 {
                label.append(character)
            }
        }
        return label.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func modelCode(from evn: String?) -> String? {
        guard let evn else { return nil }
        let parts = evn.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count > 2 else { return nil }
        let field = parts[2].count == 1 && parts[2].allSatisfy(\.isNumber) && parts.count > 3
            ? parts[3] : parts[2]
        if field.count == 4, field.allSatisfy(\.isNumber) {
            let series = String(field.suffix(3))
            if electricLocomotives.contains(series) || emus.contains(series) { return series }
        }
        return field
    }

    private static func emuUnitKey(from evn: String?) -> String? {
        guard let evn,
              let model = modelCode(from: evn), emus.contains(model) else { return nil }
        let parts = evn.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 4,
              let serial = parts.last?.split(separator: "-").first,
              serial.allSatisfy(\.isNumber) else { return nil }
        return "\(parts[0])-\(parts[1])-\(model)-\(serial)"
    }

    static func unitCabFacesRight(
        evn: String?, position: Int,
        among vehicles: [(position: Int, evn: String?)]
    ) -> Bool? {
        guard let key = emuUnitKey(from: evn) else { return nil }
        let positions = vehicles.compactMap { emuUnitKey(from: $0.evn) == key ? $0.position : nil }
        guard positions.count > 1, let last = positions.max() else { return nil }
        return position == last
    }

    static func controlCabFacesRight(at index: Int, among artworks: [Selection]) -> Bool? {
        guard artworks.indices.contains(index), artworks[index].isCab,
              !artworks[index].isLocomotive else { return nil }
        if index == artworks.startIndex { return false }
        if index == artworks.index(before: artworks.endIndex) { return true }
        func isControlCab(_ neighbor: Int) -> Bool {
            artworks.indices.contains(neighbor) && artworks[neighbor].isCab
                && !artworks[neighbor].isLocomotive
        }
        if isControlCab(index + 1) { return true }
        if isControlCab(index - 1) { return false }
        return nil
    }

    static func select(evn: String?, typeCodeName: String?, hasAsset: (String) -> Bool) -> Selection {
        let model = modelCode(from: evn)
        let type = typeCodeName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isLocomotive = model.map(electricLocomotives.contains) == true
            || type.hasPrefix("Re") || type == "LK"

        let isEMU = model.map(emus.contains) == true
        let isDoubleDeck: Bool = {
            if let model {
                if doubleDeckCars.contains(model) || doubleDeckControlCars.contains(model) { return true }
                if singleDeckCars.contains(model) || singleDeckControlCars.contains(model) || emus.contains(model) { return false }
            }
            let upperType = type.uppercased()
            return upperType.contains("DOSTO") || upperType.contains("IC2000") || upperType.hasPrefix("DD")
        }()
        let hasControlCab: Bool = {
            guard !type.isEmpty else {
                return model.map { singleDeckControlCars.contains($0) || doubleDeckControlCars.contains($0) } == true
            }
            // Lowercase t marks a control cab, except within parenthesized suffixes.
            var depth = 0
            for character in type {
                if character == "(" { depth += 1 }
                else if character == ")" { depth = max(0, depth - 1) }
                else if character == "t" && depth == 0 { return true }
            }
            return false
        }()

        // Specific artwork takes priority. A left/right pair picks the matching
        // image; an -f image faces left by default and may be mirrored. An
        // unsuffixed image is used as supplied in either position.
        if let model {
            let left = "\(model)-left"
            let right = "\(model)-right"
            if hasAsset(left) && hasAsset(right) {
                return Selection(name: left, rightName: right, isLocomotive: isLocomotive,
                                 isCab: isLocomotive || hasControlCab, mirrorsArtwork: false)
            }
            let flippable = "\(model)-f"
            if hasAsset(flippable) {
                return Selection(name: flippable, isLocomotive: isLocomotive,
                                 isCab: isLocomotive || hasControlCab, mirrorsArtwork: true)
            }
            if hasAsset(model) {
                return Selection(name: model, isLocomotive: isLocomotive,
                                 isCab: isLocomotive || hasControlCab, mirrorsArtwork: false)
            }
        }

        if let model, flirtModels.contains(model),
           hasAsset("flirt-c-f"), hasAsset("flirt-cc-f") {
            return Selection(name: hasControlCab ? "flirt-cc-f" : "flirt-c-f",
                             isLocomotive: false, isCab: hasControlCab, mirrorsArtwork: true)
        }

        // The existing Re460 artwork is unsuffixed and keeps its lettering.
        if model == "460" || type == "Re460" {
            return Selection(name: "re460", isLocomotive: true, isCab: true, mirrorsArtwork: false)
        }
        if isLocomotive {
            return Selection(name: "el-default", isLocomotive: true, isCab: true, mirrorsArtwork: true)
        }

        let name: String
        if isDoubleDeck {
            name = hasControlCab ? "ddcc-default" : "dd-default"
        } else if isEMU && hasControlCab && hasAsset("emuc-default") {
            name = "emuc-default"
        } else {
            name = hasControlCab ? "cc-default" : "c-default"
        }
        return Selection(name: name, isLocomotive: false, isCab: hasControlCab, mirrorsArtwork: true)
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
                guard let agency = trip.agencyId, !agency.isEmpty, let number else {
                    throw FormationFailure.invalidRequest
                }
                let url = try FormationSettings.request(server: server, agency: agency, number: number, date: trip.travelDate)
                let result = try await FormationService.shared.load(url: url)
                try Task.checkCancellation()
                let uic = trip.sharedJourneyLeg?.origin.id ?? GTFSDataSource.shared.stationUIC(for: trip.originStopId)
                formation = try result.response.formation(boardingUIC: uic, boardingName: trip.originName,
                    operatorName: agency == "11" ? "SBB" : (GTFSDataSource.shared.agencyInfo(for: agency)?.name ?? agency))
            } catch is CancellationError { return }
            catch { formation = nil }
        }
    }
}

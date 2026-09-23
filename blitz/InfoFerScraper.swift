import Foundation
internal import UIKit
#if canImport(Vision)
internal import Vision
#endif

// MARK: - Models

struct StationDelay: Equatable, Codable {
    let stationName: String
    let arrivalDelayMinutes: Int?
    let departureDelayMinutes: Int?
    let platform: String?
}

struct InfoFerLiveCoordinate: Equatable, Codable {
    let latitude: Double
    let longitude: Double
    let sourceText: String?
    let fetchedAt: Date?

    init(
        latitude: Double,
        longitude: Double,
        sourceText: String?,
        fetchedAt: Date? = Date()
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.sourceText = sourceText
        self.fetchedAt = fetchedAt
    }

    private enum CodingKeys: String, CodingKey {
        case latitude
        case longitude
        case sourceText
        case fetchedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        latitude = try container.decode(Double.self, forKey: .latitude)
        longitude = try container.decode(Double.self, forKey: .longitude)
        sourceText = try container.decodeIfPresent(String.self, forKey: .sourceText)
        fetchedAt = try container.decodeIfPresent(Date.self, forKey: .fetchedAt)
    }
}

struct InfoFerMapInfo: Equatable {
    let routePolylines: [StoredRoutePolyline]
    let liveCoordinate: InfoFerLiveCoordinate?
    let gpsPermanentlyUnavailable: Bool
}

struct DelayInfo: Equatable, Codable {
    let delayMinutes: Int?
    let platform: String?
    let statusText: String?
    let stationDelays: [StationDelay]
    let liveCoordinate: InfoFerLiveCoordinate?
    let fetchedAt: Date?

    init(
        delayMinutes: Int?,
        platform: String?,
        statusText: String? = nil,
        stationDelays: [StationDelay] = [],
        liveCoordinate: InfoFerLiveCoordinate? = nil,
        fetchedAt: Date? = Date()
    ) {
        self.delayMinutes = delayMinutes
        self.platform = platform
        self.statusText = statusText
        self.stationDelays = stationDelays
        self.liveCoordinate = liveCoordinate
        self.fetchedAt = fetchedAt
    }

    func updatingLiveCoordinate(_ coordinate: InfoFerLiveCoordinate?) -> DelayInfo {
        DelayInfo(
            delayMinutes: delayMinutes,
            platform: platform,
            statusText: statusText,
            stationDelays: stationDelays,
            liveCoordinate: coordinate,
            fetchedAt: fetchedAt
        )
    }
}

extension DelayInfo {
    var freshnessText: String? {
        guard let fetchedAt else { return nil }
        let seconds = max(0, Int(Date().timeIntervalSince(fetchedAt)))
        if seconds < 60 { return "Synced just now" }
        if seconds < 3600 { return "Synced \(max(1, seconds / 60))m ago" }
        return "Synced \(seconds / 3600)h ago"
    }
}

struct CFRWebcamBoardCell: Equatable, Codable {
    let index: Int
    let bounds: CGRect
    let text: String
    let confidence: Float
}

struct CFRWebcamBoardRow: Equatable, Codable {
    let index: Int
    let bounds: CGRect
    let text: String
    let columns: [CFRWebcamBoardCell]
}

struct CFRWebcamBoardScan: Equatable, Codable {
    let station: String
    let sourceURL: URL
    let fetchedAt: Date
    let imageSize: CGSize
    let entries: [CFRWebcamBoardTriplet]
}

struct CFRWebcamBoardSnapshot {
    let scan: CFRWebcamBoardScan
    let image: UIImage
}

struct CFRWebcamBoardTrackingState: Codable, Equatable {
    var lastSeenSideRaw: String?
    var lastSeenRowIndex: Int?
    var lastSeenTrainNumber: String?
    var lastImageFetchedAt: Date?
    var pendingPlatform: String?
    var pendingPlatformCount: Int = 0
    var confirmedPlatform: String?
    var confirmedSideRaw: String?
    var confirmedRowIndex: Int?
    var lastUpdatedAt: Date?

    var lastSeenSide: CFRWebcamBoardSide? {
        get { CFRWebcamBoardSide(rawValue: lastSeenSideRaw ?? "") }
        set { lastSeenSideRaw = newValue?.rawValue }
    }

    var confirmedSide: CFRWebcamBoardSide? {
        get { CFRWebcamBoardSide(rawValue: confirmedSideRaw ?? "") }
        set { confirmedSideRaw = newValue?.rawValue }
    }
}

struct CFRWebcamBoardObservation {
    let image: UIImage
    let statusText: String
    let platformText: String?
    let updatedTrip: Trip?
    let state: CFRWebcamBoardTrackingState
}

final class CFRWebcamBoardStateStore {
    static let shared = CFRWebcamBoardStateStore()

    private let defaultsKey = "cfr_webcam_board_state_store"
    private var cache: [String: CFRWebcamBoardTrackingState]

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([String: CFRWebcamBoardTrackingState].self, from: data) {
            cache = decoded
        } else {
            cache = [:]
        }
    }

    func state(for key: String) -> CFRWebcamBoardTrackingState {
        cache[key] ?? CFRWebcamBoardTrackingState()
    }

    func save(_ state: CFRWebcamBoardTrackingState, for key: String) {
        cache[key] = state
        persist()
    }

    func clear(for key: String) {
        cache.removeValue(forKey: key)
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

enum CFRWebcamBoardSide: String, Codable {
    case arrivals
    case departures
}

struct CFRWebcamBoardTripletLayout: Equatable, Codable {
    let side: CFRWebcamBoardSide
    let rowIndex: Int
    let trainNumberRect: CGRect
    let delayRect: CGRect
    let platformRect: CGRect
}

struct CFRWebcamBoardTriplet: Equatable, Codable {
    let side: CFRWebcamBoardSide
    let rowIndex: Int
    let trainNumber: String
    let delay: String
    let platformNumber: String
    let trainNumberBounds: CGRect
    let delayBounds: CGRect
    let platformBounds: CGRect
}

enum CFRWebcamBoardLayout {
    static let imageSize = CGSize(width: 1100, height: 350)

    // Edit these rectangles directly in pixels. The webcam image is always 1100x350.
    // Left half = arrivals, right half = departures.
    static var manualTripletLayouts: [CFRWebcamBoardTripletLayout] = [
        // Arrivals
        .init(side: .arrivals, rowIndex: 0, trainNumberRect: .init(x: 57, y: 86, width: 52, height: 20), delayRect: .init(x: 443, y: 87, width: 33, height: 17), platformRect: .init(x: 478, y: 87, width: 23, height: 16)),
        .init(side: .arrivals, rowIndex: 1, trainNumberRect: .init(x: 57, y: 103, width: 52, height: 20), delayRect: .init(x: 443, y: 104, width: 33, height: 17), platformRect: .init(x: 478, y: 104, width: 23, height: 16)),
        .init(side: .arrivals, rowIndex: 2, trainNumberRect: .init(x: 57, y: 120, width: 52, height: 20), delayRect: .init(x: 443, y: 121, width: 33, height: 17), platformRect: .init(x: 478, y: 121, width: 23, height: 16)),
        .init(side: .arrivals, rowIndex: 3, trainNumberRect: .init(x: 58, y: 150, width: 52, height: 20), delayRect: .init(x: 443, y: 150, width: 33, height: 17), platformRect: .init(x: 478, y: 150, width: 23, height: 16)),
        .init(side: .arrivals, rowIndex: 4, trainNumberRect: .init(x: 58, y: 167, width: 52, height: 20), delayRect: .init(x: 443, y: 167, width: 33, height: 17), platformRect: .init(x: 478, y: 167, width: 23, height: 16)),
        .init(side: .arrivals, rowIndex: 5, trainNumberRect: .init(x: 58, y: 184, width: 52, height: 20), delayRect: .init(x: 443, y: 184, width: 33, height: 17), platformRect: .init(x: 478, y: 184, width: 23, height: 16)),
        .init(side: .arrivals, rowIndex: 6, trainNumberRect: .init(x: 60, y: 213, width: 52, height: 20), delayRect: .init(x: 443, y: 213, width: 33, height: 17), platformRect: .init(x: 478, y: 213, width: 23, height: 16)),
        .init(side: .arrivals, rowIndex: 7, trainNumberRect: .init(x: 60,  y: 230, width: 52, height: 20), delayRect: .init(x: 443, y: 230, width: 33, height: 17), platformRect: .init(x: 478, y: 230, width: 23, height: 16)),
        .init(side: .arrivals, rowIndex: 8, trainNumberRect: .init(x: 60, y: 247, width: 52, height: 20), delayRect: .init(x: 443, y: 247, width: 33, height: 17), platformRect: .init(x: 478, y: 247, width: 23, height: 16)),
        .init(side: .arrivals, rowIndex: 9, trainNumberRect: .init(x: 60, y: 276, width: 52, height: 20), delayRect: .init(x: 443, y: 275, width: 33, height: 17), platformRect: .init(x: 478, y: 275, width: 23, height: 16)),
        .init(side: .arrivals, rowIndex: 10, trainNumberRect: .init(x: 60, y: 293, width: 52, height: 20), delayRect: .init(x: 443, y: 292, width: 33, height: 17), platformRect: .init(x: 478, y: 292, width: 23, height: 16)),
        .init(side: .arrivals, rowIndex: 11, trainNumberRect: .init(x: 60, y: 310, width: 52, height: 20), delayRect: .init(x: 443, y: 309, width: 33, height: 17), platformRect: .init(x: 478, y: 309, width: 23, height: 16)),
        // Departures
        .init(side: .departures, rowIndex: 0, trainNumberRect: .init(x: 643, y: 84, width: 52, height: 20), delayRect: .init(x: 1019, y: 83, width: 33, height: 17), platformRect: .init(x: 1057, y: 83, width: 22, height: 16)),
        .init(side: .departures, rowIndex: 1, trainNumberRect: .init(x: 643, y: 101, width: 52, height: 20), delayRect: .init(x: 1019, y: 100, width: 33, height: 17), platformRect: .init(x: 1057, y: 100, width: 22, height: 16)),
        .init(side: .departures, rowIndex: 2, trainNumberRect: .init(x: 643, y: 118, width: 52, height: 20), delayRect: .init(x: 1019, y: 117, width: 33, height: 17), platformRect: .init(x: 1057, y: 117, width: 22, height: 16)),
        .init(side: .departures, rowIndex: 3, trainNumberRect: .init(x: 643, y: 148, width: 52, height: 20), delayRect: .init(x: 1019, y: 146, width: 33, height: 17), platformRect: .init(x: 1055, y: 146, width: 22, height: 16)),
        .init(side: .departures, rowIndex: 4, trainNumberRect: .init(x: 643, y: 165, width: 52, height: 20), delayRect: .init(x: 1019, y: 163, width: 33, height: 17), platformRect: .init(x: 1055, y: 163, width: 22, height: 16)),
        .init(side: .departures, rowIndex: 5, trainNumberRect: .init(x: 643, y: 182, width: 52, height: 20), delayRect: .init(x: 1019, y: 180, width: 33, height: 17), platformRect: .init(x: 1055, y: 180, width: 22, height: 16)),
        .init(side: .departures, rowIndex: 6, trainNumberRect: .init(x: 643, y: 210, width: 52, height: 20), delayRect: .init(x: 1019, y: 209, width: 33, height: 17), platformRect: .init(x: 1054, y: 209, width: 22, height: 16)),
        .init(side: .departures, rowIndex: 7, trainNumberRect: .init(x: 643, y: 227, width: 52, height: 20), delayRect: .init(x: 1019, y: 226, width: 33, height: 17), platformRect: .init(x: 1054, y: 226, width: 22, height: 16)),
        .init(side: .departures, rowIndex: 8, trainNumberRect: .init(x: 643, y: 244, width: 52, height: 20), delayRect: .init(x: 1019, y: 243, width: 33, height: 17), platformRect: .init(x: 1054, y: 243, width: 22, height: 16)),
        .init(side: .departures, rowIndex: 9, trainNumberRect: .init(x: 643, y: 272, width: 52, height: 20), delayRect: .init(x: 1019, y: 271, width: 33, height: 17), platformRect: .init(x: 1054, y: 271, width: 22, height: 16)),
        .init(side: .departures, rowIndex: 10, trainNumberRect: .init(x: 643, y: 289, width: 52, height: 20), delayRect: .init(x: 1019, y: 288, width: 33, height: 17), platformRect: .init(x: 1054, y: 288, width: 22, height: 16)),
        .init(side: .departures, rowIndex: 11, trainNumberRect: .init(x: 643, y: 306, width: 52, height: 20), delayRect: .init(x: 1019, y: 305, width: 33, height: 17), platformRect: .init(x: 1054, y: 305, width: 22, height: 16))
    ]
}

private enum CFRWebcamBoardCellKind {
    case trainNumber
    case delay
    case platform

    var validLengthRange: ClosedRange<Int> {
        switch self {
        case .trainNumber:
            return 3...5
        case .delay:
            return 1...3
        case .platform:
            return 1...2
        }
    }
}

// MARK: - Session Manager

final class InfoFerSessionManager {
    static let shared = InfoFerSessionManager()
    private let cookieStoreKey = "infofer_cookies"
    
    private init() {}

    func refreshSession(for trainNumber: String) async {
        do {
            try await performHandshake(trainNumber: trainNumber)
        } catch {
            print("[InfoFerSessionManager] ❌ Handshake failed: \(error)")
        }
    }

    private func performHandshake(trainNumber: String) async throws {
        let date = Self.formatDate(Date())
        let urlString = "https://mersultrenurilor.infofer.ro/ro-RO/Tren/\(trainNumber)?__Invariant=TrainRunningNumber&Date=\(date)"
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.addValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20

        let (_, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              let finalURL = httpResponse.url,
              let headerFields = httpResponse.allHeaderFields as? [String: String] else { return }

        let responseCookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: finalURL)
        let storageCookies = HTTPCookieStorage.shared.cookies(for: finalURL) ?? []
        let merged = responseCookies + storageCookies
        
        if !merged.isEmpty {
            persist(cookies: merged)
            print("[InfoFerSessionManager] ✅ Stored \(merged.count) cookies")
        }
    }

    func storedCookies() -> [HTTPCookie]? {
        guard let data = UserDefaults.standard.data(forKey: cookieStoreKey),
              let cookies = try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data) as? [HTTPCookie]
        else { return nil }
        return cookies
    }

    private func persist(cookies: [HTTPCookie]) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: cookies, requiringSecureCoding: false) else { return }
        UserDefaults.standard.set(data, forKey: cookieStoreKey)
    }

    static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy"
        return formatter.string(from: date)
    }
}

// MARK: - Scraper Service

final class InfoFerScraper {
    static let shared = InfoFerScraper()
    private init() {}

    func fetchAndDecodeImage(
        for station: String = "BucurestiNord"
    ) async -> UIImage? {
        guard let html = await fetchWebcamHTML(for: station) else { return nil }
        guard let base64Image = extractWebcamImageBase64(from: html) else { return nil }
        guard let imageData = Data(base64Encoded: base64Image, options: .ignoreUnknownCharacters) else { return nil }
        return UIImage(data: imageData)
    }

    func fetchAndRecognizeBoard(
        for station: String = "BucurestiNord"
    ) async -> CFRWebcamBoardScan? {
        guard let snapshot = await fetchBoardSnapshot(for: station) else { return nil }
        return snapshot.scan
    }

    func fetchBoardObservation(
        for trip: Trip,
        station: String = "BucurestiNord"
    ) async -> CFRWebcamBoardObservation? {
        guard let trainNumber = trip.resolvedTrainNumber else { return nil }
        guard let image = await fetchAndDecodeImage(for: station) else { return nil }
        guard let cgImage = image.cgImage ?? normalizedCGImage(from: image) else { return nil }

        let stateKey = boardStateKey(for: trip, station: station)
        var state = CFRWebcamBoardStateStore.shared.state(for: stateKey)
        let now = Date()
        if let lastImageFetchedAt = state.lastImageFetchedAt,
           now.timeIntervalSince(lastImageFetchedAt) < 60 {
            CFRWebcamBoardStateStore.shared.save(state, for: stateKey)
            return CFRWebcamBoardObservation(
                image: image,
                statusText: "Recently refreshed. OCR will resume in the next minute.",
                platformText: state.confirmedPlatform ?? state.pendingPlatform,
                updatedTrip: nil,
                state: state
            )
        }

        if let confirmedPlatform = state.confirmedPlatform, !confirmedPlatform.isEmpty {
            state.lastImageFetchedAt = now
            state.lastUpdatedAt = now
            CFRWebcamBoardStateStore.shared.save(state, for: stateKey)
            return CFRWebcamBoardObservation(
                image: image,
                statusText: "Platform locked for today.",
                platformText: confirmedPlatform,
                updatedTrip: nil,
                state: state
            )
        }

        do {
            try Task.checkCancellation()

            state.lastImageFetchedAt = now
            let preferredSide = trip.webcamBoardSideHint
            let candidateLayouts = candidateBoardLayouts(for: state, preferredSide: preferredSide)
            guard let matchedLayout = try recognizedTrainLayout(
                in: cgImage,
                expectedTrainNumber: trainNumber,
                candidateLayouts: candidateLayouts
            ) else {
                state.lastUpdatedAt = now
                CFRWebcamBoardStateStore.shared.save(state, for: stateKey)
                return CFRWebcamBoardObservation(
                    image: image,
                    statusText: "Train not on the board yet.",
                    platformText: nil,
                    updatedTrip: nil,
                    state: state
                )
            }

            state.lastSeenSide = matchedLayout.side
            state.lastSeenRowIndex = matchedLayout.rowIndex
            state.lastSeenTrainNumber = trainNumber

            let platform = try recognizeText(
                in: cgImage,
                rect: matchedLayout.platformRect,
                kind: .platform
            )
            let cleanedPlatform = sanitizedPlatformCandidate(platform)

            var updatedTrip: Trip?
            var statusText: String

            if let cleanedPlatform {
                if state.pendingPlatform == cleanedPlatform {
                    state.pendingPlatformCount += 1
                } else {
                    state.pendingPlatform = cleanedPlatform
                    state.pendingPlatformCount = 1
                }

                updatedTrip = trip.updatingPlatform(cleanedPlatform, for: matchedLayout.side)

                if state.pendingPlatformCount >= 2 {
                    state.confirmedPlatform = cleanedPlatform
                    state.confirmedSide = matchedLayout.side
                    state.confirmedRowIndex = matchedLayout.rowIndex
                    state.pendingPlatform = nil
                    state.pendingPlatformCount = 0
                    statusText = "Platform confirmed."
                } else {
                    statusText = "Platform \(cleanedPlatform) seen \(state.pendingPlatformCount)/2."
                }
            } else {
                statusText = "Found row \(matchedLayout.rowIndex + 1) on \(matchedLayout.side == .arrivals ? "arrivals" : "departures"), waiting for platform."
            }

            state.lastUpdatedAt = now
            CFRWebcamBoardStateStore.shared.save(state, for: stateKey)

            return CFRWebcamBoardObservation(
                image: image,
                statusText: statusText,
                platformText: state.confirmedPlatform ?? cleanedPlatform,
                updatedTrip: updatedTrip,
                state: state
            )
        } catch {
            #if DEBUG
            print("[InfoFerScraper] Webcam board observation failed: \(error)")
            #endif
            state.lastImageFetchedAt = now
            state.lastUpdatedAt = now
            CFRWebcamBoardStateStore.shared.save(state, for: stateKey)
            return CFRWebcamBoardObservation(
                image: image,
                statusText: "Unable to read the board right now.",
                platformText: state.confirmedPlatform,
                updatedTrip: nil,
                state: state
            )
        }
    }

    func fetchBoardSnapshot(
        for station: String = "BucurestiNord"
    ) async -> CFRWebcamBoardSnapshot? {
        guard !Task.isCancelled else { return nil }
        guard let sourceURL = webcamURL(for: station) else { return nil }
        guard let image = await fetchAndDecodeImage(for: station) else { return nil }
        guard let cgImage = image.cgImage ?? normalizedCGImage(from: image) else { return nil }

        return autoreleasepool {
            do {
                try Task.checkCancellation()
                let pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
                let entries = try recognizeBoardEntries(in: cgImage)
                let scan = CFRWebcamBoardScan(
                    station: station,
                    sourceURL: sourceURL,
                    fetchedAt: Date(),
                    imageSize: pixelSize,
                    entries: entries
                )
                return CFRWebcamBoardSnapshot(scan: scan, image: image)
            } catch {
                #if DEBUG
                print("[InfoFerScraper] OCR failed: \(error)")
                #endif
                return nil
            }
        }
    }

    func clearBoardObservationState(for trip: Trip, station: String = "BucurestiNord") {
        CFRWebcamBoardStateStore.shared.clear(for: boardStateKey(for: trip, station: station))
    }

    func printBoardTripletsFromWebcam(for station: String = "BucurestiNord") async {
        guard let scan = await fetchAndRecognizeBoard(for: station) else {
            print("[InfoFerScraper] No webcam board data found for \(station)")
            return
        }

        print("[InfoFerScraper] Webcam board triplets for \(station):")
        for entry in scan.entries {
            let side = entry.side == .arrivals ? "arrival" : "departure"
            let trainNumber = entry.trainNumber.isEmpty ? "-" : entry.trainNumber
            let delay = entry.delay.isEmpty ? "-" : entry.delay
            let platform = entry.platformNumber.isEmpty ? "-" : entry.platformNumber
            print("[InfoFerScraper] \(side) row \(entry.rowIndex + 1): train_number=\(trainNumber) delay=\(delay) platform_number=\(platform)")
        }
    }

    func fetchDelay(for trainNumber: String, travelDate: Date?) async -> DelayInfo {
        guard let cookies = InfoFerSessionManager.shared.storedCookies() else {
            print("[InfoFerScraper] ❌ Missing cookies")
            return DelayInfo(delayMinutes: nil, platform: nil)
        }

        do {
            let formattedDate = InfoFerSessionManager.formatDate(travelDate ?? Date())
            let shellHTML = try await requestShellHTML(for: trainNumber, dateString: formattedDate, cookies: cookies)
            var bodyParams = try extractFormParameters(from: shellHTML)
            bodyParams["Date"] = formattedDate
            bodyParams["TravelDate"] = formattedDate
            let resultHTML = try await requestResultHTML(with: bodyParams, cookies: cookies, refererTrain: trainNumber, dateString: formattedDate)

            let info = parseResultHTML(resultHTML)

            print("\n🚂 [InfoFerScraper] REPORT FOR IR \(trainNumber)")
            print("------------------------------------------------")
            print("🔴 HEADER DELAY: \(info.delayMinutes ?? 0) min")
            print("🚉 PLATFORM:     \(info.platform ?? "n/a")")
            print("------------------------------------------------")

            for station in info.stationDelays {
                let name = station.stationName.padding(toLength: 25, withPad: " ", startingAt: 0)
                let arr = station.arrivalDelayMinutes != nil ? "\(station.arrivalDelayMinutes!)m" : "-"
                let dep = station.departureDelayMinutes != nil ? "\(station.departureDelayMinutes!)m" : "-"
                print("\(name) | Arr: \(arr) | Dep: \(dep)")
            }
            print("------------------------------------------------\n")

            return info

        } catch {
            print("[InfoFerScraper] ❌ Scrape failed: \(error)")
            return DelayInfo(delayMinutes: nil, platform: nil)
        }
    }

    func fetchMapInfo(
        for trainNumber: String,
        travelDate: Date?,
        departureTime: String
    ) async -> InfoFerMapInfo {
        guard let cookies = InfoFerSessionManager.shared.storedCookies() else {
            print("[InfoFerScraper] ❌ Missing cookies for route map")
            return InfoFerMapInfo(routePolylines: [], liveCoordinate: nil, gpsPermanentlyUnavailable: false)
        }

        do {
            let formattedDate = InfoFerSessionManager.formatDate(travelDate ?? Date())
            let mapHTML = try await requestMapHTML(
                for: trainNumber,
                dateString: formattedDate,
                departureTime: departureTime,
                cookies: cookies
            )
            let polylines = parseRoutePolylines(from: mapHTML)
            let liveCoordinate = parseTrustedLiveCoordinate(from: mapHTML, travelDate: travelDate ?? Date())
            let gpsPermanentlyUnavailable = containsEstimatedCFRPosition(in: mapHTML)
            #if DEBUG
            print("[InfoFerScraper] Map route found \(polylines.count) polyline segments; GPS=\(liveCoordinate != nil ? "yes" : "no")")
            printLiveCoordinateDebugInfo(from: mapHTML, liveCoordinate: liveCoordinate, gpsPermanentlyUnavailable: gpsPermanentlyUnavailable)
            #endif
            return InfoFerMapInfo(
                routePolylines: polylines,
                liveCoordinate: liveCoordinate,
                gpsPermanentlyUnavailable: gpsPermanentlyUnavailable
            )
        } catch {
            print("[InfoFerScraper] ❌ Map scrape failed: \(error)")
            return InfoFerMapInfo(routePolylines: [], liveCoordinate: nil, gpsPermanentlyUnavailable: false)
        }
    }

    func fetchRoutePolylines(
        for trainNumber: String,
        travelDate: Date?,
        departureTime: String
    ) async -> [StoredRoutePolyline] {
        await fetchMapInfo(
            for: trainNumber,
            travelDate: travelDate,
            departureTime: departureTime
        ).routePolylines
    }

    // --- Networking ---

    private func requestShellHTML(for trainNumber: String, dateString: String, cookies: [HTTPCookie]) async throws -> String {
        let urlString = "https://mersultrenurilor.infofer.ro/ro-RO/Tren/\(trainNumber)?__Invariant=TrainRunningNumber&Date=\(dateString)"
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        let headers = HTTPCookie.requestHeaderFields(with: cookies)
        headers.forEach { request.addValue($0.value, forHTTPHeaderField: $0.key) }
        request.addValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let html = String(data: data, encoding: .utf8) else { throw URLError(.cannotDecodeRawData) }
        return html
    }

    private func requestMapHTML(
        for trainNumber: String,
        dateString: String,
        departureTime: String,
        cookies: [HTTPCookie]
    ) async throws -> String {
        var components = URLComponents(string: "https://mersultrenurilor.infofer.ro/ro-RO/Trains/LoadTrainMapPartial")
        components?.queryItems = [
            URLQueryItem(name: "RunningNumber", value: trainNumber),
            URLQueryItem(name: "DepartureDateTime", value: "\(dateString) \(departureTime)"),
            URLQueryItem(name: "_", value: "\(Int(Date().timeIntervalSince1970 * 1000))")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        let headers = HTTPCookie.requestHeaderFields(with: cookies)
        headers.forEach { request.addValue($0.value, forHTTPHeaderField: $0.key) }
        request.addValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.addValue("https://mersultrenurilor.infofer.ro/ro-RO/Tren/\(trainNumber)?__Invariant=TrainRunningNumber&Date=\(dateString)", forHTTPHeaderField: "Referer")
        request.addValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw URLError(.badServerResponse)
        }
        guard let html = String(data: data, encoding: .utf8) else { throw URLError(.cannotDecodeRawData) }
        return html
    }

    private func requestResultHTML(with params: [String: String], cookies: [HTTPCookie], refererTrain: String, dateString: String) async throws -> String {
        let postURL = URL(string: "https://mersultrenurilor.infofer.ro/ro-RO/Trains/TrainsResult")!
        var request = URLRequest(url: postURL)
        request.httpMethod = "POST"
        
        let headers = HTTPCookie.requestHeaderFields(with: cookies)
        headers.forEach { request.addValue($0.value, forHTTPHeaderField: $0.key) }
        
        request.addValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.addValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        let referer = "https://mersultrenurilor.infofer.ro/ro-RO/Tren/\(refererTrain)?__Invariant=TrainRunningNumber&Date=\(params["Date"] ?? dateString)"
        request.addValue(referer, forHTTPHeaderField: "Referer")
        request.addValue("https://mersultrenurilor.infofer.ro", forHTTPHeaderField: "Origin")
        request.addValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")

        var components = URLComponents()
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = components.query?.data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let html = String(data: data, encoding: .utf8) else { throw URLError(.cannotDecodeRawData) }
        return html
    }

    private func extractFormParameters(from html: String) throws -> [String: String] {
        guard let formRange = html.range(of: "form id=\"form-search\"") else {
            throw NSError(domain: "InfoFer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Form not found"])
        }

        let substring = html[formRange.lowerBound...]
        var params: [String: String] = [:]

        let pattern = "name=\\\"([^\\\"]+)\\\"[^>]*value=\\\"([^\\\"]*)\\\""
        let regex = try NSRegularExpression(pattern: pattern, options: [])
        let matches = regex.matches(in: String(substring), options: [], range: NSRange(location: 0, length: substring.utf16.count))

        for match in matches {
            guard match.numberOfRanges >= 3,
                  let nameRange = Range(match.range(at: 1), in: substring),
                  let valueRange = Range(match.range(at: 2), in: substring)
            else { continue }
            params[String(substring[nameRange])] = String(substring[valueRange])
        }

        params["IsSearchWanted"] = "True"
        params["IsReCaptchaFailed"] = "False"
        return params
    }

    // --- Parsing Logic (CRASH PROOF) ---

    private func parseResultHTML(_ html: String) -> DelayInfo {
        let activeBranch = extractActiveBranch(from: html)
        let platform = parsePlatform(in: activeBranch ?? html)
        let headline = parseHeadlineDetails(from: html)
        let delay = headline.delay
        let stationDelays = parseDetailedSchedule(in: activeBranch)

        return DelayInfo(delayMinutes: delay, platform: platform, statusText: headline.text, stationDelays: stationDelays)
    }

    private func parseHeadlineDetails(from html: String) -> (delay: Int?, text: String?) {
        let paragraphMatches = allMatches(in: html, pattern: "(?is)<p[^>]*class=\\\"[^\\\"]*text-1-1rem[^\\\"]*\\\"[^>]*>(.*?)</p>")
        if let targetParagraph = paragraphMatches.dropFirst().first ?? paragraphMatches.first {
            let cleaned = targetParagraph.replacingOccurrences(of: "Puteți apăsa pe butonul ”Hartă” pentru a vedea locația.", with: "")
            let decoded = decodeHTMLEntities(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
            let delayValue = interpretHeadlineDelayValue(from: decoded)
            return (delayValue, decoded.isEmpty ? nil : decoded)
        }

        guard let delayClassRange = html.range(of: "class=\"color-firebrick\"", options: .caseInsensitive) else {
            return (nil, nil)
        }
        let snippet = html[delayClassRange.upperBound...]
        guard let closing = snippet.firstIndex(of: "<") else {
            return (nil, nil)
        }
        let rawText = String(snippet[..<closing])
        let decoded = decodeHTMLEntities(rawText).trimmingCharacters(in: .whitespacesAndNewlines)
        let delayValue = interpretHeadlineDelayValue(from: decoded)
        return (delayValue, decoded.isEmpty ? nil : decoded)
    }

    private func parsePlatform(in html: String) -> String? {
        guard let liRange = html.range(of: "li class=\"list-group-item\"", options: .caseInsensitive) else { return nil }
        let liSnippet = html[liRange.lowerBound...]
        guard let liniaRange = liSnippet.range(of: "Linia ", options: .caseInsensitive) else { return nil }
        let suffix = liSnippet[liniaRange.upperBound...]
        let components = suffix.components(separatedBy: .whitespacesAndNewlines)
        guard let candidate = components.first else { return nil }
        let sanitized = candidate.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        return sanitized.isEmpty ? nil : sanitized
    }

    // --- REWRITTEN PARSER (Safe String Splitting) ---
    private func parseDetailedSchedule(in branchHTML: String?) -> [StationDelay] {
        guard let branchHTML else { return [] }
        
        // Split by the class name instead of Regex (Crash Proof)
        // We drop the first one because it's the stuff before the first station
        let rawItems = branchHTML.components(separatedBy: "list-group-item")
        guard rawItems.count > 1 else { return [] }
        
        // Skip the first chunk (header garbage), map the rest
        return rawItems.dropFirst().compactMap { liContent -> StationDelay? in
            
            // 1. Station Name
            // It's inside <div class="...col-md-5..."> <a ...> Name </a>
            // We search for "col-md-5" then find the <a> tag
            guard let nameStart = liContent.range(of: "col-md-5"),
                  let linkStart = liContent.range(of: "<a", range: nameStart.upperBound..<liContent.endIndex),
                  let linkClose = liContent.range(of: "</a>", range: linkStart.upperBound..<liContent.endIndex),
                  let nameContentStart = liContent.range(of: ">", range: linkStart.upperBound..<linkClose.lowerBound)
            else { return nil }
            
            let nameRaw = String(liContent[nameContentStart.upperBound..<linkClose.lowerBound])
            let stationName = decodeHTMLEntities(nameRaw).trimmingCharacters(in: .whitespacesAndNewlines)
            
            // 2. Times (Arrival vs Departure)
            // There are two "col-3 col-md-2" columns.
            // We can just split the string by "col-3 col-md-2" to separate them.
            let timeColumns = liContent.components(separatedBy: "col-3 col-md-2")
            
            var arrivalDelay: Int? = nil
            var departureDelay: Int? = nil
            
            // The split will give [Junk, ArrivalHTML, DepartureHTML, Junk...]
            if timeColumns.count >= 3 {
                arrivalDelay = parseDelayFromColumn(timeColumns[1])
                departureDelay = parseDelayFromColumn(timeColumns[2])
            } else if timeColumns.count == 2 {
                // Usually implies only one time present (Start/End station)
                // We'll treat the first valid one we found as the "active" time
                // This is a simplification; precise logic would check ordering.
                // For now, let's assume if it's the *only* one, it might be Dep (if start) or Arr (if end).
                // But typically scraper sees 3 components (split creates n+1).
                // 1st component = before 1st column
                // 2nd component = 1st column content
                // 3rd component = 2nd column content
            }
            
            return StationDelay(
                stationName: stationName,
                arrivalDelayMinutes: arrivalDelay,
                departureDelayMinutes: departureDelay,
                platform: parsePlatformFromStationRow(liContent)
            )
        }
    }

    private func parseDelayFromColumn(_ htmlSnippet: String) -> Int? {
        let clean = decodeHTMLEntities(htmlSnippet)

        if clean.contains("*") {
            return nil
        }
        
        // 1. On Time check
        if clean.localizedCaseInsensitiveContains("la timp") {
            return 0
        }
        
        // 2. Explicit delay "+ 5 min"
        // Find "+5" or "+ 5" or "-2" inside the string
        let pattern = "([+-]?\\s*\\d+)\\s*min"
        if let match = firstMatch(in: clean, pattern: pattern, groupIndex: 1) {
            let numberString = match.replacingOccurrences(of: " ", with: "")
            return Int(numberString)
        }
        
        return nil
    }

    private func parsePlatformFromStationRow(_ htmlSnippet: String) -> String? {
        let decoded = decodeHTMLEntities(htmlSnippet)
        let pattern = "Linia\\s*([A-Za-z0-9]+)"
        guard let raw = firstMatch(in: decoded, pattern: pattern, groupIndex: 1) else { return nil }
        let sanitized = raw.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        return sanitized.isEmpty ? nil : sanitized
    }

    private func parseRoutePolylines(from html: String) -> [StoredRoutePolyline] {
        let encodedSegments = allMatches(
            in: html,
            pattern: #"L\.PolylineUtil\.decode\("([^"]+)"\)"#
        )

        return encodedSegments.compactMap { rawSegment in
            let decodedString = decodeJavaScriptString(rawSegment)
            let points = decodePolyline(decodedString)
            guard points.count > 1 else { return nil }
            return StoredRoutePolyline(points: points)
        }
    }

    func parseTrustedLiveCoordinate(from html: String, travelDate: Date) -> InfoFerLiveCoordinate? {
        let visibleText = visibleText(from: html)
        let normalizedText = visibleText
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        guard !containsEstimatedCFRPosition(in: html) else { return nil }
        guard normalizedText.contains("ultima pozitie gps la") || normalizedText.contains("raportat de personalul cfr la") else { return nil }

        guard
            let latitudeText = firstMatch(
                in: html,
                pattern: #"lastGpsPositionLatitude\s*=\s*([-+]?\d+(?:\.\d+)?);"#,
                groupIndex: 1
            ),
            let longitudeText = firstMatch(
                in: html,
                pattern: #"lastGpsPositionLongitude\s*=\s*([-+]?\d+(?:\.\d+)?);"#,
                groupIndex: 1
            ),
            let latitude = Double(latitudeText),
            let longitude = Double(longitudeText)
        else { return nil }

        return InfoFerLiveCoordinate(
            latitude: latitude,
            longitude: longitude,
            sourceText: visibleText.isEmpty ? nil : visibleText
        )
    }

    func containsEstimatedCFRPosition(in html: String) -> Bool {
        let visibleText = visibleText(from: html)
        let normalizedText = visibleText
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        return normalizedText.contains("pozitie estimata pe baza raportarii cfr")
    }

    private func printLiveCoordinateDebugInfo(
        from html: String,
        liveCoordinate: InfoFerLiveCoordinate?,
        gpsPermanentlyUnavailable: Bool
    ) {
        let visibleText = visibleText(from: html)
        let normalizedText = visibleText
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        let message = firstLiveCoordinateMessage(in: visibleText) ?? "No GPS/CFR position message found in visible map text."
        let latitude = firstMapCoordinateValue(in: html, axis: "Latitude")
        let longitude = firstMapCoordinateValue(in: html, axis: "Longitude")
        let hasTrustedGPSMessage = normalizedText.contains("ultima pozitie gps la")
            || normalizedText.contains("raportat de personalul cfr la")

        print("[InfoFerScraper] Map GPS message/block: \(message)")
        print("[InfoFerScraper] Map trainGPS position: latitude=\(latitude?.value ?? "nil") (\(latitude?.name ?? "missing")), longitude=\(longitude?.value ?? "nil") (\(longitude?.name ?? "missing"))")
        print("[InfoFerScraper] Map GPS decision: trustedMessage=\(hasTrustedGPSMessage), estimatedOnly=\(gpsPermanentlyUnavailable), acceptedCoordinate=\(liveCoordinate != nil)")
    }

    private func firstMapCoordinateValue(in html: String, axis: String) -> (name: String, value: String)? {
        for prefix in ["lastGpsPosition", "theoreticalGpsPosition"] {
            let name = "\(prefix)\(axis)"
            if let value = firstMatch(
                in: html,
                pattern: #"\#(name)\s*=\s*([-+]?\d+(?:\.\d+)?);"#,
                groupIndex: 1
            ) {
                return (name, value)
            }
        }

        return nil
    }

    private func firstLiveCoordinateMessage(in visibleText: String) -> String? {
        let pattern = #"(?i)(?:Ultima pozi(?:ț|t)ie GPS la|RAPORTAT de personalul CFR la|Pozi(?:ț|t)ie ESTIMAT(?:Ă|A) pe baza raport(?:ă|a)rii CFR).{0,300}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsText = visibleText as NSString
        let range = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: visibleText, options: [], range: range) else { return nil }
        return nsText.substring(with: match.range)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func visibleText(from html: String) -> String {
        let textIncludingScriptTemplates = html
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return decodeHTMLEntities(textIncludingScriptTemplates)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodeJavaScriptString(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\\\"")
        let jsonString = "\"\(escaped)\""
        if let data = jsonString.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(String.self, from: data) {
            return decoded
        }

        return value
            .replacingOccurrences(of: "\\\\", with: "\\")
            .replacingOccurrences(of: "\\\"", with: "\"")
    }

    private func decodePolyline(_ encoded: String, precision: Double = 1e5) -> [StoredRoutePoint] {
        let scalars = Array(encoded.unicodeScalars)
        var index = 0
        var latitude = 0
        var longitude = 0
        var points: [StoredRoutePoint] = []

        while index < scalars.count {
            guard let deltaLatitude = decodePolylineComponent(scalars: scalars, index: &index) else { break }
            guard let deltaLongitude = decodePolylineComponent(scalars: scalars, index: &index) else { break }

            latitude += deltaLatitude
            longitude += deltaLongitude
            points.append(
                StoredRoutePoint(
                    latitude: Double(latitude) / precision,
                    longitude: Double(longitude) / precision
                )
            )
        }

        return points
    }

    private func decodePolylineComponent(scalars: [String.UnicodeScalarView.Element], index: inout Int) -> Int? {
        var shift = 0
        var result = 0

        while index < scalars.count {
            let byte = Int(scalars[index].value) - 63
            index += 1
            result |= (byte & 0x1f) << shift
            shift += 5

            if byte < 0x20 {
                return (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
            }
        }

        return nil
    }

    // --- Helpers ---

    private func extractActiveBranch(from html: String) -> String? {
        let pattern = "(?s)<div[^>]*id=\\\"(div-stations-branch-[^\\\"]+)\\\"[^>]*>(.*?)<div[^>]*id=\\\"div-stations-branch"
        if let match = firstMatch(in: html, pattern: pattern, groupIndex: 0) {
            return match
        }
        return html
    }

    private func firstMatch(in text: String, pattern: String, groupIndex: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let nsText = text as NSString
        guard let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: nsText.length)) else { return nil }

        if groupIndex < match.numberOfRanges {
            let range = match.range(at: groupIndex)
            if range.location != NSNotFound {
                return nsText.substring(with: range)
            }
        }
        return nil
    }

    private func allMatches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let nsText = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
        return matches.compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            let range = match.range(at: 1)
            guard range.location != NSNotFound else { return nil }
            return nsText.substring(with: range)
        }
    }

    private func interpretHeadlineDelayValue(from text: String) -> Int? {
        let normalized = text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()

        if normalized.contains("fara intarziere") {
            return 0
        }

        if let earlyMatch = firstMatch(in: normalized, pattern: "(\\d+)\\s*min\\s+mai\\s+devreme", groupIndex: 1),
           let value = Int(earlyMatch) {
            return -value
        }

        if let lateMatch = firstMatch(in: normalized, pattern: "(\\d+)\\s*min\\s+intarziere", groupIndex: 1),
           let value = Int(lateMatch) {
            return value
        }

        return extractDelayNumber(from: text)
    }

    private func extractDelayNumber(from text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let pattern = "([+-]?\\s*\\d+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let nsText = trimmed as NSString
        guard let match = regex.firstMatch(in: trimmed, options: [], range: NSRange(location: 0, length: nsText.length)) else {
            return nil
        }

        let range = match.range(at: 1)
        guard range.location != NSNotFound else { return nil }

        // Ignore numbers that appear far into the sentence (likely timestamps "Raportat la 2:01")
        if range.location > 5 { return nil }

        let raw = nsText.substring(with: range).replacingOccurrences(of: " ", with: "")
        return Int(raw)
    }

    private func decodeHTMLEntities(_ text: String) -> String {
        guard let data = text.data(using: .utf8) else { return text }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        if let attributed = try? NSAttributedString(data: data, options: options, documentAttributes: nil) {
            return attributed.string
        }
        return text
    }

    private func fetchWebcamHTML(for station: String) async -> String? {
        guard let url = webcamURL(for: station) else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let html = String(data: data, encoding: .utf8)
            else { return nil }
            return html
        } catch {
            #if DEBUG
            print("[InfoFerScraper] Webcam HTML fetch failed: \(error)")
            #endif
            return nil
        }
    }

    private func webcamURL(for station: String) -> URL? {
        let trimmed = station.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var components = URLComponents(string: "https://cfr.ro/gari/camereweb/index.php")
        components?.queryItems = [
            URLQueryItem(name: "statie", value: trimmed)
        ]
        return components?.url
    }

    private func extractWebcamImageBase64(from html: String) -> String? {
        let pattern = #"id="webcam-img"[^>]*src="data:image\/(?:jpg|jpeg|png);base64,([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: nsRange),
              let range = Range(match.range(at: 1), in: html)
        else { return nil }
        return String(html[range])
    }

    private func recognizeBoardEntries(in cgImage: CGImage) throws -> [CFRWebcamBoardTriplet] {
        let layouts = CFRWebcamBoardLayout.manualTripletLayouts
        guard !layouts.isEmpty else { return [] }

        var entries: [CFRWebcamBoardTriplet] = []
        for layout in layouts {
            try Task.checkCancellation()
            let trainNumber = try recognizeText(
                in: cgImage,
                rect: layout.trainNumberRect,
                kind: .trainNumber
            )
            let delay = try recognizeText(
                in: cgImage,
                rect: layout.delayRect,
                kind: .delay
            )
            let platform = try recognizeText(
                in: cgImage,
                rect: layout.platformRect,
                kind: .platform
            )

            entries.append(
                CFRWebcamBoardTriplet(
                    side: layout.side,
                    rowIndex: layout.rowIndex,
                    trainNumber: trainNumber,
                    delay: delay,
                    platformNumber: platform,
                    trainNumberBounds: layout.trainNumberRect,
                    delayBounds: layout.delayRect,
                    platformBounds: layout.platformRect
                )
            )
        }

        return entries
    }

    private func boardStateKey(for trip: Trip, station: String) -> String {
        "\(trip.id)|\(station.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    private func candidateBoardLayouts(
        for state: CFRWebcamBoardTrackingState,
        preferredSide: CFRWebcamBoardSide
    ) -> [CFRWebcamBoardTripletLayout] {
        let layouts = CFRWebcamBoardLayout.manualTripletLayouts
        guard !layouts.isEmpty else { return [] }

        if let side = state.lastSeenSide, let rowIndex = state.lastSeenRowIndex {
            let filtered = layouts
                .filter { $0.side == side && $0.rowIndex <= rowIndex }
                .sorted {
                    if $0.rowIndex != $1.rowIndex { return $0.rowIndex > $1.rowIndex }
                    return $0.side.rawValue < $1.side.rawValue
                }
            if !filtered.isEmpty {
                return filtered
            }
        }

        return layouts.sorted {
            if $0.side != $1.side {
                return $0.side == preferredSide
            }
            return $0.rowIndex > $1.rowIndex
        }
    }

    private func recognizedTrainLayout(
        in cgImage: CGImage,
        expectedTrainNumber: String,
        candidateLayouts: [CFRWebcamBoardTripletLayout]
    ) throws -> CFRWebcamBoardTripletLayout? {
        for layout in candidateLayouts {
            try Task.checkCancellation()
            let trainNumber = try recognizeText(
                in: cgImage,
                rect: layout.trainNumberRect,
                kind: .trainNumber
            )
            if trainNumber == expectedTrainNumber {
                return layout
            }
        }

        return nil
    }

    private func sanitizedPlatformCandidate(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let digits = trimmed.filter(\.isNumber)
        guard !digits.isEmpty, let platform = Int(digits), (1...14).contains(platform) else { return nil }
        return String(platform)
    }

    private func recognizeText(
        in cgImage: CGImage,
        rect: CGRect,
        kind: CFRWebcamBoardCellKind
    ) throws -> String {
        guard !rect.isEmpty, rect.width > 0, rect.height > 0 else { return "" }

        let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
        let paddingVariants: [CGFloat] = [0, 2, 4]

        var bestCandidate: (value: String, confidence: VNConfidence)?

        for padding in paddingVariants {
            try Task.checkCancellation()
            autoreleasepool {
                let expandedRect = rect.insetBy(dx: -padding, dy: -padding)
                let clampedRect = clampRect(expandedRect, to: CGRect(origin: .zero, size: imageSize)).integral
                guard clampedRect.width > 0, clampedRect.height > 0,
                      let cropped = cgImage.cropping(to: clampedRect) else {
                    return
                }

                let cropRequest = makeTextRecognitionRequest()
                let handler = VNImageRequestHandler(
                    cgImage: cropped,
                    orientation: .up,
                    options: [:]
                )
                try? handler.perform([cropRequest])

                let candidates = (cropRequest.results ?? [])
                    .compactMap { $0.topCandidates(1).first }

                for candidate in candidates {
                    let normalized = normalizeNumericCandidate(candidate.string)
                    guard kind.validLengthRange.contains(normalized.count) else { continue }

                    if let currentBest = bestCandidate {
                        if candidate.confidence > currentBest.confidence {
                            bestCandidate = (normalized, candidate.confidence)
                        }
                    } else {
                        bestCandidate = (normalized, candidate.confidence)
                    }
                }
            }
        }

        return bestCandidate?.value ?? ""
    }

    private func makeTextRecognitionRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.0
        request.recognitionLanguages = ["en-US"]
        return request
    }

    private func normalizeNumericCandidate(_ text: String) -> String {
        let digits = text.filter(\.isNumber)
        return String(digits)
    }

    private func normalizedCGImage(from image: UIImage) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        let renderedImage = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        return renderedImage.cgImage
    }

    private func clampRect(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        let x = max(bounds.minX, rect.minX)
        let y = max(bounds.minY, rect.minY)
        let maxX = min(bounds.maxX, rect.maxX)
        let maxY = min(bounds.maxY, rect.maxY)
        return CGRect(x: x, y: y, width: max(0, maxX - x), height: max(0, maxY - y))
    }

}

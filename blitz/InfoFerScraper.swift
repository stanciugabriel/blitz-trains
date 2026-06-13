import Foundation
internal import UIKit

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

    init(
        delayMinutes: Int?,
        platform: String?,
        statusText: String? = nil,
        stationDelays: [StationDelay] = [],
        liveCoordinate: InfoFerLiveCoordinate? = nil
    ) {
        self.delayMinutes = delayMinutes
        self.platform = platform
        self.statusText = statusText
        self.stationDelays = stationDelays
        self.liveCoordinate = liveCoordinate
    }

    func updatingLiveCoordinate(_ coordinate: InfoFerLiveCoordinate?) -> DelayInfo {
        DelayInfo(
            delayMinutes: delayMinutes,
            platform: platform,
            statusText: statusText,
            stationDelays: stationDelays,
            liveCoordinate: coordinate
        )
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
            let latitudeText = firstMapCoordinateValue(in: html, axis: "Latitude")?.value,
            let longitudeText = firstMapCoordinateValue(in: html, axis: "Longitude")?.value,
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
}

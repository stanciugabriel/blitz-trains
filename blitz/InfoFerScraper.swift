import Foundation
internal import UIKit

// MARK: - Models

struct StationDelay: Equatable, Codable {
    let stationName: String
    let arrivalDelayMinutes: Int?
    let departureDelayMinutes: Int?
    let platform: String?
}

struct DelayInfo: Equatable, Codable {
    let delayMinutes: Int?
    let platform: String?
    let stationDelays: [StationDelay]

    init(delayMinutes: Int?, platform: String?, stationDelays: [StationDelay] = []) {
        self.delayMinutes = delayMinutes
        self.platform = platform
        self.stationDelays = stationDelays
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
        let delay = parseHeadlineDelay(from: html)
        let stationDelays = parseDetailedSchedule(in: activeBranch)

        return DelayInfo(delayMinutes: delay, platform: platform, stationDelays: stationDelays)
    }

    private func parseHeadlineDelay(from html: String) -> Int? {
        guard let delayClassRange = html.range(of: "class=\"color-firebrick\"", options: .caseInsensitive) else { return 0 }
        let snippet = html[delayClassRange.upperBound...]
        guard let closing = snippet.firstIndex(of: "<") else { return 0 }
        let text = String(snippet[..<closing])
        return extractDelayNumber(from: text)
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

    private func extractDelayNumber(from text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = "([+-]?\\d+)"
        guard let match = firstMatch(in: trimmed, pattern: pattern, groupIndex: 1) else { return nil }
        return Int(match)
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

import Foundation

struct DelayInfo: Equatable, Codable {
    let delayMinutes: Int?
    let platform: String?
}

final class InfoFerSessionManager {
    static let shared = InfoFerSessionManager()

    private let cookieStoreKey = "infofer_cookies"
    private init() {}

    func refreshSession(for trainNumber: String) async {
        do {
            try await performHandshake(trainNumber: trainNumber)
        } catch {
            print("[InfoFerSessionManager] Handshake failed: \(error)")
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
              let headerFields = httpResponse.allHeaderFields as? [String: String],
              let finalURL = httpResponse.url else { return }

        let responseCookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: finalURL)
        let storageCookies = HTTPCookieStorage.shared.cookies(for: finalURL) ?? []
        let merged = responseCookies + storageCookies
        if !merged.isEmpty {
            persist(cookies: merged)
            print("[InfoFerSessionManager] Stored \(merged.count) cookies")
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

final class InfoFerScraper {
    static let shared = InfoFerScraper()

    private init() {}

    func fetchDelay(for trainNumber: String) async -> DelayInfo {
        guard let cookieData = UserDefaults.standard.data(forKey: "infofer_cookies"),
              let cookies = try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(cookieData) as? [HTTPCookie]
        else {
            print("[InfoFerScraper] Missing cookies")
            return DelayInfo(delayMinutes: nil, platform: nil)
        }

        do {
            let shellHTML = try await requestShellHTML(for: trainNumber, cookies: cookies)
            let bodyParams = try extractFormParameters(from: shellHTML)
            let resultHTML = try await requestResultHTML(with: bodyParams, cookies: cookies, refererTrain: trainNumber)
            let info = parseResultHTML(resultHTML)
            print("[InfoFerScraper] Delay=\(info.delayMinutes ?? -1) platform=\(info.platform ?? "n/a")")
            return info
        } catch {
            print("[InfoFerScraper] Scrape failed: \(error)")
            return DelayInfo(delayMinutes: nil, platform: nil)
        }
    }

    private func requestShellHTML(for trainNumber: String, cookies: [HTTPCookie]) async throws -> String {
        let date = InfoFerSessionManager.formatDate(Date())
        let urlString = "https://mersultrenurilor.infofer.ro/ro-RO/Tren/\(trainNumber)?__Invariant=TrainRunningNumber&Date=\(date)"
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        let headers = HTTPCookie.requestHeaderFields(with: cookies)
        headers.forEach { request.addValue($0.value, forHTTPHeaderField: $0.key) }
        request.addValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let html = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeRawData)
        }
        print("[InfoFerScraper] Shell HTML:\n\(html)")
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
            let name = String(substring[nameRange])
            let value = String(substring[valueRange])
            params[name] = value
        }

        params["IsSearchWanted"] = params["IsSearchWanted"] ?? "False"
        params["IsReCaptchaFailed"] = params["IsReCaptchaFailed"] ?? "False"
        return params
    }

    private func requestResultHTML(with params: [String: String], cookies: [HTTPCookie], refererTrain: String) async throws -> String {
        let postURL = URL(string: "https://mersultrenurilor.infofer.ro/ro-RO/Trains/TrainsResult")!
        var request = URLRequest(url: postURL)
        request.httpMethod = "POST"
        let headers = HTTPCookie.requestHeaderFields(with: cookies)
        headers.forEach { request.addValue($0.value, forHTTPHeaderField: $0.key) }
        request.addValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.addValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        let referer = "https://mersultrenurilor.infofer.ro/ro-RO/Tren/\(refererTrain)?__Invariant=TrainRunningNumber&Date=\(params["Date"] ?? InfoFerSessionManager.formatDate(Date()))"
        request.addValue(referer, forHTTPHeaderField: "Referer")
        request.addValue("https://mersultrenurilor.infofer.ro", forHTTPHeaderField: "Origin")
        request.addValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")

        var components = URLComponents()
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = components.query?.data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let html = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeRawData)
        }
        print("[InfoFerScraper] Result HTML:\n\(html)")
        return html
    }

    private func parseResultHTML(_ html: String) -> DelayInfo {
        var delay = 0
        var platform: String?

        // Delay: span with class color-firebrick
        if let delayClassRange = html.range(of: "class=\"color-firebrick\"", options: .caseInsensitive) {
            let snippet = html[delayClassRange.upperBound...]
            if let closing = snippet.firstIndex(of: "<") {
                let text = String(snippet[..<closing])
                let components = text.components(separatedBy: CharacterSet.decimalDigits.inverted)
                if let first = components.first(where: { !$0.isEmpty }),
                   let parsed = Int(first) {
                    delay = parsed
                }
            }
        }

        // Platform: search first "Linia " occurrence in list item
        if let liRange = html.range(of: "li class=\"list-group-item\"", options: .caseInsensitive) {
            let liSnippet = html[liRange.lowerBound...]
            if let liniaRange = liSnippet.range(of: "Linia ", options: .caseInsensitive) {
                let suffix = liSnippet[liniaRange.upperBound...]
                let components = suffix.components(separatedBy: .whitespacesAndNewlines)
                if let candidate = components.first {
                    let sanitized = candidate.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
                    if !sanitized.isEmpty {
                        platform = sanitized
                    }
                }
            }
        }

        print("✅ Parsed Delay=\(delay) Platform=\(platform ?? "N/A")")
        return DelayInfo(delayMinutes: delay, platform: platform)
    }
}

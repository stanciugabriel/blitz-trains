import UIKit
import UniformTypeIdentifiers

/// A dedicated journey screen with explicit loading, error and saved states.
final class ShareViewController: UIViewController {
    private let status = UILabel()
    private let journeyScroll = UIScrollView()
    private let journeyStack = UIStackView()
    private let message = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let action = UIButton(type: .system)
    private var resolutionTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var resolvedJourney: SharedJourney?
    private var saved = false
    private var requestID = UUID()

    override func loadView() {
        view = UIView()
        view.backgroundColor = .systemGroupedBackground
        let heading = UILabel()
        heading.text = "Add to Blitz"
        heading.font = .preferredFont(forTextStyle: .headline)
        heading.adjustsFontForContentSizeCategory = true
        let subheading = UILabel()
        subheading.text = "SBB Mobile journey"
        subheading.font = .preferredFont(forTextStyle: .caption1)
        subheading.textColor = .secondaryLabel
        let brandText = UIStackView(arrangedSubviews: [heading, subheading])
        brandText.axis = .vertical
        brandText.spacing = 2
        let brandIcon = UILabel()
        brandIcon.text = "SBB"
        brandIcon.textColor = .white
        brandIcon.font = .systemFont(ofSize: 13, weight: .bold)
        brandIcon.textAlignment = .center
        brandIcon.backgroundColor = UIColor(red: 0.88, green: 0.08, blue: 0.10, alpha: 1)
        brandIcon.layer.cornerRadius = 19
        brandIcon.layer.masksToBounds = true
        brandIcon.widthAnchor.constraint(equalToConstant: 38).isActive = true
        brandIcon.heightAnchor.constraint(equalToConstant: 38).isActive = true
        let cancel = UIButton(type: .system)
        cancel.setTitle("Cancel", for: .normal)
        cancel.addTarget(self, action: #selector(close), for: .touchUpInside)
        let headerSpacer = UIView()
        let header = UIStackView(arrangedSubviews: [brandIcon, brandText, headerSpacer, cancel])
        header.spacing = 12
        header.alignment = .center
        brandText.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.font = .preferredFont(forTextStyle: .subheadline)
        status.numberOfLines = 0
        status.accessibilityIdentifier = "shareStatus"
        let progress = UIStackView(arrangedSubviews: [spinner, status])
        progress.spacing = 10
        progress.alignment = .center
        journeyScroll.backgroundColor = .clear
        journeyScroll.alwaysBounceVertical = true
        journeyScroll.accessibilityIdentifier = "sharedJourneyDetails"
        journeyStack.axis = .vertical
        journeyStack.spacing = 10
        journeyStack.translatesAutoresizingMaskIntoConstraints = false
        journeyScroll.addSubview(journeyStack)
        NSLayoutConstraint.activate([
            journeyStack.topAnchor.constraint(equalTo: journeyScroll.contentLayoutGuide.topAnchor),
            journeyStack.bottomAnchor.constraint(equalTo: journeyScroll.contentLayoutGuide.bottomAnchor),
            journeyStack.leadingAnchor.constraint(equalTo: journeyScroll.contentLayoutGuide.leadingAnchor),
            journeyStack.trailingAnchor.constraint(equalTo: journeyScroll.contentLayoutGuide.trailingAnchor),
            journeyStack.widthAnchor.constraint(equalTo: journeyScroll.frameLayoutGuide.widthAnchor)
        ])
        message.font = .preferredFont(forTextStyle: .body)
        message.textColor = .secondaryLabel
        message.numberOfLines = 0
        message.textAlignment = .center
        action.configuration = .filled()
        action.tintColor = .systemBlue
        action.configuration?.cornerStyle = .large
        action.configuration?.image = UIImage(systemName: "arrow.down.circle.fill")
        action.configuration?.imagePadding = 8
        action.accessibilityIdentifier = "sharePrimaryAction"
        action.addTarget(self, action: #selector(primaryAction), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [header, progress, journeyScroll, action])
        stack.axis = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            action.heightAnchor.constraint(greaterThanOrEqualToConstant: 50),
            journeyScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180)
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        loadJourney()
    }

    private func loadJourney() {
        resolutionTask?.cancel()
        timeoutTask?.cancel()
        resolvedJourney = nil
        let current = UUID()
        requestID = current
        spinner.startAnimating()
        status.text = "Reading SBB journey…"
        showMessage("Loading all connections from the shared link.")
        action.setTitle("Add journey to Blitz", for: .normal)
        action.isEnabled = false
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self, self.requestID == current else { return }
            self.requestID = UUID()
            self.resolutionTask?.cancel()
            self.showError("Reading the shared journey took too long. Check your connection and try again.")
        }
        resolutionTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let url = await self.sharedSBBURL() else { throw SBBSharedJourneyResolver.Failure.unsupported }
                try Task.checkCancellation()
                let journey = try await SBBSharedJourneyResolver.resolve(url)
                guard !Task.isCancelled, self.requestID == current else { return }
                self.timeoutTask?.cancel()
                self.resolvedJourney = journey
                self.spinner.stopAnimating()
                self.status.text = "\(journey.legs.count) connections · Swiss local time"
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_GB")
                formatter.timeZone = TimeZone(identifier: "Europe/Zurich")
                formatter.dateFormat = "dd MMM yyyy, HH:mm"
                self.showJourney(journey, formatter: formatter)
                self.action.isEnabled = true
            } catch {
                guard !Task.isCancelled, self.requestID == current else { return }
                self.timeoutTask?.cancel()
                self.showError(error.localizedDescription)
            }
        }
    }

    private func showError(_ message: String) {
        spinner.stopAnimating()
        status.text = "Couldn’t add journey"
        showMessage(message)
        action.setTitle("Try Again", for: .normal)
        action.isEnabled = true
    }

    @objc private func primaryAction() {
        if saved { close(); return }
        guard let resolvedJourney else { loadJourney(); return }
        action.isEnabled = false
        do {
            try SharedJourneyInbox().enqueue(resolvedJourney)
            saved = true
            status.text = "Saved for import"
            showMessage("Saved to Blitz. Open Blitz to finish adding this journey.")
            action.isHidden = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
            }
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func showMessage(_ text: String) {
        journeyStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        journeyStack.addArrangedSubview(message)
        message.text = text
        message.isHidden = false
    }

    private func showJourney(_ journey: SharedJourney, formatter: DateFormatter) {
        journeyStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        message.isHidden = true
        for (index, leg) in journey.legs.enumerated() {
            let card = UIView()
            card.backgroundColor = .secondarySystemGroupedBackground
            card.layer.cornerRadius = 16
            card.layer.borderWidth = 0.5
            card.layer.borderColor = UIColor.separator.withAlphaComponent(0.35).cgColor

            let number = UILabel()
            number.text = "\(index + 1)"
            number.font = .systemFont(ofSize: 12, weight: .bold)
            number.textColor = .white
            number.textAlignment = .center
            number.backgroundColor = .systemBlue
            number.layer.cornerRadius = 12
            number.layer.masksToBounds = true
            number.widthAnchor.constraint(equalToConstant: 24).isActive = true
            number.heightAnchor.constraint(equalToConstant: 24).isActive = true

            let service = UILabel()
            service.text = leg.service
            service.font = .systemFont(ofSize: 15, weight: .semibold)
            service.textColor = .label
            let route = UILabel()
            route.text = "\(leg.origin.name)  →  \(leg.destination.name)"
            route.font = .preferredFont(forTextStyle: .body)
            route.numberOfLines = 0
            let times = UILabel()
            times.text = "\(formatter.string(from: leg.departure))  ·  \(formatter.string(from: leg.arrival))"
            times.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            times.textColor = .secondaryLabel

            let copy = UIStackView(arrangedSubviews: [service, route, times])
            copy.axis = .vertical
            copy.spacing = 5
            let row = UIStackView(arrangedSubviews: [number, copy])
            row.alignment = .top
            row.spacing = 10
            row.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(row)
            NSLayoutConstraint.activate([
                row.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
                row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
                row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
                row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14)
            ])
            journeyStack.addArrangedSubview(card)
        }
    }

    @objc private func close() {
        requestID = UUID()
        resolutionTask?.cancel()
        timeoutTask?.cancel()
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    private func sharedSBBURL() async -> URL? {
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        // Prefer the full link over a thumbnail, and accept host-provided text.
        for type in [UTType.url.identifier, UTType.plainText.identifier, UTType.text.identifier] {
            for provider in providers where provider.hasItemConformingToTypeIdentifier(type) {
                guard !Task.isCancelled else { return nil }
                if let text = await loadText(provider, type: type), let url = findURL(text) { return url }
            }
        }
        for item in items {
            if let text = item.attributedContentText?.string, let url = findURL(text) { return url }
        }
        return nil
    }

    private func findURL(_ text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url)
            .first { $0.scheme == "https" && $0.host?.lowercased() == "a.sbbmobile.ch" }
    }

    private func loadText(_ provider: NSItemProvider, type: String) async -> String? {
        await withCheckedContinuation { continuation in
            let pending = PendingTextLoad(continuation)
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                let text = (item as? URL)?.absoluteString ?? (item as? String)
                    ?? (item as? NSAttributedString)?.string
                    ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
                Task { @MainActor in pending.finish(text) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { pending.finish(nil) }
        }
    }
}

@MainActor
private final class PendingTextLoad {
    private var continuation: CheckedContinuation<String?, Never>?
    init(_ continuation: CheckedContinuation<String?, Never>) { self.continuation = continuation }
    func finish(_ text: String?) {
        continuation?.resume(returning: text)
        continuation = nil
    }
}

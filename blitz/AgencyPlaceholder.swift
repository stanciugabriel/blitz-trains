import SwiftUI

struct AgencyBadge: View {
    let agencyId: String?

    var body: some View {
        let entry = Self.registry[agencyId ?? ""] ?? Self.defaultEntry
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(entry.background)
            .frame(width: 48, height: 48)
            .overlay(
                Group {
                    if let imageName = entry.symbol {
                        Image(systemName: imageName)
                            .font(.system(size: 24))
                    } else if let text = entry.initials {
                        Text(text)
                            .font(.headline)
                    }
                }
                .foregroundStyle(entry.foreground)
            )
    }

    private struct Entry {
        let background: Color
        let foreground: Color
        let symbol: String?
        let initials: String?
    }

    private static let defaultEntry = Entry(
        background: Color.gray.opacity(0.1),
        foreground: .primary,
        symbol: "train.side.front.car.fill",
        initials: nil
    )

    private static let registry: [String: Entry] = [
        "6100826": Entry(background: Color.blue.opacity(0.8), foreground: .white, symbol: "tram.fill", initials: nil),
        "237330": Entry(background: Color.purple.opacity(0.8), foreground: .white, symbol: "sparkles", initials: nil),
        "906090": Entry(background: Color.green.opacity(0.8), foreground: .white, symbol: "leaf.fill", initials: nil),
        "236037": Entry(background: Color.orange.opacity(0.8), foreground: .white, symbol: "bus.fill", initials: nil),
        "227098": Entry(background: Color.teal.opacity(0.8), foreground: .white, symbol: "bolt.fill", initials: nil),
        "236025": Entry(background: Color.indigo.opacity(0.8), foreground: .white, symbol: "waveform", initials: nil),
        "228389": Entry(background: Color.pink.opacity(0.8), foreground: .white, symbol: "hexagon.fill", initials: nil)
    ]
}

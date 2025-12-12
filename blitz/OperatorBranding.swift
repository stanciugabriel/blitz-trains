import SwiftUI


struct OperatorBranding {
    let logoName: String
    let phoneNumber: String?
    let city: String?
}

enum OperatorBrandingCatalog {
    private static let fallback = OperatorBranding(logoName: "cfr", phoneNumber: nil, city: "Bucharest")

    private static let entries: [String: OperatorBranding] = [
        "6100826": OperatorBranding(logoName: "cfr", phoneNumber: "+40213190358", city: "Bucharest"),
        "227098": OperatorBranding(logoName: "regio", phoneNumber: "+40310800900", city: "Brașov"),
        "236025": OperatorBranding(logoName: "softrans", phoneNumber: "+40742018798", city: "Craiova"),
        "200000": OperatorBranding(logoName: "astra", phoneNumber: "+40751525520", city: "Bucharest"),
        "228389": OperatorBranding(logoName: "tfc", phoneNumber: "+40238434380", city: "Bucharest"),
        "236037": OperatorBranding(logoName: "interregional", phoneNumber: "+40364140245", city: "Cluj-Napoca")
    ]

    static func branding(for agencyId: String?) -> OperatorBranding {
        guard let agencyId else { return fallback }
        return entries[agencyId] ?? fallback
    }

    static func city(for agencyId: String?) -> String? {
        branding(for: agencyId).city
    }
}

struct OperatorLogoView: View {
    let logoName: String?
    var size: CGFloat = 40

    private var cornerRadius: CGFloat {
        max(8, size * 0.25)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        Group {
            if let logoName, UIImage(named: logoName) != nil {
                Image(logoName)
                    .resizable()
                    .scaledToFit()
                    .clipShape(shape)
            } else {
                ZStack {
                    shape.fill(Color(.systemGray5))
                    Image(systemName: "train.side.front.car")
                        .font(.system(size: size * 0.45))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

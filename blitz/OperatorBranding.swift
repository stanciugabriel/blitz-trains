import SwiftUI


struct OperatorBranding {
    let logoName: String
    let phoneNumber: String?
    let city: String?
}

enum OperatorBrandingCatalog {
    private static let fallback = OperatorBranding(logoName: "", phoneNumber: nil, city: "Switzerland")

    private static let entries: [String: OperatorBranding] = [
        "11": OperatorBranding(logoName: "sbb", phoneNumber: "0848 44 66 88", city: "Switzerland"),
        "351": OperatorBranding(logoName: "sbb", phoneNumber: nil, city: "Switzerland"),
        "L7____": OperatorBranding(logoName: "sbb", phoneNumber: nil, city: "Switzerland"),
        "33": OperatorBranding(logoName: "bls", phoneNumber: nil, city: "Switzerland"),
        "65": OperatorBranding(logoName: "thurbo", phoneNumber: nil, city: "Switzerland"),
        "23": OperatorBranding(logoName: "tpc", phoneNumber: nil, city: "Switzerland"),
        "32": OperatorBranding(logoName: "jungfrau", phoneNumber: nil, city: "Switzerland"),
        "35": OperatorBranding(logoName: "jungfrau", phoneNumber: nil, city: "Switzerland"),
        "157": OperatorBranding(logoName: "jungfrau", phoneNumber: nil, city: "Switzerland"),
        "124": OperatorBranding(logoName: "jungfrau", phoneNumber: nil, city: "Switzerland"),
        "140": OperatorBranding(logoName: "jungfrau", phoneNumber: nil, city: "Switzerland"),
        "78": OperatorBranding(logoName: "szu", phoneNumber: nil, city: "Switzerland"),
        "72": OperatorBranding(logoName: "rhb", phoneNumber: nil, city: "Switzerland"),
        "97": OperatorBranding(logoName: "travys", phoneNumber: nil, city: "Switzerland"),
        "96": OperatorBranding(logoName: "aargau-verkehr", phoneNumber: nil, city: "Switzerland"),
        "31": OperatorBranding(logoName: "aargau-verkehr", phoneNumber: nil, city: "Switzerland"),
        "82": OperatorBranding(logoName: "sob", phoneNumber: "+41 585 807 777", city: "Switzerland")
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

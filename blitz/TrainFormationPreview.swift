import SwiftUI

/// A visual prototype. These vehicles and identifiers are illustrative, and
/// are deliberately independent of the selected trip and any network service.
struct TrainFormationPreview: View {
    let formation: PlatformFormation
    let isSample: Bool
    init(formation: PlatformFormation = .sample, isSample: Bool = true) {
        self.formation = formation
        self.isSample = isSample
    }
    private var displayedVehicles: [FormationVehicle] {
        formation.vehicles
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Train Formation")
                    .font(.system(size: 20, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(displayedVehicles) { vehicle in
                            vehicleColumn(vehicle)
                        }
                    }
                    if formation.sectors != nil {
                        sectorStrip
                    }
                }
                .padding(.vertical, 4)
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .scrollIndicators(.hidden)
            .defaultScrollAnchor(.leading)
            .environment(\.layoutDirection, .leftToRight)
        }
        .padding(.vertical, 16)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.75)
        }
    }

    private func vehicleColumn(_ vehicle: FormationVehicle) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            vehicleArtwork(vehicle)
                .frame(height: 116, alignment: .bottom)
                .accessibilityLabel("\(vehicle.position) side profile")

            HStack(spacing: 4) {
                Text(vehicle.position)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(vehicle.isLocked ? Color.gray.opacity(0.42) : Color(red: 1, green: 0.78, blue: 0),
                                in: RoundedRectangle(cornerRadius: 4))
                Text(vehicle.operatorName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(vehicle.type)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            FormationFlowLayout(spacing: 4) {
                ForEach(vehicle.classes, id: \.self) { coachClass in
                    FormationBadge(title: "Class \(coachClass)", symbol: nil,
                                   text: coachClass, isClass: true, isLocked: vehicle.isLocked)
                }
                if let seats = vehicle.firstClassSeats, seats > 0 {
                    FormationCountBadge(symbol: "airplaneseat", value: seats, title: "First-class seats", isLocked: vehicle.isLocked)
                }
                if let seats = vehicle.secondClassSeats, seats > 0 {
                    FormationCountBadge(symbol: "airplaneseat", value: seats, title: "Second-class seats", isLocked: vehicle.isLocked)
                }
                if let bikes = vehicle.bikeSeats, bikes > 0 {
                    FormationCountBadge(symbol: "bicycle", value: bikes, title: "Bike spaces", isLocked: vehicle.isLocked)
                }
                if let wheelchairs = vehicle.wheelchairSeats, wheelchairs > 0 {
                    FormationCountBadge(symbol: "figure.roll", value: wheelchairs, title: "Wheelchair spaces", isLocked: vehicle.isLocked)
                }
                ForEach(vehicle.features) { feature in
                    FormationBadge(title: feature.title, symbol: feature.symbol, text: nil,
                                   isClass: false, isLocked: vehicle.isLocked)
                }
            }

            if let evn = vehicle.evn, !evn.isEmpty {
                Text(evn)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .frame(width: vehicle.displayWidth, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func vehicleArtwork(_ vehicle: FormationVehicle) -> some View {
        // Both PNGs use the same 251px height. A shared scale keeps rooflines,
        // wheels and gangways aligned without adding gaps or stretching a cab.
        // This supplied cab faces right; mirroring it is explicitly supported.
        let suppliedAsset = vehicle.artworkName ?? (vehicle.isCab ? "loco" : "car")
        let directionalAsset = vehicle.facesRight ? vehicle.rightArtwork : vehicle.leftArtwork
        Image(directionalAsset ?? suppliedAsset)
            .resizable()
            .scaledToFit()
            .frame(width: vehicle.displayWidth, alignment: .bottom)
            .scaleEffect(x: vehicle.isCab && vehicle.mirrorsArtwork && !vehicle.facesRight && directionalAsset == nil ? -1 : 1, y: 1)
    }

    private func sectorSlices(for vehicle: FormationVehicle) -> [FormationSectorSlice] {
        let slices = formation.sectors?[vehicle.id] ?? []
        return slices
    }

    // Merge adjacent slices into a single continuous sector, irrespective of
    // coach edges. The bar width shows where a sector crosses a coach.
    private var sectorSpans: [(label: String, width: CGFloat)] {
        var spans: [(label: String, width: CGFloat)] = []
        for vehicle in displayedVehicles {
            let slices = sectorSlices(for: vehicle)
            for slice in slices.isEmpty ? [FormationSectorSlice(label: "—", fraction: 1)] : slices {
                let width = vehicle.displayWidth * slice.fraction
                if spans.last?.label == slice.label {
                    spans[spans.count - 1].width += width
                } else {
                    spans.append((slice.label, width))
                }
            }
        }
        return spans
    }

    private var sectorStrip: some View {
        HStack(spacing: 0) {
            ForEach(Array(sectorSpans.enumerated()), id: \.offset) { _, sector in
                Text(sector.label)
                    .font(.system(.caption, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Color(red: 0.08, green: 0.32, blue: 0.78), in: RoundedRectangle(cornerRadius: 5))
                    .frame(width: sector.width)
                    .padding(.vertical, 5)
                    .background(Color(.secondarySystemBackground))
                    .accessibilityLabel("Platform sector \(sector.label)")
            }
        }
    }
}

private struct FormationFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += (x > 0 ? spacing : 0) + size.width
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private struct FormationSilhouette: Shape {
    let isCab: Bool

    func path(in rect: CGRect) -> Path {
        guard isCab else { return Path(roundedRect: rect, cornerRadius: 7) }
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 7, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - 32, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - 26, y: rect.minY + 5),
                          control: CGPoint(x: rect.maxX - 28, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - 2, y: rect.maxY - 7))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - 7, y: rect.maxY),
                          control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + 7, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - 7),
                          control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + 7))
        path.addQuadCurve(to: CGPoint(x: rect.minX + 7, y: rect.minY),
                          control: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// Scoped to one boarding stop and one platform-view orientation. Providers
/// must normalize their own order/orientation here, including reversals en route.
/// Sector assignments travel with the vehicle when the viewing side changes.
struct PlatformFormation {
    let vehicles: [FormationVehicle] // Front to rear, never sorted by coach label.
    let track: String?
    let sectors: [Int: [FormationSectorSlice]]?

    static let sample = Self(vehicles: FormationVehicle.samples, track: "7",
                             sectors: [1: [.init(label: "A", fraction: 1)],
                                       2: [.init(label: "A", fraction: 0.5), .init(label: "B", fraction: 0.5)],
                                       3: [.init(label: "B", fraction: 0.3), .init(label: "C", fraction: 0.7)],
                                       4: [.init(label: "C", fraction: 1)]])
}

/// Fractions are schematic sample positions, not surveyed platform distances.
/// Real assignments need explicit offsets; multiple sector names alone do not
/// imply that the boundary is halfway through a vehicle.
struct FormationSectorSlice {
    let label: String
    let fraction: CGFloat
}


private struct FormationBadge: View {
    let title: String
    let symbol: String?
    let text: String?
    let isClass: Bool
    let isLocked: Bool
    @State private var showsHint = false

    var body: some View {
        Button { showsHint.toggle() } label: {
            Group {
                if let symbol {
                    Image(systemName: symbol)
                } else {
                    Text(text ?? "")
                }
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(isLocked ? Color.gray.opacity(0.72) : .white)
            .frame(width: 28, height: 28)
            .background(isLocked ? Color.gray.opacity(0.22) : (isClass ? Color(red: 0.06, green: 0.16, blue: 0.3)
                        : Color(red: 30.0 / 255, green: 100.0 / 255, blue: 250.0 / 255)),
                        in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .popover(isPresented: $showsHint, arrowEdge: .bottom) {
            Text(title)
                .font(.subheadline)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .presentationCompactAdaptation(.popover)
        }
    }
}

private struct FormationCountBadge: View {
    let symbol: String
    let value: Int
    let title: String
    let isLocked: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            Text("\(value)")
                .minimumScaleFactor(0.65)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(isLocked ? Color.gray.opacity(0.72) : .white)
        .padding(.horizontal, 5)
        .frame(minWidth: 28)
        .frame(height: 28)
        .fixedSize(horizontal: true, vertical: false)
        .background(isLocked ? Color.gray.opacity(0.22) : Color(red: 30.0 / 255, green: 100.0 / 255, blue: 250.0 / 255),
                    in: RoundedRectangle(cornerRadius: 5))
        .accessibilityLabel("\(title): \(value)")
    }
}

struct FormationVehicle: Identifiable {
    let id: Int
    let position: String
    let classes: [String]
    let type: String
    let evn: String?
    let isCab: Bool
    let artworkName: String?
    let mirrorsArtwork: Bool
    /// The supplied locomotive artwork faces right. This flag describes the
    /// physical facing of a control cab in the consist.
    let facesRight: Bool
    let isLocked: Bool
    let features: [FormationFeature]
    let firstClassSeats: Int?
    let secondClassSeats: Int?
    let bikeSeats: Int?
    let wheelchairSeats: Int?
    var operatorName = "SBB"
    var displayWidth: CGFloat { CGFloat(isCab ? 1097 : 1006) * 0.26 }
    var leftArtwork: String? = nil
    var rightArtwork: String? = nil

    static let samples: [Self] = [
        .init(id: 1, position: "Car 1", classes: ["1"], type: "RABe 526",
              evn: "93 85 1501 224-4", isCab: true, artworkName: nil, mirrorsArtwork: true, facesRight: true, isLocked: false,
              features: [.airConditioning, .wifi, .power, .quiet], firstClassSeats: 41, secondClassSeats: nil, bikeSeats: nil, wheelchairSeats: nil),
        .init(id: 2, position: "Car 2", classes: ["2"], type: "RABe 526",
              evn: "93 85 0501 002-8", isCab: false, artworkName: nil, mirrorsArtwork: true, facesRight: true, isLocked: false,
              features: [.airConditioning, .restaurant, .wifi], firstClassSeats: nil, secondClassSeats: 80, bikeSeats: nil, wheelchairSeats: nil),
        .init(id: 3, position: "Car 3", classes: ["2"], type: "RABe 526",
              evn: "93 85 0501 003-6", isCab: false, artworkName: nil, mirrorsArtwork: true, facesRight: true, isLocked: false,
              features: [.airConditioning, .accessible, .power, .wifi], firstClassSeats: nil, secondClassSeats: 80, bikeSeats: nil, wheelchairSeats: 2),
        .init(id: 4, position: "Car 4", classes: ["2"], type: "RABe 526",
              evn: "93 85 0501 004-4", isCab: true, artworkName: nil, mirrorsArtwork: true, facesRight: true, isLocked: false,
              features: [.airConditioning, .bicycle, .power], firstClassSeats: nil, secondClassSeats: 70, bikeSeats: 8, wheelchairSeats: nil)
    ]
}

enum FormationFeature: String, Identifiable {
    case airConditioning, restaurant, wifi, power, accessible, bicycle, quiet
    case closed, lowFloor, toilet, family, business, stroller, baggage
    case reservedBicycle, luggage, sleeping, couchette
    var id: String { rawValue }
    var title: String {
        switch self {
        case .closed: "Closed coach"
        case .lowFloor: "Low-floor boarding"
        case .toilet: "Accessible toilet"
        case .family: "Family zone"
        case .business: "Business zone"
        case .stroller: "Stroller spaces"
        case .baggage: "Baggage coach"
        case .reservedBicycle: "Bicycle reservation required"
        case .luggage: "Luggage space"
        case .sleeping: "Sleeping compartments"
        case .couchette: "Couchette compartments"
        case .airConditioning: "Air conditioning"
        case .restaurant: "Restaurant"
        case .wifi: "Wi-Fi"
        case .power: "Power outlets"
        case .accessible: "Wheelchair access"
        case .bicycle: "Bicycle spaces"
        case .quiet: "Quiet zone"
        }
    }
    var symbol: String {
        switch self {
        case .closed: "lock"
        case .lowFloor: "arrow.down.to.line"
        case .toilet: "toilet"
        case .family: "figure.2.and.child.holdinghands"
        case .business: "briefcase"
        case .stroller: "stroller"
        case .baggage: "suitcase"
        case .reservedBicycle: "bicycle.circle"
        case .luggage: "luggage.cart"
        case .sleeping: "bed.double"
        case .couchette: "bed.double.fill"
        case .airConditioning: "snowflake"
        case .restaurant: "fork.knife"
        case .wifi: "wifi"
        case .power: "powerplug"
        case .accessible: "figure.roll"
        case .bicycle: "bicycle"
        case .quiet: "speaker.slash"
        }
    }
    var detail: String { "This symbol marks \(title.lowercased()) on this coach. This formation is sample data." }
}

#Preview {
    ScrollView {
        TrainFormationPreview().padding()
    }
}

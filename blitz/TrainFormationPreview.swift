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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Train Formation")
                    .font(.system(size: 20, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(displayedVehicles.indices, id: \.self) { index in
                            vehicleColumn(displayedVehicles[index])
                                .padding(.trailing, gap(after: index))
                        }
                    }
                    if formation.sectors != nil {
                        sectorStrip
                    }
                }
                .padding(.vertical, 2)
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
                .frame(height: 76, alignment: .bottom)
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
                if vehicle.classes.contains("1") || (vehicle.firstClassSeats ?? 0) > 0 {
                    FormationBadge(title: "First class", symbol: nil,
                                   text: "1", isClass: true, isLocked: vehicle.isLocked)
                }
                if vehicle.classes.contains("2") || (vehicle.secondClassSeats ?? 0) > 0 {
                    FormationBadge(title: "Second class", symbol: nil,
                                   text: "2", isClass: true, isLocked: vehicle.isLocked)
                }
                let seatCount = max(0, vehicle.firstClassSeats ?? 0) + max(0, vehicle.secondClassSeats ?? 0)
                if seatCount > 0 {
                    FormationSeatBadge(seatCount: seatCount, isLocked: vehicle.isLocked)
                }
                if let bikes = vehicle.bikeSeats, bikes > 0 {
                    FormationCountBadge(symbol: "bicycle", value: bikes, title: "Bike spaces", isLocked: vehicle.isLocked)
                }
                if let wheelchairs = vehicle.wheelchairSeats, wheelchairs > 0 {
                    FormationCountBadge(symbol: "figure.roll", value: wheelchairs, title: "Wheelchair spaces", isLocked: vehicle.isLocked)
                }
                ForEach(vehicle.features.filter { feature in
                    !(feature == .bicycle && (vehicle.bikeSeats ?? 0) > 0)
                        && !(feature == .accessible && (vehicle.wheelchairSeats ?? 0) > 0)
                }) { feature in
                    FormationBadge(title: feature.title, symbol: feature.symbol, text: nil,
                                   isClass: false, isLocked: vehicle.isLocked)
                }
            }

            if let evn = vehicle.evn, !evn.isEmpty {
                Text(evn)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .frame(width: vehicle.displayWidth, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private func vehicleArtwork(_ vehicle: FormationVehicle) -> some View {
        // Use the same FLIRT artwork for every formation so the preview stays
        // visually consistent even when the provider reports a different
        // vehicle model. The control-cab asset is selected for cab vehicles;
        // the existing consist-facing calculation supplies the mirror.
        let assetName = vehicle.isCab ? "flirt-cc-f" : "flirt-c-f"
        return Image(assetName)
            .resizable()
            .scaledToFit()
            .scaleEffect(x: vehicle.facesRight ? -1 : 1, y: 1)
            .opacity(vehicle.isLocked ? 0.58 : 1)
            .frame(width: vehicle.displayWidth, height: 68)
    }

    private func gap(after _: Int) -> CGFloat {
        // The FLIRT artwork includes the complete vehicle edge, so adjacent
        // cars should meet directly on the same track.
        0
    }

    private func sectorSlices(for vehicle: FormationVehicle) -> [FormationSectorSlice] {
        let slices = formation.sectors?[vehicle.id] ?? []
        return slices
    }

    // Merge adjacent slices into a single continuous sector, irrespective of
    // coach edges. The bar width shows where a sector crosses a coach.
    private var sectorSpans: [(label: String, width: CGFloat)] {
        var spans: [(label: String, width: CGFloat)] = []
        for (index, vehicle) in displayedVehicles.enumerated() {
            let slices = sectorSlices(for: vehicle)
            let visibleSlices = slices.isEmpty ? [FormationSectorSlice(label: "—", fraction: 1)] : slices
            for (sliceIndex, slice) in visibleSlices.enumerated() {
                let width = vehicle.displayWidth * slice.fraction
                    + (sliceIndex == visibleSlices.count - 1 ? gap(after: index) : 0)
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
    let isLocomotive: Bool
    let facesRight: Bool

    func path(in rect: CGRect) -> Path {
        guard isCab || isLocomotive else {
            return Path(roundedRect: rect, cornerRadius: 12)
        }
        let sweptLeft = isLocomotive || !facesRight
        let sweptRight = isLocomotive || facesRight
        let radius: CGFloat = 12
        let sweep: CGFloat = 34
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + (sweptLeft ? sweep : radius), y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - (sweptRight ? sweep : radius), y: rect.minY))
        if sweptRight {
            path.addQuadCurve(to: CGPoint(x: rect.maxX - 25, y: rect.minY + 7),
                              control: CGPoint(x: rect.maxX - 27, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - 2, y: rect.maxY - radius))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
                              control: CGPoint(x: rect.maxX, y: rect.maxY))
        } else {
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + radius),
                              control: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
                              control: CGPoint(x: rect.maxX, y: rect.maxY))
        }
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        if sweptLeft {
            path.addQuadCurve(to: CGPoint(x: rect.minX + 2, y: rect.maxY - radius),
                              control: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + 25, y: rect.minY + 7))
            path.addQuadCurve(to: CGPoint(x: rect.minX + sweep, y: rect.minY),
                              control: CGPoint(x: rect.minX + 27, y: rect.minY))
        } else {
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius),
                              control: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
            path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY),
                              control: CGPoint(x: rect.minX, y: rect.minY))
        }
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
            .background(isLocked ? Color.gray.opacity(0.22) : (isClass ? Color(red: 0.08, green: 0.19, blue: 0.54)
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
    @State private var showsHint = false

    var body: some View {
        Button { showsHint.toggle() } label: {
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
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title): \(value)")
        .popover(isPresented: $showsHint, arrowEdge: .bottom) {
            Text("\(value) \(title.lowercased())")
                .font(.subheadline)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .presentationCompactAdaptation(.popover)
        }
    }
}

private struct FormationSeatBadge: View {
    let seatCount: Int
    let isLocked: Bool
    @State private var showsHint = false

    var body: some View {
        Button { showsHint.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "airplaneseat")
                Text("\(seatCount)")
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(isLocked ? Color.gray.opacity(0.72) : .white)
            .padding(.horizontal, 5)
            .frame(minWidth: 28, minHeight: 28)
            .fixedSize(horizontal: true, vertical: false)
            .background(isLocked ? Color.gray.opacity(0.22) : Color(red: 30.0 / 255, green: 100.0 / 255, blue: 250.0 / 255),
                        in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(seatCount) seats")
        .popover(isPresented: $showsHint, arrowEdge: .bottom) {
            Text("\(seatCount) seats")
                .font(.subheadline)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .presentationCompactAdaptation(.popover)
        }
    }
}

struct FormationVehicle: Identifiable {
    let id: Int
    let position: String
    let classes: [String]
    let type: String
    let evn: String?
    let isCab: Bool
    let isLocomotive: Bool
    /// Physical facing of a control cab in the consist.
    let facesRight: Bool
    let isLocked: Bool
    let features: [FormationFeature]
    let firstClassSeats: Int?
    let secondClassSeats: Int?
    let bikeSeats: Int?
    let wheelchairSeats: Int?
    let operatorName: String
    // Both FLIRT assets are 275 px tall. Use one shared display height and
    // preserve each asset's intrinsic aspect ratio, so neither car is scaled
    // independently just to fit an arbitrary column width.
    var displayWidth: CGFloat {
        let artworkHeight: CGFloat = 68
        return isCab ? artworkHeight * 1200 / 275 : artworkHeight * 1102 / 275
    }

    static let samples: [Self] = [
        .init(id: 1, position: "Car 1", classes: ["1"], type: "RABe 526",
              evn: "93 85 1501 224-4", isCab: true, isLocomotive: false, facesRight: false, isLocked: false,
              features: [.airConditioning, .wifi, .power, .quiet], firstClassSeats: 41, secondClassSeats: nil, bikeSeats: nil, wheelchairSeats: nil,
              operatorName: "SBB"),
        .init(id: 2, position: "Car 2", classes: ["2"], type: "RABe 526",
              evn: "93 85 0501 002-8", isCab: false, isLocomotive: false, facesRight: true, isLocked: false,
              features: [.airConditioning, .restaurant, .wifi], firstClassSeats: nil, secondClassSeats: 80, bikeSeats: nil, wheelchairSeats: nil,
              operatorName: "SBB"),
        .init(id: 3, position: "Car 3", classes: ["2"], type: "RABe 526",
              evn: "93 85 0501 003-6", isCab: false, isLocomotive: false, facesRight: true, isLocked: false,
              features: [.airConditioning, .accessible, .power, .wifi], firstClassSeats: nil, secondClassSeats: 80, bikeSeats: nil, wheelchairSeats: 2,
              operatorName: "SBB"),
        .init(id: 4, position: "Car 4", classes: ["2"], type: "RABe 526",
              evn: "93 85 0501 004-4", isCab: true, isLocomotive: false, facesRight: true, isLocked: false,
              features: [.airConditioning, .bicycle, .power], firstClassSeats: nil, secondClassSeats: 70, bikeSeats: 8, wheelchairSeats: nil,
              operatorName: "SBB")
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

struct TrainFormationPreview_Previews: PreviewProvider {
    static var previews: some View {
        ScrollView {
            TrainFormationPreview().padding()
        }
    }
}

import Foundation
import Testing
@testable import blitz

struct FormationArtworkCatalogTests {
    private func artwork(_ evn: String, _ type: String? = nil, emucAvailable: Bool = true) -> FormationArtworkCatalog.Selection {
        FormationArtworkCatalog.select(evn: evn, typeCodeName: type) {
            $0 == "emuc-default" && emucAvailable
        }
    }

    @Test func evnIdentifiesEmuAndControlCab() {
        #expect(FormationArtworkCatalog.modelCode(from: "94 85 1 512 021-0") == "512")
        #expect(artwork("94 85 1 512 021-0", "B").name == "c-default")
        #expect(artwork("94 85 1 512 021-0", "Bt").name == "emuc-default")
        #expect(artwork("94 85 1 512 021-0", "Bt", emucAvailable: false).name == "cc-default")
    }

    @Test func evnIdentifiesDeckHeightAndTypeCodeDeterminesCab() {
        #expect(FormationArtworkCatalog.modelCode(from: "50 85 86-94 025-8") == "86-94")
        #expect(artwork("50 85 86-94 025-8", "B").name == "dd-default")
        #expect(artwork("50 85 86-94 025-8", "Bt").name == "ddcc-default")
        #expect(artwork("50 85 86-33 025-8").name == "ddcc-default")
        #expect(artwork("50 85 86-33 025-8", "B").name == "dd-default")
        #expect(artwork("50 85 10-90 025-8", "Bt").name == "cc-default")
    }

    @Test func specificArtworkPrecedesLocomotiveDefault() {
        #expect(artwork("91 85 4 460 021-0", "Re460").name == "re460")
        #expect(artwork("91 85 4 460 021-0", "Re460").mirrorsArtwork == false)
        #expect(artwork("91 85 4 460 021-0").name == "re460")
        #expect(artwork("91 85 4 420 021-0", "Re420").name == "el-default")
    }

    @Test func fourDigitSeriesAndParenthesizedT() {
        #expect(FormationArtworkCatalog.modelCode(from: "93 85 1501 224-4") == "501")
        #expect(artwork("93 85 1501 224-4", "Bt(2E)Fam").name == "emuc-default")
        #expect(artwork("50 85 28-94 025-8", "B(t)").name == "c-default")
    }

    @Test func coupledEmuCabsFaceEachOtherOnTrain865() {
        let vehicles: [(position: Int, evn: String?)] = [
            (1, "94 85 2 502 013-7"),   // car 18, first cab of unit 013
            (8, "94 85 1 502 013-9"),   // car 11, last cab of unit 013
            (9, "94 85 2 502 020-2"),   // car 8, first cab of unit 020
            (16, "94 85 1 502 020-4")   // car 1, last cab of unit 020
        ]
        #expect(FormationArtworkCatalog.unitCabFacesRight(evn: vehicles[0].evn, position: 1, among: vehicles) == false)
        #expect(FormationArtworkCatalog.unitCabFacesRight(evn: vehicles[1].evn, position: 8, among: vehicles) == true)
        #expect(FormationArtworkCatalog.unitCabFacesRight(evn: vehicles[2].evn, position: 9, among: vehicles) == false)
        #expect(FormationArtworkCatalog.unitCabFacesRight(evn: vehicles[3].evn, position: 16, among: vehicles) == true)

        let normal = artwork("94 85 3 502 020-0", "B3(502)")
        let control = artwork("94 85 2 502 020-2", "Bt2(502)Fam")
        let artworks = [control, normal, normal, normal, normal, normal, normal,
                        control, control,
                        normal, normal, normal, normal, normal, normal, control]
        #expect(FormationArtworkCatalog.controlCabFacesRight(at: 0, among: artworks) == false)
        #expect(FormationArtworkCatalog.controlCabFacesRight(at: 7, among: artworks) == true)
        #expect(FormationArtworkCatalog.controlCabFacesRight(at: 8, among: artworks) == false)
        #expect(FormationArtworkCatalog.controlCabFacesRight(at: 15, among: artworks) == true)
        #expect(FormationArtworkCatalog.controlCabFacesRight(at: 6, among: artworks) == nil)
    }

    @Test func specificDirectionalArtworkFollowsCabDirectionWithoutMirroring() {
        let directional = FormationArtworkCatalog.select(
            evn: "94 85 1 502 013-9", typeCodeName: "ADt1(502)",
            hasAsset: { ["502-left", "502-right"].contains($0) }
        )
        #expect(directional.assetName(facesRight: false) == "502-left")
        #expect(directional.assetName(facesRight: true) == "502-right")
        #expect(directional.mirrorsArtwork == false)
        let normal = artwork("94 85 3 502 020-0", "B3(502)")
        let coupled = [normal, directional, directional, normal]
        #expect(FormationArtworkCatalog.controlCabFacesRight(at: 1, among: coupled) == true)
        #expect(FormationArtworkCatalog.controlCabFacesRight(at: 2, among: coupled) == false)
        let ends = [directional, normal, directional]
        #expect(FormationArtworkCatalog.controlCabFacesRight(at: 0, among: ends) == false)
        #expect(FormationArtworkCatalog.controlCabFacesRight(at: 2, among: ends) == true)

        let unsuffixed = FormationArtworkCatalog.select(
            evn: "94 85 1 502 013-9", typeCodeName: "ADt1(502)",
            hasAsset: { $0 == "502" }
        )
        #expect(unsuffixed.assetName(facesRight: false) == "502")
        #expect(unsuffixed.assetName(facesRight: true) == "502")
        #expect(unsuffixed.mirrorsArtwork == false)
    }

    @Test func flippableSpecificArtworkUsesFormationDirection() {
        let flippable = FormationArtworkCatalog.select(
            evn: "94 85 1 502 013-9", typeCodeName: "ADt1(502)",
            hasAsset: { $0 == "502-f" || $0 == "502" }
        )
        #expect(flippable.assetName(facesRight: false) == "502-f")
        #expect(flippable.assetName(facesRight: true) == "502-f")
        #expect(flippable.mirrorsArtwork == true)

        let directional = FormationArtworkCatalog.select(
            evn: "94 85 1 502 013-9", typeCodeName: "ADt1(502)",
            hasAsset: { ["502-left", "502-right", "502-f"].contains($0) }
        )
        #expect(directional.assetName(facesRight: true) == "502-right")
        #expect(directional.mirrorsArtwork == false)
    }

    @Test func flirtModelsUseFlippableCarAndControlCarArtwork() {
        for model in ["521", "522", "523", "524", "526", "528"] {
            let evn = "94 85 1 \(model) 021-0"
            let assets: (String) -> Bool = { ["flirt-c-f", "flirt-cc-f"].contains($0) }
            let car = FormationArtworkCatalog.select(evn: evn, typeCodeName: "B3(\(model))", hasAsset: assets)
            let cab = FormationArtworkCatalog.select(evn: evn, typeCodeName: "Bt2(\(model))", hasAsset: assets)
            #expect(car.name == "flirt-c-f")
            #expect(cab.name == "flirt-cc-f")
            #expect(car.mirrorsArtwork && cab.mirrorsArtwork)
            #expect(FormationArtworkCatalog.displayType(evn: evn, typeCodeName: "Bt2(\(model))") == "RABe \(model)")
        }
        #expect(FormationArtworkCatalog.displayType(evn: "94 85 1 502 013-9", typeCodeName: "ADt1(502)") == "ADt1")
        #expect(FormationArtworkCatalog.displayType(evn: "94 85 1 502 013-9", typeCodeName: "Bt2(502)Fam") == "Bt2Fam")

        let specific = FormationArtworkCatalog.select(
            evn: "94 85 1 521 021-0", typeCodeName: "Bt2(521)",
            hasAsset: { ["521-f", "flirt-c-f", "flirt-cc-f"].contains($0) }
        )
        #expect(specific.name == "521-f")
    }

    @Test @MainActor func formationUsesPassedAgencyName() throws {
        let json = """
        {"formations":[{"formationVehicles":[{"position":1,"number":1,
          "vehicleIdentifier":{"evn":"94 85 1 523 021-0","typeCodeName":"Bt2(523)"}}]}]}
        """
        let response = try JSONDecoder().decode(FormationResponse.self, from: Data(json.utf8))
        let formation = try response.formation(boardingUIC: nil, boardingName: nil, operatorName: "BLS AG")
        #expect(formation?.vehicles.first?.operatorName == "BLS AG")
        #expect(formation?.vehicles.first?.type == "RABe 523")
    }
}

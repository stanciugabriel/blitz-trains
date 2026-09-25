import Foundation

protocol StaticPlatformProviding {
    func platform(trainId: String, stationId: String) -> String?
}

final class StaticPlatformDataSource: StaticPlatformProviding {
    static let shared = StaticPlatformDataSource()
    private init() {}

    func platform(trainId: String, stationId: String) -> String? {
        GTFSDataSource.shared.platform(trainId: trainId, stationId: stationId)
    }
}

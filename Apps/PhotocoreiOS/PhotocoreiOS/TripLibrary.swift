import CoreLocation
import Foundation
import Observation
import Photos
import PhotoEngineApple
import PhotoEngineCore

/// A trip found in the camera roll, ready to show on the home screen.
struct TripSummary: Identifiable, Hashable, Sendable {
    var id: String
    var start: Date
    var end: Date
    var photoCount: Int
    var days: Int
    var coverIdentifier: String
    var coverLatitude: Double?
    var coverLongitude: Double?
    var place: String?

    var dates: String {
        let formatter = DateIntervalFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: start, to: end)
    }

    /// "Lisbon" when the photos say where, otherwise the dates.
    var title: String { place ?? dates }

    var subtitle: String {
        let dayWord = days == 1 ? "1 day" : "\(days) days"
        return (place == nil ? "" : dates + " · ") + "\(dayWord) · \(photoCount) photos"
    }
}

/// Reads the camera roll's capture dates and turns them into trips. Only dates are
/// read here; pixels are read when a trip is opened.
@MainActor
@Observable
final class TripLibrary {
    enum Access: Equatable {
        case unknown, granted, limited, denied
    }

    private(set) var access: Access = .unknown
    private(set) var trips: [TripSummary] = []
    private(set) var isLoading = false

    func start() async {
        let status = await PhotoLibraryIngest.requestAccess()
        switch status {
        case .authorized: access = .granted
        case .limited: access = .limited
        case .denied, .restricted: access = .denied
        default: access = .unknown
        }
        guard access == .granted || access == .limited else { return }
        await reload()
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        trips = await Task.detached(priority: .userInitiated) { Self.scanTrips() }.value
        // Name trips by place where the cover photo has a location. One lookup per
        // area, cached on disk, done after the list is already on screen.
        for index in trips.indices {
            guard let lat = trips[index].coverLatitude, let lon = trips[index].coverLongitude else { continue }
            let names = await PlaceNamer.shared.names(for: [(lat, lon)])
            if let place = names.values.first {
                trips[index].place = place.locality ?? place.name
            }
        }
    }

    nonisolated static func scanTrips() -> [TripSummary] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        var dates: [Date] = []
        var identifiers: [String] = []
        var locations: [CLLocationCoordinate2D?] = []
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in
            guard let date = asset.creationDate, !asset.mediaSubtypes.contains(.photoScreenshot) else { return }
            dates.append(date)
            identifiers.append(asset.localIdentifier)
            locations.append(asset.location?.coordinate)
        }
        return TripDetector.detect(dates: dates).map { trip in
            TripSummary(
                id: trip.id,
                start: trip.start,
                end: trip.end,
                photoCount: trip.photoCount,
                days: trip.days,
                coverIdentifier: identifiers[trip.coverIndex],
                coverLatitude: locations[trip.coverIndex]?.latitude,
                coverLongitude: locations[trip.coverIndex]?.longitude
            )
        }
    }
}

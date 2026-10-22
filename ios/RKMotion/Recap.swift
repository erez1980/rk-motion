import Foundation
import CoreLocation
import Photos

/// A movie made from the photo library by itself: the latest trip, the last
/// month or this year. The videos and photos are chosen spread over the
/// days, favourites first, and become one project like any other.
enum Recap {
    enum Span: String, CaseIterable, Identifiable {
        case trip, month, year
        var id: String {rawValue}
        var title: String {
            switch self {
            case .trip: return NSLocalizedString("הטיול האחרון", comment: "Recap span: the latest trip")
            case .month: return NSLocalizedString("החודש האחרון", comment: "Recap span: the last 30 days")
            case .year: return NSLocalizedString("השנה", comment: "Recap span: this calendar year")
            }
        }
        var detail: String {
            switch self {
            case .trip: return NSLocalizedString("אמצא ימים רצופים עם הרבה צילומים, רחוק מהבית", comment: "Recap span detail: trip")
            case .month: return NSLocalizedString("הרגעים של 30 הימים האחרונים", comment: "Recap span detail: month")
            case .year: return NSLocalizedString("קטעים מכל חודש מתחילת השנה", comment: "Recap span detail: year")
            }
        }
        var symbol: String {
            switch self {
            case .trip: return "airplane"
            case .month: return "calendar"
            case .year: return "sparkles"
            }
        }
        /// How many videos and photos the movie takes, and what they are spread over.
        var limits: (videos: Int, photos: Int, spread: Calendar.Component) {
            switch self {
            case .trip, .month: return (14, 8, .day)
            case .year: return (18, 8, .month)
            }
        }
    }

    /// One video or photo of the library, as the choice needs it.
    struct Item: Equatable {
        var id: String
        var date: Date
        var video: Bool
        var duration: Double = 0
        var favorite = false
        var place: CLLocationCoordinate2D?
        static func == (a: Item, b: Item) -> Bool {
            a.id == b.id && a.date == b.date && a.video == b.video && a.duration == b.duration && a.favorite == b.favorite
                && a.place?.latitude == b.place?.latitude && a.place?.longitude == b.place?.longitude
        }
    }

    /// A day counts towards a trip with this many shots; a trip needs this many in all.
    static let busyDay = 3, tripShots = 12
    /// How far from home a trip's shots must mostly be, when the library knows where they were taken.
    static let awayMeters = 40_000.0

    /// Where most shots were taken, to a few kilometres; nil when few have a place.
    static func home(_ items: [Item]) -> CLLocationCoordinate2D? {
        let placed = items.compactMap(\.place)
        guard placed.count >= max(5, items.count / 4) else {return nil}
        func cell(_ place: CLLocationCoordinate2D) -> [Int] {[Int((place.latitude * 5).rounded()), Int((place.longitude * 5).rounded())]}
        let counts = Dictionary(grouping: placed, by: cell)
        guard let top = counts.max(by: {$0.value.count < $1.value.count || ($0.value.count == $1.value.count && $0.key.lexicographicallyPrecedes($1.key))})?.value else {return nil}
        return CLLocationCoordinate2D(latitude: top.map(\.latitude).reduce(0, +) / Double(top.count), longitude: top.map(\.longitude).reduce(0, +) / Double(top.count))
    }
    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude).distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
    /// The runs of busy days, at most one quiet day apart, with enough shots
    /// to be a trip and, when places are known, taken mostly away from home.
    static func trips(_ items: [Item], calendar: Calendar = .current) -> [DateInterval] {
        let byDay = Dictionary(grouping: items) {calendar.startOfDay(for: $0.date)}
        let busy = byDay.filter {$0.value.count >= busyDay}.keys.sorted()
        var runs: [[Date]] = []
        for day in busy {
            if let last = runs.last?.last, let gap = calendar.dateComponents([.day], from: last, to: day).day, gap <= 2 {runs[runs.count - 1].append(day)}
            else {runs.append([day])}
        }
        let base = home(items)
        return runs.compactMap {days -> DateInterval? in
            let shots = days.flatMap {byDay[$0] ?? []}
            guard days.count >= 2, shots.count >= tripShots,
                  let end = calendar.date(byAdding: .day, value: 1, to: days.last!) else {return nil}
            if let base {
                let away = shots.compactMap(\.place).map {distance($0, base)}.sorted()
                if !away.isEmpty, away[away.count / 2] < awayMeters {return nil}
            }
            return DateInterval(start: days[0], end: end)
        }
    }
    /// The stretch of time `span` covers, from `now` back.
    static func interval(_ span: Span, now: Date, items: [Item], calendar: Calendar = .current) -> DateInterval? {
        switch span {
        case .trip: return trips(items, calendar: calendar).last
        case .month: return calendar.date(byAdding: .day, value: -30, to: now).map {DateInterval(start: $0, end: now)}
        case .year: return calendar.dateInterval(of: .year, for: now).map {DateInterval(start: $0.start, end: now)}
        }
    }
    /// How far back the library is read for `span`.
    static func earliest(_ span: Span, now: Date, calendar: Calendar = .current) -> Date {
        switch span {
        case .trip: return calendar.date(byAdding: .day, value: -365, to: now) ?? now
        case .month: return calendar.date(byAdding: .day, value: -30, to: now) ?? now
        case .year: return calendar.dateInterval(of: .year, for: now)?.start ?? now
        }
    }
    /// Up to `videos` videos and `photos` photos, taken in turn from each
    /// day (or month) so the whole stretch shows; within one, favourites
    /// first, then videos of a usable length, then the longest. In the order taken.
    static func choose(_ items: [Item], videos: Int, photos: Int, spread: Calendar.Component, calendar: Calendar = .current) -> [Item] {
        func usable(_ item: Item) -> Bool {item.duration >= 3 && item.duration <= 300}
        func pick(_ pool: [Item], limit: Int, rank: (Item, Item) -> Bool) -> [Item] {
            let buckets = Dictionary(grouping: pool) {calendar.dateInterval(of: spread, for: $0.date)?.start ?? $0.date}
            var queues = buckets.keys.sorted().map {buckets[$0]!.sorted(by: rank)}
            var chosen: [Item] = []
            while chosen.count < limit, queues.contains(where: {!$0.isEmpty}) {
                for index in queues.indices where chosen.count < limit && !queues[index].isEmpty {chosen.append(queues[index].removeFirst())}
            }
            return chosen
        }
        func videoFirst(_ a: Item, _ b: Item) -> Bool {
            if a.favorite != b.favorite {return a.favorite}
            if usable(a) != usable(b) {return usable(a)}
            if a.duration != b.duration {return a.duration > b.duration}
            return a.id < b.id
        }
        func photoFirst(_ a: Item, _ b: Item) -> Bool {
            if a.favorite != b.favorite {return a.favorite}
            if a.date != b.date {return a.date < b.date}
            return a.id < b.id
        }
        let clips = pick(items.filter(\.video), limit: videos, rank: videoFirst)
        let stills = pick(items.filter {!$0.video}, limit: photos, rank: photoFirst)
        return (clips + stills).sorted {$0.date != $1.date ? $0.date < $1.date : $0.id < $1.id}
    }
    /// The project's name: the trip's dates, or the span.
    static func name(_ span: Span, interval: DateInterval) -> String {
        switch span {
        case .trip:
            let format = DateIntervalFormatter()
            format.dateStyle = .medium; format.timeStyle = .none
            let last = interval.end.addingTimeInterval(-1)
            return String(format: NSLocalizedString("טיול · %@", comment: "Recap project name: a trip and its dates"), format.string(from: interval.start, to: last))
        case .month: return NSLocalizedString("סיכום החודש", comment: "Recap project name: the last month")
        case .year:
            let year = Calendar.current.component(.year, from: interval.start)
            return String(format: NSLocalizedString("סיכום %@", comment: "Recap project name: a year"), String(year))
        }
    }

    // MARK: The photo library

    /// Every video and photo since `date`, screenshots left out, with the asset each came from.
    static func library(since date: Date) -> (items: [Item], assets: [String: PHAsset]) {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate >= %@", date as NSDate)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let found = PHAsset.fetchAssets(with: options)
        var items: [Item] = [], assets: [String: PHAsset] = [:]
        found.enumerateObjects {asset, _, _ in
            guard asset.mediaType == .video || asset.mediaType == .image, !asset.mediaSubtypes.contains(.photoScreenshot),
                  let created = asset.creationDate else {return}
            items.append(Item(id: asset.localIdentifier, date: created, video: asset.mediaType == .video, duration: asset.duration,
                              favorite: asset.isFavorite, place: asset.location?.coordinate))
            assets[asset.localIdentifier] = asset
        }
        return (items, assets)
    }
    /// Copies the chosen videos out of the library and turns the photos
    /// into moving ones, into `folder`, in the order given. iCloud ones download.
    static func export(_ items: [Item], assets: [String: PHAsset], into folder: URL,
                       progress: @escaping (Double, String) async -> Void) async throws -> [URL] {
        var made: [URL] = []
        do {
            for (index, item) in items.enumerated() {
                try Task.checkCancellation()
                guard let asset = assets[item.id] else {continue}
                let text = String(format: NSLocalizedString("מביא מהגלריה %@ מתוך %@…", comment: "Copying recap items out of the photo library"), "\(index + 1)", "\(items.count)")
                await progress(Double(index) / Double(max(1, items.count)), text)
                if item.video {
                    let resources = PHAssetResource.assetResources(for: asset)
                    guard let resource = resources.first(where: {$0.type == .fullSizeVideo}) ?? resources.first(where: {$0.type == .video}) else {continue}
                    let ext = (resource.originalFilename as NSString).pathExtension
                    let target = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext.isEmpty ? "mov" : ext)
                    made.append(target)
                    let options = PHAssetResourceRequestOptions()
                    options.isNetworkAccessAllowed = true
                    try await withCheckedThrowingContinuation {(done: CheckedContinuation<Void, Error>) in
                        PHAssetResourceManager.default().writeData(for: resource, toFile: target, options: options) {error in
                            if let error {done.resume(throwing: error)} else {done.resume()}
                        }
                    }
                } else {
                    let options = PHImageRequestOptions()
                    options.isNetworkAccessAllowed = true; options.version = .current; options.deliveryMode = .highQualityFormat
                    let data: Data? = await withCheckedContinuation {done in
                        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) {data, _, _, _ in done.resume(returning: data)}
                    }
                    guard let data else {continue}
                    let target = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
                    made.append(target)
                    try await PhotoMotion.makeVideo(from: data, to: target)
                }
            }
        } catch {
            for url in made {try? FileManager.default.removeItem(at: url)}
            throw error
        }
        return made
    }
}

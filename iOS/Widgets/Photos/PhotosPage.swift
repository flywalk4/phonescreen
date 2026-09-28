import Photos
import SwiftUI
import UIKit

/// Photo frame: the iPhone's Favorites (or the latest photos if there are none) as a slideshow with a slow
/// Ken Burns drift and a crossfade. Photos never leave the phone. Tap to go to the next one.
struct PhotosPage: View {
    @StateObject private var library = PhotoLibrary()
    @Environment(\.widgetSize) private var size
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geo in
            ZStack {
                switch library.state {
                case .loading:
                    ThemedSpinner()
                case .denied:
                    message("Нет доступа к фото", "Разрешите PhoneScreen доступ в Настройках → Конфиденциальность → Фото")
                case .empty:
                    message("Нет фото", "Добавьте снимки в «Избранное» — они появятся здесь")
                case .ready:
                    if let image = library.image {
                        KenBurns(image: image, seed: library.index)
                            .id(library.index)
                            .transition(.opacity)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipShape(RoundedRectangle(cornerRadius: size == .full ? theme.radius : 0, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                if let caption = library.caption, size != .small {
                    Text(caption)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(12)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { library.next() }
            .pointerTarget { library.next() }
            .task(id: geo.size) { await library.start(target: geo.size) }
        }
        .padding(size == .full ? 8 : -14) // edge to edge inside a card; a little margin on a whole page
    }

    private func message(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 8) {
            Glyph("photo.on.rectangle.angled").font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding()
    }
}

/// A photo that slowly zooms and pans (a different direction for each photo).
private struct KenBurns: View {
    let image: UIImage
    let seed: Int
    @State private var moved = false

    var body: some View {
        let dx: CGFloat = seed % 2 == 0 ? 18 : -18, dy: CGFloat = seed % 3 == 0 ? 12 : -12
        ThemedPicture(image: image)
            .scaleEffect(moved ? 1.12 : 1.02)
            .offset(x: moved ? dx : -dx, y: moved ? dy : -dy)
            .onAppear { withAnimation(.easeInOut(duration: PhotoLibrary.interval + 2)) { moved = true } }
    }
}

@MainActor
final class PhotoLibrary: ObservableObject {
    enum State { case loading, denied, empty, ready }

    static let interval: TimeInterval = 9

    @Published private(set) var state = State.loading
    @Published private(set) var image: UIImage?
    @Published private(set) var caption: String?
    @Published private(set) var index = 0

    private var assets: PHFetchResult<PHAsset>?
    private var target = CGSize(width: 400, height: 400)
    private var timer: Timer?
    /// Off for a still picture (the theme's photo background): no timer.
    private let slideshow: Bool

    init(slideshow: Bool = true) { self.slideshow = slideshow }

    func start(target size: CGSize) async {
        target = CGSize(width: size.width * UIScreen.main.scale, height: size.height * UIScreen.main.scale)
        #if DEBUG
        // Demo screenshots don't stop at the system prompt (it would cover every page); `--demo-photos` asks anyway.
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--demo"), !args.contains("--demo-photos"),
           PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined { state = .denied; return }
        #endif
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { state = .denied; return }
        assets = Self.fetch()
        guard let assets, assets.count > 0 else { state = .empty; return }
        index = Int.random(in: 0..<assets.count)
        await show()
        guard slideshow else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.next() }
        }
    }

    func next() {
        guard let assets, assets.count > 0 else { return }
        index = (index + 1) % assets.count
        Task { await show() }
    }

    /// Favorites; without any, the 200 latest photos.
    private static func fetch() -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        let favorites = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumFavorites, options: nil)
        if let album = favorites.firstObject {
            let result = PHAsset.fetchAssets(in: album, options: options)
            if result.count > 0 { return result }
        }
        options.fetchLimit = 200
        return PHAsset.fetchAssets(with: options)
    }

    private func show() async {
        guard let assets, assets.count > index else { return }
        let asset = assets.object(at: index)
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast
        let loaded: UIImage? = await withCheckedContinuation { done in
            PHImageManager.default().requestImage(for: asset, targetSize: target, contentMode: .aspectFill, options: options) { image, _ in
                done.resume(returning: image)
            }
        }
        guard let loaded else { return }
        withAnimation(.easeInOut(duration: 1.2)) {
            image = loaded
            caption = asset.creationDate.map { $0.formatted(.dateTime.day().month(.wide).year()) }
            state = .ready
        }
    }
}

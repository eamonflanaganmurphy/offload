import OffloadCore
import QuickLook
import QuickLookThumbnailing
import SwiftUI

/// The card's photos and videos by day, marked with what Immich already has.
/// Tap to pick; with nothing picked, Upload sends everything new.
struct CardView: View {
    @Environment(CardStore.self) private var card
    @Environment(Uploader.self) private var uploader
    @State private var filter = CardStore.Filter.all
    @State private var preview: URL?

    private let columns = [GridItem(.adaptive(minimum: 86), spacing: 2)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                summary
                Picker("Show", selection: $filter) {
                    ForEach(CardStore.Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            .padding(.horizontal)
            .padding(.top, 8)

            LazyVGrid(columns: columns, spacing: 2, pinnedViews: [.sectionHeaders]) {
                ForEach(card.sections(filter)) { section in
                    Section {
                        ForEach(section.files) { file in
                            cell(file)
                        }
                    } header: {
                        header(section)
                    }
                }
            }
            if card.files.isEmpty && !card.scanning {
                ContentUnavailableView("No Photos or Videos", systemImage: "photo.on.rectangle.angled",
                                       description: Text("Nothing on this card that Immich can take."))
            }
        }
        .refreshable { await card.scan() }
        .safeAreaInset(edge: .bottom) { UploadBar() }
        .quickLookPreview($preview)
    }

    // MARK: -

    @ViewBuilder private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            if card.scanning {
                Label("Reading the card…", systemImage: "sdcard")
            } else {
                Text("\(card.files.count) photos and videos · \(card.totalBytes.bytes)")
                    .font(.headline)
            }
            let counts = card.counts
            if card.checking {
                ProgressView(value: Double(card.checkedCount), total: Double(max(card.files.count, 1))) {
                    Text("Checking with Immich… \(card.checkedCount) of \(card.files.count)")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            } else if !card.files.isEmpty {
                Text("\(counts.new) not in Immich · \(counts.inImmich) already there")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if let album = card.albumName {
                Label(album, systemImage: "rectangle.stack")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let error = card.error {
                HStack {
                    Text(error).font(.footnote).foregroundStyle(.red)
                    Spacer()
                    Button("Try Again") { card.startCheck() }.font(.footnote)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func header(_ section: DaySection) -> some View {
        let selectable = card.selectable(in: section)
        let allPicked = !selectable.isEmpty && selectable.allSatisfy { card.selection.contains($0) }
        return HStack {
            Text(section.title).font(.subheadline.weight(.semibold))
            Text("\(section.files.count)").font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            if !selectable.isEmpty {
                Button(allPicked ? "Deselect" : "Select") {
                    if allPicked { card.selection.subtract(selectable) } else { card.selection.formUnion(selectable) }
                }
                .font(.subheadline)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func cell(_ file: CardFile) -> some View {
        let state = card.state(of: file)
        let selected = card.selection.contains(file.rel)
        return Color(.secondarySystemBackground)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let root = card.root {
                    Thumbnail(url: file.url(in: root), key: file.cacheKey)
                }
            }
            .clipped()
            .overlay { if selected { Color.black.opacity(0.25) } }
            .overlay(alignment: .bottomLeading) { kindBadge(file) }
            .overlay(alignment: .topTrailing) {
                StatusBadge(state: state, selected: selected, picking: !card.selection.isEmpty)
                    .padding(5)
            }
            .opacity(state.isInImmich ? 0.6 : 1)
            .contentShape(Rectangle())
            .onTapGesture { card.toggle(file) }
            .contextMenu {
                if let root = card.root {
                    Button { preview = file.url(in: root) } label: { Label("Preview", systemImage: "eye") }
                }
                if case let .failed(message) = state {
                    Text(message)
                }
            } preview: {
                if let root = card.root {
                    Thumbnail(url: file.url(in: root), key: file.cacheKey + "-large", size: 600, fill: false)
                        .frame(width: 300, height: 300)
                }
            }
            .accessibilityLabel(file.name)
    }

    @ViewBuilder private func kindBadge(_ file: CardFile) -> some View {
        let isVideo = card.types.isVideo(file.ext)
        let isRaw = MediaTypes.raw.contains(file.ext)
        if isVideo || isRaw {
            HStack(spacing: 3) {
                if isVideo { Image(systemName: "video.fill") }
                if isRaw { Text("RAW").fontWeight(.bold) }
            }
            .font(.system(size: 10))
            .foregroundStyle(.white)
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
            .padding(4)
        }
    }
}

struct StatusBadge: View {
    let state: FileState
    let selected: Bool
    let picking: Bool

    var body: some View {
        Group {
            switch state {
            case .inImmich:
                Image(systemName: "checkmark.icloud.fill").foregroundStyle(.white)
            case .uploaded:
                Image(systemName: "checkmark.icloud.fill").foregroundStyle(.green)
            case .unsupported:
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.orange)
            case .queued:
                Image(systemName: "clock.fill").foregroundStyle(.white)
            case let .reading(p):
                Ring(progress: p, color: .yellow)
            case let .uploading(p):
                Ring(progress: p, color: .accentColor)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            case .new, .unchecked:
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                } else if picking {
                    Image(systemName: "circle").foregroundStyle(.white)
                }
            }
        }
        .font(.system(size: 20))
        .shadow(color: .black.opacity(0.5), radius: 2)
    }
}

struct Ring: View {
    let progress: Double
    let color: Color

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.5), lineWidth: 3)
            Circle().trim(from: 0, to: max(0.03, progress))
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 18, height: 18)
        .background(Circle().fill(.black.opacity(0.35)))
    }
}

/// A thumbnail made by Quick Look, which reads the preview embedded in a RAW or
/// a frame from a video rather than decoding the whole file.
struct Thumbnail: View {
    let url: URL
    let key: String
    var size: CGFloat = 180
    var fill = true
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                if fill {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(uiImage: image).resizable().scaledToFit()
                }
            }
        }
        .task(id: key) {
            image = await ThumbnailLoader.shared.load(url, key: key, size: size)
        }
    }
}

@MainActor
final class ThumbnailLoader {
    static let shared = ThumbnailLoader()
    private let cache = NSCache<NSString, UIImage>()

    func load(_ url: URL, key: String, size: CGFloat) async -> UIImage? {
        if let hit = cache.object(forKey: key as NSString) { return hit }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                                   scale: 2, representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        cache.setObject(rep.uiImage, forKey: key as NSString)
        return rep.uiImage
    }
}

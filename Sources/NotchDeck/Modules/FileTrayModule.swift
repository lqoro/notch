import SwiftUI
import AppKit
import Observation
import QuickLookThumbnailing
import UniformTypeIdentifiers

struct TrayItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var bookmark: Data
    var name: String
}

@MainActor
@Observable
final class FileTrayModule: NotchModule {
    let id = "filetray"
    let title = "File Tray"
    let icon = "tray.full"
    let priority = 90

    private(set) var items: [TrayItem] = []
    @ObservationIgnored private var urlCache: [UUID: URL] = [:]
    @ObservationIgnored private(set) var thumbs: [UUID: NSImage] = [:]
    var thumbVersion = 0
    @ObservationIgnored private weak var state: NotchState?

    private var storeURL: URL { AppPaths.supportDirectory.appendingPathComponent("tray.json") }

    func start(state: NotchState) {
        self.state = state
        load()
    }

    var isCompactActive: Bool { false }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([TrayItem].self, from: data) else { return }
        items = decoded
        var kept: [TrayItem] = []
        for var item in items {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: item.bookmark, options: [.withSecurityScope],
                                     relativeTo: nil, bookmarkDataIsStale: &stale) else { continue }
            _ = url.startAccessingSecurityScopedResource()
            if stale, let fresh = try? url.bookmarkData(options: [.withSecurityScope]) { item.bookmark = fresh }
            urlCache[item.id] = url
            kept.append(item)
        }
        items = kept
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: storeURL, options: .atomic) }
    }

    // MARK: Mutations

    func add(providers: [NSItemProvider]) {
        for p in providers {
            _ = p.loadObject(ofClass: URL.self) { [weak self] url, _ in
                guard let url, url.isFileURL else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.add(url: url) } }
            }
        }
    }

    func add(url: URL) {
        if urlCache.values.contains(url) { return }
        guard let bm = try? url.bookmarkData(options: [.withSecurityScope]) else { return }
        _ = url.startAccessingSecurityScopedResource()
        let item = TrayItem(bookmark: bm, name: url.lastPathComponent)
        urlCache[item.id] = url
        items.append(item)
        save()
    }

    func remove(_ item: TrayItem) {
        urlCache[item.id]?.stopAccessingSecurityScopedResource()
        urlCache[item.id] = nil
        thumbs[item.id] = nil
        items.removeAll { $0 == item }
        save()
    }

    func clear() { for i in items { remove(i) } }

    func url(for item: TrayItem) -> URL? { urlCache[item.id] }

    func thumbnail(for item: TrayItem) -> NSImage? {
        if let t = thumbs[item.id] { return t }
        guard let url = urlCache[item.id] else { return nil }
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 64, height: 64),
                                               scale: NSScreen.main?.backingScaleFactor ?? 2,
                                               representationTypes: .thumbnail)
        let itemID = item.id
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
            guard let img = rep?.nsImage else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.thumbs[itemID] = img
                    self?.thumbVersion += 1
                }
            }
        }
        return nil
    }

    func markDraggingOut() { state?.isDraggingOut = true }

    func expandedView() -> AnyView { AnyView(FileTrayView(module: self)) }
}

struct FileTrayView: View {
    let module: FileTrayModule

    var body: some View {
        let _ = module.thumbVersion
        if module.items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray.and.arrow.down").font(.system(size: 28)).foregroundStyle(.white.opacity(0.4))
                Text("Drop files here").font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                Text("Drag them out again anywhere").font(.system(size: 11)).foregroundStyle(.white.opacity(0.3))
            }
            .frame(maxWidth: .infinity, minHeight: 100)
            .background(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.15), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
        } else {
            HStack(spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(module.items) { item in TrayItemView(module: module, item: item) }
                    }
                    .padding(.vertical, 4)
                }
                VStack(spacing: 8) {
                    shareButton
                    Button { module.clear() } label: {
                        Image(systemName: "trash").frame(width: 28, height: 24)
                    }.buttonStyle(.plain).help("Clear tray (files are not deleted)")
                }
                .foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    private var shareButton: some View {
        Button {
            let urls = module.items.compactMap { module.url(for: $0) }
            if let airdrop = NSSharingService(named: .sendViaAirDrop), airdrop.canPerform(withItems: urls) {
                airdrop.perform(withItems: urls)
            }
        } label: { Image(systemName: "airplayaudio").frame(width: 28, height: 24) }
        .buttonStyle(.plain).help("AirDrop all")
    }
}

struct TrayItemView: View {
    let module: FileTrayModule
    let item: TrayItem
    @StateObject private var hoverBox = Local(false)
    private var hover: Bool { hoverBox.value }

    var body: some View {
        let url = module.url(for: item)
        VStack(spacing: 5) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let t = module.thumbnail(for: item) {
                        Image(nsImage: t).resizable().aspectRatio(contentMode: .fit)
                    } else if let url {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "doc")
                    }
                }
                .frame(width: 64, height: 64)
                if hover {
                    Button { module.remove(item) } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 14))
                            .foregroundStyle(.white, .black.opacity(0.6))
                    }.buttonStyle(.plain).offset(x: 4, y: -4)
                }
            }
            Text(item.name).font(.system(size: 10)).lineLimit(1).truncationMode(.middle)
                .frame(width: 76).foregroundStyle(.white.opacity(0.75))
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(hover ? 0.1 : 0.05)))
        .onHover { hoverBox.value = $0 }
        .onDrag {
            module.markDraggingOut()
            if let url, let p = NSItemProvider(contentsOf: url) { return p }
            return NSItemProvider(object: (url ?? URL(fileURLWithPath: "/")) as NSURL)
        }
        .contextMenu {
            if let url {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Open") { NSWorkspace.shared.open(url) }
            }
            Button("Remove from tray") { module.remove(item) }
        }
    }
}

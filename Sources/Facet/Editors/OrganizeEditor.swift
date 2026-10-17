import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Reorder (drag), rotate and delete PDF pages, then save a copy.
struct OrganizeEditor: View {
    let url: URL
    let close: () -> Void

    struct Item: Identifiable, Equatable {
        let id = UUID()
        let page: PDFPage
        let number: Int
        var rotation: Int
        var thumbnail: NSImage?

        static func == (a: Item, b: Item) -> Bool { a.id == b.id && a.rotation == b.rotation && (a.thumbnail == nil) == (b.thumbnail == nil) }
    }

    @ViewState private var items: [Item] = []
    @ViewState private var dragging: Item.ID? = nil
    @ViewState private var changed = false

    private let columns = [GridItem(.adaptive(minimum: 120, maximum: 150), spacing: 14)]

    var body: some View {
        EditorChrome(title: "Organize Pages", close: close) {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(items) { item in cell(item) }
                }
                .padding(.vertical, 6)
                .animation(.spring(response: 0.3, dampingFraction: 0.85), value: items.map(\.id))
            }
        } footer: {
            Text("\(items.count) pages · drag to reorder")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            PrimaryButton(title: "Save Copy", disabled: !changed || items.isEmpty) { save() }
        }
        .onAppear(perform: load)
    }

    private func cell(_ item: Item) -> some View {
        let delegate = ReorderDelegate(target: item.id, items: $items, dragging: $dragging, changed: $changed)
        return PageCell(item: item, rotate: { rotate(item.id) }, delete: { delete(item.id) })
            .opacity(dragging == item.id ? 0.35 : 1)
            .onDrag { beginDrag(item) }
            .onDrop(of: [UTType.text], delegate: delegate)
    }

    private func beginDrag(_ item: Item) -> NSItemProvider {
        dragging = item.id
        return NSItemProvider(object: item.id.uuidString as NSString)
    }

    private func load() {
        guard let doc = try? PDFEngine.open(url) else { return }
        items = (0..<doc.pageCount).compactMap { i in
            guard let page = doc.page(at: i) else { return nil }
            return Item(page: page, number: i + 1, rotation: page.rotation, thumbnail: nil)
        }
        let pages = items.map(\.page)
        DispatchQueue.global(qos: .userInitiated).async {
            for (i, page) in pages.enumerated() {
                let thumb = page.thumbnail(of: NSSize(width: 260, height: 260), for: .cropBox)
                DispatchQueue.main.async {
                    if i < items.count, items[i].page === page { items[i].thumbnail = thumb }
                    else if let j = items.firstIndex(where: { $0.page === page }) { items[j].thumbnail = thumb }
                }
            }
        }
    }

    private func rotate(_ id: Item.ID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].rotation = (items[i].rotation + 90) % 360
        changed = true
    }

    private func delete(_ id: Item.ID) {
        items.removeAll { $0.id == id }
        changed = true
    }

    private func save() {
        let pages = items.map { (page: $0.page, rotation: $0.rotation) }
        let url = self.url
        close()
        JobCenter.shared.run("Saving PDF", subtitle: url.lastPathComponent) { _ in
            [try PDFTools.save(pages: pages, source: url)]
        }
    }
}

private struct PageCell: View {
    let item: OrganizeEditor.Item
    let rotate: () -> Void
    let delete: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let thumb = item.thumbnail {
                        Image(nsImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.6))
                            .aspectRatio(0.75, contentMode: .fit)
                    }
                }
                .rotationEffect(.degrees(Double(item.rotation - item.page.rotation)))
                .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                .frame(height: 150)
                .frame(maxWidth: .infinity)

                if hovering {
                    HStack(spacing: 4) {
                        GlassIconButton(symbol: "rotate.right", size: 24, action: rotate)
                        GlassIconButton(symbol: "trash", size: 24, action: delete)
                    }
                    .padding(4)
                    .transition(.opacity)
                }
            }
            Text("\(item.number)")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }
}

private struct ReorderDelegate: DropDelegate {
    let target: UUID
    @Binding var items: [OrganizeEditor.Item]
    @Binding var dragging: UUID?
    @Binding var changed: Bool

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target,
              let from = items.firstIndex(where: { $0.id == dragging }),
              let to = items.firstIndex(where: { $0.id == target }) else { return }
        items.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        changed = true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

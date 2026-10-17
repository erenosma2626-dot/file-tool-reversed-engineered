import AppKit
import SwiftUI

struct ShelfView: View {
    @ObservedObject var model: ShelfModel
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        ZStack {
            if model.expanded {
                ExpandedShelf(model: model)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topLeading)))
            } else {
                CollapsedShelf(model: model)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .facetSurface(RoundedRectangle(cornerRadius: 30, style: .continuous),
                      tint: model.isTargeted ? Tint.subtle : nil)
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(model.isTargeted ? 0.55 : 0), lineWidth: 2)
        }
        .padding(1)
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: model.expanded)
        .animation(.easeOut(duration: 0.15), value: model.isTargeted)
    }
}

/// Close · menu, a stack of thumbnails, and a name pill that opens the full shelf.
private struct CollapsedShelf: View {
    @ObservedObject var model: ShelfModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                GlassIconButton(symbol: "xmark", size: 30) { model.onClose?() }
                Spacer()
                ShelfMenu(model: model)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            Spacer(minLength: 0)
            stack
            Spacer(minLength: 0)

            if !model.items.isEmpty {
                Button { model.expanded = true } label: {
                    HStack(spacing: 4) {
                        Text(model.title)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 12.5, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .frame(maxWidth: 170)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .facetSurface(Capsule(), interactive: true)
                .padding(.bottom, 14)
            }
        }
    }

    @ViewBuilder private var stack: some View {
        if model.items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 28, weight: .light))
                Text("Drop files here")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .frame(width: 140, height: 110)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
            }
        } else {
            let top = Array(model.items.suffix(3))
            ZStack {
                ForEach(Array(top.enumerated()), id: \.element.id) { i, item in
                    ThumbnailView(item: item, size: 96)
                        .rotationEffect(.degrees(top.count == 1 ? 0 : Double(i - (top.count - 1)) * -5))
                        .offset(x: CGFloat(i - (top.count - 1)) * -6)
                }
                if model.items.count > 1 {
                    Text("\(model.items.count)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .facetSurface(Capsule(), tint: Tint.selection)
                        .offset(x: 50, y: -46)
                }
            }
            .frame(width: 150, height: 120)
            .overlay {
                DragSource(urls: { model.items.map(\.url) },
                           preview: { model.items.last?.thumbnail },
                           onClick: { count in
                               if count >= 2, model.items.count == 1 { NSWorkspace.shared.open(model.items[0].url) }
                               else if count == 1 { model.expanded = true }
                           },
                           onEnded: { model.pruneMoved() })
            }
        }
    }
}

private struct ExpandedShelf: View {
    @ObservedObject var model: ShelfModel
    private let columns = [GridItem(.adaptive(minimum: 118, maximum: 140), spacing: 10)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                GlassIconButton(symbol: "chevron.left", size: 32) { model.expanded = false }
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.items.count == 1 ? "1 File" : model.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text(model.totalSize)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                ShelfMenu(model: model)
                HStack(spacing: 0) {
                    layoutButton(.grid, symbol: "square.grid.2x2")
                    layoutButton(.list, symbol: "list.bullet")
                }
                .padding(3)
                .facetSurface(Capsule())
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            ScrollView {
                if model.layout == .grid {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(model.items) { item in ItemTile(item: item, model: model) }
                        RevealTile(model: model)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                } else {
                    LazyVStack(spacing: 2) {
                        ForEach(model.items) { item in ItemRow(item: item, model: model) }
                        Button { reveal(model) } label: {
                            Label("Reveal in Finder", systemImage: "arrow.turn.up.right")
                                .font(.system(size: 12, weight: .medium))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
                }
            }
        }
    }

    private func layoutButton(_ layout: ShelfLayout, symbol: String) -> some View {
        Button { model.layout = layout } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 32, height: 26)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background {
            if model.layout == layout { Capsule().fill(Color.primary.opacity(0.12)) }
        }
    }
}

private struct ItemTile: View {
    @ObservedObject var item: ShelfItem
    let model: ShelfModel
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 6) {
            ThumbnailView(item: item, size: 76)
                .frame(height: 80)
            Text(item.name)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(item.detail)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.07 : 0))
        }
        .overlay { dragSource }
        .overlay(alignment: .topLeading) { removeButton }
    }

    private var dragSource: some View {
        DragSource(urls: { [item.url] },
                   preview: { item.thumbnail },
                   onClick: { count in if count >= 2 { NSWorkspace.shared.open(item.url) } },
                   onHover: { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } },
                   onEnded: { model.pruneMoved() })
    }

    @ViewBuilder private var removeButton: some View {
        if hovering {
            GlassIconButton(symbol: "xmark", size: 20) { model.remove([item.id]) }
                .padding(4)
                .transition(.opacity)
        }
    }
}

private struct ItemRow: View {
    @ObservedObject var item: ShelfItem
    let model: ShelfModel
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            ThumbnailView(item: item, size: 30)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.07 : 0))
        }
        .overlay {
            DragSource(urls: { [item.url] },
                       preview: { item.thumbnail },
                       onClick: { count in if count >= 2 { NSWorkspace.shared.open(item.url) } },
                       onHover: { h in hovering = h },
                       onEnded: { model.pruneMoved() })
        }
        .overlay(alignment: .trailing) {
            if hovering {
                GlassIconButton(symbol: "xmark", size: 20) { model.remove([item.id]) }
                    .padding(.trailing, 8)
            }
        }
    }
}

private struct RevealTile: View {
    let model: ShelfModel

    var body: some View {
        Button { reveal(model) } label: {
            VStack(spacing: 8) {
                Image(systemName: "arrow.turn.up.right")
                    .font(.system(size: 22, weight: .medium))
                    .frame(width: 58, height: 58)
                    .background(Circle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 2))
                    .frame(height: 80)
                Text("Reveal in Finder")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(8)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ShelfMenu: View {
    @ObservedObject var model: ShelfModel

    var body: some View {
        Menu {
            Button("Reveal in Finder") { reveal(model) }
            Button("Copy Paths") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.items.map(\.url.path).joined(separator: "\n"), forType: .string)
            }
            Button("AirDrop") { Actions.perform(.airdrop, urls: model.items.map(\.url), at: NSEvent.mouseLocation) }
            Divider()
            Button("Clear Shelf") { model.remove(Set(model.items.map(\.id))) }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .facetSurface(Circle(), interactive: true)
        .disabled(model.items.isEmpty)
    }
}

private struct ThumbnailView: View {
    @ObservedObject var item: ShelfItem
    let size: CGFloat

    var body: some View {
        Group {
            if let image = item.thumbnail {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.08))
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.22), radius: 5, y: 2)
    }
}

private func reveal(_ model: ShelfModel) {
    let urls = model.items.map(\.url).filter { FileManager.default.fileExists(atPath: $0.path) }
    guard !urls.isEmpty else { return }
    NSWorkspace.shared.activateFileViewerSelecting(urls)
}

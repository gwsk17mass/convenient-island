import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ClipboardHistoryView: View {
    @EnvironmentObject private var store: IslandStore
    @State private var searchText = ""
    @State private var editingItem: ClipboardItem?
    @State private var showingDeleteAllConfirmation = false
    @State private var folderSelection: FolderSelection = .all
    @State private var isSearchVisible = false

    private var columns: [GridItem] {
        switch store.layoutMode(for: .clipboard) {
        case .list: [GridItem(.flexible())]
        case .grid: [GridItem(.adaptive(minimum: 205), spacing: IslandMetrics.gridSpacing)]
        case .icons: [GridItem(.adaptive(minimum: IslandMetrics.compactGridMinimum), spacing: IslandMetrics.compactGridSpacing)]
        }
    }

    private var usesMiniIcons: Bool { store.layoutMode(for: .clipboard) == .icons }

    private var filteredItems: [ClipboardItem] {
        return store.clipboardItems.filter {
            let matchesFolder: Bool
            switch folderSelection {
            case .all: matchesFolder = true
            case .unfiled: matchesFolder = $0.folderID == nil
            case .folder(let id): matchesFolder = $0.folderID == id
            }
            let matchesSearch = searchText.isEmpty
                || $0.text.localizedCaseInsensitiveContains(searchText)
                || ($0.sourceApplication?.localizedCaseInsensitiveContains(searchText) ?? false)
                || $0.resolvedKind.title.localizedCaseInsensitiveContains(searchText)
            return matchesFolder && matchesSearch
        }
    }

    var body: some View {
        VStack(spacing: IslandMetrics.sectionSpacing) {
            HStack(spacing: 10) {
                LayoutModeButton(tab: .clipboard)
                FolderStrip(selection: $folderSelection, tab: .clipboard)
                Spacer(minLength: 8)

                Button {
                    withAnimation(.easeOut(duration: 0.12)) {
                        isSearchVisible.toggle()
                        if !isSearchVisible { searchText = "" }
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(IslandToolbarIconStyle(isActive: isSearchVisible))
                .help("Поиск по буферу")

                Button {
                    if !store.clipboardItems.isEmpty {
                        store.beginInteraction()
                        showingDeleteAllConfirmation = true
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(IslandToolbarIconStyle())
                .disabled(store.clipboardItems.isEmpty)
                .help("Удалить все карточки буфера")
            }

            if isSearchVisible {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.white.opacity(0.4))
                    TextField("Найти текст, ссылку или изображение", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(Capsule().fill(Color.white.opacity(0.055)))
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if filteredItems.isEmpty {
                EmptyIslandState(
                    symbol: "clipboard",
                    title: "Буфер пока пуст",
                    message: "Текст, ссылки и изображения появятся здесь. Нажатие копирует карточку повторно."
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: usesMiniIcons ? IslandMetrics.compactGridSpacing : IslandMetrics.gridSpacing) {
                        ForEach(filteredItems) { item in
                            ClipboardCard(item: item, compact: usesMiniIcons)
                                .onTapGesture { store.copyClipboardItem(item) }
                                .onDrag { dragProvider(for: item) }
                                .contextMenu { contextMenu(for: item) }
                        }
                    }
                    .padding(.vertical, 2)
                    .padding(.horizontal, usesMiniIcons ? 4 : 2)
                }
            }
        }
        .padding(.top, 14)
        .onAppear { store.setPreferredExpandedHeight(500) }
        .overlay(alignment: .bottomTrailing) {
            if store.copiedItemID != nil {
                Label("Скопировано", systemImage: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Capsule().fill(Color.white.opacity(0.19)))
                    .padding(.trailing, 8)
                    .padding(.bottom, 8)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.16), value: store.copiedItemID)
        .confirmationDialog(
            "Очистить буфер островка?",
            isPresented: Binding(
                get: { showingDeleteAllConfirmation },
                set: { isPresented in
                    showingDeleteAllConfirmation = isPresented
                    if !isPresented { store.endInteraction() }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Удалить все (\(store.clipboardItems.count))", role: .destructive) {
                editingItem = nil
                searchText = ""
                store.deleteAllClipboardItems()
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Все сохранённые карточки будут удалены. Текущее содержимое системного буфера обмена не изменится.")
        }
        .sheet(item: $editingItem, onDismiss: store.endInteraction) { item in
            ClipboardEditorSheet(item: item)
                .environmentObject(store)
                .onAppear { store.beginInteraction() }
        }
    }

    @ViewBuilder
    private func contextMenu(for item: ClipboardItem) -> some View {
        if item.resolvedKind != .image {
            Button("Редактировать", systemImage: "pencil") {
                editingItem = item
            }
        } else if let url = store.clipboardImageURL(for: item) {
            Button("Показать в Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        Button(item.isPinned ? "Открепить" : "Закрепить", systemImage: "pin") {
            store.toggleClipboardPin(item)
        }
        MoveToFolderMenu(currentFolderID: item.folderID, tab: .clipboard) { folderID in
            store.moveClipboardItem(item, to: folderID)
        } label: {
            Label("Переместить в папку", systemImage: "folder")
        }
        Divider()
        Button("Удалить", systemImage: "trash", role: .destructive) {
            store.deleteClipboardItem(item)
        }
    }

    private func dragProvider(for item: ClipboardItem) -> NSItemProvider {
        if item.resolvedKind == .image,
           let url = store.clipboardImageURL(for: item),
           let provider = NSItemProvider(contentsOf: url) {
            provider.suggestedName = url.lastPathComponent
            return provider
        }
        return NSItemProvider(object: item.text as NSString)
    }
}

struct ClipboardCard: View {
    @EnvironmentObject private var store: IslandStore
    let item: ClipboardItem
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 9) {
            HStack(spacing: 6) {
                Image(systemName: item.resolvedKind.symbol)
                Text(item.resolvedKind.title)
                Spacer(minLength: 2)
                if item.isPinned {
                    Image(systemName: "pin.fill")
                }
            }
            .font(.system(size: compact ? 9.5 : 10.5, weight: .semibold))
            .foregroundStyle(.white.opacity(0.46))

            cardContent

            Spacer(minLength: 0)

            if compact {
                Text(item.sourceApplication ?? "Буфер")
                    .lineLimit(1)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.40))
            } else {
                Label(item.sourceApplication ?? "Буфер", systemImage: "app.dashed")
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.40))
            }
        }
        .padding(compact ? IslandMetrics.compactCardPadding : IslandMetrics.cardPadding)
        .frame(maxWidth: .infinity, minHeight: compact ? 88 : 126, alignment: .topLeading)
        .islandCardSurface(compact: compact, selected: store.copiedItemID == item.id)
    }

    @ViewBuilder
    private var cardContent: some View {
        if item.resolvedKind == .image {
            if let image = store.clipboardImage(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: compact ? 44 : 66)
                    .clipShape(RoundedRectangle(cornerRadius: compact ? 7 : 8, style: .continuous))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: compact ? 7 : 8).fill(Color.white.opacity(0.04))
                    Image(systemName: "photo.badge.exclamationmark")
                        .foregroundStyle(.white.opacity(0.34))
                }
                .frame(height: compact ? 44 : 66)
            }
        } else {
            Text(item.text)
                .font(.system(size: compact ? 10.5 : 13))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(compact ? 3 : 4)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .textSelection(.disabled)
        }
    }
}

struct ClipboardEditorSheet: View {
    @EnvironmentObject private var store: IslandStore
    @Environment(\.dismiss) private var dismiss
    let item: ClipboardItem
    @State private var text: String

    init(item: ClipboardItem) {
        self.item = item
        _text = State(initialValue: item.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Редактировать карточку")
                .font(.title2.weight(.semibold))
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                Button("Сохранить") {
                    store.updateClipboardItem(item, text: text)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520, height: 360)
    }
}

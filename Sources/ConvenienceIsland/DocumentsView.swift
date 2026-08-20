import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DocumentsView: View {
    @EnvironmentObject private var store: IslandStore
    @State private var folderSelection: FolderSelection = .all
    @State private var selectedItemID: UUID?
    @State private var isChoosingDocuments = false

    private var columns: [GridItem] {
        switch store.layoutMode(for: .documents) {
        case .list: [GridItem(.flexible())]
        case .grid: [GridItem(.adaptive(minimum: IslandMetrics.regularGridMinimum), spacing: IslandMetrics.gridSpacing)]
        case .icons: [GridItem(.adaptive(minimum: IslandMetrics.compactGridMinimum), spacing: IslandMetrics.compactGridSpacing)]
        }
    }

    private var usesMiniIcons: Bool { store.layoutMode(for: .documents) == .icons }

    private var filteredItems: [DocumentItem] {
        store.documents.filter { item in
            switch folderSelection {
            case .all: true
            case .unfiled: item.folderID == nil
            case .folder(let id): item.folderID == id
            }
        }
    }

    var body: some View {
        VStack(spacing: IslandMetrics.sectionSpacing) {
            HStack(spacing: 10) {
                LayoutModeButton(tab: .documents)
                FolderStrip(selection: $folderSelection, tab: .documents)
                Spacer(minLength: 8)
                Button {
                    chooseDocuments()
                } label: {
                    Label("Добавить", systemImage: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 12)
                        .frame(height: IslandMetrics.toolbarControlSize)
                }
                .buttonStyle(IslandToolbarActionStyle())
                .disabled(isChoosingDocuments)
            }

            if filteredItems.isEmpty {
                EmptyIslandState(
                    symbol: "doc.badge.plus",
                    title: "Закрепите нужные документы",
                    message: "Нажмите «Добавить». Островок сохранит ссылку на оригинал и не станет копировать файл."
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: usesMiniIcons ? IslandMetrics.compactGridSpacing : IslandMetrics.gridSpacing) {
                        ForEach(filteredItems) { item in
                            DocumentCard(
                                item: item,
                                isSelected: selectedItemID == item.id,
                                compact: usesMiniIcons,
                                onRemove: {
                                    if selectedItemID == item.id { selectedItemID = nil }
                                }
                            )
                                .gesture(documentTapGesture(for: item))
                        }
                    }
                    .padding(.vertical, 2)
                    .padding(.horizontal, usesMiniIcons ? 4 : 2)
                }
            }

        }
        .padding(.top, 14)
        .onAppear { store.setPreferredExpandedHeight(520) }
    }

    private func chooseDocuments() {
        let panel = NSOpenPanel()
        panel.title = "Выберите документы"
        panel.message = "Выбранные файлы останутся на своих местах. Островок сохранит только ссылки на них."
        panel.prompt = "Добавить"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)

        isChoosingDocuments = true
        store.beginInteraction()
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            Task { @MainActor in
                if response == .OK {
                    store.addDocuments(panel.urls)
                }
                isChoosingDocuments = false
                store.endInteraction()
            }
        }
    }

    private func documentTapGesture(for item: DocumentItem) -> some Gesture {
        TapGesture(count: 2)
            .exclusively(before: TapGesture(count: 1))
            .onEnded { value in
                switch value {
                case .first:
                    store.openDocument(item)
                case .second:
                    selectedItemID = item.id
                }
            }
    }

}

struct DocumentCard: View {
    @EnvironmentObject private var store: IslandStore
    let item: DocumentItem
    let isSelected: Bool
    let compact: Bool
    let onRemove: () -> Void

    private var resolvedURL: URL? { store.resolvedURL(for: item) }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 12) {
            HStack(alignment: .top) {
                Text(fileTypeLabel)
                    .font(.system(size: compact ? 9 : 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(minWidth: compact ? 30 : 38)
                    .frame(height: compact ? 24 : 30)
                    .background(RoundedRectangle(cornerRadius: compact ? 7 : 8).fill(Color.white.opacity(0.085)))

                Spacer(minLength: 4)

                Menu {
                    Button("Открыть", systemImage: "arrow.up.forward.app") {
                        store.openDocument(item)
                    }
                    Button("Редактировать", systemImage: "pencil") {
                        store.openDocument(item)
                    }
                    Button("Показать в Finder", systemImage: "folder") {
                        store.revealDocument(item)
                    }
                    MoveToFolderMenu(currentFolderID: item.folderID, tab: .documents) { folderID in
                        store.moveDocument(item, to: folderID)
                    } label: {
                        Label("Переместить в папку", systemImage: "folder.badge.plus")
                    }
                    Divider()
                    Button("Убрать из островка", systemImage: "minus.circle", role: .destructive) {
                        onRemove()
                        store.removeDocument(item)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.46))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            Text(item.displayName)
                .font(.system(size: compact ? 11 : 13.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(2)
                .truncationMode(.middle)

            Spacer(minLength: 0)

            Button {
                store.revealDocument(item)
            } label: {
                HStack(spacing: 4) {
                    if resolvedURL == nil {
                        Image(systemName: "exclamationmark.triangle")
                    } else {
                        Image(systemName: "folder")
                    }
                    Text(resolvedURL == nil ? "Файл недоступен" : parentFolderName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 2)
                    Image(systemName: "arrow.up.right")
                }
                .font(compact ? .caption2 : .caption)
                .foregroundStyle(.white.opacity(resolvedURL == nil ? 0.58 : 0.42))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(compact ? IslandMetrics.compactCardPadding : IslandMetrics.cardPadding)
        .frame(maxWidth: .infinity, minHeight: compact ? 88 : 126, alignment: .topLeading)
        .islandCardSurface(compact: compact, selected: isSelected)
    }

    private var fileTypeLabel: String {
        let fileExtension = URL(fileURLWithPath: item.displayName).pathExtension
        return fileExtension.isEmpty ? "FILE" : String(fileExtension.prefix(4)).uppercased()
    }

    private var parentFolderName: String {
        URL(fileURLWithPath: item.pathHint).deletingLastPathComponent().lastPathComponent
    }
}

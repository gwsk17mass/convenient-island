import AppKit
import SwiftUI
import UniformTypeIdentifiers

private extension UTType {
    static let islandScreenshotReorder = UTType(
        exportedAs: "app.convenience-island.local.screenshot-reorder",
        conformingTo: .data
    )
}

struct ScreenshotsView: View {
    @EnvironmentObject private var store: IslandStore
    @State private var folderSelection: FolderSelection = .all
    @State private var editingItem: ScreenshotItem?
    @State private var draggedItem: ScreenshotItem?
    @State private var showingDeleteAllConfirmation = false

    private var layoutMode: IslandLayoutMode {
        store.layoutMode(for: .screenshots)
    }

    private var filteredItems: [ScreenshotItem] {
        store.screenshots.filter { item in
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
                LayoutModeButton(tab: .screenshots)
                FolderStrip(selection: $folderSelection, tab: .screenshots)
                Spacer(minLength: 10)

                Button {
                    if !store.screenshots.isEmpty {
                        store.beginInteraction()
                        showingDeleteAllConfirmation = true
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(IslandToolbarIconStyle())
                .disabled(store.screenshots.isEmpty)
                .help("Удалить все снимки")

                VStack(alignment: .trailing, spacing: 6) {
                    Button {
                        store.captureScreenshot()
                    } label: {
                        HStack(spacing: 8) {
                            if store.isCapturing && !store.isSelectingScreenshotArea {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                            } else {
                                Image(systemName: "camera.fill")
                            }
                            Text(store.isCapturing && !store.isSelectingScreenshotArea ? "Снимаю…" : "Снимок")
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .frame(minWidth: 112)
                        .frame(height: IslandMetrics.toolbarControlSize)
                    }
                    .buttonStyle(IslandToolbarActionStyle())
                    .disabled(store.isCapturing)
                    .help("Сделать снимок без островка")

                    Button {
                        store.captureSelectionScreenshot()
                    } label: {
                        HStack(spacing: 8) {
                            if store.isSelectingScreenshotArea {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                            } else {
                                Image(systemName: "crop")
                            }
                            Text(store.isSelectingScreenshotArea ? "Выделение…" : "Обрезать")
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .frame(minWidth: 112)
                        .frame(height: IslandMetrics.toolbarControlSize)
                    }
                    .buttonStyle(IslandToolbarActionStyle())
                    .disabled(store.isCapturing)
                    .help("Выделить область экрана и сохранить её как снимок")
                }
            }

            if layoutMode == .list,
               store.screenCaptureAccess != .granted,
               !filteredItems.isEmpty {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: IslandMetrics.sectionSpacing) {
                        screenCaptureAccessPanel
                        screenshotItemsContent
                    }
                    .padding(.bottom, 8)
                }
            } else {
                screenCaptureAccessPanel
                screenshotItemsContent
            }
        }
        .padding(.top, 14)
        .onAppear {
            store.setPreferredExpandedHeight(layoutMode == .list ? 330 : 500)
            store.refreshPrivacyPermissions()
        }
        .onChange(of: store.layoutMode(for: .screenshots)) { _, mode in
            store.setPreferredExpandedHeight(mode == .list ? 330 : 500)
        }
        .onChange(of: store.isScreenshotDragActive) { _, isActive in
            if !isActive {
                draggedItem = nil
            }
        }
        .confirmationDialog(
            "Удалить все снимки?",
            isPresented: Binding(
                get: { showingDeleteAllConfirmation },
                set: { isPresented in
                    showingDeleteAllConfirmation = isPresented
                    if !isPresented { store.endInteraction() }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Удалить все (\(store.screenshots.count))", role: .destructive) {
                editingItem = nil
                draggedItem = nil
                store.deleteAllScreenshots()
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Все снимки будут перемещены в Корзину, откуда их можно восстановить.")
        }
        .sheet(item: $editingItem, onDismiss: store.endInteraction) { item in
            ScreenshotEditorView(item: item)
                .environmentObject(store)
                .onAppear { store.beginInteraction() }
        }
    }

    @ViewBuilder
    private var screenshotItemsContent: some View {
        if filteredItems.isEmpty {
            EmptyIslandState(
                symbol: "photo.badge.plus",
                title: "Снимков пока нет",
                message: "Нажмите «Снимок» для всего экрана или «Обрезать» для выбранной области."
            )
        } else if layoutMode != .list {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: layoutMode == .icons ? IslandMetrics.compactGridMinimum : IslandMetrics.regularGridMinimum), spacing: layoutMode == .icons ? IslandMetrics.compactGridSpacing : IslandMetrics.gridSpacing)],
                    spacing: layoutMode == .icons ? IslandMetrics.compactGridSpacing : IslandMetrics.gridSpacing
                ) {
                    ForEach(filteredItems) { item in
                        ScreenshotCard(item: item, mode: layoutMode)
                            .gesture(cardTapGesture(for: item))
                            .onDrag { dragProvider(for: item) }
                            .onDrop(
                                of: [.islandScreenshotReorder],
                                delegate: ScreenshotReorderDelegate(
                                    target: item,
                                    draggedItem: $draggedItem,
                                    store: store
                                )
                            )
                            .contextMenu { contextMenu(for: item) }
                    }
                }
                .padding(.vertical, 2)
                .padding(.horizontal, layoutMode == .icons ? 4 : 2)
                .padding(.bottom, 6)
            }
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(filteredItems) { item in
                        ScreenshotCard(item: item, mode: .list)
                            .frame(width: 250)
                            .gesture(cardTapGesture(for: item))
                            .onDrag { dragProvider(for: item) }
                            .contextMenu { contextMenu(for: item) }
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
                .padding(.bottom, 6)
            }
        }
    }

    @ViewBuilder
    private var screenCaptureAccessPanel: some View {
        switch store.screenCaptureAccess {
        case .granted:
            EmptyView()
        case .permissionRequired, .settingsOpened:
            HStack(spacing: 12) {
                Image(systemName: "camera.badge.ellipsis")
                    .font(.system(size: 21))
                    .foregroundStyle(.white.opacity(0.64))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Разрешите снимки экрана")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                    Text(screenCapturePermissionHint)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.48))
                }

                Spacer(minLength: 12)

                Button(store.screenCaptureAccess == .settingsOpened ? "Перезапустить" : "Разрешить") {
                    if store.screenCaptureAccess == .settingsOpened {
                        store.relaunchForPermissions()
                    } else {
                        store.requestScreenCapturePermission()
                    }
                }
                .buttonStyle(IslandToolbarActionStyle())
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 13).fill(Color.islandCard))
        }
    }

    private var screenCapturePermissionHint: String {
        if store.screenCaptureAccess == .settingsOpened {
            return "Включите «Островок удобства» в настройках macOS и нажмите «Перезапустить»."
        }
        return "Разрешите доступ один раз, чтобы создавать снимки."
    }

    @ViewBuilder
    private func contextMenu(for item: ScreenshotItem) -> some View {
        Button("Копировать", systemImage: "doc.on.doc") {
            store.copyScreenshot(item)
        }
        Button("Редактировать", systemImage: "pencil") {
            editingItem = item
        }
        MoveToFolderMenu(currentFolderID: item.folderID, tab: .screenshots) { folderID in
            store.moveScreenshot(item, to: folderID)
        } label: {
            Label("Переместить в папку", systemImage: "folder")
        }
        Divider()
        Button("Показать в Finder", systemImage: "folder") {
            if let url = store.screenshotURL(for: item) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        Button("Удалить", systemImage: "trash", role: .destructive) {
            store.deleteScreenshot(item)
        }
    }

    private func cardTapGesture(for item: ScreenshotItem) -> some Gesture {
        TapGesture(count: 2)
            .exclusively(before: TapGesture(count: 1))
            .onEnded { value in
                switch value {
                case .first:
                    editingItem = item
                case .second:
                    store.copyScreenshot(item)
                }
            }
    }

    private func dragProvider(for item: ScreenshotItem) -> NSItemProvider {
        draggedItem = item
        store.beginScreenshotDrag()

        guard let url = store.screenshotURL(for: item) else {
            store.endScreenshotDrag()
            return NSItemProvider()
        }
        let provider = NSItemProvider(contentsOf: url) ?? NSItemProvider()
        provider.suggestedName = item.fileName

        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.islandScreenshotReorder.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(Data(item.id.uuidString.utf8), nil)
            return nil
        }

        if !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.registerFileRepresentation(
                forTypeIdentifier: UTType.png.identifier,
                fileOptions: [.openInPlace],
                visibility: .all
            ) { completion in
                completion(url, true, nil)
                return nil
            }
        }
        return provider
    }
}

struct ScreenshotCard: View {
    @EnvironmentObject private var store: IslandStore
    let item: ScreenshotItem
    let mode: IslandLayoutMode

    private var usesMiniIcon: Bool { mode == .icons }

    private var imageHeight: CGFloat {
        switch mode {
        case .list: 150
        case .grid: 102
        case .icons: 52
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let url = store.screenshotURL(for: item),
                   let image = NSImage(contentsOf: url) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Color.white.opacity(0.035)
                        Image(systemName: "photo")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(.white.opacity(0.32))
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: imageHeight)
            .clipped()

            if !usesMiniIcon {
                HStack {
                    Label {
                        Text(item.createdAt, style: .relative)
                    } icon: {
                        Image(systemName: "clock")
                    }
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.44))
                    Spacer()
                    Image(systemName: "hand.draw")
                        .foregroundStyle(.white.opacity(0.25))
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
            }
        }
        .frame(maxWidth: .infinity)
        .islandCardSurface(compact: usesMiniIcon, selected: store.copiedScreenshotID == item.id)
        .overlay {
            if store.copiedScreenshotID == item.id {
                if usesMiniIcon {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.white.opacity(0.24)))
                        .transition(.opacity)
                } else {
                    Label("Скопировано", systemImage: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 11)
                        .frame(height: 27)
                        .background(Capsule().fill(Color.white.opacity(0.24)))
                        .transition(.opacity)
                }
            }
        }
        .animation(.easeInOut(duration: 0.16), value: store.copiedScreenshotID)
    }
}

struct ScreenshotReorderDelegate: DropDelegate {
    let target: ScreenshotItem
    @Binding var draggedItem: ScreenshotItem?
    let store: IslandStore

    func dropEntered(info: DropInfo) {
        guard let draggedItem, draggedItem.id != target.id else { return }
        store.moveScreenshot(draggedItem.id, before: target.id)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedItem = nil
        store.endScreenshotDrag()
        return true
    }
}

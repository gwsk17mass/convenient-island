import AppKit
import SwiftUI

enum FolderSelection: Hashable {
    case all
    case unfiled
    case folder(UUID)
}

struct IslandRootView: View {
    @EnvironmentObject private var store: IslandStore

    var body: some View {
        ZStack(alignment: .top) {
            GeometryReader { proxy in
                expandedContent
                    .frame(
                        width: max(1, store.expandedCanvasSize.width),
                        height: max(1, store.expandedCanvasSize.height),
                        alignment: .top
                    )
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                    .opacity(store.isExpanded ? 1 : 0)
                    .allowsHitTesting(store.isExpanded)
            }

            collapsedContent
                .opacity(store.isExpanded ? 0 : 1)
                .allowsHitTesting(!store.isExpanded)
        }
        .animation(.easeOut(duration: 0.12), value: store.isExpanded)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(islandBackground)
        .clipShape(islandShape)
        .overlay {
            if store.isExpanded && store.isResizeModeEnabled {
                WindowResizeOverlay()
                    .transition(.opacity)
            }
        }
        .tint(.white)
        .onHover { store.pointerChanged(isInside: $0) }
        .alert("Островок удобства", isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )) {
            Button("OK") { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
    }

    private var islandShape: IslandChromeShape {
        IslandChromeShape()
    }

    private var islandBackground: some View {
        ZStack {
            Color.black.opacity(0.982)
            LinearGradient(
                colors: [.white.opacity(0.027), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var collapsedContent: some View {
        ZStack {
            if store.isRepositionModeEnabled {
                HStack(spacing: 9) {
                    Image(systemName: "arrow.left")
                    Image(systemName: store.selectedTab.symbol)
                    Image(systemName: "arrow.right")
                }
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.76))
                .allowsHitTesting(false)
                IslandRepositionHandle()
            } else {
                Image(systemName: store.selectedTab.symbol)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.78))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    private var expandedContent: some View {
        VStack(spacing: 0) {
            tabBar
            Divider().overlay(.white.opacity(0.07))
            selectedContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 18)
        .padding(.top, 11)
        .padding(.bottom, 4)
    }

    private var tabBar: some View {
        HStack(spacing: 3) {
            ForEach(IslandTab.allCases) { tab in
                Button {
                    store.select(tab)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: tab.symbol)
                        Text(tab.title)
                    }
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(store.selectedTab == tab ? Color.white.opacity(0.94) : Color.white.opacity(0.58))
                    .padding(.horizontal, 11)
                    .frame(height: 34)
                    .background {
                        if store.selectedTab == tab {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.white.opacity(0.13))
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 8)

            Button {
                store.toggleResizeMode()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(store.isResizeModeEnabled ? Color.white.opacity(0.96) : Color.white.opacity(0.7))
                    .background {
                        if store.isResizeModeEnabled {
                            Circle().fill(Color.white.opacity(0.13))
                        }
                    }
            }
            .buttonStyle(.plain)
            .help(store.isResizeModeEnabled ? "Перейти к перемещению островка" : "Изменить размер окна")
            .contextMenu {
                Button("Сбросить размер", systemImage: "arrow.counterclockwise") {
                    store.resetCustomExpandedSize()
                }
                .disabled(store.customExpandedWidth == nil && store.customExpandedHeight == nil)
            }
        }
        .padding(.bottom, 9)
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch store.selectedTab {
        case .screenshots:
            ScreenshotsView()
        case .clipboard:
            ClipboardHistoryView()
        case .documents:
            DocumentsView()
        case .credentials:
            CredentialsView()
        case .recordings:
            RecordingsView()
        }
    }

}

private struct IslandChromeShape: Shape {
    func path(in rect: CGRect) -> Path {
        let expansion = min(max((rect.height - 29) / 331, 0), 1)
        let topRadius = 4 + 4 * expansion
        let bottomRadius = 14 + 14 * expansion

        return UnevenRoundedRectangle(
            topLeadingRadius: topRadius,
            bottomLeadingRadius: bottomRadius,
            bottomTrailingRadius: bottomRadius,
            topTrailingRadius: topRadius,
            style: .continuous
        )
        .path(in: rect)
    }
}

struct LayoutModeButton: View {
    @EnvironmentObject private var store: IslandStore
    let tab: IslandTab

    private var mode: IslandLayoutMode {
        store.layoutMode(for: tab)
    }

    private var nextModeSymbol: String {
        switch mode {
        case .list: "square.grid.2x2"
        case .grid: "square.grid.3x3"
        case .icons: "rectangle.grid.1x2"
        }
    }

    private var helpText: String {
        switch mode {
        case .list: "Показать сеткой"
        case .grid: "Показать мини-значками"
        case .icons: "Показать списком"
        }
    }

    var body: some View {
        Button {
            store.toggleLayoutMode(for: tab)
        } label: {
            Image(systemName: nextModeSymbol)
        }
        .buttonStyle(IslandToolbarIconStyle())
        .help(helpText)
    }
}

private struct WindowResizeOverlay: View {
    var body: some View {
        ZStack {
            WindowResizeHandle(edge: .left)
                .frame(width: 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            WindowResizeHandle(edge: .right)
                .frame(width: 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)

            WindowResizeHandle(edge: .bottom)
                .frame(height: 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

            WindowResizeHandle(edge: .bottomLeft)
                .frame(width: 28, height: 28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

            WindowResizeHandle(edge: .bottomRight)
                .frame(width: 28, height: 28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)

            HStack {
                Capsule().fill(Color.white.opacity(0.62)).frame(width: 3, height: 44)
                Spacer()
                Capsule().fill(Color.white.opacity(0.62)).frame(width: 3, height: 44)
            }
            .padding(.horizontal, 3)
            .allowsHitTesting(false)

            VStack {
                Spacer()
                Capsule().fill(Color.white.opacity(0.62)).frame(width: 52, height: 3)
            }
            .padding(.bottom, 3)
            .allowsHitTesting(false)
        }
    }
}

private enum FolderEditorMode: Identifiable {
    case create
    case rename(IslandFolder)

    var id: String {
        switch self {
        case .create: "create"
        case .rename(let folder): "rename-\(folder.id.uuidString)"
        }
    }

    var title: String {
        switch self {
        case .create: "Новая папка"
        case .rename: "Переименовать папку"
        }
    }

    var actionTitle: String {
        switch self {
        case .create: "Создать"
        case .rename: "Сохранить"
        }
    }
}

struct FolderStrip: View {
    @EnvironmentObject private var store: IslandStore
    @Binding var selection: FolderSelection
    let tab: IslandTab
    @State private var folderEditor: FolderEditorMode?
    @State private var folderName = ""

    private var scopedFolders: [IslandFolder] {
        store.folders.filter { $0.tab == tab }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                folderChip(title: "Все", symbol: "square.grid.2x2", value: .all)
                folderChip(title: "Без папки", symbol: "tray", value: .unfiled)
                ForEach(scopedFolders) { folder in
                    folderChip(title: folder.name, symbol: "folder.fill", value: .folder(folder.id))
                        .contextMenu {
                            Button("Переименовать", systemImage: "pencil") {
                                store.beginInteraction()
                                folderName = folder.name
                                folderEditor = .rename(folder)
                            }
                            Divider()
                            Button("Удалить папку", role: .destructive) {
                                if selection == .folder(folder.id) { selection = .all }
                                store.deleteFolder(folder)
                            }
                        }
                }

                Button {
                    store.beginInteraction()
                    folderName = ""
                    folderEditor = .create
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(IslandToolbarIconStyle(subtle: true))
                .help("Новая папка")
            }
        }
        .sheet(item: $folderEditor, onDismiss: store.endInteraction) { mode in
            VStack(alignment: .leading, spacing: 18) {
                Text(mode.title)
                    .font(.title2.weight(.semibold))
                TextField("Название", text: $folderName)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Отмена") {
                        folderEditor = nil
                        folderName = ""
                    }
                    Button(mode.actionTitle) {
                        switch mode {
                        case .create:
                            store.createFolder(name: folderName, tab: tab)
                        case .rename(let folder):
                            store.renameFolder(folder, name: folderName)
                        }
                        folderEditor = nil
                        folderName = ""
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(24)
            .frame(width: 380)
        }
    }

    private func folderChip(title: String, symbol: String, value: FolderSelection) -> some View {
        Button {
            selection = value
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selection == value ? Color.white : Color.white.opacity(0.58))
                .padding(.horizontal, 12)
                .frame(height: IslandMetrics.toolbarControlSize)
                .background(
                    Capsule().fill(selection == value ? Color.white.opacity(0.13) : Color.white.opacity(0.045))
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct EmptyIslandState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.white.opacity(0.34))
            Text(title)
                .font(.headline)
                .foregroundStyle(.white.opacity(0.82))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MoveToFolderMenu<LabelContent: View>: View {
    @EnvironmentObject private var store: IslandStore
    let currentFolderID: UUID?
    let tab: IslandTab
    let action: (UUID?) -> Void
    @ViewBuilder let label: () -> LabelContent

    var body: some View {
        Menu {
            Button {
                action(nil)
            } label: {
                Label("Без папки", systemImage: currentFolderID == nil ? "checkmark" : "tray")
            }
            Divider()
            ForEach(store.folders.filter { $0.tab == tab }) { folder in
                Button {
                    action(folder.id)
                } label: {
                    Label(folder.name, systemImage: currentFolderID == folder.id ? "checkmark" : "folder")
                }
            }
        } label: {
            label()
        }
    }
}

extension Color {
    static let islandCard = Color.white.opacity(0.062)
}

enum IslandMetrics {
    static let sectionSpacing: CGFloat = 10
    static let gridSpacing: CGFloat = 8
    static let compactGridSpacing: CGFloat = 7
    static let regularGridMinimum: CGFloat = 164
    static let compactGridMinimum: CGFloat = 84
    static let cardCornerRadius: CGFloat = 12
    static let compactCardCornerRadius: CGFloat = 10
    static let cardPadding: CGFloat = 10
    static let compactCardPadding: CGFloat = 7
    static let toolbarControlSize: CGFloat = 32
}

private struct IslandCardSurface: ViewModifier {
    let compact: Bool
    let selected: Bool

    func body(content: Content) -> some View {
        let radius = compact ? IslandMetrics.compactCardCornerRadius : IslandMetrics.cardCornerRadius
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(selected ? Color.white.opacity(0.14) : Color.islandCard)
            )
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

extension View {
    func islandCardSurface(compact: Bool = false, selected: Bool = false) -> some View {
        modifier(IslandCardSurface(compact: compact, selected: selected))
    }
}

struct IslandToolbarActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.68 : 0.9))
            .background(
                Capsule().fill(
                    Color.white.opacity(configuration.isPressed ? 0.16 : (isActive ? 0.13 : 0.085))
                )
            )
            .opacity(isEnabled ? 1 : 0.42)
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

struct IslandToolbarIconStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var isActive = false
    var subtle = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.62 : 0.82))
            .frame(width: IslandMetrics.toolbarControlSize, height: IslandMetrics.toolbarControlSize)
            .background(
                Circle().fill(
                    Color.white.opacity(
                        configuration.isPressed ? 0.15 : (isActive ? 0.13 : (subtle ? 0.05 : 0.075))
                    )
                )
            )
            .contentShape(Circle())
            .opacity(isEnabled ? 1 : 0.38)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

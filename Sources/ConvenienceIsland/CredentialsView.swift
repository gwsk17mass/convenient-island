import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CredentialsView: View {
    @EnvironmentObject private var store: IslandStore
    @State private var editingItem: CredentialItem?
    @State private var revealedPasswords: [UUID: String] = [:]
    @State private var copiedEmailID: UUID?
    @State private var folderSelection: FolderSelection = .all
    @State private var isChoosingFile = false

    private var columns: [GridItem] {
        switch store.layoutMode(for: .credentials) {
        case .list: [GridItem(.flexible())]
        case .grid: [GridItem(.adaptive(minimum: IslandMetrics.regularGridMinimum), spacing: IslandMetrics.gridSpacing)]
        case .icons: [GridItem(.adaptive(minimum: IslandMetrics.compactGridMinimum), spacing: IslandMetrics.compactGridSpacing)]
        }
    }

    private var usesMiniIcons: Bool { store.layoutMode(for: .credentials) == .icons }

    private var filteredCredentials: [CredentialItem] {
        store.credentials.filter { item in
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
                LayoutModeButton(tab: .credentials)
                FolderStrip(selection: $folderSelection, tab: .credentials)
                Spacer(minLength: 8)
                Button {
                    chooseCredentialFile()
                } label: {
                    Label("Создать", systemImage: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 12)
                        .frame(height: IslandMetrics.toolbarControlSize)
                }
                .buttonStyle(IslandToolbarActionStyle())
                .disabled(isChoosingFile)
            }

            if filteredCredentials.isEmpty {
                EmptyIslandState(
                    symbol: "doc.text.fill",
                    title: "Карточек пока нет",
                    message: "Нажмите «Создать», выберите место для .txt и заполните удобную карточку."
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: usesMiniIcons ? IslandMetrics.compactGridSpacing : IslandMetrics.gridSpacing) {
                        ForEach(filteredCredentials) { item in
                            CredentialCard(
                                item: item,
                                revealedPassword: revealedPasswords[item.id],
                                emailCopied: copiedEmailID == item.id,
                                compact: usesMiniIcons,
                                onReveal: { togglePassword(for: item) },
                                onCopyEmail: { copyPrimaryEmail(for: item) }
                            )
                            .contentShape(RoundedRectangle(cornerRadius: usesMiniIcons ? IslandMetrics.compactCardCornerRadius : IslandMetrics.cardCornerRadius))
                            .gesture(cardTapGesture(for: item))
                            .help("Один клик — копировать email. Двойной клик — открыть карточку")
                            .contextMenu { contextMenu(for: item) }
                        }
                    }
                    .padding(.vertical, 2)
                    .padding(.horizontal, usesMiniIcons ? 4 : 2)
                }
            }
        }
        .padding(.top, 14)
        .overlay {
            if let item = editingItem {
                GeometryReader { proxy in
                    ZStack {
                        Color.black.opacity(0.62)
                            .contentShape(Rectangle())
                            .onTapGesture { closeEditor() }

                        CredentialEditorSheet(
                            item: item,
                            values: store.credentialValues(for: item),
                            onClose: closeEditor
                        )
                        .environmentObject(store)
                        .frame(
                            width: min(620, max(440, proxy.size.width - 36)),
                            height: max(240, min(630, proxy.size.height - 24))
                        )
                        .background(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .fill(Color(red: 0.075, green: 0.078, blue: 0.085).opacity(0.995))
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .padding(12)
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.985)))
                .zIndex(20)
            }
        }
        .onAppear {
            store.setPreferredExpandedHeight(490)
            store.removeMissingCredentialFiles()
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                store.removeMissingCredentialFiles()
            }
        }
        .onDisappear {
            if editingItem != nil {
                editingItem = nil
                store.endInteraction()
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for item: CredentialItem) -> some View {
        if item.filePathHint == nil {
            Button("Сохранить в текстовый файл…", systemImage: "doc.badge.plus") {
                chooseCredentialFile(for: item)
            }
        } else {
            Button("Редактировать карточку", systemImage: "pencil") {
                openEditor(for: item)
            }
            Button("Открыть текстовый файл", systemImage: "doc.text") {
                store.openCredentialFile(item)
            }
            Button("Показать в Finder", systemImage: "folder") {
                store.revealCredentialFile(item)
            }
        }

        Divider()
        Button("Копировать email", systemImage: "person.crop.circle") {
            copyPrimaryEmail(for: item)
        }
        Button("Копировать пароль", systemImage: "key") {
            store.copyCredentialPassword(item)
        }
        MoveToFolderMenu(currentFolderID: item.folderID, tab: .credentials) { folderID in
            store.moveCredential(item, to: folderID)
        } label: {
            Label("Переместить в папку", systemImage: "folder")
        }
    }

    private func togglePassword(for item: CredentialItem) {
        if revealedPasswords[item.id] != nil {
            revealedPasswords[item.id] = nil
        } else {
            revealedPasswords[item.id] = store.password(for: item)
        }
    }

    private func cardTapGesture(for item: CredentialItem) -> some Gesture {
        TapGesture(count: 2)
            .exclusively(before: TapGesture(count: 1))
            .onEnded { result in
                switch result {
                case .first:
                    if item.filePathHint == nil {
                        chooseCredentialFile(for: item)
                    } else {
                        openEditor(for: item)
                    }
                case .second:
                    copyPrimaryEmail(for: item)
                }
            }
    }

    private func copyPrimaryEmail(for item: CredentialItem) {
        let email = store.credentialValues(for: item).username
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else {
            store.lastError = "В карточке не заполнена основная почта."
            return
        }
        store.copyCredentialUsername(item)
        withAnimation(.easeOut(duration: 0.14)) { copiedEmailID = item.id }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.1))
            guard copiedEmailID == item.id else { return }
            withAnimation(.easeOut(duration: 0.14)) { copiedEmailID = nil }
        }
    }

    private func openEditor(for item: CredentialItem) {
        guard editingItem?.id != item.id else { return }
        if editingItem == nil { store.beginInteraction() }
        withAnimation(.easeOut(duration: 0.16)) { editingItem = item }
    }

    private func closeEditor() {
        guard editingItem != nil else { return }
        withAnimation(.easeOut(duration: 0.13)) { editingItem = nil }
        store.endInteraction()
    }

    private func chooseCredentialFile(for existingItem: CredentialItem? = nil) {
        let panel = NSSavePanel()
        panel.title = existingItem == nil ? "Создать файл карточки" : "Сохранить карточку в файл"
        panel.message = "Пароль будет записан в этот файл открытым текстом. Выберите безопасное место хранения."
        panel.prompt = "Создать"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        let suggestedName = existingItem?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        panel.nameFieldStringValue = "\((suggestedName?.isEmpty == false ? suggestedName : nil) ?? "Новый доступ").txt"
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)

        isChoosingFile = true
        store.beginInteraction()
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            Task { @MainActor in
                defer {
                    isChoosingFile = false
                    store.endInteraction()
                }
                guard response == .OK, let url = panel.url else { return }
                let item: CredentialItem?
                if let existingItem {
                    item = store.attachCredentialFile(existingItem, to: url)
                } else {
                    item = store.createCredentialFile(at: url)
                }
                if let item { openEditor(for: item) }
            }
        }
    }
}

struct CredentialCard: View {
    @EnvironmentObject private var store: IslandStore
    let item: CredentialItem
    let revealedPassword: String?
    let emailCopied: Bool
    let compact: Bool
    let onReveal: () -> Void
    let onCopyEmail: () -> Void

    private var hasTextFile: Bool { item.filePathHint != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 12) {
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: compact ? 8 : 11)
                        .fill(Color.white.opacity(0.085))
                    Image(systemName: hasTextFile ? "doc.text.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(hasTextFile ? Color.white.opacity(0.68) : Color.white.opacity(0.58))
                }
                .frame(width: compact ? 24 : 34, height: compact ? 24 : 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title.isEmpty ? "Без названия" : item.title)
                        .font(.system(size: compact ? 11 : 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                    Text(item.service.isEmpty ? "Сайт не указан" : item.service)
                        .font(compact ? .caption2 : .caption)
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                }
                Spacer()
            }

            HStack {
                Text(item.username.isEmpty ? "Email не указан" : item.username)
                    .font(.system(size: compact ? 10.5 : 13.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.66))
                    .lineLimit(1)
                Spacer()
                if !compact {
                    Button(action: onCopyEmail) {
                        Image(systemName: emailCopied ? "checkmark.circle.fill" : "doc.on.doc")
                            .foregroundStyle(emailCopied ? Color.white.opacity(0.94) : Color.white.opacity(0.72))
                    }
                    .buttonStyle(.plain)
                    .help(emailCopied ? "Email скопирован" : "Копировать email")
                }
            }

            if !compact {
                HStack {
                    Text(revealedPassword ?? "••••••••••••")
                        .font(.system(size: 13.5, design: .monospaced))
                        .foregroundStyle(.white.opacity(revealedPassword == nil ? 0.42 : 0.78))
                        .lineLimit(1)
                    Spacer()
                    Button(action: onReveal) {
                        Image(systemName: revealedPassword == nil ? "eye" : "eye.slash")
                    }
                    .buttonStyle(.plain)
                    .help(revealedPassword == nil ? "Показать" : "Скрыть")
                }
            }
        }
        .padding(compact ? IslandMetrics.compactCardPadding : IslandMetrics.cardPadding)
        .frame(maxWidth: .infinity, minHeight: compact ? 88 : 126, alignment: .topLeading)
        .islandCardSurface(compact: compact)
    }
}

struct CredentialEditorSheet: View {
    @EnvironmentObject private var store: IslandStore
    let item: CredentialItem
    let onClose: () -> Void
    @State private var title: String
    @State private var service: String
    @State private var username: String
    @State private var password: String
    @State private var extras: [CredentialExtraField]
    @State private var showsPassword = false
    @State private var revealedExtraIDs: Set<UUID> = []
    @State private var saveTask: Task<Void, Never>?
    @State private var savedRecently = false

    init(item: CredentialItem, values: CredentialFileValues, onClose: @escaping () -> Void) {
        self.item = item
        self.onClose = onClose
        _title = State(initialValue: values.title)
        _service = State(initialValue: values.service)
        _username = State(initialValue: values.username)
        _password = State(initialValue: values.password)
        _extras = State(initialValue: values.extras)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Карточка доступа")
                        .font(.title2.weight(.semibold))
                    Text("Изменения автоматически записываются в связанный .txt")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label(savedRecently ? "Сохранено" : "Автосохранение", systemImage: savedRecently ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(savedRecently ? Color.primary.opacity(0.9) : Color.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GroupBox {
                        VStack(spacing: 13) {
                            LabeledContent("Название") {
                                TextField("Например, Личная почта", text: $title)
                            }
                            LabeledContent("Сайт") {
                                TextField("example.com", text: $service)
                            }
                            LabeledContent("Email / логин") {
                                TextField("name@example.com", text: $username)
                            }
                            LabeledContent("Пароль") {
                                HStack(spacing: 8) {
                                    Group {
                                        if showsPassword {
                                            TextField("Пароль", text: $password)
                                        } else {
                                            SecureField("Пароль", text: $password)
                                        }
                                    }
                                    Button {
                                        showsPassword.toggle()
                                    } label: {
                                        Image(systemName: showsPassword ? "eye.slash" : "eye")
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        .padding(4)
                    }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Дополнения")
                                        .font(.headline)
                                    Text("Поля находятся внутри этой карточки и сохраняются в тот же файл")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Menu {
                                    extraMenuButton(kind: .website, label: "Рабочий сайт")
                                    extraMenuButton(kind: .messenger, label: "Telegram")
                                    extraMenuButton(kind: .secret, label: "API / токен")
                                    Divider()
                                    extraMenuButton(kind: .custom, label: "Новое поле")
                                } label: {
                                    Label("Добавить", systemImage: "plus")
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                            }

                            if extras.isEmpty {
                                HStack(spacing: 10) {
                                    Image(systemName: "plus.square.dashed")
                                        .font(.title3)
                                    Text("Нажмите «Добавить»: сайт, мессенджер, токен/API или своё поле.")
                                }
                                .foregroundStyle(.secondary)
                                .font(.caption)
                                .padding(.vertical, 10)
                            } else {
                                VStack(spacing: 10) {
                                    ForEach($extras) { $field in
                                        CredentialExtraFieldRow(
                                            field: $field,
                                            isRevealed: Binding(
                                                get: { revealedExtraIDs.contains(field.id) },
                                                set: { isRevealed in
                                                    if isRevealed {
                                                        revealedExtraIDs.insert(field.id)
                                                    } else {
                                                        revealedExtraIDs.remove(field.id)
                                                    }
                                                }
                                            ),
                                            onRemove: { removeExtra(id: field.id) }
                                        )
                                    }
                                }
                            }
                        }
                        .padding(4)
                    }

                    Label("Пароли и токены хранятся открытым текстом в выбранном файле, без Связки ключей macOS.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let path = item.filePathHint {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.text")
                            Text(path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Spacer()
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.trailing, 4)
            }

            HStack {
                Button("Открыть файл", systemImage: "doc.text") {
                    flushSave()
                    store.openCredentialFile(item)
                }
                Button("Показать в Finder", systemImage: "folder") {
                    flushSave()
                    store.revealCredentialFile(item)
                }
                Spacer()
                Button("Готово") {
                    flushSave()
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: title) { _, _ in scheduleSave() }
        .onChange(of: service) { _, _ in scheduleSave() }
        .onChange(of: username) { _, _ in scheduleSave() }
        .onChange(of: password) { _, _ in scheduleSave() }
        .onChange(of: extras) { _, _ in scheduleSave() }
        .onDisappear {
            flushSave()
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        savedRecently = false
        let snapshot = CredentialFileValues(title: title, service: service, username: username, password: password, extras: extras)
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            store.updateCredentialFile(
                item,
                title: snapshot.title,
                service: snapshot.service,
                username: snapshot.username,
                password: snapshot.password,
                extras: snapshot.extras
            )
            withAnimation(.easeOut(duration: 0.15)) { savedRecently = true }
        }
    }

    private func flushSave() {
        saveTask?.cancel()
        store.updateCredentialFile(item, title: title, service: service, username: username, password: password, extras: extras)
        savedRecently = true
    }

    @ViewBuilder
    private func extraMenuButton(kind: CredentialExtraKind, label: String) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) {
                extras.append(CredentialExtraField(kind: kind, label: label, value: ""))
            }
        } label: {
            Label(kind.title, systemImage: kind.symbol)
        }
    }

    private func removeExtra(id: UUID) {
        withAnimation(.easeOut(duration: 0.16)) {
            extras.removeAll { $0.id == id }
            revealedExtraIDs.remove(id)
        }
    }
}

private struct CredentialExtraFieldRow: View {
    @Binding var field: CredentialExtraField
    @Binding var isRevealed: Bool
    let onRemove: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .center, spacing: 9) {
                Image(systemName: field.kind.symbol)
                    .frame(width: 20)
                    .foregroundStyle(.secondary)

                TextField("Название поля", text: $field.label)
                    .frame(width: 140)

                Group {
                    if field.kind == .secret && !isRevealed {
                        SecureField("Значение", text: $field.value)
                    } else {
                        TextField(field.kind == .messenger ? "@имя или номер" : "Значение", text: $field.value)
                    }
                }

                if field.kind == .secret {
                    revealButton
                }

                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "minus.circle.fill")
                }
                .buttonStyle(.plain)
                .help("Удалить дополнительное поле")
            }

            if field.kind == .website || field.kind == .messenger {
                HStack(spacing: 9) {
                    Image(systemName: "lock.fill")
                        .frame(width: 20)
                        .foregroundStyle(.secondary)
                    Text("Пароль")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 140, alignment: .leading)
                    Group {
                        if isRevealed {
                            TextField("Пароль", text: $field.password)
                        } else {
                            SecureField("Пароль", text: $field.password)
                        }
                    }
                    revealButton
                    Color.clear.frame(width: 13, height: 1)
                }
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(.vertical, 2)
    }

    private var revealButton: some View {
        Button {
            isRevealed.toggle()
        } label: {
            Image(systemName: isRevealed ? "eye.slash" : "eye")
        }
        .buttonStyle(.plain)
        .help(isRevealed ? "Скрыть" : "Показать")
    }
}

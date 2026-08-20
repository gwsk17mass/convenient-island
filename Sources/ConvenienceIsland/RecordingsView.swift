import SwiftUI

struct RecordingsView: View {
    @EnvironmentObject private var store: IslandStore
    @State private var folderSelection: FolderSelection = .all

    private var layoutMode: IslandLayoutMode { store.layoutMode(for: .recordings) }
    private var compact: Bool { layoutMode == .icons }

    private var columns: [GridItem] {
        switch layoutMode {
        case .list:
            [GridItem(.flexible())]
        case .grid:
            [GridItem(.adaptive(minimum: IslandMetrics.regularGridMinimum), spacing: IslandMetrics.gridSpacing)]
        case .icons:
            [GridItem(.adaptive(minimum: IslandMetrics.compactGridMinimum), spacing: IslandMetrics.compactGridSpacing)]
        }
    }

    private var filteredRecordings: [RecordingItem] {
        store.recordings.filter { item in
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
                LayoutModeButton(tab: .recordings)
                FolderStrip(selection: $folderSelection, tab: .recordings)
                Spacer(minLength: 8)

                Button {
                    store.refreshSystemVoiceMemos()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(IslandToolbarIconStyle())
                .help("Обновить записи из Apple «Диктофона»")

                Button {
                    store.toggleRecording()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: store.isRecording ? "mic.fill" : "record.circle")
                        Text(store.isRecording ? "Открыть" : "Запись")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .frame(height: IslandMetrics.toolbarControlSize)
                    .padding(.horizontal, 12)
                }
                .buttonStyle(IslandToolbarActionStyle(isActive: store.isRecording))
            }

            libraryAccessPanel

            if store.isRecording {
                LiveRecordingCard()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if filteredRecordings.isEmpty && !store.isRecording {
                EmptyIslandState(
                    symbol: "waveform.badge.mic",
                    title: "Записей пока нет",
                    message: "Нажмите «Начать запись». Оригинал сохранится в Apple «Диктофоне» и появится здесь."
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: compact ? IslandMetrics.compactGridSpacing : IslandMetrics.gridSpacing) {
                        ForEach(filteredRecordings) { item in
                            RecordingCard(item: item, compact: compact)
                                .contextMenu { recordingMenu(for: item) }
                        }
                    }
                    .padding(.horizontal, compact ? 4 : 2)
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(.top, 14)
        .animation(.easeOut(duration: 0.18), value: store.isRecording)
        .onAppear {
            store.setPreferredExpandedHeight(520)
            store.refreshPrivacyPermissions()
            store.refreshSystemVoiceMemos()
        }
    }

    @ViewBuilder
    private var libraryAccessPanel: some View {
        if store.voiceMemosLibraryAccess == .granted,
           store.hasVoiceMemosAutomationPermission {
            EmptyView()
        } else {
            HStack(spacing: 12) {
                Image(systemName: "lock.open.display")
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.62))

                VStack(alignment: .leading, spacing: 5) {
                    Text("Доступ к Apple «Диктофону»")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                    HStack(spacing: 12) {
                        permissionStatus(
                            "Видеть записи",
                            granted: store.voiceMemosLibraryAccess == .granted
                        )
                        permissionStatus(
                            "Управлять записью",
                            granted: store.hasVoiceMemosAutomationPermission
                        )
                    }
                    Text(voiceMemosPermissionHint)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.42))
                }

                Spacer(minLength: 10)

                Button(voiceMemosPermissionActionTitle) {
                    store.continueVoiceMemosPermissionSetup()
                }
                .buttonStyle(IslandToolbarActionStyle())
                .disabled(store.voiceMemosLibraryAccess == .checking)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 13).fill(Color.islandCard))
        }
    }

    private func permissionStatus(_ title: String, granted: Bool) -> some View {
        Label(title, systemImage: granted ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.white.opacity(granted ? 0.72 : 0.38))
    }

    private var voiceMemosPermissionActionTitle: String {
        switch store.voiceMemosLibraryAccess {
        case .checking:
            return "Проверяем…"
        case .fullDiskAccessRequired:
            return store.voiceMemosFullDiskSettingsOpened ? "Перезапустить" : "Разрешить"
        case .failed:
            return "Открыть Диктофон"
        case .granted:
            return store.voiceMemosAccessibilitySettingsOpened ? "Проверить" : "Разрешить"
        }
    }

    private var voiceMemosPermissionHint: String {
        switch store.voiceMemosLibraryAccess {
        case .checking:
            return "Островок сам проверяет выданные доступы."
        case .fullDiskAccessRequired:
            if store.voiceMemosFullDiskSettingsOpened {
                return "Добавьте выделенное в Finder приложение в «Полный доступ к диску», затем перезапустите."
            }
            return "Островок откроет нужный раздел и выделит себя в Finder."
        case .failed(let message):
            return message
        case .granted:
            return store.hasVoiceMemosAutomationPermission
                ? "Все готово."
                : "Осталось разрешить островку нажимать кнопки в Apple «Диктофоне»."
        }
    }

    @ViewBuilder
    private func recordingMenu(for item: RecordingItem) -> some View {
        if item.isAppleVoiceMemo {
            Button("Открыть Apple «Диктофон»", systemImage: "mic.fill") {
                store.openSystemVoiceMemos()
            }
        }
        Button("Показать аудио в Finder", systemImage: "waveform") {
            store.revealRecording(item)
        }

        switch store.transcriptionState(for: item) {
        case .ready:
            Button("Открыть транскрибацию", systemImage: "doc.text") {
                store.openTranscript(item)
            }
            Button("Показать транскрибацию в Finder", systemImage: "folder") {
                store.revealTranscript(item)
            }
            Button("Копировать TXT-файл", systemImage: "doc.on.doc") {
                store.copyTranscriptFile(item)
            }
            Button("Копировать текст", systemImage: "doc.on.doc") {
                store.copyTranscript(item)
            }
        case .idle, .failed:
            Button("Транскрибировать", systemImage: "captions.bubble") {
                store.transcribeRecording(item)
            }
        case .running:
            EmptyView()
        }

        MoveToFolderMenu(currentFolderID: item.folderID, tab: .recordings) { folderID in
            store.moveRecording(item, to: folderID)
        } label: {
            Label("Переместить в папку", systemImage: "folder")
        }

        Divider()
        if item.isAppleVoiceMemo {
            Button("Удалить в Apple «Диктофоне»", systemImage: "arrow.up.forward.app") {
                store.openSystemVoiceMemos()
            }
        } else {
            Button("Удалить запись", systemImage: "trash", role: .destructive) {
                store.deleteRecording(item)
            }
        }
    }
}

private struct LiveRecordingCard: View {
    @EnvironmentObject private var store: IslandStore

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.white.opacity(0.10))
                Circle()
                    .fill(Color.white.opacity(0.92))
                    .frame(width: 12, height: 12)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                Text(store.isRecordingPaused ? "Запись на паузе" : "Идёт запись")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Text(formatRecordingDuration(store.recordingElapsed))
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.68))
                systemVoiceMemosStatus
            }

            Spacer()

            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<22, id: \.self) { index in
                    Capsule()
                        .fill(index.isMultiple(of: 4) ? Color.white.opacity(0.82) : Color.white.opacity(0.42))
                        .frame(
                            width: 3,
                            height: max(4, 7 + store.recordingLevel * waveFactor(index) * 29)
                        )
                }
            }
            .frame(height: 42)

            Button {
                store.openSystemVoiceMemos()
            } label: {
                Label("Открыть Диктофон", systemImage: "arrow.up.forward.app")
                    .font(.system(size: 12.5, weight: .semibold))
                    .padding(.horizontal, 12)
                    .frame(height: IslandMetrics.toolbarControlSize)
            }
            .buttonStyle(IslandToolbarActionStyle())
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 13).fill(Color.islandCard))
    }

    private func waveFactor(_ index: Int) -> Double {
        let phase = Double(index) * 0.91 + store.recordingElapsed * 4.2
        return 0.28 + abs(sin(phase)) * 0.72
    }

    @ViewBuilder
    private var systemVoiceMemosStatus: some View {
        switch store.systemVoiceMemoState {
        case .idle:
            EmptyView()
        case .starting:
            Label("Подключаем Диктофон Apple…", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.white.opacity(0.42))
        case .recording:
            Label("Оригинал сохраняется в Apple «Диктофоне»", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.white.opacity(0.62))
        case .permissionRequired:
            Button {
                store.requestSystemVoiceMemosPermission()
            } label: {
                Label("Разрешить запуск записи", systemImage: "hand.raised.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.72))
        case .failed:
            Label("Запись в Диктофоне не запустилась", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.white.opacity(0.62))
        }
    }
}

private struct RecordingCard: View {
    @EnvironmentObject private var store: IslandStore
    let item: RecordingItem
    let compact: Bool

    private var state: RecordingTranscriptionState {
        store.transcriptionState(for: item)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 10) {
            HStack(alignment: .top) {
                Text(recordingFormat)
                    .font(.system(size: compact ? 9 : 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.76))
                    .frame(minWidth: compact ? 30 : 38)
                    .frame(height: compact ? 24 : 30)
                    .background(RoundedRectangle(cornerRadius: compact ? 7 : 8).fill(Color.white.opacity(0.085)))
                Spacer()
                Button {
                    store.togglePlayback(item)
                } label: {
                    Image(systemName: store.activePlaybackID == item.id ? "stop.fill" : "play.fill")
                        .font(.system(size: compact ? 10 : 12, weight: .semibold))
                        .frame(width: compact ? 24 : 30, height: compact ? 24 : 30)
                        .background(Circle().fill(.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }

            Text(item.title)
                .font(.system(size: compact ? 11 : 13.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(2)

            Text(recordingSubtitle)
                .font(compact ? .caption2 : .caption)
                .foregroundStyle(.white.opacity(0.42))
                .lineLimit(1)

            Spacer(minLength: 0)
            transcriptionAction
        }
        .padding(compact ? IslandMetrics.compactCardPadding : IslandMetrics.cardPadding)
        .frame(maxWidth: .infinity, minHeight: compact ? 96 : 136, alignment: .topLeading)
        .islandCardSurface(compact: compact)
        .simultaneousGesture(
            TapGesture(count: 2)
                .onEnded {
                    guard case .ready = state else { return }
                    store.openTranscript(item)
                }
        )
    }

    private var recordingSubtitle: String {
        if item.isAppleVoiceMemo {
            return "\(formatRecordingDuration(item.duration)) • Apple Диктофон"
        }
        return formatRecordingDuration(item.duration)
    }

    private var recordingFormat: String {
        item.fileName.split(separator: ".").last.map { String($0.prefix(4)).uppercased() } ?? "AUDIO"
    }

    @ViewBuilder
    private var transcriptionAction: some View {
        switch state {
        case .idle:
            Button {
                store.transcribeRecording(item)
            } label: {
                transcriptionLabel("Транскрибировать", symbol: "captions.bubble")
            }
            .buttonStyle(.plain)
        case .running:
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("Распознаём…")
                    .font(.caption.weight(.semibold))
                Spacer()
            }
            .foregroundStyle(.white.opacity(0.66))
        case .ready:
            Button {
                store.copyTranscriptFile(item)
            } label: {
                transcriptionLabel("Текст готов", symbol: "doc.text.fill")
            }
            .buttonStyle(.plain)
            .help("Один клик — копировать TXT-файл, два — открыть в TextEdit")
        case .failed:
            Button {
                store.transcribeRecording(item)
            } label: {
                transcriptionLabel("Повторить", symbol: "arrow.clockwise")
            }
            .buttonStyle(.plain)
        }
    }

    private func transcriptionLabel(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: compact ? 9.5 : 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.68))
            .lineLimit(1)
            .padding(.horizontal, compact ? 7 : 9)
            .frame(height: compact ? 24 : 27)
            .background(Capsule().fill(Color.white.opacity(0.065)))
    }
}

private func formatRecordingDuration(_ duration: TimeInterval) -> String {
    let totalSeconds = max(0, Int(duration.rounded(.down)))
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let seconds = totalSeconds % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%02d:%02d", minutes, seconds)
}

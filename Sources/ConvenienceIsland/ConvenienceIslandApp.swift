import AppKit
import Darwin
import SwiftUI

@main
struct ConvenienceIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(IslandStore.shared)
                .frame(width: 520, height: 430)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var islandWindowController: IslandWindowController?
    private var statusItem: NSStatusItem?
    private var instanceLockFileDescriptor: Int32 = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard acquireSingleInstanceLock() else {
            DistributedNotificationCenter.default().post(
                name: .convenienceIslandShowRequested,
                object: nil
            )
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.accessory)
        let controller = IslandWindowController(store: .shared)
        islandWindowController = controller
        controller.show()
        configureStatusItem()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(showIsland),
            name: .convenienceIslandShowRequested,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        guard instanceLockFileDescriptor >= 0 else { return }
        IslandStore.shared.shutdown()
        IslandStore.shared.persist()
        Darwin.close(instanceLockFileDescriptor)
        instanceLockFileDescriptor = -1
    }

    private func acquireSingleInstanceLock() -> Bool {
        let lockURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.anviby.convenience-island.instance.lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return false }
        guard Darwin.lockf(descriptor, F_TLOCK, 0) == 0 else {
            Darwin.close(descriptor)
            return false
        }
        instanceLockFileDescriptor = descriptor
        return true
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "Островок удобства")

        let menu = NSMenu()
        let showItem = NSMenuItem(title: "Показать островок", action: #selector(showIsland), keyEquivalent: "o")
        showItem.target = self
        menu.addItem(showItem)

        let positionMenu = NSMenu(title: "Положение")
        for position in IslandPosition.allCases {
            let menuItem = NSMenuItem(title: position.title, action: #selector(changePosition(_:)), keyEquivalent: "")
            menuItem.representedObject = position.rawValue
            menuItem.target = self
            positionMenu.addItem(menuItem)
        }
        let positionRoot = NSMenuItem(title: "Положение", action: nil, keyEquivalent: "")
        positionRoot.submenu = positionMenu
        menu.addItem(positionRoot)

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Настройки…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Завершить", action: #selector(quitApplication), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    @objc private func showIsland() {
        IslandStore.shared.setExpanded(true)
        islandWindowController?.show()
    }

    @objc private func changePosition(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String,
              let position = IslandPosition(rawValue: value) else { return }
        IslandStore.shared.setPosition(position)
    }

    @objc private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }
}

private extension Notification.Name {
    static let convenienceIslandShowRequested = Notification.Name(
        "com.anviby.convenience-island.show-requested"
    )
}

struct SettingsView: View {
    @EnvironmentObject private var store: IslandStore

    var body: some View {
        Form {
            Picker("Положение", selection: Binding(
                get: { store.islandPosition },
                set: { store.setPosition($0) }
            )) {
                ForEach(IslandPosition.allCases, id: \.self) { position in
                    Text(position.title).tag(position)
                }
            }
            .pickerStyle(.segmented)

            LabeledContent("Хранилище") {
                Text(store.directories.root.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Button("Открыть хранилище в Finder") {
                NSWorkspace.shared.open(store.directories.root)
            }
        }
        .padding(24)
    }
}

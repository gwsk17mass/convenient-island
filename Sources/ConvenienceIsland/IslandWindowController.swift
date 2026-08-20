import AppKit
import QuartzCore
import SwiftUI

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private enum IslandWindowSizeLimits {
    static let designedMinimum = NSSize(width: 760, height: 360)
    static let designedMaximum = NSSize(width: 1_180, height: 760)
    static let horizontalScreenMargin: CGFloat = 22
    static let bottomScreenMargin: CGFloat = 24

    struct Values {
        let minimumWidth: CGFloat
        let maximumWidth: CGFloat
        let minimumHeight: CGFloat
        let maximumHeight: CGFloat

        func clamped(_ size: NSSize) -> NSSize {
            NSSize(
                width: min(max(size.width, minimumWidth), maximumWidth),
                height: min(max(size.height, minimumHeight), maximumHeight)
            )
        }
    }

    static func values(on screen: NSScreen, top: CGFloat? = nil) -> Values {
        let availableWidth = max(1, screen.frame.width - horizontalScreenMargin * 2)
        let maximumWidth = min(designedMaximum.width, availableWidth)
        let minimumWidth = min(designedMinimum.width, maximumWidth)

        let windowTop = top ?? screen.frame.maxY
        let availableHeight = max(1, windowTop - screen.visibleFrame.minY - bottomScreenMargin)
        let maximumHeight = min(designedMaximum.height, availableHeight)
        let minimumHeight = min(designedMinimum.height, maximumHeight)

        return Values(
            minimumWidth: minimumWidth,
            maximumWidth: maximumWidth,
            minimumHeight: minimumHeight,
            maximumHeight: maximumHeight
        )
    }
}

@MainActor
final class IslandWindowController: NSWindowController {
    private let store: IslandStore
    private let collapsedSize = NSSize(width: 52, height: 30)
    private let repositionSize = NSSize(width: 94, height: 30)
    private var observers: [NSObjectProtocol] = []
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?

    init(store: IslandStore) {
        self.store = store
        let panel = IslandPanel(
            contentRect: NSRect(origin: .zero, size: collapsedSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init(window: panel)
        configure(panel)
        let hostingView = NSHostingView(rootView: IslandRootView().environmentObject(store))
        hostingView.wantsLayer = true
        hostingView.layer?.masksToBounds = true
        hostingView.layerContentsRedrawPolicy = .duringViewResize
        panel.contentView = hostingView
        observeStoreChanges()
        observeConfigurationClicks()
        moveWindow(animated: false)
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
    }

    func show() {
        guard let window else { return }
        window.orderFrontRegardless()
    }

    private func configure(_ panel: IslandPanel) {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        panel.animationBehavior = .none
        panel.isMovableByWindowBackground = false
        panel.acceptsMouseMovedEvents = true
    }

    private func observeStoreChanges() {
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: .islandExpansionChanged, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.transitionExpansion() }
            }
        )
        observers.append(
            center.addObserver(forName: .islandPositionChanged, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.moveWindow(animated: true) }
            }
        )
        observers.append(
            center.addObserver(forName: .islandRequestSnap, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.snapToNearestPosition() }
            }
        )
        observers.append(
            center.addObserver(forName: .islandPreferredSizeChanged, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.moveWindow(animated: true) }
            }
        )
        observers.append(
            center.addObserver(forName: .islandCustomSizeChanged, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.moveWindow(animated: true) }
            }
        )
        observers.append(
            center.addObserver(forName: .islandConfigurationModeChanged, object: nil, queue: .main) { [weak self] notification in
                guard let mode = notification.object as? IslandConfigurationMode, mode == .none else { return }
                Task { @MainActor in self?.moveWindow(animated: true) }
            }
        )
        observers.append(
            center.addObserver(forName: .islandCaptureVisibilityChanged, object: nil, queue: .main) { [weak self] notification in
                guard let self, let shouldHide = notification.object as? Bool else { return }
                Task { @MainActor in
                    if shouldHide {
                        self.window?.orderOut(nil)
                    } else {
                        self.window?.orderFrontRegardless()
                    }
                }
            }
        )
    }

    private func observeConfigurationClicks() {
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak store] _ in
            Task { @MainActor in
                guard store?.isRepositionModeEnabled == true else { return }
                store?.finishIslandConfiguration()
            }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self,
                  self.store.isRepositionModeEnabled,
                  event.window !== self.window else { return event }
            Task { @MainActor in self.store.finishIslandConfiguration() }
            return event
        }
    }

    private func expandedSize(on screen: NSScreen) -> NSSize {
        let limits = IslandWindowSizeLimits.values(on: screen)
        let defaultWidth = min(max(screen.frame.width * 0.66, 760), 1_000)
        let defaultHeight: CGFloat = switch store.selectedTab {
        case .screenshots:
            store.layoutMode(for: .screenshots) == .list ? 330 : 500
        case .clipboard:
            500
        case .documents, .recordings:
            520
        case .credentials:
            490
        }
        return limits.clamped(
            NSSize(
                width: store.customExpandedWidth ?? defaultWidth,
                height: store.customExpandedHeight ?? defaultHeight
            )
        )
    }

    private func targetSize(on screen: NSScreen) -> NSSize {
        if store.isExpanded { return expandedSize(on: screen) }
        return store.isRepositionModeEnabled ? repositionSize : collapsedSize
    }

    private func targetOrigin(size: NSSize, on screen: NSScreen) -> NSPoint {
        let frame = screen.frame
        let horizontalMargin = IslandWindowSizeLimits.horizontalScreenMargin
        let x: CGFloat
        if let anchor = store.islandHorizontalAnchor {
            let desiredX = frame.minX + frame.width * CGFloat(anchor) - size.width / 2
            x = min(
                max(desiredX, frame.minX + horizontalMargin),
                frame.maxX - size.width - horizontalMargin
            )
        } else {
            switch store.islandPosition {
            case .left:
                x = frame.minX + horizontalMargin
            case .center:
                x = frame.midX - size.width / 2
            case .right:
                x = frame.maxX - size.width - horizontalMargin
            }
        }
        return NSPoint(x: x, y: frame.maxY - size.height)
    }

    private func activeScreen() -> NSScreen {
        guard let window else { return NSScreen.main ?? NSScreen.screens[0] }
        return NSScreen.screens.first(where: { $0.frame.intersects(window.frame) })
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    private func moveWindow(animated: Bool) {
        guard let window else { return }
        let screen = activeScreen()
        store.setExpandedCanvasSize(expandedSize(on: screen))
        let size = targetSize(on: screen)
        let frame = NSRect(origin: targetOrigin(size: size, on: screen), size: size)
        guard !window.frame.isApproximatelyEqual(to: frame) else { return }
        guard animated else {
            window.setFrame(frame, display: true)
            return
        }

        let isGrowing = frame.height > window.frame.height + 1
        NSAnimationContext.runAnimationGroup { context in
            context.duration = isGrowing ? 0.24 : 0.18
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.20, 0.82, 0.24, 1.0)
            window.animator().setFrame(frame, display: true)
        }
    }

    private func transitionExpansion() {
        guard let window else { return }
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.displayIfNeeded()
        let screen = activeScreen()
        store.setExpandedCanvasSize(expandedSize(on: screen))
        let size = targetSize(on: screen)
        let frame = NSRect(origin: targetOrigin(size: size, on: screen), size: size)
        guard !window.frame.isApproximatelyEqual(to: frame) else { return }

        animateFrame(
            frame,
            duration: store.isExpanded ? 0.235 : 0.155,
            timing: store.isExpanded
                ? CAMediaTimingFunction(controlPoints: 0.18, 0.84, 0.22, 1.0)
                : CAMediaTimingFunction(controlPoints: 0.40, 0.0, 0.62, 1.0)
        )
    }

    private func animateFrame(
        _ frame: NSRect,
        duration: TimeInterval,
        timing: CAMediaTimingFunction
    ) {
        guard let window else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = timing
            window.animator().setFrame(frame, display: true)
        }
    }

    private func snapToNearestPosition() {
        guard let window else { return }
        let screen = activeScreen()
        var normalizedX = (window.frame.midX - screen.frame.minX) / screen.frame.width
        if abs(normalizedX - 0.5) < 0.035 {
            normalizedX = 0.5
        }
        store.setHorizontalAnchor(normalizedX)
    }
}

private extension NSRect {
    func isApproximatelyEqual(to other: NSRect) -> Bool {
        abs(origin.x - other.origin.x) < 0.5
            && abs(origin.y - other.origin.y) < 0.5
            && abs(size.width - other.size.width) < 0.5
            && abs(size.height - other.size.height) < 0.5
    }
}

struct IslandRepositionHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> RepositionHandleView {
        RepositionHandleView()
    }

    func updateNSView(_ nsView: RepositionHandleView, context: Context) {}
}

final class RepositionHandleView: NSView {
    private var initialFrame = NSRect.zero
    private var initialMouseLocation = NSPoint.zero
    private var didDrag = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        initialFrame = window.frame
        initialMouseLocation = NSEvent.mouseLocation
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - initialMouseLocation.x
        if abs(dx) > 2 { didDrag = true }
        let margin: CGFloat = 6
        let minimumX = screen.frame.minX + margin
        let maximumX = screen.frame.maxX - initialFrame.width - margin
        let desiredX = min(max(initialFrame.minX + dx, minimumX), maximumX)
        let desiredCenter = desiredX + initialFrame.width / 2
        let centerDelta = desiredCenter - screen.frame.midX
        let magneticRadius = min(86, screen.frame.width * 0.06)
        let x: CGFloat
        if abs(centerDelta) < magneticRadius {
            let proximity = 1 - abs(centerDelta) / magneticRadius
            let attraction = proximity * proximity * 0.82
            let attractedCenter = desiredCenter - centerDelta * attraction
            x = abs(centerDelta) < 9
                ? screen.frame.midX - initialFrame.width / 2
                : attractedCenter - initialFrame.width / 2
        } else {
            x = desiredX
        }
        window.setFrameOrigin(NSPoint(x: x, y: screen.frame.maxY - initialFrame.height))
    }

    override func mouseUp(with event: NSEvent) {
        Task { @MainActor in
            if didDrag {
                IslandStore.shared.snapWindowAfterDrag()
            } else {
                IslandStore.shared.finishIslandConfiguration()
            }
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}

enum IslandResizeEdge {
    case left
    case right
    case bottom
    case bottomLeft
    case bottomRight

    var changesLeft: Bool {
        self == .left || self == .bottomLeft
    }

    var changesRight: Bool {
        self == .right || self == .bottomRight
    }

    var changesBottom: Bool {
        self == .bottom || self == .bottomLeft || self == .bottomRight
    }
}

struct WindowResizeHandle: NSViewRepresentable {
    let edge: IslandResizeEdge

    func makeNSView(context: Context) -> ResizeHandleView {
        ResizeHandleView(edge: edge)
    }

    func updateNSView(_ nsView: ResizeHandleView, context: Context) {}
}

final class ResizeHandleView: NSView {
    private let edge: IslandResizeEdge
    private var initialFrame = NSRect.zero
    private var initialMouseLocation = NSPoint.zero

    init(edge: IslandResizeEdge) {
        self.edge = edge
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        initialFrame = window.frame
        initialMouseLocation = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window,
              let screen = window.screen ?? NSScreen.main else { return }

        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - initialMouseLocation.x
        let dy = mouse.y - initialMouseLocation.y
        let screenFrame = screen.frame
        let top = initialFrame.maxY
        let limits = IslandWindowSizeLimits.values(on: screen, top: top)
        var frame = initialFrame

        if edge.changesLeft {
            let fixedRight = initialFrame.maxX
            let minimumX = max(
                screenFrame.minX + IslandWindowSizeLimits.horizontalScreenMargin,
                fixedRight - limits.maximumWidth
            )
            let maximumX = fixedRight - limits.minimumWidth
            let x = min(max(initialFrame.minX + dx, minimumX), maximumX)
            frame.origin.x = x
            frame.size.width = fixedRight - x
        } else if edge.changesRight {
            let fixedLeft = initialFrame.minX
            let minimumRight = fixedLeft + limits.minimumWidth
            let maximumRight = min(
                screenFrame.maxX - IslandWindowSizeLimits.horizontalScreenMargin,
                fixedLeft + limits.maximumWidth
            )
            let right = min(max(initialFrame.maxX + dx, minimumRight), maximumRight)
            frame.size.width = right - fixedLeft
        }

        if edge.changesBottom {
            let minimumY = top - limits.maximumHeight
            let maximumY = top - limits.minimumHeight
            let y = min(max(initialFrame.minY + dy, minimumY), maximumY)
            frame.origin.y = y
            frame.size.height = top - y
        }

        window.setFrame(frame, display: true)
    }

    override func mouseUp(with event: NSEvent) {
        guard let size = window?.frame.size else { return }
        Task { @MainActor in
            IslandStore.shared.setCustomExpandedSize(size)
        }
    }

    override func resetCursorRects() {
        let cursor: NSCursor
        switch edge {
        case .left, .right:
            cursor = .resizeLeftRight
        case .bottom:
            cursor = .resizeUpDown
        case .bottomLeft, .bottomRight:
            cursor = .crosshair
        }
        addCursorRect(bounds, cursor: cursor)
    }
}

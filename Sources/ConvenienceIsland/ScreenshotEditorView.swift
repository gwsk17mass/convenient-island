import AppKit
import SwiftUI

private enum EditorTool: String, CaseIterable, Identifiable {
    case crop
    case brush
    case marker
    case text

    var id: String { rawValue }

    var title: String {
        switch self {
        case .crop: "Кадр"
        case .brush: "Кисть"
        case .marker: "Маркер"
        case .text: "Текст"
        }
    }

    var symbol: String {
        switch self {
        case .crop: "crop"
        case .brush: "pencil.tip"
        case .marker: "highlighter"
        case .text: "textformat"
        }
    }
}

private enum EditorInk: String, CaseIterable, Identifiable {
    case red
    case orange
    case yellow
    case green
    case blue
    case purple
    case white
    case black

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        case .white: .white
        case .black: .black
        }
    }

    var nsColor: NSColor {
        switch self {
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .white: .white
        case .black: .black
        }
    }
}

private struct EditorStroke {
    var points: [CGPoint]
    var ink: EditorInk
    var normalizedWidth: CGFloat
    var opacity: CGFloat
}

private struct EditorText {
    var text: String
    var point: CGPoint
    var ink: EditorInk
}

private struct CropInsets {
    var left: Double = 0
    var right: Double = 0
    var top: Double = 0
    var bottom: Double = 0
}

private enum CropHandle {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
}

struct ScreenshotEditorView: View {
    @EnvironmentObject private var store: IslandStore
    @Environment(\.dismiss) private var dismiss
    let item: ScreenshotItem

    @State private var tool: EditorTool = .crop
    @State private var ink: EditorInk = .red
    @State private var thickness = 5.0
    @State private var cropInsets = CropInsets()
    @State private var cropGestureStart: CropInsets?
    @State private var strokes: [EditorStroke] = []
    @State private var currentPoints: [CGPoint] = []
    @State private var textAnnotations: [EditorText] = []
    @State private var textDraft = ""
    @State private var imageRefreshID = UUID()
    @State private var saveError: String?

    private var imageURL: URL? { store.screenshotURL(for: item) }
    private var originalURL: URL? {
        FileSecurity.safeChildURL(
            fileName: "\(item.id.uuidString).png",
            in: store.directories.originals,
            allowedExtensions: ["png"]
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Редактор")
                    .font(.title3.weight(.semibold))
                Spacer()
                if let originalURL,
                   FileManager.default.fileExists(atPath: originalURL.path) {
                    Button("Вернуть оригинал") { restoreOriginal() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)

            Divider()

            if let imageURL,
               let image = NSImage(contentsOf: imageURL) {
                editorCanvas(image: image)
                    .id(imageRefreshID)
            } else {
                ContentUnavailableView("Снимок недоступен", systemImage: "photo.badge.exclamationmark")
            }

            Divider()
            editorToolbar

            if tool == .crop {
                cropControls
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if tool == .text {
                textControls
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack {
                Button("Отмена") { dismiss() }
                Spacer()
                Button {
                    save()
                } label: {
                    Text("Сохранить")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 18)
                        .frame(height: 32)
                        .background(Capsule().fill(Color.primary.opacity(0.12)))
                }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 15)
        }
        .frame(minWidth: 900, minHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: tool)
        .alert("Не удалось сохранить", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    private func editorCanvas(image: NSImage) -> some View {
        GeometryReader { proxy in
            let rect = aspectFitRect(imageSize: image.size, container: proxy.size)
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.88)

                Image(nsImage: image)
                    .resizable()
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)

                Canvas { context, size in
                    drawAnnotations(context: &context, size: size)
                }
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)

                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .gesture(drawingGesture(in: rect.size))

                if tool == .crop {
                    cropOverlay(in: rect.size)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(18)
    }

    private var editorToolbar: some View {
        HStack(spacing: 8) {
            ForEach(EditorTool.allCases) { candidate in
                Button {
                    tool = candidate
                } label: {
                    Label(candidate.title, systemImage: candidate.symbol)
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 10)
                        .frame(height: 36)
                        .background(Capsule().fill(tool == candidate ? Color.primary.opacity(0.11) : Color.clear))
                        .foregroundStyle(tool == candidate ? Color.primary.opacity(0.9) : Color.primary.opacity(0.62))
                }
                .buttonStyle(.plain)
            }

            Divider().frame(height: 28).padding(.horizontal, 4)

            ForEach(EditorInk.allCases) { candidate in
                Button {
                    ink = candidate
                } label: {
                    ZStack {
                        Circle()
                            .fill(candidate.color)
                            .frame(width: 22, height: 22)
                        if ink == candidate {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .heavy))
                                .foregroundStyle(candidate == .white ? Color.black.opacity(0.72) : Color.white)
                        }
                    }
                    .padding(3)
                }
                .buttonStyle(.plain)
            }

            Divider().frame(height: 28).padding(.horizontal, 4)
            Image(systemName: "lineweight")
                .foregroundStyle(.secondary)
            Slider(value: $thickness, in: 2...18)
                .frame(width: 110)

            Spacer()

            Button {
                if !strokes.isEmpty {
                    strokes.removeLast()
                } else if !textAnnotations.isEmpty {
                    textAnnotations.removeLast()
                }
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .disabled(strokes.isEmpty && textAnnotations.isEmpty)
            .help("Отменить последнее")
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
    }

    private var cropControls: some View {
        HStack(spacing: 12) {
            Label("Перетаскивайте рамку целиком, а за углы меняйте её размер", systemImage: "crop")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Сбросить рамку") {
                cropInsets = CropInsets()
            }
            .disabled(cropInsets.left == 0 && cropInsets.right == 0 && cropInsets.top == 0 && cropInsets.bottom == 0)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 10)
    }

    private func cropOverlay(in size: CGSize) -> some View {
        let crop = cropRect(in: size)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .frame(width: crop.width, height: crop.height)
                .position(x: crop.midX, y: crop.midY)
                .gesture(moveCropGesture(in: size))

            cropHandle(.topLeft, at: CGPoint(x: crop.minX, y: crop.minY), in: size)
            cropHandle(.topRight, at: CGPoint(x: crop.maxX, y: crop.minY), in: size)
            cropHandle(.bottomLeft, at: CGPoint(x: crop.minX, y: crop.maxY), in: size)
            cropHandle(.bottomRight, at: CGPoint(x: crop.maxX, y: crop.maxY), in: size)
        }
    }

    private func cropHandle(_ handle: CropHandle, at point: CGPoint, in size: CGSize) -> some View {
        ZStack {
            Circle()
                .fill(.white)
                .frame(width: 13, height: 13)
                .shadow(color: .black.opacity(0.7), radius: 2)
        }
        .frame(width: 30, height: 30)
        .contentShape(Rectangle())
        .position(point)
        .gesture(resizeCropGesture(handle, in: size))
    }

    private func moveCropGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard size.width > 0, size.height > 0 else { return }
                let start = cropGestureStart ?? cropInsets
                if cropGestureStart == nil { cropGestureStart = cropInsets }

                let width = 1 - start.left - start.right
                let height = 1 - start.top - start.bottom
                let proposedLeft = start.left + Double(value.translation.width / size.width)
                let proposedTop = start.top + Double(value.translation.height / size.height)
                let left = min(max(proposedLeft, 0), 1 - width)
                let top = min(max(proposedTop, 0), 1 - height)

                cropInsets = CropInsets(
                    left: left,
                    right: 1 - width - left,
                    top: top,
                    bottom: 1 - height - top
                )
            }
            .onEnded { _ in
                cropGestureStart = nil
            }
    }

    private func resizeCropGesture(_ handle: CropHandle, in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard size.width > 0, size.height > 0 else { return }
                let start = cropGestureStart ?? cropInsets
                if cropGestureStart == nil { cropGestureStart = cropInsets }

                let dx = Double(value.translation.width / size.width)
                let dy = Double(value.translation.height / size.height)
                let minimumSize = 0.08
                var next = start

                switch handle {
                case .topLeft:
                    next.left = min(max(start.left + dx, 0), 1 - start.right - minimumSize)
                    next.top = min(max(start.top + dy, 0), 1 - start.bottom - minimumSize)
                case .topRight:
                    next.right = min(max(start.right - dx, 0), 1 - start.left - minimumSize)
                    next.top = min(max(start.top + dy, 0), 1 - start.bottom - minimumSize)
                case .bottomLeft:
                    next.left = min(max(start.left + dx, 0), 1 - start.right - minimumSize)
                    next.bottom = min(max(start.bottom - dy, 0), 1 - start.top - minimumSize)
                case .bottomRight:
                    next.right = min(max(start.right - dx, 0), 1 - start.left - minimumSize)
                    next.bottom = min(max(start.bottom - dy, 0), 1 - start.top - minimumSize)
                }

                cropInsets = next
            }
            .onEnded { _ in
                cropGestureStart = nil
            }
    }

    private var textControls: some View {
        HStack(spacing: 10) {
            TextField("Введите текст", text: $textDraft)
                .textFieldStyle(.roundedBorder)
            Button("Добавить") {
                let trimmed = textDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                textAnnotations.append(EditorText(text: trimmed, point: CGPoint(x: 0.5, y: 0.5), ink: ink))
                textDraft = ""
            }
            .disabled(textDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 10)
    }

    private func aspectFitRect(imageSize: NSSize, container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    private func drawingGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard tool == .brush || tool == .marker, size.width > 0, size.height > 0 else { return }
                let point = CGPoint(
                    x: min(max(value.location.x / size.width, 0), 1),
                    y: min(max(value.location.y / size.height, 0), 1)
                )
                currentPoints.append(point)
            }
            .onEnded { _ in
                guard tool == .brush || tool == .marker, !currentPoints.isEmpty else {
                    currentPoints = []
                    return
                }
                strokes.append(
                    EditorStroke(
                        points: currentPoints,
                        ink: ink,
                        normalizedWidth: thickness / 900,
                        opacity: tool == .marker ? 0.36 : 1
                    )
                )
                currentPoints = []
            }
    }

    private func drawAnnotations(context: inout GraphicsContext, size: CGSize) {
        for stroke in strokes + currentStrokeIfNeeded {
            guard let first = stroke.points.first else { continue }
            var path = Path()
            path.move(to: CGPoint(x: first.x * size.width, y: first.y * size.height))
            for point in stroke.points.dropFirst() {
                path.addLine(to: CGPoint(x: point.x * size.width, y: point.y * size.height))
            }
            context.stroke(
                path,
                with: .color(stroke.ink.color.opacity(stroke.opacity)),
                style: StrokeStyle(lineWidth: stroke.normalizedWidth * min(size.width, size.height), lineCap: .round, lineJoin: .round)
            )
        }

        for annotation in textAnnotations {
            context.draw(
                Text(annotation.text)
                    .font(.system(size: max(17, min(size.width, size.height) * 0.045), weight: .semibold))
                    .foregroundStyle(annotation.ink.color),
                at: CGPoint(x: annotation.point.x * size.width, y: annotation.point.y * size.height)
            )
        }

        let crop = cropRect(in: size)
        if crop != CGRect(origin: .zero, size: size) {
            context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: crop.minY)), with: .color(.black.opacity(0.48)))
            context.fill(Path(CGRect(x: 0, y: crop.maxY, width: size.width, height: size.height - crop.maxY)), with: .color(.black.opacity(0.48)))
            context.fill(Path(CGRect(x: 0, y: crop.minY, width: crop.minX, height: crop.height)), with: .color(.black.opacity(0.48)))
            context.fill(Path(CGRect(x: crop.maxX, y: crop.minY, width: size.width - crop.maxX, height: crop.height)), with: .color(.black.opacity(0.48)))
            context.stroke(Path(crop), with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 2, dash: [7, 4]))
        }
    }

    private var currentStrokeIfNeeded: [EditorStroke] {
        guard !currentPoints.isEmpty else { return [] }
        return [EditorStroke(points: currentPoints, ink: ink, normalizedWidth: thickness / 900, opacity: tool == .marker ? 0.36 : 1)]
    }

    private func cropRect(in size: CGSize) -> CGRect {
        let left = cropInsets.left * size.width
        let right = cropInsets.right * size.width
        let top = cropInsets.top * size.height
        let bottom = cropInsets.bottom * size.height
        return CGRect(
            x: left,
            y: top,
            width: max(1, size.width - left - right),
            height: max(1, size.height - top - bottom)
        )
    }

    private func save() {
        guard let imageURL,
              let originalURL,
              let image = NSImage(contentsOf: imageURL) else { return }
        do {
            if !FileManager.default.fileExists(atPath: originalURL.path) {
                try FileManager.default.copyItem(at: imageURL, to: originalURL)
            }
            try render(image: image, to: imageURL)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func restoreOriginal() {
        guard let imageURL, let originalURL else { return }
        do {
            let data = try Data(contentsOf: originalURL)
            try data.write(to: imageURL, options: [.atomic])
            strokes = []
            textAnnotations = []
            cropInsets = CropInsets()
            imageRefreshID = UUID()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func render(image: NSImage, to destination: URL) throws {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw NSError(domain: "ConvenienceIsland.Editor", code: 1, userInfo: [NSLocalizedDescriptionKey: "Не удалось прочитать изображение."])
        }

        let width = CGFloat(source.width)
        let height = CGFloat(source.height)
        let cropX = cropInsets.left * width
        let cropY = cropInsets.bottom * height
        let cropWidth = max(1, width - (cropInsets.left + cropInsets.right) * width)
        let cropHeight = max(1, height - (cropInsets.top + cropInsets.bottom) * height)
        let crop = CGRect(x: cropX, y: cropY, width: cropWidth, height: cropHeight).integral
        guard let cropped = source.cropping(to: crop),
              let context = CGContext(
                data: nil,
                width: cropped.width,
                height: cropped.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw NSError(domain: "ConvenienceIsland.Editor", code: 2, userInfo: [NSLocalizedDescriptionKey: "Не удалось применить кадрирование."])
        }

        let outputSize = CGSize(width: cropped.width, height: cropped.height)
        context.draw(cropped, in: CGRect(origin: .zero, size: outputSize))
        context.setLineCap(.round)
        context.setLineJoin(.round)

        for stroke in strokes {
            guard let first = stroke.points.first else { continue }
            context.beginPath()
            let firstPoint = renderedPoint(first, fullWidth: width, fullHeight: height, crop: crop)
            context.move(to: firstPoint)
            for point in stroke.points.dropFirst() {
                context.addLine(to: renderedPoint(point, fullWidth: width, fullHeight: height, crop: crop))
            }
            context.setStrokeColor(stroke.ink.nsColor.withAlphaComponent(stroke.opacity).cgColor)
            context.setLineWidth(stroke.normalizedWidth * min(width, height))
            context.strokePath()
        }

        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        for annotation in textAnnotations {
            let point = renderedPoint(annotation.point, fullWidth: width, fullHeight: height, crop: crop)
            let fontSize = max(20, min(width, height) * 0.045)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: annotation.ink.nsColor
            ]
            annotation.text.draw(at: NSPoint(x: point.x, y: point.y - fontSize / 2), withAttributes: attributes)
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let output = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: output).representation(using: .png, properties: [:]) else {
            throw NSError(domain: "ConvenienceIsland.Editor", code: 3, userInfo: [NSLocalizedDescriptionKey: "Не удалось создать итоговое изображение."])
        }
        try data.write(to: destination, options: [.atomic])
    }

    private func renderedPoint(_ point: CGPoint, fullWidth: CGFloat, fullHeight: CGFloat, crop: CGRect) -> CGPoint {
        let originalX = point.x * fullWidth
        let originalTopY = point.y * fullHeight
        let topInset = cropInsets.top * fullHeight
        let localTopY = originalTopY - topInset
        return CGPoint(
            x: originalX - crop.minX,
            y: crop.height - localTopY
        )
    }
}

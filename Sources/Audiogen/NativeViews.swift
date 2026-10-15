import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct PromptEditor: NSViewRepresentable {
    @Binding var text: String
    let history: (Int) -> Void
    let focusChanged: (Bool) -> Void
    /// Handles audio files dropped on the prompt instead of inserting their paths as text.
    var audioDrop: (([URL]) -> Bool)?
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = PromptScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
        scroll.hasVerticalScroller = true
        // Transparent, so the composer's Liquid Glass shows through.
        scroll.drawsBackground = false; scroll.contentView.drawsBackground = false
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout); layout.addTextContainer(container)
        let editor = HistoryTextView(frame: scroll.contentView.bounds, textContainer: container)
        editor.minSize = NSSize(width: 0, height: 80)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isRichText = false; editor.isEditable = true; editor.isSelectable = true
        editor.drawsBackground = false
        editor.textColor = .textColor; editor.insertionPointColor = .textColor
        editor.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor, .foregroundColor: NSColor.selectedTextColor]
        editor.font = .systemFont(ofSize: 14)
        editor.textContainerInset = NSSize(width: 8, height: 10)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        container.widthTracksTextView = true
        editor.delegate = context.coordinator; editor.history = history; editor.onAudioDrop = audioDrop
        editor.onFocusChange = { context.coordinator.parent.focusChanged($0) }
        editor.string = text
        editor.setAccessibilityLabel("Audio prompt")
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? HistoryTextView else { return }
        editor.delegate = context.coordinator
        editor.onFocusChange = { context.coordinator.parent.focusChanged($0) }
        editor.history = history; editor.onAudioDrop = audioDrop
        if editor.string != text, !editor.hasMarkedText() {
            editor.string = text
            editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        editor.needsDisplay = true
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptEditor
        init(_ parent: PromptEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) { if let editor = notification.object as? NSTextView { parent.text = editor.string } }
    }
}
final class PromptScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let editor = documentView as? NSTextView else { return }
        editor.minSize = NSSize(width: 0, height: contentSize.height)
        if editor.frame.width != contentSize.width || editor.frame.height < contentSize.height {
            editor.setFrameSize(NSSize(width: contentSize.width, height: max(editor.frame.height, contentSize.height)))
        }
    }
}
final class HistoryTextView: NSTextView {
    var history: ((Int) -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    var onAudioDrop: (([URL]) -> Bool)?
    private func audioFiles(_ info: NSDraggingInfo) -> [URL] {
        guard onAudioDrop != nil else { return [] }
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { AudioFiles.acceptedExtensions.contains($0.pathExtension.lowercased()) }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { audioFiles(sender).isEmpty ? super.draggingEntered(sender) : .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { audioFiles(sender).isEmpty ? super.draggingUpdated(sender) : .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = audioFiles(sender)
        if !urls.isEmpty, let onAudioDrop { return onAudioDrop(urls) }
        return super.performDragOperation(sender)
    }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange?(false) }
        return accepted
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(visibleRect, cursor: .iBeam)
    }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            if event.keyCode == 126, selectedRange().length == 0, selectedRange().location == 0 { history?(-1); return }
            if event.keyCode == 125, selectedRange().length == 0, NSMaxRange(selectedRange()) == (string as NSString).length { history?(1); return }
        }
        super.keyDown(with: event)
    }
}

struct NativeWaveform: NSViewRepresentable {
    let player: AudioPlayer
    func makeNSView(context: Context) -> WaveformNSView { let view = WaveformNSView(); view.player = player; view.setAccessibilityElement(true); view.setAccessibilityLabel("Audio waveform"); view.setAccessibilityHelp("Click to seek, drag to select a region, or Option-drag to export audio. Arrow keys move the playhead; Shift-arrow selects."); return view }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WaveformNSView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 600, height: proposal.height ?? 240)
    }
    func updateNSView(_ view: WaveformNSView, context: Context) { view.player = player; view.needsDisplay = true }
}
final class AudioPromise: NSFilePromiseProvider {
    let source: URL
    init(source: URL, delegate: NSFilePromiseProviderDelegate) { self.source = source; super.init(fileType: UTType.wav.identifier, delegate: delegate) }
    required init?(coder: NSCoder) { nil }
    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] { super.writableTypes(for: pasteboard) + [.fileURL] }
    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == .fileURL { return source.absoluteString }
        return super.pasteboardPropertyList(forType: type)
    }
}
final class WaveformNSView: NSView, NSDraggingSource {
    var player: AudioPlayer?
    private var anchor: Double?
    private var downPoint: NSPoint?
    /// The fixed end of a selection made with Shift-arrow keys.
    private var keyAnchor: Double?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6).fill() }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { keyAnchor = nil; return super.resignFirstResponder() }
    /// Left/Right move the playhead 1 s (Option: 0.1 s), Command jumps to either end,
    /// Shift extends a selection from where it started, and Escape clears it.
    override func keyDown(with event: NSEvent) {
        guard let player, player.duration > 0 else { super.keyDown(with: event); return }
        let flags = event.modifierFlags
        switch event.keyCode {
        case 123, 124:
            let direction: Double = event.keyCode == 123 ? -1 : 1
            let current = keyAnchor.flatMap { anchor in player.selection.map { abs($0.start - anchor) < 1e-9 ? $0.end : $0.start } } ?? player.time
            let target = flags.contains(.command) ? (direction < 0 ? 0 : player.duration) : min(player.duration, max(0, current + direction * (flags.contains(.option) ? 0.1 : 1)))
            if flags.contains(.shift) {
                let fixed = keyAnchor ?? player.time
                keyAnchor = fixed
                player.selection = target == fixed ? nil : AudioRegion(start: min(fixed, target), end: max(fixed, target))
            } else { keyAnchor = nil }
            player.seek(target)
        case 115: keyAnchor = nil; player.seek(0)
        case 119: keyAnchor = nil; player.seek(player.duration)
        case 53: keyAnchor = nil; player.selection = nil
        default: super.keyDown(with: event); return
        }
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let player else { return }
        let inset: CGFloat = 24
        let width = max(1, bounds.width - inset * 2)
        let center = bounds.midY
        // With the graphite accent the accent is grey, so played audio uses the label colour instead.
        let accent = (NSColor.controlAccentColor.usingColorSpace(.sRGB)?.saturationComponent ?? 1) < 0.15 ? NSColor.labelColor : NSColor.controlAccentColor
        let playheadX = player.duration > 0 ? inset + player.time / player.duration * width : inset
        if let selection = player.selection, player.duration > 0 {
            let band = NSRect(x: inset + selection.start / player.duration * width, y: 16, width: max(1, selection.duration / player.duration * width), height: max(0, bounds.height - 32))
            accent.withAlphaComponent(0.16).setFill(); NSBezierPath(roundedRect: band, xRadius: 6, yRadius: 6).fill()
            accent.withAlphaComponent(0.7).setFill()
            NSRect(x: band.minX, y: band.minY, width: 1, height: band.height).fill(); NSRect(x: band.maxX - 1, y: band.minY, width: 1, height: band.height).fill()
        }
        // Rounded bars, 2 pt wide with 1 pt gaps; each bar shows the loudest peak it covers.
        let peaks = player.peaks
        if !peaks.isEmpty {
            let columns = max(1, Int(width / 3))
            let played = NSBezierPath(), unplayed = NSBezierPath()
            for column in 0..<columns {
                let lower = column * peaks.count / columns, upper = max(lower + 1, (column + 1) * peaks.count / columns)
                let peak = peaks[lower..<min(upper, peaks.count)].max() ?? 0
                let x = inset + CGFloat(column) * 3 + 1
                let height = max(1, CGFloat(peak) * max(1, bounds.height * 0.38))
                let bar = NSBezierPath(roundedRect: NSRect(x: x - 1, y: center - height, width: 2, height: height * 2), xRadius: 1, yRadius: 1)
                (x <= playheadX && player.time > 0 ? played : unplayed).append(bar)
            }
            NSColor.secondaryLabelColor.withAlphaComponent(0.4).setFill(); unplayed.fill()
            accent.setFill(); played.fill()
        }
        if player.duration > 0 {
            accent.setFill()
            NSRect(x: playheadX - 1, y: 14, width: 2, height: max(0, bounds.height - 28)).fill()
            NSBezierPath(ovalIn: NSRect(x: playheadX - 4, y: 10, width: 8, height: 8)).fill()
        }
    }
    private func seconds(_ event: NSEvent) -> Double { guard let player else { return 0 }; let point = convert(event.locationInWindow, from: nil); return min(1, max(0, (point.x - 24) / max(1, bounds.width - 48))) * player.duration }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); keyAnchor = nil; anchor = seconds(event); downPoint = convert(event.locationInWindow, from: nil) }
    override func mouseDragged(with event: NSEvent) {
        guard let player, let anchor else { return }
        if event.modifierFlags.contains(.option), let url = player.url, url.pathExtension.lowercased() == "wav" || player.selection != nil {
            // Drag the selected region as a clip, or the whole WAV. Both are real files, so use
            // a direct file URL instead of NSFilePromiseProvider, which traps on macOS 27.
            let file: URL
            do { guard let chosen = try AudioClips.dragFile(for: player) else { return }; file = chosen }
            catch { player.error = error.localizedDescription; self.anchor = nil; return }
            let item = NSDraggingItem(pasteboardWriter: file as NSURL)
            item.setDraggingFrame(NSRect(origin: convert(event.locationInWindow, from: nil), size: NSSize(width: 48, height: 48)), contents: NSWorkspace.shared.icon(forFile: file.path))
            beginDraggingSession(with: [item], event: event, source: self)
            self.anchor = nil; return
        }
        let end = seconds(event)
        player.selection = AudioRegion(start: min(anchor, end), end: max(anchor, end))
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard let player, anchor != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let downPoint, abs(point.x - downPoint.x) < 3 { player.selection = nil; player.seek(seconds(event)) }
        anchor = nil; needsDisplay = true
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}

/// A DisclosureGroup whose whole label row toggles it; on macOS only the small triangle does by default.
struct ClickableDisclosure<Label: View, Content: View>: View {
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content
    @ViewBuilder let label: () -> Label
    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded, content: content) {
            Button { withAnimation { isExpanded.toggle() } } label: { label().frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }
                .buttonStyle(.plain)
        }
    }
}
extension ClickableDisclosure where Label == Text {
    init(_ title: String, isExpanded: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) {
        self.init(isExpanded: isExpanded, content: content) { Text(title) }
    }
}

/// Accepts dropped files and highlights itself while a drag is over it.
private struct AudioDropZone: ViewModifier {
    let title: String
    let perform: ([URL]) -> Bool
    @State private var targeted = false
    func body(content: Content) -> some View {
        content
            .dropDestination(for: URL.self) { urls, _ in perform(urls) } isTargeted: { targeted = $0 }
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 2)
                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                        .overlay { Label(title, systemImage: "square.and.arrow.down").font(.headline).padding(.horizontal, 14).padding(.vertical, 8).background(.regularMaterial, in: Capsule()) }
                        .padding(4).allowsHitTesting(false)
                }
            }
    }
}
extension View {
    func audioDropZone(_ title: String, perform: @escaping ([URL]) -> Bool) -> some View { modifier(AudioDropZone(title: title, perform: perform)) }
}

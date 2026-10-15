import AppKit
import UserNotifications

enum SendDestination: String, CaseIterable, Identifiable {
    case reference, extract, transform, timbre
    var id: Self { self }
    var title: String {
        switch self {
        case .reference: "Use as Reference in Generate"
        case .extract: "Extract From This"
        case .transform: "Transform This"
        case .timbre: "Use as Timbre Reference"
        }
    }
}

struct AppActivity: Equatable {
    var count: Int
    var fraction: Double?
}

/// Posts a notification when work finishes while Audiogen is in the background.
@MainActor enum Notifier {
    // UserNotifications requires an app bundle; a bare `swift run` binary has none.
    private static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }
    private static var requested = false
    static func prepare() {
        guard available, !requested else { return }
        requested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    static func generationsFinished(_ names: [String], failed: Int) {
        guard !names.isEmpty || failed > 0 else { return }
        let title = names.isEmpty ? "Generation failed" : names.count == 1 ? "Generation finished" : "\(names.count) generations finished"
        var body = names.count == 1 ? names[0] : names.prefix(3).joined(separator: ", ") + (names.count > 3 ? "…" : "")
        if failed > 0 { body += (body.isEmpty ? "" : " · ") + "\(failed) failed" }
        post(title, body)
    }
    static func processingFinished(_ name: String, extraction: Bool, failed: Bool) {
        post(failed ? (extraction ? "Extraction failed" : "Transform failed") : (extraction ? "Extraction finished" : "Transform finished"), name)
    }
    private static func post(_ title: String, _ body: String) {
        guard available, !NSApp.isActive else { return }
        let content = UNMutableNotificationContent(); content.title = title; content.body = body; content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

/// Shows the number of queued jobs and current progress on the Dock icon. The count is
/// drawn into the tile rather than set as `badgeLabel`, because macOS hides badge labels
/// for apps that use notifications until the user allows badges for them.
@MainActor enum DockActivity {
    final class TileView: NSView {
        var count = 0
        var fraction: Double?
        override func draw(_ dirtyRect: NSRect) {
            NSApplication.shared.applicationIconImage?.draw(in: bounds)
            if let fraction {
                let track = NSRect(x: bounds.width * 0.12, y: bounds.height * 0.08, width: bounds.width * 0.76, height: bounds.height * 0.1)
                NSColor.black.withAlphaComponent(0.55).setFill(); NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2).fill()
                let inset = track.insetBy(dx: 2, dy: 2)
                let fill = NSRect(x: inset.minX, y: inset.minY, width: max(inset.height, inset.width * min(1, max(0, fraction))), height: inset.height)
                NSColor.controlAccentColor.setFill(); NSBezierPath(roundedRect: fill, xRadius: fill.height / 2, yRadius: fill.height / 2).fill()
            }
            guard count > 0 else { return }
            let text = NSAttributedString(string: String(count), attributes: [.font: NSFont.systemFont(ofSize: bounds.height * 0.2, weight: .semibold), .foregroundColor: NSColor.white])
            let height = bounds.height * 0.3, width = max(height, text.size().width + height * 0.5)
            let badge = NSRect(x: bounds.maxX - width - bounds.width * 0.02, y: bounds.maxY - height - bounds.height * 0.02, width: width, height: height)
            NSColor.systemRed.setFill(); NSBezierPath(roundedRect: badge, xRadius: height / 2, yRadius: height / 2).fill()
            text.draw(at: NSPoint(x: badge.midX - text.size().width / 2, y: badge.midY - text.size().height / 2))
        }
    }
    private static let tile = TileView()
    static func update(_ activity: AppActivity) {
        let dock = NSApp.dockTile
        if activity.count > 0 {
            tile.count = activity.count; tile.fraction = activity.fraction; tile.frame = NSRect(origin: .zero, size: dock.size)
            if dock.contentView !== tile { dock.contentView = tile }
            tile.needsDisplay = true
        } else { dock.contentView = nil }
        dock.display()
    }
}

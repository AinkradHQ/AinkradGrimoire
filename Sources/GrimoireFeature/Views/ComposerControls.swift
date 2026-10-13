import AinkradAppKit
import SwiftUI
import UniformTypeIdentifiers

extension Harness {
    /// The reasoning efforts the CLI takes, in its own words; empty hides the control. Claude and agy list theirs in
    /// `--help` (`--effort`); Codex's `turn/start` takes an `effort` its models advertise; OpenCode's prompt takes a
    /// provider-specific `variant` (`opencode run --variant`).
    var efforts: [String] {
        switch self {
        case .claude, .agy: ["low", "medium", "high", "xhigh", "max"]
        case .codex: ["low", "medium", "high", "xhigh"]
        case .opencode: ["low", "medium", "high", "max"]
        }
    }
}

enum Effort {
    /// "High", "Extra high"; nil (the CLI's default) is "Default".
    static func title(_ effort: String?) -> String {
        switch effort {
        case nil: "Default"
        case "xhigh": "Extra high"
        case let effort?: effort.capitalized
        }
    }
}

/// The composer strip's "EFFORT High" (mockups 1–3): how hard the agent thinks, for this thread.
struct EffortMenu: View {
    let live: LiveThread
    let harness: Harness
    let captions: Bool

    var body: some View {
        if !harness.efforts.isEmpty {
            AinkradMenuButton(
                items: harness.efforts.map { effort in
                    AinkradMenuItem(title: Effort.title(effort), systemName: effort == live.effort ? "checkmark" : nil) {
                        live.setEffort(effort)
                    }
                }
            ) {
                PullDownLabel(showsChevron: false) {
                    // Without its caption an unset effort reads "Effort", not a second "Default" beside the model's.
                    MenuValue(
                        caption: captions ? "Effort" : nil,
                        value: !captions && live.effort == nil ? "Effort" : Effort.title(live.effort))
                }
            }
            .fixedSize()
            .help("Effort")
        }
    }
}

/// Mockup 3's chips row: each image waiting to go with the next message, with ✕ to take it out.
struct AttachmentChips: View {
    let live: LiveThread
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        if !live.attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: skin.size.s6) {
                    ForEach(live.attachments) { attachment in
                        AinkradChip(label: attachment.name, systemName: "photo") {
                            live.attachments.removeAll { $0.id == attachment.id }
                        }
                        .fixedSize()
                    }
                }
            }
        }
    }
}

/// Adding images to a thread's composer: the strip's 📎, drag and drop, and ⌘V of an image.
@MainActor
enum Attach {
    /// The 📎 panel: pick images to attach.
    static func choose(into live: LiveThread) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = "Choose images to send with your next message"
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in for url in urls { add(await ImageAttachment.load(url), to: live) } }
        }
    }

    /// Images (files or image data) dropped on the composer. False when nothing dropped is an image.
    static func drop(_ providers: [NSItemProvider], into live: LiveThread) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in add(await ImageAttachment.load(url), to: live) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                accepted = true
                let name = provider.suggestedName.map { $0 + ".png" } ?? "Dropped image.png"
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in add(await ImageAttachment.load(data, name: name), to: live) }
                }
            }
        }
        return accepted
    }

    /// ⌘V: image files copied in Finder, or image data with no text (a screenshot). True when it attached.
    static func paste(_ pasteboard: NSPasteboard, into live: LiveThread) -> Bool {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
        if !urls.isEmpty {
            Task { for url in urls { add(await ImageAttachment.load(url), to: live) } }
            return true
        }
        guard pasteboard.string(forType: .string) == nil,
            let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)
        else { return false }
        Task { add(await ImageAttachment.load(data, name: "Pasted image.png"), to: live) }
        return true
    }

    private static func add(_ attachment: ImageAttachment?, to live: LiveThread) {
        if let attachment { live.attachments.append(attachment) }
    }
}

/// ⌘V in the composer's text view attaches an image on the pasteboard instead of doing nothing (the text view is
/// plain text). Watches key-downs in its own window only, while it is in one; text pastes as before.
struct PasteImageMonitor: NSViewRepresentable {
    let onPaste: (NSPasteboard) -> Bool

    func makeNSView(context: Context) -> MonitorView { MonitorView() }
    func updateNSView(_ view: MonitorView, context: Context) { view.onPaste = onPaste }

    final class MonitorView: NSView {
        var onPaste: ((NSPasteboard) -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                    event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                    event.charactersIgnoringModifiers == "v",
                    let editor = window.firstResponder as? NSTextView, editor.isEditable, !editor.isFieldEditor,
                    self.onPaste?(.general) == true
                else { return event }
                return nil
            }
        }
    }
}

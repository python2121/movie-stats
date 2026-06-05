import AppKit
import SwiftUI

/// Attach as a `.background` of a sheet's content. While the sheet is on
/// screen, this installs an `NSEvent` local mouse-down monitor that calls
/// `action` whenever the user clicks on the sheet's parent window — letting
/// us emulate "click outside to dismiss" for a real macOS `.sheet` without
/// giving up its native chrome.
struct DismissOnOutsideClick: NSViewRepresentable {
    let action: @Sendable () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let action = action
        DispatchQueue.main.async {
            context.coordinator.attach(to: view, action: action)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var monitor: Any?
        private weak var parentWindow: NSWindow?

        @MainActor
        func attach(to view: NSView, action: @escaping @Sendable () -> Void) {
            // `view.window` is the sheet's NSWindow once added to the
            // hierarchy. `sheetParent` is the host window the sheet is
            // attached to — the only "outside" we want to react to.
            parentWindow = view.window?.sheetParent
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self,
                      let parent = self.parentWindow,
                      event.window === parent else {
                    return event
                }
                Task { @MainActor in action() }
                return event
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

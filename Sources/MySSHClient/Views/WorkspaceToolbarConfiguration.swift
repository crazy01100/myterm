import AppKit
import SwiftUI

/// The workspace strip draws its own icons and titles. AppKit's generic
/// icon/label modes cannot meaningfully customize that composite item.
struct WorkspaceToolbarConfiguration: NSViewRepresentable {
    func makeNSView(context: Context) -> ConfigurationView {
        ConfigurationView(frame: .zero)
    }

    func updateNSView(_ view: ConfigurationView, context: Context) {
        view.scheduleConfiguration()
    }

    final class ConfigurationView: NSView {
        private var configurationScheduled = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleConfiguration()
        }

        override func layout() {
            super.layout()
            scheduleConfiguration()
        }

        func scheduleConfiguration() {
            guard !configurationScheduled else { return }
            configurationScheduled = true
            // SwiftUI may attach the toolbar after attaching the content view.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.configurationScheduled = false
                guard let toolbar = self.window?.toolbar else { return }
                if toolbar.allowsDisplayModeCustomization {
                    toolbar.allowsDisplayModeCustomization = false
                }
                // Also normalize a mode persisted before customization was disabled.
                // The custom workspace labels remain visible in this native mode.
                if toolbar.displayMode != .iconOnly {
                    toolbar.displayMode = .iconOnly
                }
            }
        }
    }
}

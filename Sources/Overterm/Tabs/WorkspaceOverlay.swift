import Foundation

/// A page that covers the window's body in place of the selected terminal
/// tab, and sits in the strip after the terminal tabs while open
/// (`TabStore.openOverlays`). Not a `Tab`: no terminal, no group, no ⌘1–9.
enum WorkspaceOverlay: String, Equatable {
    case settings, notes

    var title: String {
        switch self {
        case .settings: "Settings"
        case .notes: "Notes"
        }
    }

    /// The SF Symbol in front of its name in the strip.
    var symbol: String {
        switch self {
        case .settings: "gearshape"
        case .notes: "note.text"
        }
    }
}

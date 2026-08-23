import Foundation

/// Scene identifier for the multi-window app. 0.5.0 introduces this so
/// each camera can be opened in its own scene under Stage Manager (iPad)
/// and macOS Mission Control. Encoded by `WindowGroup(for: DomusCamScene.self)`
/// in [App/DomusCamApp.swift] and [AppiOS/Sources/DomusCamiOSApp.swift].
///
/// `Codable` is required by `WindowGroup` for state restoration; `Hashable`
/// is required for the scene's identity key.
public enum DomusCamScene: Hashable, Codable, Sendable {
    /// Main app window — sidebar + grid + detail.
    case main
    /// Standalone camera window — opened from the sidebar's
    /// "Open in New Window" action.
    case camera(id: UUID, channel: Int)
    /// Standalone digest window — opened by tapping an Overnight Digest
    /// notification. `day` is the day being summarized (local midnight).
    case digest(day: Date)
}

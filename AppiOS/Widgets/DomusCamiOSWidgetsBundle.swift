import WidgetKit
import SwiftUI

/// `@main` entry point for the DomusCam iOS WidgetKit + ActivityKit
/// extension (target `DomusCamiOSWidgets`).
///
/// Holds every DomusCam widget surface:
///
///   - `CameraSnapshotWidget` — Home Screen, configurable, latest
///     snapshot.
///   - `LastMotionWidget` — Lock Screen accessory family.
///   - `MotionDigestWidget` — Home Screen, daily-digest summary.
///   - `OpenCameraControlWidget` — Control Center (iOS 26+).
///   - `MotionEventActivityWidget` — in-flight motion event Live
///     Activity (Lock Screen + Dynamic Island).
///
/// All read from the shared App Group (`group.com.75-c.DomusCam`).
/// No network, no Keychain. AGENTS.md §16.
@main
struct DomusCamiOSWidgetsBundle: WidgetBundle {

    @WidgetBundleBuilder
    var body: some Widget {
        CameraSnapshotWidget()
        LastMotionWidget()
        MotionDigestWidget()
        if #available(iOS 26.0, *) {
            OpenCameraControlWidget()
            MotionEventActivityWidget()
        }
    }
}

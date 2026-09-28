import SwiftUI

/// The iPhone encoder probe of phase 0 measurement 6 (spec 09 9.11 item 6, D105): one
/// screen that runs schedule 1 on the front camera and writes log format 1 (D120).
@main
struct ZakadiProbeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

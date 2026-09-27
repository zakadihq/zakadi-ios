import SwiftUI
import ZakadiSDK
import ZakadiSDKTesting

/// The probe's one screen, portrait only. The imports are the app's dependencies,
/// resolved by the scaffold's build; Z-070 puts them to use.
struct ContentView: View {
    var body: some View {
        Text("Zakadi probe")
            .padding()
    }
}

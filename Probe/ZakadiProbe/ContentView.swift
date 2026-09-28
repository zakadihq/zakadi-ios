import SwiftUI

/// The probe's one screen, portrait only: the mirrored preview, the run button, the run's
/// progress and the log's path; a run that ends offers its log in the share sheet.
struct ContentView: View {
    @StateObject private var model = ProbeModel()

    var body: some View {
        VStack(spacing: 16) {
            CameraPreview(session: model.session)
                .aspectRatio(3 / 4, contentMode: .fit)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            status
                .frame(maxWidth: .infinity, alignment: .leading)
            if let path = model.logPath {
                Text(path)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Run") {
                    Task { await model.runCamera() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.phase == .running)
                Button("Share log") {
                    model.sharing = true
                }
                .buttonStyle(.bordered)
                .disabled(model.log == nil || model.phase == .running)
            }
        }
        .padding()
        .sheet(isPresented: $model.sharing) {
            if let log = model.log {
                ShareSheet(url: log)
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch model.phase {
        case .ready:
            Text("Hold the phone upright, then tap Run.")
        case .running:
            ProgressView(
                value: Double(model.progress.runsEnded), total: Double(model.runCount),
                label: { Text(runLabel) },
                currentValueLabel: {
                    if let started = model.started { Text(started, style: .timer) }
                })
        case .ended(let reason):
            Text("Ended: \(reason)")
        case .denied:
            Text("Camera access is off: allow it in Settings, then tap Run.")
        case .failed(let message):
            Text("The log could not be written: \(message)")
        }
    }

    private var runLabel: String {
        let begun = model.progress.runsBegun
        guard begun > 0 else { return "Starting" }
        return "Run \(begun) of \(model.runCount): keep the phone upright"
    }
}

/// The share sheet with the log: AirDrop, Mail or Save to Files.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

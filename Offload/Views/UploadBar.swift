import SwiftUI

/// The bar along the bottom: the Upload button, or how the upload is going.
struct UploadBar: View {
    @Environment(CardStore.self) private var card
    @Environment(Uploader.self) private var uploader
    @State private var confirmStop = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let t = uploader.totals
            if uploader.isRunning {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Uploading \(t.finished + t.failed) of \(t.files)")
                            .font(.subheadline.weight(.semibold))
                        Text("\(t.doneBytes.bytes) of \(t.bytes.bytes)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Stop", role: .destructive) { confirmStop = true }
                }
                ProgressView(value: Double(t.doneBytes), total: Double(max(t.bytes, 1)))
                if let paused = uploader.paused {
                    Label(paused, systemImage: "pause.circle").font(.caption).foregroundStyle(.orange)
                } else if let name = t.reading {
                    Text("Reading \(name) from the card…").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Carries on if you lock the phone or leave Offload.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if t.files > 0 && (t.finished > 0 || t.failed > 0) && card.selection.isEmpty && card.uploadable.isEmpty {
                // Finished, and nothing else to send.
                HStack {
                    Label("\(t.finished) uploaded" + (t.failed > 0 ? ", \(t.failed) failed" : ""),
                          systemImage: t.failed > 0 ? "exclamationmark.triangle" : "checkmark.circle.fill")
                        .foregroundStyle(t.failed > 0 ? .orange : .green)
                    Spacer()
                    if t.failed > 0 { Button("Retry") { uploader.retryFailed() } }
                }
                .font(.subheadline.weight(.semibold))
            }

            if !uploader.isRunning && card.root != nil {
                uploadButton
            }
        }
        .padding()
        .background(.bar)
        .confirmationDialog("Stop uploading?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop Uploading", role: .destructive) { uploader.stop() }
        } message: {
            Text("What's already in Immich stays there. The rest stays on the card.")
        }
    }

    @ViewBuilder private var uploadButton: some View {
        let picked = card.files.filter { card.selection.contains($0.rel) }
        let files = picked.isEmpty ? card.uploadable : picked
        let size = files.reduce(Int64(0)) { $0 + $1.size }
        HStack {
            Button {
                card.upload()
            } label: {
                Text(files.isEmpty ? "Nothing New to Upload"
                     : picked.isEmpty ? "Upload \(files.count) New · \(size.bytes)"
                     : "Upload \(files.count) Selected · \(size.bytes)")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(files.isEmpty || card.scanning)
            if !picked.isEmpty {
                Button("Clear") { card.selection = [] }
            }
        }
    }
}

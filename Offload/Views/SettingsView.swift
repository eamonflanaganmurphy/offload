import OffloadCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var testing = false
    @State private var result: Result<String, Error>?

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section {
                    TextField("Server", text: $settings.server, prompt: Text("https://photos.example.com"))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API Key", text: $settings.apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            Text("Test Connection")
                            Spacer()
                            if testing { ProgressView() }
                        }
                    }
                    .disabled(testing || !settings.isConfigured)
                    switch result {
                    case let .success(message)?:
                        Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case let .failure(error)?:
                        Label(error.localizedDescription, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    case nil:
                        EmptyView()
                    }
                } header: {
                    Text("Immich")
                } footer: {
                    Text("Make a key in Immich under Account Settings → API Keys. It needs asset.upload, album.read, album.create and albumAsset.create.")
                }

                Section {
                    Toggle("Add to an Album", isOn: $settings.addToAlbum)
                    Toggle("Keep the Screen On", isOn: $settings.keepAwake)
                } header: {
                    Text("Uploading")
                } footer: {
                    Text("The album is named after the card's dates, \"SD import 2026-09-28\", the same as the card reader at home uses, so a card started here and finished there ends up in one album. Photos from the card's trash don't go in it.\n\nUploads carry on with the phone locked, but they go fastest with Offload open, and the screen kept on lets it read ahead from the card.")
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onChange(of: settings.server) { result = nil }
            .onChange(of: settings.apiKey) { result = nil }
        }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        do {
            let client = try settings.client()
            try await client.ping()
            try await client.verify()
            result = .success("Connected to \(client.api.host ?? "Immich").")
        } catch {
            result = .failure(error)
        }
    }
}

import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(CardStore.self) private var card
    @Environment(Uploader.self) private var uploader
    @Environment(\.scenePhase) private var scenePhase
    @State private var picking = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            Group {
                if !settings.isConfigured {
                    ContentUnavailableView {
                        Label("Connect to Immich", systemImage: "photo.stack")
                    } description: {
                        Text("Add your Immich server and an API key to get started.")
                    } actions: {
                        Button("Open Settings") { showSettings = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else if card.root == nil {
                    ContentUnavailableView {
                        Label("Plug In the Card", systemImage: "sdcard")
                    } description: {
                        Text("Connect the card reader and tap Choose Card. The card is under Locations in the Files browser: open it and tap Open.")
                    } actions: {
                        Button("Choose Card") { picking = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    CardView()
                }
            }
            .navigationTitle(card.root == nil ? "Offload" : card.cardName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if card.root != nil {
                        Button { picking = true } label: { Label("Choose Card", systemImage: "sdcard") }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                }
            }
            .safeAreaInset(edge: .bottom) {
                // Uploads carry on with no card open, e.g. after it's taken out.
                if card.root == nil && !uploader.jobs.isEmpty { UploadBar() }
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result { card.open(url) }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .alert(settings.setupMessage ?? "", isPresented: Binding(
            get: { settings.setupMessage != nil }, set: { if !$0 { settings.setupMessage = nil } })) {
            Button("OK") {}
        }
        .task { card.restore() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { card.refresh() }
        }
        .onChange(of: settings.apiKey) { card.startCheck() }
        .onChange(of: settings.server) { card.startCheck() }
    }
}

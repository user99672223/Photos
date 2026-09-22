import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: VaultStore

    var body: some View {
        if store.onboarded {
            TabView {
                PhotosGridView()
                    .tabItem { Label("Photos", systemImage: "photo.on.rectangle") }
                LibraryView()
                    .tabItem { Label("Library", systemImage: "square.grid.2x2") }
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
            }
        } else {
            OnboardingView()
        }
    }
}

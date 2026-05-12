import SwiftUI

struct CompanionRootView: View {
    let speechController: NativeSpeechController
    let carModeRunWatcher: CarModeRunWatcher
    let carCommandListener: NativeCarCommandListener
    let idleTimerController: NativeIdleTimerController
    @AppStorage("companionURL") private var companionURL = CompanionDefaults.defaultCompanionURL
    @State private var draftURL = CompanionDefaults.defaultCompanionURL
    @State private var showingSettings = false
    @State private var loadError: String?
    @State private var webViewLoaded = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color(red: 0.04, green: 0.045, blue: 0.052)
                .ignoresSafeArea()

            if let url = URL(string: companionURL), url.scheme?.hasPrefix("http") == true {
                CompanionWebView(
                    url: url,
                    speechController: speechController,
                    carModeRunWatcher: carModeRunWatcher,
                    carCommandListener: carCommandListener,
                    idleTimerController: idleTimerController,
                    loadError: $loadError,
                    isLoaded: $webViewLoaded
                )
                .ignoresSafeArea()
            } else {
                setupView(message: "La URL del companion no es valida.")
            }

            if !webViewLoaded && loadError == nil {
                LaunchOverlay()
                    .transition(.opacity)
            }

            if loadError != nil {
                VStack(alignment: .trailing, spacing: 8) {
                    Button("Ajustar URL") {
                        draftURL = companionURL
                        showingSettings = true
                    }
                    .buttonStyle(.borderedProminent)

                    if let loadError {
                        Text(loadError)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .padding(8)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding()
            }
        }
        .onAppear {
            draftURL = companionURL
        }
        .ignoresSafeArea()
        .statusBarHidden(true)
        .animation(.easeOut(duration: 0.18), value: webViewLoaded)
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                Form {
                    Section("Companion URL") {
                        TextField("https://your-mac.your-tailnet.ts.net", text: $draftURL)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                    }

                    Section {
                        Text("La interfaz sigue viniendo de la PWA servida por MiWhisper en el Mac. Esta app solo aporta voz nativa de iOS.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("MiWhisper")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancelar") {
                            showingSettings = false
                        }
                    }

                    ToolbarItem(placement: .confirmationAction) {
                        Button("Guardar") {
                            companionURL = draftURL.trimmingCharacters(in: .whitespacesAndNewlines)
                            loadError = nil
                            showingSettings = false
                        }
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }

    private func setupView(message: String) -> some View {
        VStack(spacing: 14) {
            Text("MiWhisper Companion")
                .font(.title3.weight(.semibold))

            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)

            Button("Configurar URL") {
                draftURL = companionURL
                showingSettings = true
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

private struct LaunchOverlay: View {
    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.045, blue: 0.052)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Image("BrandIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 86, height: 86)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: .black.opacity(0.28), radius: 18, y: 10)

                VStack(spacing: 6) {
                    Text("MiWhisper")
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)

                    Text("Companion")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white.opacity(0.58))
                }

                ProgressView()
                    .tint(.white.opacity(0.82))
                    .padding(.top, 4)
            }
            .padding(.horizontal, 28)
        }
        .accessibilityLabel("Cargando MiWhisper")
    }
}

enum CompanionDefaults {
    static let defaultCompanionURL = "https://your-mac.your-tailnet.ts.net"
}

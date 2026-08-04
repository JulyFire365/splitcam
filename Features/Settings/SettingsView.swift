import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @ObservedObject var settings: AppSettings
    @ObservedObject private var subscriptionManager = SubscriptionManager.shared

    var body: some View {
        NavigationStack {
            List {
                Section("settings.section.appearance".localized) {
                    NavigationLink {
                        AppIconPickerView(settings: settings)
                    } label: {
                        HStack(spacing: 12) {
                            Image(settings.selectedAppIcon.previewImageName)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 34, height: 34)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                            Text("settings.appIcon".localized)
                            Spacer()
                            Text(settings.selectedAppIcon.displayName)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("settings.section.capture".localized) {
                    NavigationLink {
                        AspectRatioPickerView(settings: settings)
                    } label: {
                        LabeledContent("settings.aspectRatio".localized, value: settings.defaultAspectRatio.rawValue)
                    }

                    Toggle("settings.frontMirror".localized, isOn: $settings.frontCameraMirrored)
                    Toggle("settings.rememberLayout".localized, isOn: $settings.remembersLastLayout)

                    Picker("settings.videoQuality".localized, selection: $settings.defaultVideoQuality) {
                        ForEach(ResolutionQuality.allCases, id: \.self) { quality in
                            Text(quality.displayName).tag(quality)
                        }
                    }
                }

                Section("settings.section.support".localized) {
                    Button {
                        ReviewPromptManager.shared.recordManualReviewIntent()
                        if let reviewURL = URL(string: "https://apps.apple.com/app/id6761194664?action=write-review") {
                            openURL(reviewURL)
                        }
                    } label: {
                        Label("settings.rate".localized, systemImage: "star.bubble")
                    }

                    if !subscriptionManager.isPro {
                        Button {
                            Task { await subscriptionManager.restorePurchases() }
                        } label: {
                            Label("paywall.restore".localized, systemImage: "arrow.clockwise")
                        }
                    }
                }

                Section("settings.section.about".localized) {
                    LabeledContent("settings.version".localized, value: appVersion)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .foregroundStyle(.white)
            .navigationTitle("settings.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("settings.done".localized) { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var appVersion: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(shortVersion) (\(build))"
    }
}

/// A dedicated, full-row selection screen avoids the inconsistent hit target of a Picker inside List.
private struct AspectRatioPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var settings: AppSettings

    var body: some View {
        List {
            Section {
                ForEach(AspectRatioMode.allCases) { ratio in
                    Button {
                        settings.defaultAspectRatio = ratio
                        dismiss()
                    } label: {
                        HStack {
                            Text(ratio.rawValue)
                            Spacer()
                            if ratio == settings.defaultAspectRatio {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.yellow)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .foregroundStyle(.white)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .navigationTitle("settings.aspectRatio".localized)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AppIconPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var settings: AppSettings
    @State private var changingIcon = false
    @State private var errorMessage: String?

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(SplitCamAppIcon.allCases) { icon in
                    Button {
                        select(icon)
                    } label: {
                        VStack(spacing: 10) {
                            Image(icon.previewImageName)
                                .resizable()
                                .scaledToFill()
                                .frame(maxWidth: .infinity)
                                .aspectRatio(1, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                                        .stroke(icon == settings.selectedAppIcon ? Color.yellow : .white.opacity(0.16), lineWidth: icon == settings.selectedAppIcon ? 3 : 1)
                                }

                            HStack(spacing: 6) {
                                Text(icon.displayName)
                                    .font(.subheadline.weight(.semibold))
                                if icon == settings.selectedAppIcon {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.yellow)
                                }
                            }
                            .foregroundStyle(.white)
                        }
                    }
                    .disabled(changingIcon || icon == settings.selectedAppIcon)
                }
            }
            .padding(20)
        }
        .background(Color.black)
        .navigationTitle("settings.appIcon".localized)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if changingIcon {
                ProgressView()
                    .tint(.white)
            }
        }
        .alert("error".localized, isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("ok".localized, role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func select(_ icon: SplitCamAppIcon) {
        changingIcon = true
        Task {
            defer { changingIcon = false }
            do {
                try await settings.selectAppIcon(icon)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

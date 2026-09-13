import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @ObservedObject var settings: AppSettings
    @ObservedObject private var subscriptionManager = SubscriptionManager.shared
    @State private var showPaywall = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    subscriptionStatusRow
                }

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

                    NavigationLink {
                        VideoQualityPickerView(settings: settings)
                    } label: {
                        LabeledContent("settings.videoQuality".localized, value: settings.defaultVideoQuality.displayName)
                    }
                }

                Section("settings.section.support".localized) {
                    Link(destination: URL(string: "mailto:captainlongevity@gmail.com")!) {
                        HStack {
                            Label("settings.contact".localized, systemImage: "envelope")
                            Spacer()
                            Text("captainlongevity@gmail.com")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        ReviewPromptManager.shared.recordManualReviewIntent()
                        if let reviewURL = URL(string: "https://apps.apple.com/app/id6761194664?action=write-review") {
                            openURL(reviewURL)
                        }
                    } label: {
                        Label("settings.rate".localized, systemImage: "star.bubble")
                    }
                }

                Section("settings.section.moreApps".localized) {
                    Link(destination: URL(string: "https://apps.apple.com/app/id6762594124")!) {
                        HStack(spacing: 12) {
                            Image("CustodyJournalIcon")
                                .resizable()
                                .scaledToFill()
                                .frame(width: 40, height: 40)
                                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Custody Journal")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text("settings.custodyJournal.subtitle".localized)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Image(systemName: "arrow.up.right.square")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
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
        .fullScreenCover(isPresented: $showPaywall) {
            PaywallView(triggeredBy: nil)
        }
    }

    @ViewBuilder
    private var subscriptionStatusRow: some View {
        if subscriptionManager.isPro {
            subscriptionRow(
                title: "SplitCam Pro",
                subtitle: "settings.subscription.active".localized,
                icon: "checkmark.seal.fill",
                trailingIcon: nil
            )
        } else {
            Button { showPaywall = true } label: {
                subscriptionRow(
                    title: "SplitCam Pro",
                    subtitle: "settings.subscription.cta".localized,
                    icon: "sparkles",
                    trailingIcon: "chevron.right"
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func subscriptionRow(
        title: String,
        subtitle: String,
        icon: String,
        trailingIcon: String?
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.orange)
                .frame(width: 32, height: 32)
                .background(.orange.opacity(0.16), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let trailingIcon {
                Image(systemName: trailingIcon)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
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

struct VideoQualityPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var settings: AppSettings

    var body: some View {
        List {
            Section {
                ForEach(ResolutionQuality.allCases, id: \.self) { quality in
                    Button {
                        settings.defaultVideoQuality = quality
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(quality.displayName)
                                    .font(.body.weight(.medium))
                                Text(quality.detail)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text("quality.estimate".localized("\(quality.estimatedMegabytesPerMinute)"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if quality == settings.defaultVideoQuality {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.yellow)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .foregroundStyle(.white)
                }
            } footer: {
                Text("quality.footer".localized)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .navigationTitle("settings.videoQuality".localized)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AppIconPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var settings: AppSettings
    @ObservedObject private var subscriptionManager = SubscriptionManager.shared
    @State private var changingIcon = false
    @State private var errorMessage: String?
    @State private var showPaywall = false

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(SplitCamAppIcon.allCases) { icon in
                    Button {
                        selectOrPresentPaywall(for: icon)
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
                                .overlay(alignment: .topTrailing) {
                                    if icon.requiresPro && !subscriptionManager.isPro {
                                        Text("PRO")
                                            .font(.system(size: 10, weight: .bold, design: .rounded))
                                            .foregroundStyle(.black)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 4)
                                            .background(.yellow, in: Capsule())
                                            .padding(8)
                                    }
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
        .fullScreenCover(isPresented: $showPaywall) {
            PaywallView(triggeredBy: .appIcons)
        }
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

    private func selectOrPresentPaywall(for icon: SplitCamAppIcon) {
        if icon.requiresPro && !subscriptionManager.isPro {
            showPaywall = true
        } else {
            select(icon)
        }
    }
}

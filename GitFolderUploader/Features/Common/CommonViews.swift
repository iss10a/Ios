//
//  CommonViews.swift
//  GitFolderUploader
//
//  Small reusable presentation pieces shared by every feature screen.
//

import SwiftUI

/// Wraps a `URL` so it can drive `.sheet(item:)` without a retroactive
/// `Identifiable` conformance on a Foundation type.
struct IdentifiableURL: Identifiable, Hashable {
    let id = UUID()
    let url: URL
}

/// Full-screen "nothing here yet" state.
struct EmptyStateView: View {

    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Design.spacing) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let actionTitle = actionTitle, let action = action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

/// Inline error banner with an optional retry.
struct ErrorBanner: View {

    let message: String
    var retry: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: Design.tightSpacing) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                if let retry = retry {
                    Button(L10n.t("common.retry"), action: retry)
                        .font(.footnote.weight(.semibold))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Design.spacing)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: Design.smallRadius))
        .padding(.horizontal)
    }
}

/// Centred spinner with a caption.
struct LoadingView: View {
    var title: String = L10n.t("common.loading")

    var body: some View {
        VStack(spacing: Design.spacing) {
            ProgressView()
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Determinate bar plus a caption, used by upload and download screens.
struct ProgressBar: View {

    let fraction: Double
    var caption: String?
    var tint: Color = .brand

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: min(max(fraction, 0), 1))
                .tint(tint)
            if let caption = caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Compact key/value row for detail screens.
struct DetailRow: View {

    let title: String
    let value: String
    var monospaced: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: Design.spacing)
            Text(value)
                .multilineTextAlignment(.trailing)
                .font(monospaced ? .caption.monospaced() : .body)
                .textSelection(.enabled)
        }
        .font(.subheadline)
    }
}

/// Presents an alert bound to an optional error message.
struct ErrorAlertModifier: ViewModifier {

    @Binding var message: String?

    func body(content: Content) -> some View {
        content.alert(L10n.t("common.error"),
                      isPresented: Binding(get: { message != nil },
                                           set: { if !$0 { message = nil } })) {
            Button(L10n.t("common.ok"), role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
    }
}

extension View {
    /// Shows a standard error alert whenever `message` becomes non-nil.
    func errorAlert(_ message: Binding<String?>) -> some View {
        modifier(ErrorAlertModifier(message: message))
    }
}

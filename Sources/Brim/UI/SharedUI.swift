// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

struct FullDiskAccessNote: View {
    var compact = false
    /// Why this surface needs the permission. The scan is the usual reason;
    /// a failed removal has its own, so it says so in its own words.
    var reason: String?

    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var permissions = Permissions.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: compact ? 7 : 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text(reason ?? l10n.s.uninstallerFDANote)
                    .font(compact ? .system(size: 10) : .caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(l10n.s.uninstallerFDAHint)
                .font(compact ? .system(size: 9) : .caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: compact ? 7 : 8) {
                Button(l10n.s.uninstallerFDAGrant) { permissions.requestFullDiskAccess() }
                // Shown alongside because access only takes effect on relaunch.
                Button(l10n.s.uninstallerFDARelaunch) { appDelegate()?.relaunchApp() }
            }
            .controlSize(.small)
            .font(compact ? .system(size: 10.5) : nil)
        }
        // Take the width the host offers, so the card lines up with the cards
        // around it instead of shrinking to its longest line.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(compact ? 9 : 11)
        .background(
            RoundedRectangle(cornerRadius: compact ? 8 : 9, style: .continuous)
                .fill(Color.primary.opacity(compact ? 0.045 : 0.05))
        )
    }
}

/// What a removal left behind, and why. Sandboxed app data lives in
/// ~/Library/Containers, which macOS keeps behind Full Disk Access; the
/// administrator prompt Finder shows covers file ownership, not that
/// permission, so those items are refused however the removal is attempted.
/// Naming them at the moment they survive is the only point where the
/// permission has visibly cost the person something.
struct UninstallFailureNote: View {
    let items: [AppUninstaller.Leftover]
    var compact = false

    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var permissions = Permissions.shared

    private static let namesShown = 4

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 7) {
            Text(l10n.s.uninstallerSomeFailed)
                .font(compact ? .system(size: 10) : .caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(items.prefix(Self.namesShown)) { item in
                Text(item.name)
                    .font(compact ? .system(size: 9.5) : .caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if items.count > Self.namesShown {
                Text(String(format: l10n.s.uninstallerFailedMoreFormat,
                            items.count - Self.namesShown))
                    .font(compact ? .system(size: 9.5) : .caption2)
                    .foregroundStyle(.tertiary)
            }
            if !permissions.fullDiskAccess,
               UninstallerSupport.failureNeedsFullDiskAccess(paths: items.map(\.url.path)) {
                FullDiskAccessNote(compact: compact, reason: l10n.s.uninstallerFailedNeedsFDA)
            }
        }
    }
}

/// Why the uninstaller turned down the app just dropped on it. The drop
/// springs back, which on its own read as the drop never arriving (#1582).
struct UninstallRefusalNote: View {
    let refusal: UninstallerSupport.RefusedApp
    var compact = false

    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        HStack(alignment: .top, spacing: compact ? 6 : 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(refusal.message(l10n.s))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(compact ? .system(size: 10) : .caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A disclosure header where the whole row toggles the group and the chevron
/// sits on the trailing side, the way a drop-down reads. The label supplies
/// the row's one Spacer, so trailing accessories stay flush to the chevron.
struct DisclosureHeaderRow<Label: View>: View {
    @ObservedObject private var l10n = L10n.shared

    private let isExpanded: Binding<Bool>
    private let label: () -> Label

    init(isExpanded: Binding<Bool>, @ViewBuilder label: @escaping () -> Label) {
        self.isExpanded = isExpanded
        self.label = label
    }

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                isExpanded.wrappedValue.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                label()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isExpanded.wrappedValue
            ? l10n.s.disclosureExpanded : l10n.s.disclosureCollapsed)
    }
}

/// A checkbox that can also show AppKit's mixed state, which SwiftUI's Toggle
/// cannot draw. One control stands for a list of independently checkable rows:
/// all checked, none, or a dash for some of each.
struct MixedStateCheckbox: NSViewRepresentable {
    let title: String
    let isOn: Bool
    let isMixed: Bool
    var isEnabled = true
    /// The title's point size, matched to the text around each use site.
    var fontSize: CGFloat = 12

    let onToggle: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: context.coordinator,
                              action: #selector(Coordinator.toggled(_:)))
        button.allowsMixedState = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.onToggle = onToggle
        button.title = title
        button.font = .systemFont(ofSize: fontSize)
        button.isEnabled = isEnabled
        // The model decides the value; AppKit's own click cycling is undone
        // here on the next render.
        button.state = isMixed ? .mixed : (isOn ? .on : .off)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onToggle: onToggle) }

    final class Coordinator: NSObject {
        var onToggle: () -> Void

        init(onToggle: @escaping () -> Void) { self.onToggle = onToggle }

        @objc func toggled(_ sender: NSButton) { onToggle() }
    }
}

extension View {
    /// Child rows sit inset under their group's header row.
    func disclosureIndent() -> some View {
        padding(.leading, 25)
    }
}

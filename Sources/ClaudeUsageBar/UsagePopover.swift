import SwiftUI

struct UsagePopover: View {
    @Bindable var model: UsageModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
    }

    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header(now: now)

            if model.isSigningIn {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Finish signing in in your browser…").foregroundStyle(.secondary)
                }
                HStack {
                    Button("Open browser again", action: model.signIn)
                    Button("Cancel", action: model.cancelSignIn)
                }
            } else if !model.hasSession {
                Text("Sign in with your Claude account to show your plan usage.")
                    .foregroundStyle(.secondary)
                Button("Sign in with Claude…", action: model.signIn)
                    .buttonStyle(.borderedProminent)
            } else if model.windows.isEmpty, model.error == nil {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading usage…").foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(model.windows) { UsageRow(window: $0, now: now) }
                }
            }

            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
    }

    private func header(now: Date) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude usage").font(.headline)
                if let account = model.account {
                    Text(account).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.isRefreshing {
                ProgressView().controlSize(.small)
            } else if let lastUpdated = model.lastUpdated {
                Text(now.timeIntervalSince(lastUpdated) < 60
                     ? "Updated just now"
                     : "Updated \(shortDuration(now.timeIntervalSince(lastUpdated))) ago")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Launch at login", isOn: $model.launchAtLogin)
                .toggleStyle(.checkbox)
            HStack {
                Button("Refresh", systemImage: "arrow.clockwise", action: model.refreshNow)
                    .disabled(!model.hasSession || model.isRefreshing)
                Button("claude.ai", systemImage: "safari") {
                    NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
                }
                Spacer()
                Menu {
                    Button(model.hasSession ? "Switch account…" : "Sign in with Claude…", action: model.signIn)
                    if model.hasSession { Button("Sign out", action: model.signOut) }
                    Divider()
                    Button("Quit Claude Usage Bar") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "gearshape")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .labelStyle(.titleAndIcon)
        }
    }
}

private struct UsageRow: View {
    let window: UsageWindow
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.title).font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(UsageModel.percent(window.remaining)) left")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(color)
            }
            // Drawn by hand: ProgressView ignores `.tint` when the popover isn't the key window.
            Capsule()
                .fill(.quaternary)
                .frame(height: 6)
                .overlay(alignment: .leading) {
                    GeometryReader { geometry in
                        Capsule()
                            .fill(color)
                            .frame(width: geometry.size.width * min(window.utilization, 100) / 100)
                    }
                }
            HStack {
                Text("\(UsageModel.percent(window.utilization)) used")
                Spacer()
                if let resetsAt = window.resetsAt { Text(resetText(resetsAt)) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }

    private var color: Color {
        UsageLevel(remaining: window.remaining).popoverColor
    }

    private func resetText(_ date: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "Resetting…" }
        let style: Date.FormatStyle = Calendar.current.isDate(date, inSameDayAs: now)
            ? .dateTime.hour().minute()
            : .dateTime.weekday(.abbreviated).hour().minute()
        return "Resets in \(shortDuration(seconds)) · \(date.formatted(style))"
    }
}

/// "2d 4h", "3h 12m", "7m".
private func shortDuration(_ interval: TimeInterval) -> String {
    let seconds = Int(interval)
    let days = seconds / 86_400, hours = seconds % 86_400 / 3600, minutes = seconds % 3600 / 60
    if days > 0 { return "\(days)d \(hours)h" }
    if hours > 0 { return "\(hours)h \(minutes)m" }
    return "\(max(minutes, 1))m"
}

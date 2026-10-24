import SwiftUI
import AppKit

/// Offers Docker Desktop when the Mac has no container runtime: shown once at first launch, and from Stacks.
struct DockerSetupSheet: View {
    @StateObject private var installer = DockerDesktopInstaller()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Docker for Stacks", systemImage: "shippingbox").font(Typo.panelTitle)
            Text("Atlas runs each stack's Terraform or OpenTofu in its own isolated Docker container. Docker isn't installed on this Mac.")
            Text("Atlas can download Docker Desktop from docker.com, check that it is signed by Docker Inc and install it in Applications. Docker Desktop then asks you to accept its terms and for your password to finish its setup. It is free for personal use and small businesses; larger companies need a Docker subscription.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Without Docker, stacks run with the terraform or tofu installed on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
            status
            HStack {
                Spacer()
                switch installer.phase {
                case .done:
                    Button("Open Docker Desktop") {
                        NSWorkspace.shared.openApplication(at: installer.installedApp, configuration: .init())
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                default:
                    Button("Not Now") { dismiss() }.keyboardShortcut(.cancelAction).disabled(installer.phase.isWorking)
                    Button("Install Docker Desktop") { Task { await installer.install() } }
                        .keyboardShortcut(.defaultAction).disabled(installer.phase.isWorking)
                }
            }
        }
        .padding(20)
        .frame(width: 500)
        .interactiveDismissDisabled(installer.phase.isWorking)
    }

    @ViewBuilder private var status: some View {
        switch installer.phase {
        case .idle: EmptyView()
        case .downloading(let f):
            ProgressView(value: f) { Text("Downloading Docker Desktop… \(Int(f * 100))%").font(.callout) }
        case .verifying: ProgressView { Text("Checking Docker Inc's signature…").font(.callout) }
        case .installing: ProgressView { Text("Copying Docker.app to Applications…").font(.callout) }
        case .done: Label("Installed. Open it once to finish its setup; Atlas uses it from then on.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Palette.success)
        case .failed(let message): Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Palette.danger)
        }
    }
}

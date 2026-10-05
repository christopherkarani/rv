#if canImport(SwiftUI)
import SwiftUI
import RVIPC

/// Trusted review surface. Everything shown comes from the bound challenge
/// bundle the server issued to this connection; the Authorize button is the
/// only path to device-owner authentication, and Deny cancels without
/// authenticating.
///
/// All server strings render through `ReviewDisplayEscape` as
/// `Text(verbatim:)` — literal by construction, full values, no silent
/// truncation of security-relevant parameters.
public struct OperatorReviewView: View {
    @Bindable var model: OperatorReviewModel

    public init(model: OperatorReviewModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            List(model.items, id: \.operationID, selection: selection) { item in
                VStack(alignment: .leading) {
                    Text(verbatim: ReviewDisplayEscape.escape(item.definitionID ?? item.executable))
                        .font(.headline)
                        .lineLimit(1)
                    Text(verbatim: ReviewDisplayEscape.escape(item.status))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Launch requests")
            .toolbar {
                Button("Refresh") {
                    Task { await model.refresh() }
                }
                .disabled(model.connection != .connected)
            }
        } detail: {
            if let bound = model.bound {
                ReviewDetailView(bundle: bound, model: model)
            } else {
                ContentUnavailableView(
                    "No review selected",
                    systemImage: "checkmark.shield",
                    description: Text(connectionHint))
            }
        }
        .task {
            await model.connect()
        }
        .alert("Notice", isPresented: noticeBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.notice ?? "")
        }
    }

    private var selection: Binding<UUID?> {
        Binding(
            get: { model.selectedID },
            set: { id in Task { await model.select(id) } })
    }

    private var noticeBinding: Binding<Bool> {
        Binding(
            get: { model.notice != nil },
            set: { if !$0 { Task { await model.dismissNotice() } } })
    }

    private var connectionHint: String {
        switch model.connection {
        case .disconnected:
            return "Not connected to rvd."
        case .connecting:
            return "Connecting to rvd…"
        case .connected:
            return "Select a request to review it."
        case .failed(let reason):
            return reason
        }
    }
}

private struct ReviewDetailView: View {
    let bundle: UIChallengeBundleDTO
    @Bindable var model: OperatorReviewModel

    var body: some View {
        Form {
            Section("Request") {
                row("Kind", bundle.item.kind)
                if let definition = bundle.item.definitionID {
                    row("Definition", definition)
                }
                if let digest = bundle.item.definitionRevisionDigest {
                    row("Revision", short(digest))
                }
                row("Executable", bundle.item.executable)
                if let digest = bundle.item.expectedContentDigest {
                    // Claimed, not measured: no step hashes the file. Byte
                    // enforcement is measured-launch scope; the label must
                    // not imply the bytes were verified.
                    row("Content digest (unverified)", short(digest))
                }
                row("Working directory", bundle.item.workingDirectory)
                row("Arguments", bundle.item.arguments.joined(separator: " "))
                row("IO", ioText(bundle.item.io))
                row("Environment", bundle.item.environmentPolicy)
                row("Intent digest", short(bundle.item.intentDigestHex))
                row("Status", bundle.item.status)
            }
            Section {
                HStack {
                    Button("Deny") {
                        Task { await model.deny() }
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Button("Authorize…") {
                        Task { await model.authorize() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.authenticating)
                }
            } footer: {
                if model.authenticating {
                    Text("Waiting for device-owner authentication…")
                } else if let status = model.lastStatus {
                    Text("Last result: \(status)")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Review")
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            Text(verbatim: ReviewDisplayEscape.escape(value.isEmpty ? "—" : value))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func short(_ hex: String) -> String {
        String(hex.prefix(16)) + (hex.count > 16 ? "…" : "")
    }

    private func ioText(_ io: UIIODTO) -> String {
        switch io {
        case .discard:
            return "discard"
        case .pseudoTerminal(let rows, let columns):
            return "pty \(columns)×\(rows)"
        }
    }
}
#endif

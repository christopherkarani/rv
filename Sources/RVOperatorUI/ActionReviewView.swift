#if canImport(SwiftUI)
import SwiftUI
import RVIPC

/// Trusted action-approval review surface. Distinct mode from
/// `OperatorReviewView` (launch): different title, different item type,
/// different buttons, different model. Everything shown comes from the
/// bound challenge bundle the server issued to this connection; the
/// Allow-once button is the only path to device-owner authentication, and
/// Deny denies without authenticating.
///
/// All server strings render through `ReviewDisplayEscape` as
/// `Text(verbatim:)` — literal by construction, full values, no silent
/// truncation of security-relevant parameters.
public struct OperatorActionReviewView: View {
    @Bindable var model: OperatorActionReviewModel

    public init(model: OperatorActionReviewModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            List(model.items, id: \.approvalID, selection: selection) { item in
                VStack(alignment: .leading) {
                    Text(verbatim: ReviewDisplayEscape.escape(item.actionKind))
                        .font(.headline)
                        .lineLimit(1)
                    Text(verbatim: ReviewDisplayEscape.escape(item.status))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Action approvals")
            .toolbar {
                Button("Refresh") {
                    Task { await model.refresh() }
                }
                .disabled(model.connection != .connected)
            }
        } detail: {
            if let bound = model.bound {
                ActionReviewDetailView(bundle: bound, model: model)
            } else {
                ContentUnavailableView(
                    "No action selected",
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
            set: { if !$0 { Task { model.dismissNotice() } } })
    }

    private var connectionHint: String {
        switch model.connection {
        case .disconnected:
            return "Not connected to rvd."
        case .connecting:
            return "Connecting to rvd…"
        case .connected:
            return "Select an action to review it."
        case .failed(let reason):
            return reason
        }
    }
}

private struct ActionReviewDetailView: View {
    let bundle: UIActionChallengeBundleDTO
    @Bindable var model: OperatorActionReviewModel

    var body: some View {
        Form {
            Section("Agent") {
                row("Definition", bundle.item.definitionID)
                row("Revision", bundle.item.definitionRevisionDigest)
                row("Instance", bundle.item.instanceID.uuidString)
                row("Runtime", bundle.item.runtimeSessionID.uuidString)
                row("Workspace", bundle.item.workspaceSessionID.uuidString)
            }
            Section("Action") {
                row("Kind", bundle.item.actionKind)
                row("Target", bundle.item.exactTarget)
                row("Arguments", bundle.item.exactArguments)
                row("Policy reason", bundle.item.policyReason)
                row("Scope", bundle.item.scopeSummary)
                row("Action digest", bundle.item.actionDigestHex)
                row("Status", bundle.item.status)
            }
            Section {
                HStack {
                    Button("Deny") {
                        Task { await model.deny() }
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Button("Allow once…") {
                        Task { await model.allowOnce() }
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
        .navigationTitle("Review action")
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
}
#endif

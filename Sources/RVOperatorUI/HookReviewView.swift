#if canImport(SwiftUI)
import SwiftUI
import RVIPC

/// Trusted hook-ask review surface. Distinct mode from
/// `OperatorReviewView` (launch) and `OperatorActionReviewView` (action):
/// different title, different item type, different buttons, different
/// model. Everything shown comes from the bound challenge bundle the
/// server issued to this connection; the Allow-once button is the only
/// path to device-owner authentication, and Deny denies without
/// authenticating.
///
/// All server strings render through `ReviewDisplayEscape` as
/// `Text(verbatim:)` — literal by construction, full values, no silent
/// truncation of security-relevant parameters.
public struct OperatorHookReviewView: View {
    @Bindable var model: OperatorHookReviewModel

    public init(model: OperatorHookReviewModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            List(model.items, id: \.approvalID, selection: selection) { item in
                VStack(alignment: .leading) {
                    Text(verbatim: ReviewDisplayEscape.escape(item.exactCommand))
                        .font(.headline)
                        .lineLimit(1)
                    Text(verbatim: ReviewDisplayEscape.escape("\(item.host) · \(item.status.rawValue)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Coding-agent requests")
            .toolbar {
                Button("Refresh") {
                    Task { await model.refresh() }
                }
                .disabled(model.connection != .connected)
            }
        } detail: {
            if let bound = model.bound {
                HookReviewDetailView(bundle: bound, model: model)
            } else {
                ContentUnavailableView(
                    "No request selected",
                    systemImage: "terminal",
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

    private var selection: Binding<String?> {
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
            return "Select a request to review it."
        case .failed(let reason):
            return reason
        }
    }
}

private struct HookReviewDetailView: View {
    let bundle: UIHookChallengeBundleDTO
    @Bindable var model: OperatorHookReviewModel

    var body: some View {
        Form {
            Section("Source") {
                row("Host", bundle.item.host)
                row("Session", bundle.item.session)
                row("Reason", bundle.item.policyReason)
            }
            Section("Action") {
                row("Kind", bundle.item.actionKind)
                row("Command", bundle.item.exactCommand)
                row("Directory", bundle.item.workingDirectory)
                row("Fingerprint", bundle.item.actionFingerprint)
                row("Status", bundle.item.status.rawValue)
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
                    .disabled(model.authenticating || !model.allowOnceAvailable)
                }
            } footer: {
                if model.authenticating {
                    Text("Waiting for device-owner authentication…")
                } else if let status = model.lastStatus {
                    Text("Last result: \(status.rawValue)")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Review request")
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

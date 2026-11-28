#if canImport(SwiftUI) && canImport(AppKit)
import RVDomain
import RVGlance
import RVIPC
import SwiftUI

/// The glass sheet for one unlock ask (Menu bar v5 "Answer with a
/// fingertip"): who is waiting, the whole command, what it would do, the
/// agent's words labelled as the agent's, the three check words, then Deny,
/// Always allow and Allow once. The command is never cut: it wraps and the
/// sheet scrolls.
public struct UnlockSheetView: View {
    let model: UnlockReviewModel

    public init(model: UnlockReviewModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let sheet = model.sheet {
                UnlockSheetBody(sheet: sheet, busy: model.review.isBusy, model: model)
            } else if case .answered(_, let status) = model.review.phase {
                Text(UnlockOutcomeText.line(status, agent: "The agent"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(status == .waiting || status == .unknown ? GlanceTheme.stop : GlanceTheme.ok)
                Button("Done") { model.close() }.keyboardShortcut(.defaultAction)
            } else if case .binding = model.review.phase {
                ProgressView().controlSize(.small)
            }
            if let notice = model.review.notice {
                Text(notice).font(.system(size: 12)).foregroundStyle(GlanceTheme.watch)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: GlanceTheme.popoverWidth)
    }
}

struct UnlockSheetBody: View {
    let sheet: UnlockSheet
    let busy: Bool
    let model: UnlockReviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(sheet.title).font(.system(size: 14, weight: .semibold))
                Text(sheet.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Text(sheet.who).font(.system(size: 12.5)).foregroundStyle(.secondary)
            ScrollView {
                Text(sheet.command)
                    .font(.system(size: 12.5, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            .padding(8)
            .glanceTile(cornerRadius: 9)
            .accessibilityLabel(Text("Command: \(sheet.command)"))
            Text(sheet.effect).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            if let says = sheet.agentSays {
                VStack(alignment: .leading, spacing: 2) {
                    Text(sheet.agentSaysLabel).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Text(says).font(.system(size: 12).italic()).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(sheet.checkWords).font(.system(size: 12, weight: .medium)).foregroundStyle(GlanceTheme.rv)
            Text(sheet.codeLine).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
            if let unavailable = sheet.unavailable {
                Text(unavailable).font(.system(size: 12)).foregroundStyle(GlanceTheme.watch)
            } else {
                Text(sheet.onceScope).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(sheet.alwaysScope).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack {
                Button(UnlockSheet.denyLabel) { model.deny() }
                Spacer()
                Button(UnlockSheet.alwaysAllowLabel) { allow(.alwaysAllow) }
                    .disabled(busy || !sheet.canApprove)
                Button(UnlockSheet.allowOnceLabel) { allow(.allowOnce) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || !sheet.canApprove)
            }
        }
    }

    /// Answers the review this sheet shows, and no other.
    private func allow(_ decision: UIUnlockDecision) {
        guard let challenge = sheet.challengeID else { return }
        model.allow(decision, on: challenge)
    }
}

/// The popover's "Needs you" rows for unlock asks. No command text here:
/// a row only opens the sheet, which shows all of it.
struct UnlockAskRows: View {
    let model: UnlockReviewModel

    var body: some View {
        ForEach(model.review.waiting, id: \.codeHash) { item in
            Button {
                model.open(codeHash: item.codeHash)
            } label: {
                HStack(spacing: 8) {
                    Text(item.host.map { GlanceAgent(host: $0, lastAction: "", lastAt: .distantPast, checkedToday: 0).monogram }
                        ?? "?")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(item.host.map(GlanceTheme.avatar) ?? .gray, in: RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(item.host?.rawValue ?? "An agent") wants to run a stopped command")
                            .font(.system(size: 12.5, weight: .medium))
                        Text(AllowOnceUnlockCode(validating: item.code).map(CheckWords.line(for:)) ?? item.code)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Text("Review").font(.system(size: 11.5)).foregroundStyle(GlanceTheme.rv)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
    }
}
#endif

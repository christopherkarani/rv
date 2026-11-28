import Foundation
import RVIPC

/// Loosen proposals (F2) over the hook-consult session, which verifies
/// rvd the way owner calls do.
extension ServiceClient {
    public func proposeLoosen(_ params: ProposeLoosenParams) async -> Result<
        ProposeLoosenReply, ServiceCommandError
    > {
        await proposalCall(ProposeLoosenCall(params: params), timeoutMs: nil)
    }

    public func listProposals(_ params: ListProposalsParams) async -> Result<
        ListProposalsReply, ServiceCommandError
    > {
        await proposalCall(ListProposalsCall(params: params), timeoutMs: nil)
    }

    /// Approving waits for the owner at rvd's prompt.
    public func decideProposal(_ params: DecideProposalParams) async -> Result<
        DecideProposalReply, ServiceCommandError
    > {
        await proposalCall(DecideProposalCall(params: params), timeoutMs: Self.confirmOwnerActionTimeoutMs)
    }

    private func proposalCall<C: IPCCall>(_ call: C, timeoutMs: Int?) async -> Result<C.Reply, ServiceCommandError> {
        guard let transport else { return .failure(.noTransport) }
        do {
            let reply = try await send(
                call, using: transport, timeoutMs: timeoutMs ?? transport.oneShotEvaluateTimeoutMs, hookConsult: true)
            return .success(reply)
        } catch let error as IPCCallError {
            return .failure(mapCallError(error))
        } catch {
            return .failure(.transport(String(describing: error)))
        }
    }
}

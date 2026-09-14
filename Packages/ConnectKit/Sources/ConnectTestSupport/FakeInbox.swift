import ConnectInbox
import Foundation

/// Уведомления, приглашения и группы в памяти для тестов и офлайн-стаба.
public actor FakeInboxAPI: InboxAPI {
    public private(set) var notificationsList: [InboxNotification]
    public private(set) var invitationsList: [Invitation]
    public private(set) var viewed: [Int64] = []
    public private(set) var dismissed: [Int64] = []
    public private(set) var decisions: [(id: String, action: Invitation.Action)] = []
    public private(set) var sentInvitations: [(kind: Invitation.Kind, targetId: String, recipient: String)] = []
    public private(set) var createdGroups: [NewGroup] = []
    /// Сколько опросов списка приглашение остаётся в статусе PENDING после решения.
    public var decisionDelayPolls = 0
    public var failCreate = false
    private var pollsSinceDecision = 0
    private var pendingDecision: (id: String, status: Invitation.Status)?

    public init(notifications: [InboxNotification] = [], invitations: [Invitation] = []) {
        notificationsList = notifications
        invitationsList = invitations
    }

    public func setDecisionDelayPolls(_ value: Int) { decisionDelayPolls = value }
    public func setFailCreate(_ value: Bool) { failCreate = value }

    /// Новое уведомление, как пришло бы с сервера.
    public func deliver(_ notification: InboxNotification) {
        notificationsList.insert(notification, at: 0)
    }

    public func notifications(before: Int64?, limit: Int) async throws -> [InboxNotification] {
        let sorted = notificationsList.sorted { $0.id > $1.id }
        let filtered = before.map { id in sorted.filter { $0.id < id } } ?? sorted
        return Array(filtered.prefix(limit))
    }

    public func markViewed(ids: [Int64]) async throws {
        viewed.append(contentsOf: ids)
    }

    public func dismiss(ids: [Int64]) async throws {
        dismissed.append(contentsOf: ids)
        notificationsList.removeAll { ids.contains($0.id) }
    }

    public func dismissAll() async throws -> Int64? {
        let maxId = notificationsList.map(\.id).max()
        notificationsList.removeAll()
        return maxId
    }

    public func invitations(page: Int) async throws -> [Invitation] {
        if let pending = pendingDecision {
            pollsSinceDecision += 1
            if pollsSinceDecision > decisionDelayPolls, let index = invitationsList.firstIndex(where: { $0.id == pending.id }) {
                invitationsList[index].status = pending.status
                pendingDecision = nil
            }
        }
        return page == 0 ? invitationsList : []
    }

    public func pendingInvitations() async throws -> Int {
        invitationsList.filter { $0.status == .pending }.count
    }

    public func decide(invitationId: String, action: Invitation.Action) async throws {
        decisions.append((invitationId, action))
        let status: Invitation.Status = switch action {
        case .accept: .accepted
        case .decline: .declined
        case .cancel: .cancelled
        }
        pendingDecision = (invitationId, status)
        pollsSinceDecision = 0
    }

    public func invite(kind: Invitation.Kind, targetId: String, recipientUserId: String) async throws {
        sentInvitations.append((kind, targetId, recipientUserId))
    }

    public func createGroup(_ group: NewGroup) async throws {
        if failCreate { throw URLError(.badServerResponse) }
        createdGroups.append(group)
    }
}

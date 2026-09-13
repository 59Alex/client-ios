import ConnectAuth
import ConnectCore
import ConnectNetworking
import Foundation
import Observation

/// Корневое состояние приложения: есть ли сессия и чья она.
@MainActor
@Observable
public final class SessionModel {
    public enum State: Equatable {
        case launching
        case signedOut
        case loadingUser
        case signedIn(User)
        case failed(String)
    }

    public private(set) var state: State = .launching

    private let auth: AuthService
    private let users: any UserRepository

    public init(auth: AuthService, users: any UserRepository) {
        self.auth = auth
        self.users = users
    }

    /// Восстанавливает сессию и следит за входом/выходом до отмены задачи.
    public func run() async {
        let events = await auth.sessionEvents()
        if await auth.hasSession {
            await loadUser()
        } else {
            state = .signedOut
        }

        for await event in events {
            switch event {
            case .signedIn:
                await loadUser()
            case .signedOut:
                state = .signedOut
            }
        }
    }

    public func loadUser() async {
        state = .loadingUser
        do {
            state = .signedIn(try await users.currentUser())
        } catch APIError.unauthorized {
            state = .signedOut
        } catch {
            state = .failed("Не удалось загрузить профиль")
        }
    }

    public func logout() async {
        await auth.logout()
        state = .signedOut
    }
}

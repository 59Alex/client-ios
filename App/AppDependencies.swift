import ConnectAuth
import ConnectCore
import ConnectFeatures
import ConnectNetworking
import Foundation

/// Сборка зависимостей приложения. Вью получают их явно, без синглтонов.
@MainActor
final class AppDependencies {
    let config: AppConfig
    let auth: AuthService
    let session: SessionModel

    init(config: AppConfig, transport: any HTTPTransport, tokenStore: any TokenStore) {
        self.config = config
        auth = AuthService(userApiUrl: config.userApiUrl, transport: transport, store: tokenStore)
        let mainClient = HTTPClient(baseURL: config.mainApiUrl, transport: transport, tokenProvider: auth)
        session = SessionModel(auth: auth, users: RemoteUserRepository(client: mainClient))
    }

    static func makeForLaunch(arguments: [String] = ProcessInfo.processInfo.arguments) -> AppDependencies {
        #if DEBUG
        if arguments.contains(UITestStub.launchArgument) {
            return AppDependencies(config: .test, transport: UITestStub.makeTransport(), tokenStore: InMemoryTokenStore())
        }
        #endif
        return AppDependencies(config: .test, transport: URLSessionTransport(), tokenStore: KeychainTokenStore())
    }
}

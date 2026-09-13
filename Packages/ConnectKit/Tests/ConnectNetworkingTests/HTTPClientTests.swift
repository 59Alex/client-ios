import ConnectTestSupport
import Foundation
import Testing
@testable import ConnectNetworking

@Suite("HTTPClient")
struct HTTPClientTests {
    @Test("склеивает базовый адрес и путь без двойных слешей", arguments: [
        ("https://user.cnnect.ru", "/api/auth/login"),
        ("https://user.cnnect.ru/", "api/auth/login"),
        ("https://user.cnnect.ru//", "//api/auth/login"),
    ])
    func joinsUrls(base: String, path: String) throws {
        let url = HTTPClient.join(try #require(URL(string: base)), path)
        #expect(url.absoluteString == "https://user.cnnect.ru/api/auth/login")
    }

    @Test("подставляет bearer-токен провайдера")
    func addsBearerToken() async throws {
        let transport = StubTransport()
        transport.on("/ping", json: "{}")
        let provider = FixedTokenProvider(token: "abc")
        let client = HTTPClient(baseURL: try #require(URL(string: "https://domain.cnnect.ru")), transport: transport, tokenProvider: provider)

        _ = try await client.get("/ping")

        #expect(transport.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer abc")
    }

    @Test("401 авторизованного клиента очищает сессию")
    func unauthorizedClearsSession() async throws {
        let transport = StubTransport()
        transport.on("/private", status: 401, json: "{}")
        let provider = FixedTokenProvider(token: "abc")
        let client = HTTPClient(baseURL: try #require(URL(string: "https://domain.cnnect.ru")), transport: transport, tokenProvider: provider)

        await #expect(throws: APIError.unauthorized) {
            _ = try await client.get("/private")
        }
        #expect(await provider.unauthorizedCount == 1)
    }

    @Test("код ошибки принимается строкой и числом")
    func decodesFlexibleErrorCode() throws {
        let numeric = try JSONDecoder().decode(APIErrorBody.self, from: Data(#"{"code":512,"errMessage":"x"}"#.utf8))
        let string = try JSONDecoder().decode(APIErrorBody.self, from: Data(#"{"code":"511","message":"y"}"#.utf8))

        #expect(numeric == APIErrorBody(code: 512, errMessage: "x"))
        #expect(string.code == 511)
        #expect(string.displayMessage == "y")
    }
}

private actor FixedTokenProvider: AccessTokenProvider {
    let token: String
    private(set) var unauthorizedCount = 0

    init(token: String) {
        self.token = token
    }

    func validAccessToken() async -> String? { token }

    func handleUnauthorized() async {
        unauthorizedCount += 1
    }
}

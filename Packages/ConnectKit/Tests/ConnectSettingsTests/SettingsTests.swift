import ConnectAuth
import ConnectCore
import ConnectFeatures
import ConnectNetworking
import ConnectTestSupport
import Foundation
import Testing
@testable import ConnectSettings

@MainActor
@Suite("Регистрация и настройки")
struct SettingsTests {
    @Test("сложность пароля: требования по порядку и подписи", arguments: [
        ("", 0, "Добавьте минимум 8 символов"),
        ("abcdefgh", 2, "Добавьте цифры"),
        ("пароль12", 3, "Добавьте спецсимвол"),
        ("Passw0rd!", 4, nil),
    ] as [(String, Int, String?)])
    func passwordStrength(password: String, score: Int, firstMissing: String?) {
        let strength = PasswordStrength(password)
        #expect(strength.score == score)
        #expect(strength.missing.first == firstMissing)
        #expect(strength.label == PasswordStrength.labels[score])
    }

    @Test("маска телефона по мере ввода", arguments: [
        ("8", "+7"),
        ("8999", "+7 (999"),
        ("89991234", "+7 (999) 123-4"),
        ("+7 999 123 45 67 89", "+7 (999) 123-45-67"),
        ("9991234567", "+7 (999) 123-45-67"),
        ("", ""),
    ])
    func phoneMask(input: String, formatted: String) {
        #expect(PhoneMask.format(input) == formatted)
    }

    @Test("регистрация: ошибки полей, тело запроса, код 211 ведёт к подтверждению")
    func registration() async throws {
        let transport = StubTransport()
        transport.on("/api/user/register-profile") { _ in HTTPResponse(statusCode: 200, body: Data(#"{"code":211,"message":"Код отправлен"}"#.utf8)) }
        let auth = AuthService(userApiUrl: try #require(URL(string: "https://user.cnnect.ru")), transport: transport, store: InMemoryTokenStore())
        let model = RegistrationModel(auth: auth)

        #expect(model.validationErrors.first == "Имя: поле обязательно")
        #expect(await model.submit() == nil)
        #expect(model.errorMessage == "Имя: поле обязательно")

        model.name = " Иван "
        model.username = "@@ivan"
        model.email = "ivan@mail.ru"
        model.phone = "89991234567"
        model.password = "short"
        #expect(model.validationErrors == ["Пароль: добавьте минимум 8 символов"])
        model.phone = "8999"
        model.password = "Passw0rd!"
        #expect(model.validationErrors == ["Телефон: введите полностью или оставьте поле пустым"])
        model.phone = "89991234567"
        #expect(model.phone == "+7 (999) 123-45-67")
        #expect(model.canSubmit)

        let outcome = await model.submit()
        #expect(outcome == .verificationRequired(username: "@ivan", password: "Passw0rd!", message: "Код верификации отправлен на почту."))
        let body = try #require(transport.requests(to: "/api/user/register-profile").first?.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["username"] as? String == "@ivan")
        #expect(object["name"] as? String == "Иван")
        #expect(object["phoneNumber"] as? String == "+7 (999) 123-45-67")
    }

    @Test("регистрация без подтверждения и с ошибкой сервиса")
    func registrationOutcomes() async throws {
        let transport = StubTransport()
        let auth = AuthService(userApiUrl: try #require(URL(string: "https://user.cnnect.ru")), transport: transport, store: InMemoryTokenStore())
        let model = RegistrationModel(auth: auth)
        model.name = "Иван"
        model.username = "ivan"
        model.email = "ivan@mail.ru"
        model.password = "Passw0rd!"

        transport.on("/api/user/register-profile", json: "{}")
        #expect(await model.submit() == .created(username: "@ivan"))

        transport.on("/api/user/register-profile", status: 409, json: #"{"errMessage":"Логин занят"}"#)
        #expect(await model.submit() == nil)
        #expect(model.errorMessage == "Логин занят")
    }

    @Test("аккаунт: проверка занятости и заявка с newValue и новым eventId")
    func accountEdit() async {
        let api = FakeSettingsAPI(userId: "me", name: "Иван", username: "@ivan", email: "ivan@mail.ru", takenUsernames: ["@petr"], takenEmails: ["taken@mail.ru"])
        let model = AccountSettingsModel(userId: "me", api: api)
        await model.load()

        #expect(await model.validate(.username, value: "@ivan") == "Этот username уже принадлежит вам")
        #expect(await model.validate(.username, value: "@petr") == "Этот username занят @petr")
        #expect(await model.validate(.email, value: "bad") == "Введенное значение содержит некорректные символы")
        #expect(await model.validate(.email, value: "taken@mail.ru") == "Этот email занят taken@mail.ru")
        #expect(await model.validate(.phone, value: "8999") != nil)

        #expect(await model.save(.email, value: " new@mail.ru ") == nil)
        let update = await api.accountUpdates.first
        #expect(update?.email.newValue == "new@mail.ru")
        #expect(update?.email.verified == false)
        #expect(update?.eventId?.count == 36)
        #expect(model.field(.email)?.pendingMessage == "Поступил запрос обновления данных, данные обновляются на: new@mail.ru")

        #expect(await model.save(.phone, value: "9991234567") == nil)
        #expect(await api.accountUpdates.last?.phoneNumber.newValue == "+7 (999) 123-45-67")
    }

    @Test("плашка RETRY и признак подтверждения почты")
    func accountStatuses() {
        #expect(AccountField(value: "a", newValue: "b", keycloakStatus: .retry, connectStatus: .request).pendingMessage == "Проблемы на сервере, обновление находится в очереди, новое значение: b")
        #expect(AccountField(value: "a", newValue: "b", keycloakStatus: .complete, connectStatus: .request).pendingMessage == nil)
        var account = AccountSettings(userId: "u", name: .init(value: nil), username: .init(value: nil), phoneNumber: .init(value: nil), email: .init(value: "a@b.ru", verifyStatus: .request, verified: false))
        #expect(!account.isEmailVerified)
        account.email.verifyStatus = nil
        #expect(account.isEmailVerified)
    }

    @Test("звуки: переключение сохраняется, ошибка откатывает")
    func sounds() async {
        let api = FakeSettingsAPI(userId: "me", name: "", username: "", email: "")
        let model = NotificationSoundsModel(userId: "me", api: api)
        await model.load()

        await model.set(\.messageSound, false)
        #expect(model.sounds?.messageSound == false)
        #expect(await api.sounds.messageSound == false)
        #expect(NotificationSounds.items.count == 11)

        await api.setFailUpdates(true)
        await model.set(\.turnOffAllNotifications, true)
        #expect(model.sounds?.turnOffAllNotifications == false)
        #expect(model.errorMessage == "Не удалось сохранить настройку")
    }

    @Test("голос: запрет пустого deviceId, ограничение диапазонов, опечатка поля сервиса")
    func voice() async throws {
        #expect(!VoiceSettingsModel.isValidDeviceId("undefined"))
        #expect(!VoiceSettingsModel.isValidDeviceId(" "))

        let api = FakeSettingsAPI(userId: "me", name: "", username: "", email: "")
        let model = VoiceSettingsModel(userId: "me", deviceId: "device-1", api: api)
        await model.load()
        await model.update {
            $0.micVolume = 150
            $0.activateMicrophoneThreshold = -200
            $0.noiceReductionType = .aiLight
        }
        #expect(model.settings?.micVolume == 100)
        #expect(model.settings?.activateMicrophoneThreshold == -100)

        let json = try JSONEncoder().encode(try #require(model.settings))
        #expect(String(decoding: json, as: UTF8.self).contains(#""noiceReductionType":"AI_LIGHT""#))
    }

    @Test("стикер: проверка файла, загрузка и сброс")
    func greeting() async {
        let api = FakeSettingsAPI(userId: "me", name: "", username: "", email: "")
        let model = GreetingModel(userId: "me", api: api)

        await model.set(data: Data(count: 10), extension: "bmp") { _ in "x" }
        #expect(model.errorMessage == "Выберите PNG, JPG, WEBP или GIF до 5 МБ")

        await model.set(data: Data(count: 10), extension: "PNG") { _ in "user-gallery/me/hello.png" }
        #expect(model.sticker == GreetingSticker(urlS3: "user-gallery/me/hello.png", extension: ".png"))
        #expect(await api.sticker != nil)

        await model.reset()
        #expect(model.sticker == nil)
    }
}

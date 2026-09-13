# connect-ios

Нативный iOS-клиент Connect на Swift и SwiftUI. Переносит сценарии веб-клиента
[connect-ui](https://github.com/59Alex/connect-ui) (React/TypeScript) и работает с теми же
сервисами: адреса по умолчанию совпадают с профилем `test` (`*.cnnect.ru`).

Общий контекст проекта: [cnnect-workspace](https://github.com/59Alex/cnnect-workspace).

## Стек

- iOS 17+, iPhone, Swift 6 со строгой проверкой конкуренции.
- SwiftUI и Observation (`@Observable`), `NavigationStack`.
- `URLSession` + `async/await`, токены в Keychain.
- Xcode-проект генерируется [XcodeGen](https://github.com/yonaskolb/XcodeGen) из `project.yml`.
- Тесты: Swift Testing для пакета, XCUITest для сценариев на симуляторе.

## Структура

```text
App/                      приложение SwiftUI: сборка зависимостей, экраны, дизайн-токены
  DesignSystem/           палитра (light/dark из Theme.ts веб-клиента), стили кнопок и полей
  Views/                  RootView, LoginView, HomeView
  UITestStub.swift        офлайн-ответы сервисов для XCUITest (только DEBUG)
  Resources/Assets.xcassets
ConnectUITests/           XCUITest-сценарии со скриншотами
Packages/ConnectKit/      SPM-пакет без UIKit/SwiftUI, собирается и тестируется и на Linux
  ConnectCore             конфигурация сервисов, доменные модели
  ConnectNetworking       HTTP-клиент, транспорт, ошибки сервисов
  ConnectAuth             вход, подтверждение email, refresh, хранение токенов
  ConnectFeatures         модели экранов (LoginModel, SessionModel), репозитории
  ConnectTestSupport      StubTransport и тестовые JWT
scripts/pick-simulator.sh выбор симулятора в CI
```

Слои: вью SwiftUI → `@Observable`-модели в `ConnectFeatures` → сервисы и репозитории →
`HTTPClient`. Зависимости передаются через инициализаторы (`AppDependencies`).

## Соответствие веб-клиенту

| iOS | connect-ui |
| --- | --- |
| `AppConfig.test` | `src/config.ts` |
| `AuthService.login/verifyEmail` | `src/api/connectuserservice/useAuthApi.ts` |
| `AuthService.validAccessToken`, refresh | `src/api/auth/authorizeRequest.ts`, `refreshStoredAuthTokens.ts` |
| `AuthTokens` | `src/api/auth/authTokenStorage.ts` |
| `RemoteUserRepository` | `src/api/connectmainservice/useCurrentUser.ts` |
| `Palette`, `Radius` | `src/components/func/Theme.ts` |

## Сборка и проверка

На macOS с Xcode 16+:

```bash
brew install xcodegen
xcodegen generate
open Connect.xcodeproj

swift test --package-path Packages/ConnectKit
xcodebuild test -project Connect.xcodeproj -scheme Connect \
  -destination "id=$(scripts/pick-simulator.sh)"
```

На Linux доступны только тесты пакета: `swift test --package-path Packages/ConnectKit`.

CI (`.github/workflows/ios.yml`) на каждом PR запускает тесты пакета на Linux и macOS,
собирает приложение, прогоняет XCUITest на симуляторе и публикует артефакт
`ios-simulator-results` со скриншотами и `.xcresult`.

Для ручного прогона без сети приложение запускается с аргументом `-ui-test-stub`:
пароль `password` — успешный вход, логин `@verify` — сценарий подтверждения email с кодом `123456`.

## Этапы переноса

1. **Каркас** — проект, CI, сеть, авторизация, вход и подтверждение email, профиль, выход.
2. Чаты: список P2P и групп, сообщения, отправка текста, статусы через SSE.
3. Контакты, поиск, вложения и медиа через connect-s3.
4. Звонки: WebRTC и протокол OpenVidu 2 (официального iOS SDK нет), CallKit.
5. Push: APNs вместо Web Push — требует изменений в connect-notification-service.

Регистрация, настройки оформления и фоны пока не перенесены.

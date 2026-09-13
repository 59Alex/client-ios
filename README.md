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
  Calls/                  LiveKitCallRoom (LiveKit Swift SDK), доступ к микрофону
  Views/                  RootView, LoginView, HomeView, ContactsView, CallView
  UITestStub.swift        офлайн-ответы сервисов для XCUITest (только DEBUG)
  Resources/Assets.xcassets
ConnectUITests/           XCUITest-сценарии со скриншотами
Packages/ConnectKit/      SPM-пакет без UIKit/SwiftUI, собирается и тестируется и на Linux
  ConnectCore             конфигурация сервисов, доменные модели
  ConnectNetworking       HTTP-клиент, транспорт, ошибки сервисов
  ConnectAuth             вход, подтверждение email, refresh, хранение токенов
  ConnectFeatures         модели экранов (LoginModel, SessionModel, ContactsModel), сессия статуса
  ConnectCalls            личные звонки: протокол комнаты, API, P2PCallModel
  ConnectTestSupport      StubTransport, тестовые JWT, FakeCallRoom и FakeP2PCallAPI
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
| `ContactsModel`, `Contact` | `src/api/connectmainservice/contacts_api.ts`, `src/types/user.ts` |
| `StatusService` | `src/api/connectstatusservice/status_api.ts` |
| `P2PCallModel` | `src/calls/p2p/useP2pCall.ts` |
| `RemoteP2PCallAPI` | `src/api/connectchannelservice/p2p_call_api.ts`, `src/api/connectmainservice/p2p_room_api.ts` |
| `TrackName`, `CallClientData`, `SignalPacket`, `RemoteStreamTracker` | `src/calls/rtc/openvidu.ts` |
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
В стабе звонки идут через фейковую комнату (собеседник отвечает через полсекунды), а аргумент
`-ui-test-incoming-call` показывает входящий вызов после входа.

## Звонки

Медиасервер — OpenVidu 3, совместимый с LiveKit, поэтому iOS использует официальный
[LiveKit Swift SDK](https://github.com/livekit/client-sdk-swift). Чтобы звонить веб-клиенту, iOS
повторяет протокол его фасада `openvidu.ts`:

- микрофон публикуется одной аудиодорожкой с JSON-именем `{k,c,t,a,v}` и `a:true, v:false`
  (иначе веб не считает звонок начавшимся); `c` — `{"clientData":"{\"userId\",\"username\",\"sessionId\"}"}`;
- mute — настоящий mute дорожки плюс сигнал `mute`; `speakerOff` и `speak` — сигналы в топике `ov-signal`;
- снятие аудиодорожки собеседником означает конец звонка;
- принимающий пишет `call-time` до входа в комнату, вызывающий читает его из outbox;
- команды events-channel-service несут `eventId`, `idempotenceId` и `sessionId` из status-service.

Пока нет: видео и демонстрации экрана, CallKit/PushKit (входящие только при открытом приложении),
итога звонка в чате (`__P2P_CALL_SUMMARY__`) и групповых звонков.

## Этапы переноса

1. **Каркас** — проект, CI, сеть, авторизация, вход и подтверждение email, профиль, выход.
2. Чаты: список P2P и групп, сообщения, отправка текста, статусы через SSE.
3. Контакты (список с присутствием — сделано), поиск, вложения и медиа через connect-s3.
4. Звонки: личные аудиозвонки на LiveKit Swift SDK (OpenVidu 3) — сделано; дальше видео, CallKit, группы.
5. Push: APNs вместо Web Push — требует изменений в connect-notification-service.

Регистрация, настройки оформления и фоны пока не перенесены.

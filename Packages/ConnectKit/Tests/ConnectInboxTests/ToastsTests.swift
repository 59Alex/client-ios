import ConnectTestSupport
import Foundation
import Testing
@testable import ConnectInbox

@MainActor
@Suite("Тосты уведомлений")
struct ToastsTests {
    @Test("первая загрузка без тостов, новые непросмотренные сверху, не больше трёх")
    func newest() async {
        let api = FakeInboxAPI(notifications: [InboxNotification(id: 1, chatId: "r", chatType: .p2p, body: "старое")])
        let model = ToastsModel(api: api)
        await model.refresh()
        #expect(model.toasts.isEmpty)

        await api.deliver(InboxNotification(id: 2, chatId: "r", chatType: .p2p, body: "a"))
        await api.deliver(InboxNotification(id: 3, chatId: "r", chatType: .group, body: "b", viewedAt: Date()))
        await model.refresh()
        #expect(model.toasts.map(\.id) == [2])

        for id in Int64(4)...6 { await api.deliver(InboxNotification(id: id, chatId: "r", chatType: .p2p, body: "n\(id)")) }
        await model.refresh()
        #expect(model.toasts.map(\.id) == [6, 5, 4])
        await model.refresh()
        #expect(model.toasts.map(\.id) == [6, 5, 4])
    }

    @Test("открытый центр очищает очередь и не копит тосты; крестик снимает на сервере")
    func suppressionAndDismiss() async {
        let api = FakeInboxAPI()
        let model = ToastsModel(api: api)
        await model.refresh()
        await api.deliver(InboxNotification(id: 1, chatId: "r", chatType: .p2p, body: "a"))
        await model.refresh()
        #expect(model.toasts.count == 1)

        model.isSuppressed = true
        #expect(model.toasts.isEmpty)
        await api.deliver(InboxNotification(id: 2, chatId: "r", chatType: .p2p, body: "b"))
        await model.refresh()
        model.isSuppressed = false
        await model.refresh()
        #expect(model.toasts.isEmpty)

        await api.deliver(InboxNotification(id: 3, chatId: "r", chatType: .p2p, body: "c"))
        await model.refresh()
        await model.dismiss(3)
        #expect(model.toasts.isEmpty)
        #expect(await api.dismissed == [3])
    }

    @Test("заголовок и текст: событие комнаты, пустое тело — «Вложение»")
    func texts() {
        let event = InboxNotification(id: 1, chatType: .roomEvent, body: "Планёрка")
        #expect(ToastsModel.title(event) == "Событие комнаты")
        #expect(ToastsModel.title(InboxNotification(id: 2, chatType: .p2p)) == "Новое сообщение")
        #expect(ToastsModel.text(InboxNotification(id: 2, chatType: .p2p, body: " ")) == "Вложение")
    }
}

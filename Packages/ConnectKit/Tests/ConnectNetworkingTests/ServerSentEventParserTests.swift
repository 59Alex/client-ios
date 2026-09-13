import Foundation
import Testing
@testable import ConnectNetworking

@Suite("Разбор text/event-stream")
struct ServerSentEventParserTests {
    @Test("событие заканчивается пустой строкой при любых переводах строк", arguments: ["\n", "\r\n", "\r"])
    func lineEndings(newline: String) {
        var parser = ServerSentEventParser()
        let stream = "data: {\"type\":\"CALL\"}\(newline)\(newline)data: second\(newline)\(newline)"
        #expect(parser.feed(Array(stream.utf8)) == [
            ServerSentEvent(data: "{\"type\":\"CALL\"}"),
            ServerSentEvent(data: "second"),
        ])
    }

    @Test("несколько data склеиваются, event и комментарии учитываются")
    func multilineAndComments() {
        var parser = ServerSentEventParser()
        let stream = ": keep-alive\n\nevent: status\ndata: a\ndata:b\nid: 7\n\n"
        #expect(parser.feed(Array(stream.utf8)) == [ServerSentEvent(event: "status", data: "a\nb")])
    }

    @Test("незаконченное событие ждёт следующих байтов")
    func partialChunks() {
        var parser = ServerSentEventParser()
        #expect(parser.feed(Array("data: par".utf8)).isEmpty)
        #expect(parser.feed(Array("t\n".utf8)).isEmpty)
        #expect(parser.feed(Array("\n".utf8)) == [ServerSentEvent(data: "part")])
    }
}

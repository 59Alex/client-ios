import ConnectNetworking
import ConnectTestSupport
import Foundation
import Testing
@testable import ConnectFiles

@Suite("Файлы connect-s3")
struct FilesTests {
    private func batchBody(boundary: String, parts: [(url: String, type: String, data: Data)]) -> Data {
        var body = Data()
        for part in parts {
            body.append(Data("--\(boundary)\r\nContent-Type: \(part.type)\r\nContent-Length: \(part.data.count)\r\nX-File-Url: \(part.url)\r\n\r\n".utf8))
            body.append(part.data)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }

    @Test("граница читается из Content-Type с кавычками и без")
    func boundary() {
        #expect(MultipartBatchParser.boundary(fromContentType: "multipart/mixed; boundary=XYZ") == "XYZ")
        #expect(MultipartBatchParser.boundary(fromContentType: #"multipart/mixed; Boundary="a b"; charset=utf-8"#) == "a b")
        #expect(MultipartBatchParser.boundary(fromContentType: "application/json") == nil)
    }

    @Test("пакетный ответ разбирается по Content-Length, даже если в теле есть граница")
    func parsesBatch() throws {
        let tricky = Data("--XYZ\r\ninside".utf8)
        let body = batchBody(boundary: "XYZ", parts: [
            ("chat/a.jpg", "image/jpeg", Data([0xFF, 0xD8, 0x00, 0x0D, 0x0A])),
            ("chat/b.txt", "text/plain", tricky),
        ])
        let files = try MultipartBatchParser.parse(body, boundary: "XYZ")
        #expect(files.map(\.urlS3) == ["chat/a.jpg", "chat/b.txt"])
        #expect(files[0].data == Data([0xFF, 0xD8, 0x00, 0x0D, 0x0A]))
        #expect(files[1].data == tricky)
        #expect(files[0].contentType == "image/jpeg")
    }

    @Test("часть без обязательных заголовков и оборванный ответ — ошибки")
    func invalidBatch() throws {
        let noUrl = Data("--XYZ\r\nContent-Type: a/b\r\nContent-Length: 1\r\n\r\nx\r\n--XYZ--\r\n".utf8)
        #expect(throws: MultipartError.invalidHeaders) { try MultipartBatchParser.parse(noUrl, boundary: "XYZ") }
        let truncated = Data("--XYZ\r\nContent-Type: a/b\r\nContent-Length: 10\r\nX-File-Url: u\r\n\r\nxx".utf8)
        #expect(throws: MultipartError.incomplete) { try MultipartBatchParser.parse(truncated, boundary: "XYZ") }
        #expect(try MultipartBatchParser.parse(Data("--XYZ--\r\n".utf8), boundary: "XYZ").isEmpty)
    }

    @Test("имя файла делится по последней точке, расширение в нижнем регистре", arguments: [
        ("Photo.JPG", "Photo", ".jpg"),
        ("archive.tar.gz", "archive.tar", ".gz"),
        ("README", "README", ""),
        (".env", ".env", ""),
    ])
    func splitFilename(filename: String, name: String, ext: String) {
        let parts = UploadedFile.split(filename: filename)
        #expect(parts.name == name)
        #expect(parts.extension == ext)
    }

    @Test("загрузка: поля file, meta и size, ответ-строка — адрес")
    func upload() async throws {
        let transport = StubTransport()
        transport.on("/api/file/upload") { _ in HTTPResponse(statusCode: 200, body: Data("file-chat/room/abc.jpg".utf8)) }
        let client = HTTPClient(baseURL: try #require(URL(string: "https://s3.cnnect.ru")), transport: transport)
        let api = RemoteFileAPI(client: client)

        let file = try await api.upload(data: Data("img".utf8), filename: "Фото.JPG", mimeType: "image/jpeg", bucket: .chat, key: "room", userId: "me", username: "@me")

        #expect(file == UploadedFile(urlS3: "file-chat/room/abc.jpg", name: "Фото", extension: ".jpg"))
        let request = try #require(transport.requests.first)
        let contentType = try #require(request.value(forHTTPHeaderField: "Content-Type"))
        #expect(contentType.hasPrefix("multipart/form-data; boundary="))
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body.contains(#"name="file"; filename="Фото.JPG""#))
        #expect(body.contains(#""bucket":"file-chat""#))
        #expect(body.contains(#""key":"room""#))
        #expect(body.contains("name=\"size\"\r\n\r\n3\r\n"))
    }

    @Test("загрузчик склеивает одновременные запросы в один пакет и кэширует")
    func mediaLoaderBatches() async {
        let api = FakeFileAPI(files: ["a": Data("A".utf8), "b": Data("B".utf8)])
        let loader = MediaLoader(api: api)

        async let first = loader.data(for: "a")
        async let second = loader.data(for: "b")
        async let duplicate = loader.data(for: "a")
        async let missing = loader.data(for: "zzz")
        let results = await (first, second, duplicate, missing)

        #expect(results.0 == Data("A".utf8))
        #expect(results.1 == Data("B".utf8))
        #expect(results.2 == Data("A".utf8))
        #expect(results.3 == nil)
        #expect(await api.downloadRequests.count == 1)

        _ = await loader.data(for: "a")
        #expect(await api.downloadRequests.count == 1)
    }
}

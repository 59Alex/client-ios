import ConnectNetworking
import Foundation

/// Загруженный в connect-s3 файл: `name` без расширения, `extension` с точкой в нижнем регистре.
public struct UploadedFile: Sendable, Equatable {
    public var urlS3: String
    public var previewUrlS3: String?
    public var name: String
    public var `extension`: String

    public init(urlS3: String, previewUrlS3: String? = nil, name: String, extension: String) {
        self.urlS3 = urlS3
        self.previewUrlS3 = previewUrlS3
        self.name = name
        self.extension = `extension`
    }

    /// Делит имя по последней точке, как `useChatAttachmentUpload.ts`: `Photo.JPG` → `Photo` и `.jpg`.
    public static func split(filename: String) -> (name: String, extension: String) {
        guard let dot = filename.lastIndex(of: "."), dot != filename.startIndex else {
            return (filename, "")
        }
        return (String(filename[..<dot]), String(filename[dot...]).lowercased())
    }
}

/// Корзины connect-s3.
public enum FileBucket: String, Sendable {
    case chat = "file-chat"
    case userGallery = "user-gallery"
}

public protocol FileAPI: Sendable {
    func download(urls: [String]) async throws -> [String: DownloadedFile]
    func upload(data: Data, filename: String, mimeType: String, bucket: FileBucket, key: String, userId: String, username: String) async throws -> UploadedFile
    func delete(urls: [String]) async throws
}

public struct RemoteFileAPI: FileAPI {
    public static let batchSize = 100

    private let client: HTTPClient

    public init(client: HTTPClient) {
        self.client = client
    }

    public func download(urls: [String]) async throws -> [String: DownloadedFile] {
        var result: [String: DownloadedFile] = [:]
        let unique = Array(Set(urls.filter { !$0.isEmpty })).sorted()
        for start in stride(from: 0, to: unique.count, by: Self.batchSize) {
            let chunk = Array(unique[start..<min(unique.count, start + Self.batchSize)])
            let response = try await client.send(method: "POST", path: "/api/file/download/batch", body: try JSONEncoder().encode(chunk), timeout: 60)
            try HTTPClient.requireSuccess(response)
            guard let boundary = response.header("content-type").flatMap(MultipartBatchParser.boundary(fromContentType:)) else {
                throw MultipartError.missingBoundary
            }
            for file in try MultipartBatchParser.parse(response.body, boundary: boundary) {
                result[file.urlS3] = file
            }
        }
        return result
    }

    public func upload(data: Data, filename: String, mimeType: String, bucket: FileBucket, key: String, userId: String, username: String) async throws -> UploadedFile {
        let meta = UploadMeta(bucket: bucket.rawValue, key: key, userId: userId, username: username, id: UUID().uuidString.lowercased())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var form = MultipartFormBody()
        form.addFile(name: "file", filename: filename, mimeType: mimeType, content: data)
        form.addField(name: "meta", value: String(decoding: try encoder.encode(meta), as: UTF8.self))
        form.addField(name: "size", value: String(data.count))

        let response = try await client.send(method: "POST", path: "/api/file/upload", body: form.finalized(), contentType: form.contentType, timeout: 300)
        try HTTPClient.requireSuccess(response)
        // Сервис отвечает адресом строкой; на всякий случай принимаем и JSON.
        let urlS3: String
        if let object = try? JSONDecoder().decode(UploadResponse.self, from: response.body), let url = object.urlS3 {
            urlS3 = url
        } else if let string = try? JSONDecoder().decode(String.self, from: response.body) {
            urlS3 = string
        } else {
            urlS3 = String(decoding: response.body, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\" \n\r"))
        }
        guard !urlS3.isEmpty else { throw APIError.decoding("пустой адрес загруженного файла") }
        let parts = UploadedFile.split(filename: filename)
        return UploadedFile(urlS3: urlS3, name: parts.name, extension: parts.extension)
    }

    public func delete(urls: [String]) async throws {
        let body = try JSONEncoder().encode(urls.map { ["url": $0] })
        try HTTPClient.requireSuccess(try await client.send(method: "DELETE", path: "/api/file/deleteall", body: body))
    }
}

private struct UploadMeta: Encodable {
    let bucket: String
    let key: String
    let userId: String
    let username: String
    let id: String
}

private struct UploadResponse: Decodable {
    let urlS3: String?
}

/// Кэш и склейка запросов к файлам: одновременные запросы уходят одним пакетом,
/// повторный запрос того же адреса ждёт уже идущий.
public actor MediaLoader {
    public static let batchWindow: Duration = .milliseconds(40)

    private let api: any FileAPI
    private let cacheDirectory: URL?
    private let memoryLimit: Int
    private var memory: [String: Data] = [:]
    private var memoryOrder: [String] = []
    private var memoryBytes = 0
    private var waiting: [String: [CheckedContinuation<Data?, Never>]] = [:]
    private var queued: [String] = []
    private var flushScheduled = false

    public init(api: any FileAPI, cacheDirectory: URL? = nil, memoryLimit: Int = 64 * 1024 * 1024) {
        self.api = api
        self.cacheDirectory = cacheDirectory
        self.memoryLimit = memoryLimit
        if let cacheDirectory {
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
    }

    /// Данные файла или `nil`, если сервис его не отдал.
    public func data(for urlS3: String) async -> Data? {
        guard !urlS3.isEmpty else { return nil }
        if let cached = memory[urlS3] { return cached }
        if let file = diskURL(for: urlS3), let data = try? Data(contentsOf: file) {
            remember(data, for: urlS3)
            return data
        }
        return await withCheckedContinuation { continuation in
            if waiting[urlS3] == nil {
                waiting[urlS3] = [continuation]
                queued.append(urlS3)
                scheduleFlush()
            } else {
                waiting[urlS3]?.append(continuation)
            }
        }
    }

    /// Файл на диске для «Поделиться» и просмотра; имя берётся из вложения.
    public func fileURL(for urlS3: String, filename: String) async -> URL? {
        guard let data = await data(for: urlS3) else { return nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("connect-share", isDirectory: true)
            .appendingPathComponent(String(Self.cacheKey(urlS3).prefix(16)), isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(filename.isEmpty ? "file" : filename)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        Task {
            try? await Task.sleep(for: Self.batchWindow)
            await flush()
        }
    }

    private func flush() async {
        flushScheduled = false
        let urls = queued
        queued.removeAll()
        guard !urls.isEmpty else { return }
        let files = (try? await api.download(urls: urls)) ?? [:]
        for url in urls {
            let data = files[url]?.data
            if let data {
                remember(data, for: url)
                if let file = diskURL(for: url) { try? data.write(to: file, options: .atomic) }
            }
            for continuation in waiting.removeValue(forKey: url) ?? [] {
                continuation.resume(returning: data)
            }
        }
    }

    private func remember(_ data: Data, for url: String) {
        guard memory[url] == nil else { return }
        memory[url] = data
        memoryOrder.append(url)
        memoryBytes += data.count
        while memoryBytes > memoryLimit, let oldest = memoryOrder.first {
            memoryOrder.removeFirst()
            memoryBytes -= memory.removeValue(forKey: oldest)?.count ?? 0
        }
    }

    private func diskURL(for url: String) -> URL? {
        cacheDirectory?.appendingPathComponent(Self.cacheKey(url))
    }

    /// Имя файла кэша: адрес в base64url без спецсимволов, обрезанный до безопасной длины.
    static func cacheKey(_ url: String) -> String {
        let encoded = Data(url.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in url.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return String(encoded.suffix(80)) + "-" + String(hash, radix: 16)
    }
}

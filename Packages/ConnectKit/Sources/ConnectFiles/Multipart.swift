import Foundation

/// Файл из пакетного ответа `POST /api/file/download/batch`.
public struct DownloadedFile: Sendable, Equatable {
    public var urlS3: String
    public var contentType: String
    public var data: Data

    public init(urlS3: String, contentType: String, data: Data) {
        self.urlS3 = urlS3
        self.contentType = contentType
        self.data = data
    }
}

public enum MultipartError: Error, Sendable, Equatable {
    case missingBoundary
    case invalidHeaders
    case incomplete
}

/// Разбор пакетного ответа как в `useS3BatchDownload.ts`: у каждой части обязательны
/// `Content-Length`, `Content-Type` и `X-File-Url`; тело читается по длине, а не по границе.
public enum MultipartBatchParser {
    public static func boundary(fromContentType contentType: String) -> String? {
        guard let range = contentType.range(of: "boundary=", options: .caseInsensitive) else { return nil }
        var value = contentType[range.upperBound...]
        if let semicolon = value.firstIndex(of: ";") { value = value[..<semicolon] }
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func parse(_ body: Data, boundary: String) throws -> [DownloadedFile] {
        let bytes = [UInt8](body)
        let delimiter = Array("--\(boundary)".utf8)
        let crlf: [UInt8] = [13, 10]
        var files: [DownloadedFile] = []
        var index = 0

        func starts(with pattern: [UInt8], at position: Int) -> Bool {
            position + pattern.count <= bytes.count && Array(bytes[position..<position + pattern.count]) == pattern
        }

        while true {
            guard starts(with: delimiter, at: index) else { throw MultipartError.incomplete }
            index += delimiter.count
            if starts(with: [45, 45], at: index) { return files }
            guard starts(with: crlf, at: index) else { throw MultipartError.incomplete }
            index += 2

            var headers: [String: String] = [:]
            while true {
                guard let lineEnd = firstCRLF(in: bytes, from: index) else { throw MultipartError.incomplete }
                if lineEnd == index {
                    index += 2
                    break
                }
                let line = String(decoding: bytes[index..<lineEnd], as: UTF8.self)
                if let colon = line.firstIndex(of: ":") {
                    let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                    headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
                index = lineEnd + 2
            }

            guard
                let lengthText = headers["content-length"], let length = Int(lengthText), length >= 0,
                let contentType = headers["content-type"],
                let url = headers["x-file-url"]
            else { throw MultipartError.invalidHeaders }
            guard index + length + 2 <= bytes.count else { throw MultipartError.incomplete }
            files.append(DownloadedFile(urlS3: url, contentType: contentType, data: Data(bytes[index..<index + length])))
            index += length + 2
        }
    }

    private static func firstCRLF(in bytes: [UInt8], from start: Int) -> Int? {
        var position = start
        while position + 1 < bytes.count {
            if bytes[position] == 13, bytes[position + 1] == 10 { return position }
            position += 1
        }
        return nil
    }
}

/// Тело `multipart/form-data` для загрузки файла.
public struct MultipartFormBody: Sendable {
    public let boundary: String
    private var data = Data()

    public init(boundary: String = "connect-ios-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    public mutating func addField(name: String, value: String) {
        data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }

    public mutating func addFile(name: String, filename: String, mimeType: String, content: Data) {
        let safeName = filename.replacingOccurrences(of: "\"", with: "'")
        data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(safeName)\"\r\nContent-Type: \(mimeType)\r\n\r\n".utf8))
        data.append(content)
        data.append(Data("\r\n".utf8))
    }

    public func finalized() -> Data {
        data + Data("--\(boundary)--\r\n".utf8)
    }
}

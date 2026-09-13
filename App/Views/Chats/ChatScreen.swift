import ConnectChat
import ConnectFiles
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Открытый чат: лента от старых к новым, разделители дней и непрочитанного, поле ввода.
struct ChatScreen: View {
    let model: ChatModel

    @State private var confirmDelete: ChatMessage?
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var isPhotoPickerShown = false
    @State private var isFileImporterShown = false
    @State private var previewURL: URL?
    @FocusState private var isInputFocused: Bool
    @Environment(\.mediaLoader) private var mediaLoader

    var body: some View {
        VStack(spacing: 0) {
            switch model.state {
            case .loading:
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .failed(message):
                ContentUnavailableView {
                    Label(message, systemImage: "wifi.exclamationmark")
                } actions: {
                    Button("Повторить") { Task { await model.load() } }
                        .buttonStyle(PrimaryButtonStyle())
                        .frame(maxWidth: 240)
                }
            case .loaded:
                messageList
            }
            inputBar
        }
        .background(Palette.canvas)
        .navigationTitle(model.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(model.title)
                        .font(.headline)
                        .foregroundStyle(Palette.textPrimary)
                    if !model.isConnected, model.state == .loaded {
                        Text("Соединение...")
                            .font(.caption)
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .task { await model.load() }
        .task { await model.runRealtime() }
        .photosPicker(isPresented: $isPhotoPickerShown, selection: $photoItems, maxSelectionCount: 10, matching: .any(of: [.images, .videos]))
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            for item in items {
                Task { await attachPhoto(item) }
            }
        }
        .fileImporter(isPresented: $isFileImporterShown, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case let .success(urls) = result else { return }
            for url in urls {
                Task { await attachFile(url) }
            }
        }
        .quickLookPreview($previewURL)
        .confirmationDialog("Удалить сообщение?", isPresented: .init(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                if let message = confirmDelete {
                    Task { _ = await model.delete(message.id) }
                }
                confirmDelete = nil
            }
        }
    }

    private var messageList: some View {
        let messages = model.messages
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    if model.hasMore {
                        ProgressView()
                            .padding()
                            .task { await model.loadMore() }
                    }
                    ForEach(Array(messages.reversed().enumerated()), id: \.element.id) { index, message in
                        let previous = index > 0 ? messages[messages.count - index] : nil
                        if message.id == model.firstUnreadMessageId {
                            DayDivider(text: "Новые сообщения", highlighted: true)
                                .id("unread-divider")
                        } else if previous.map({ !Calendar.current.isDate($0.createdAt, inSameDayAs: message.createdAt) }) ?? true {
                            DayDivider(text: ChatDates.dayLabel(message.createdAt), highlighted: false)
                        }
                        MessageRow(
                            message: message,
                            isOwn: model.isOwn(message),
                            showAuthor: model.kind == .group,
                            onOpenAttachment: { open($0) },
                            onRetry: { Task { await model.retry(message.id) } },
                            onDiscard: { model.discardFailed(message.id) },
                            onDelete: { confirmDelete = message }
                        )
                        .id(message.id)
                        .onAppear { model.markVisible([message.id]) }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("chat.messages")
            .onChange(of: messages.first?.id) { _, newest in
                guard let newest else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(newest, anchor: .bottom) }
            }
            .onChange(of: model.state) { _, state in
                guard state == .loaded else { return }
                if model.firstUnreadMessageId != nil {
                    proxy.scrollTo("unread-divider", anchor: .top)
                } else if let newest = messages.first?.id {
                    proxy.scrollTo(newest, anchor: .bottom)
                }
            }
        }
    }

    private var inputBar: some View {
        VStack(spacing: 6) {
            if !model.pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.pendingAttachments) { attachment in
                            PendingAttachmentChip(attachment: attachment) {
                                Task { await model.removeAttachment(attachment.id) }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
            inputRow
        }
        .padding(.vertical, 8)
        .background(Palette.canvas)
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Menu {
                Button("Фото или видео", systemImage: "photo.on.rectangle") { isPhotoPickerShown = true }
                Button("Файл", systemImage: "doc") { isFileImporterShown = true }
            } label: {
                Image(systemName: "paperclip")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .foregroundStyle(Palette.textPrimary)
                    .background(Palette.surface, in: Circle())
                    .overlay { Circle().strokeBorder(Palette.border) }
            }
            .disabled(!model.canAttach)
            .accessibilityLabel("Прикрепить")
            .accessibilityIdentifier("chat.attach")

            TextField("Сообщение", text: Bindable(model).draft, axis: .vertical)
                .lineLimit(1...6)
                .focused($isInputFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(minHeight: 44)
                .foregroundStyle(Palette.textPrimary)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 22))
                .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(isInputFocused ? Palette.accent : Palette.border) }
                .disabled(model.isPartnerBanned)
                .accessibilityIdentifier("chat.input")

            Button {
                Task { await model.send() }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.bold))
                    .frame(width: 44, height: 44)
                    .foregroundStyle(Palette.onAccent)
                    .background(Palette.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!model.canSend)
            .opacity(model.canSend ? 1 : 0.45)
            .accessibilityLabel("Отправить")
            .accessibilityIdentifier("chat.send")
        }
        .padding(.horizontal, 12)
        .overlay(alignment: .top) {
            if model.isPartnerBanned {
                Text("Переписка недоступна")
                    .font(.footnote)
                    .foregroundStyle(Palette.textSecondary)
                    .offset(y: -18)
            }
        }
    }
}

extension ChatScreen {
    private func attachPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        let type = item.supportedContentTypes.first ?? .jpeg
        let ext = type.preferredFilenameExtension ?? "jpg"
        let prefix = type.conforms(to: .movie) ? "video" : "photo"
        await model.attach(data: data, filename: "\(prefix)-\(Int(Date().timeIntervalSince1970)).\(ext)", mimeType: type.preferredMIMEType ?? "application/octet-stream")
    }

    private func attachFile(_ url: URL) async {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        await model.attach(data: data, filename: url.lastPathComponent, mimeType: mime)
    }

    private func open(_ attachment: ChatAttachment) {
        guard let mediaLoader else { return }
        Task {
            previewURL = await mediaLoader.fileURL(for: attachment.urlS3, filename: attachment.displayName)
        }
    }
}

private struct PendingAttachmentChip: View {
    let attachment: PendingAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            switch attachment.state {
            case .uploading:
                ProgressView().controlSize(.small)
            case .uploaded:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accent)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Palette.danger)
            }
            Text(attachment.filename)
                .font(.footnote)
                .lineLimit(1)
                .foregroundStyle(Palette.textPrimary)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Убрать \(attachment.filename)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .background(Palette.surface, in: Capsule())
        .overlay { Capsule().strokeBorder(Palette.border) }
        .accessibilityIdentifier("chat.pending.\(attachment.filename)")
    }
}

private struct DayDivider: View {
    let text: String
    let highlighted: Bool

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(highlighted ? Palette.onAccent : Palette.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(highlighted ? Palette.accent : Palette.surface, in: Capsule())
            .overlay { if !highlighted { Capsule().strokeBorder(Palette.border) } }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    let isOwn: Bool
    let showAuthor: Bool
    let onOpenAttachment: (ChatAttachment) -> Void
    let onRetry: () -> Void
    let onDiscard: () -> Void
    let onDelete: () -> Void

    var body: some View {
        if let summary = message.callSummary {
            CallSummaryPill(summary: summary, time: message.createdAt)
        } else {
            HStack {
                if isOwn { Spacer(minLength: 48) }
                bubble
                if !isOwn { Spacer(minLength: 48) }
            }
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showAuthor, !isOwn {
                Text(message.guestName ?? message.username)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.accent)
            }
            ForEach(message.attachments, id: \.self) { attachment in
                Button { onOpenAttachment(attachment) } label: {
                    if attachment.kind == .image {
                        RemoteImage(key: attachment.previewUrlS3 ?? attachment.urlS3) {
                            AttachmentChip(attachment: attachment)
                        }
                        .frame(maxWidth: 240, maxHeight: 240)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.button))
                    } else {
                        AttachmentChip(attachment: attachment)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(attachment.displayName)
            }
            if !message.text.isEmpty {
                Text(FormattedMessageText.attributed(message))
                    .foregroundStyle(isOwn ? Palette.onAccent : Palette.textPrimary)
                    .textSelection(.enabled)
            }
            HStack(spacing: 4) {
                Spacer(minLength: 0)
                Text(ChatDates.messageTime(message.createdAt))
                    .font(.caption2.monospacedDigit())
                switch message.delivery {
                case .sending:
                    Image(systemName: "clock").font(.caption2).accessibilityLabel("Отправляется")
                case .failed:
                    Image(systemName: "exclamationmark.circle.fill").font(.caption2).accessibilityLabel("Не отправлено")
                case .sent:
                    EmptyView()
                }
            }
            .foregroundStyle(isOwn ? Palette.onAccent.opacity(0.8) : Palette.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isOwn ? Palette.accent : Palette.surface, in: RoundedRectangle(cornerRadius: Radius.panel))
        .overlay { if !isOwn { RoundedRectangle(cornerRadius: Radius.panel).strokeBorder(Palette.border) } }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat.message.\(message.id)")
        .contextMenu {
            if !message.text.isEmpty {
                Button("Копировать", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
            }
            switch message.delivery {
            case .failed:
                Button("Отправить снова", systemImage: "arrow.clockwise", action: onRetry)
                Button("Убрать", systemImage: "trash", role: .destructive, action: onDiscard)
            case .sent:
                if isOwn, !message.id.hasPrefix("local-") {
                    Button("Удалить", systemImage: "trash", role: .destructive, action: onDelete)
                }
            case .sending:
                EmptyView()
            }
        }
    }
}

private struct AttachmentChip: View {
    let attachment: ChatAttachment

    var body: some View {
        Label(title, systemImage: icon)
            .font(.subheadline)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Palette.canvas.opacity(0.9), in: RoundedRectangle(cornerRadius: Radius.button))
            .foregroundStyle(Palette.textPrimary)
    }

    private var title: String {
        switch attachment.kind {
        case .voiceMessage: "Голосовое сообщение"
        case .videoMessage: "Видеосообщение"
        default: attachment.displayName
        }
    }

    private var icon: String {
        switch attachment.kind {
        case .voiceMessage: "waveform"
        case .videoMessage: "video.circle"
        case .image: "photo"
        case .video: "film"
        case .audio: "music.note"
        case .pdf, .document: "doc.text"
        case .spreadsheet: "tablecells"
        case .archive: "archivebox"
        case .file: "doc"
        }
    }
}

private struct CallSummaryPill: View {
    let summary: CallSummary
    let time: Date

    var body: some View {
        Label {
            Text("\(summary.isGroup ? "Групповой созвон завершён" : "Созвон завершён") · \(summary.durationText)")
        } icon: {
            Image(systemName: "phone")
        }
        .font(.footnote)
        .foregroundStyle(Palette.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Palette.surface, in: Capsule())
        .overlay { Capsule().strokeBorder(Palette.border) }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("chat.callSummary")
    }
}

/// Оформление текста как в `MessageText.tsx`: маркер — фон, BOLD — жирный, SKINY — подчёркивание.
/// Границы включительные, в UTF-16.
enum FormattedMessageText {
    static func attributed(_ message: ChatMessage) -> AttributedString {
        var result = AttributedString(message.text)
        let utf16Count = message.text.utf16.count
        guard utf16Count > 0 else { return result }

        func range(from: Int, to: Int) -> Range<AttributedString.Index>? {
            let lower = max(0, min(from, utf16Count - 1))
            let upper = max(lower, min(to, utf16Count - 1)) + 1
            let utf16 = message.text.utf16
            guard
                let start = utf16.index(utf16.startIndex, offsetBy: lower, limitedBy: utf16.endIndex),
                let end = utf16.index(utf16.startIndex, offsetBy: upper, limitedBy: utf16.endIndex)
            else { return nil }
            return Range(start..<end, in: result)
        }

        for weight in message.weights {
            guard let range = range(from: weight.from, to: weight.to) else { continue }
            switch weight.state {
            case .bold: result[range].font = .body.bold()
            case .underline: result[range].underlineStyle = .single
            case .regular: break
            }
        }
        for marker in message.markers {
            guard let range = range(from: marker.from, to: marker.to), let color = Color(hex: marker.color) else { continue }
            result[range].backgroundColor = color
        }
        return result
    }
}

extension Color {
    /// `#rrggbb` или `#rgb`.
    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { value.removeFirst() }
        if value.count == 3 { value = value.map { "\($0)\($0)" }.joined() }
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return nil }
        self.init(
            red: Double((number >> 16) & 0xFF) / 255,
            green: Double((number >> 8) & 0xFF) / 255,
            blue: Double(number & 0xFF) / 255
        )
    }
}

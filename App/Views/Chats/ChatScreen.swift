import ConnectCalls
import ConnectChat
import ConnectFiles
import ConnectSettings
import PhotosUI
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Открытый чат: лента от старых к новым, разделители дней и непрочитанного, поле ввода.
struct ChatScreen: View {
    let model: ChatModel
    var groupTools: GroupTools?

    @State private var isMembersShown = false
    @State private var activeCall: GroupCallRecord?

    @State private var confirmDelete: ChatMessage?
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var isPhotoPickerShown = false
    @State private var isFileImporterShown = false
    @State private var previewURL: URL?
    @State private var isBulkDeleteShown = false
    @State private var recorder = VoiceRecorder()
    @State private var circleRecorder = VideoCircleRecorder()
    @State private var recordMode: RecordMode = .voice
    @State private var isRecordingLocked = false
    @State private var isEmojiShown = false
    @FocusState private var isInputFocused: Bool
    @Environment(\.mediaLoader) private var mediaLoader

    var body: some View {
        VStack(spacing: 0) {
            if let activeCall, let joinCall = groupTools?.joinCall {
                ActiveCallBanner(record: activeCall, canJoin: groupTools?.canCall() ?? false) {
                    Task { await joinCall(activeCall, model.title) }
                }
            }
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
                if model.kind == .p2p, model.messages.isEmpty, let partner = model.partnerUserId {
                    GreetingPrompt(partnerUserId: partner, model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    messageList
                }
            }
            if model.isSelecting {
                selectionBar
            } else {
                inputBar
            }
        }
        .background { ChatBackdrop() }
        .overlay {
            if circleRecorder.isActive {
                VideoCircleRecordingOverlay(recorder: circleRecorder)
            }
        }
        .navigationTitle(model.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Palette.chrome, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
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
            if let startCall = groupTools?.startCall {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await startCall(model.roomId, model.title, model.members.map(\.userId)) }
                    } label: {
                        Image(systemName: "phone")
                            .foregroundStyle(Palette.success)
                            .frame(width: 44, height: 36)
                            .background(Palette.callFill, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .disabled(!(groupTools?.canCall() ?? false))
                    .accessibilityLabel("Позвонить в группу")
                    .accessibilityIdentifier("chat.groupCall")
                }
            }
            if groupTools != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button { isMembersShown = true } label: {
                        Image(systemName: "person.2")
                    }
                    .accessibilityLabel("Участники и приглашения")
                    .accessibilityIdentifier("chat.members")
                }
            }
        }
        .sheet(isPresented: $isMembersShown) {
            if let groupTools {
                GroupMembersSheet(members: model.members, contacts: groupTools.contacts()) { contact in
                    await groupTools.invite(model.roomId, contact)
                }
            }
        }
        .task { await model.load() }
        .task { await model.runRealtime() }
        .task(id: model.kind) {
            guard let lookup = groupTools?.activeCall else { return }
            while !Task.isCancelled {
                activeCall = await lookup(model.roomId)
                try? await Task.sleep(for: .seconds(10))
            }
        }
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
                            isSelecting: model.isSelecting,
                            isSelected: model.selectedIds.contains(message.id),
                            onSelect: { model.toggleSelection(message.id) },
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

    /// Панель выделения (`Chat.tsx`): число выбранных, жирный, подчёркнутый, маркер, удаление.
    private var selectionBar: some View {
        HStack(spacing: 4) {
            ShellIconButton(systemImage: "xmark", label: "Отменить выделение", identifier: "chat.selection.cancel") { model.clearSelection() }
            Text("Выбрано: \(model.selectedIds.count)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.textPrimary)
                .accessibilityIdentifier("chat.selection.count")
            Spacer()
            ShellIconButton(systemImage: "bold", label: "Жирный", identifier: "chat.format.bold") { Task { await model.format(.bold) } }
            ShellIconButton(systemImage: "underline", label: "Подчеркнуть", identifier: "chat.format.underline") { Task { await model.format(.underline) } }
            ShellIconButton(systemImage: "highlighter", label: "Маркер", identifier: "chat.format.marker") {
                Task { await model.format(.marker(color: ChatModel.TextStyle.markerColor)) }
            }
            if model.canDeleteSelection {
                ShellIconButton(systemImage: "trash", label: "Удалить выбранные", identifier: "chat.selection.delete", tint: Palette.danger) { isBulkDeleteShown = true }
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 60)
        .background(Palette.chrome)
        .overlay(alignment: .top) { Rectangle().fill(Palette.divider).frame(height: 1) }
        .confirmationDialog("Удалить выбранные сообщения?", isPresented: $isBulkDeleteShown, titleVisibility: .visible) {
            Button("Удалить: \(model.selectedIds.count)", role: .destructive) { Task { await model.deleteSelected() } }
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
        .background(Palette.chrome)
        .overlay(alignment: .top) { Rectangle().fill(Palette.divider).frame(height: 1) }
    }

    @ViewBuilder
    private var inputRow: some View {
        if recorder.isActive && isRecordingLocked {
            VoiceRecordingBar(recorder: recorder) { data in
                Task { await model.sendVoiceMessage(data: data) }
            }
        } else {
            composerRow
        }
    }

    private var composerRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Menu {
                Button("Фото или видео", systemImage: "photo.on.rectangle") { isPhotoPickerShown = true }
                Button("Файл", systemImage: "doc") { isFileImporterShown = true }
            } label: {
                Image(systemName: "paperclip")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .foregroundStyle(Palette.textSecondary)
                    .background(Palette.canvas, in: Circle())
            }
            .disabled(!model.canAttach)
            .accessibilityLabel("Прикрепить")
            .accessibilityIdentifier("chat.attach")

            if recorder.isActive {
                HStack(spacing: 8) {
                    Circle().fill(Palette.danger).frame(width: 10, height: 10)
                    Text("\(VoiceMessagePlayer.format(recorder.elapsed)) · отпустите, чтобы отправить")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Palette.textSecondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(Palette.chrome, in: RoundedRectangle(cornerRadius: 22))
            } else {
            TextField("Сообщение", text: Bindable(model).draft, axis: .vertical)
                .lineLimit(1...6)
                .focused($isInputFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(minHeight: 44)
                .foregroundStyle(Palette.textPrimary)
                .background(Palette.chrome, in: RoundedRectangle(cornerRadius: 22))
                .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(isInputFocused ? Palette.accent : .clear) }
                .disabled(model.isPartnerBanned)
                .accessibilityIdentifier("chat.input")
            }

            Button { isEmojiShown = true } label: {
                Image(systemName: "face.smiling")
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .foregroundStyle(Palette.textSecondary)
            }
            .buttonStyle(.plain)
            .disabled(model.isPartnerBanned)
            .accessibilityLabel("Открыть смайлики")
            .accessibilityIdentifier("chat.emoji")
            .sheet(isPresented: $isEmojiShown) {
                EmojiPickerSheet { model.draft += $0 }
                    .presentationDetents([.medium, .large])
            }

            if model.canSend || !model.canAttach {
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
            } else {
                VoiceRecordButton(recorder: recorder, circleRecorder: circleRecorder, mode: $recordMode, isLocked: $isRecordingLocked) { data in
                    Task { await model.sendVoiceMessage(data: data) }
                } onSendCircle: { data in
                    Task { await model.sendVideoMessage(data: data) }
                }
                .disabled(model.isPartnerBanned)
            }
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

extension EnvironmentValues {
    /// Приветственный стикер пользователя по его id.
    @Entry var greetingLookup: (@Sendable (String) async -> GreetingSticker?)?
}

/// Пустой личный чат: стикер собеседника (или встроенный), отправляется одним нажатием.
private struct GreetingPrompt: View {
    let partnerUserId: String
    let model: ChatModel

    @Environment(\.greetingLookup) private var greetingLookup
    @Environment(\.mediaLoader) private var mediaLoader
    @State private var sticker: GreetingSticker?
    @State private var isSending = false
    @State private var failed = false

    var body: some View {
        VStack(spacing: 12) {
            Text("Начните с приветствия")
                .font(.headline)
                .foregroundStyle(Palette.textPrimary)
            Button {
                Task { await send() }
            } label: {
                RemoteImage(key: sticker?.urlS3, contentMode: .fit) {
                    Self.builtInSticker
                }
                .frame(width: 160, height: 160)
            }
            .buttonStyle(.plain)
            .disabled(isSending)
            .accessibilityLabel("Отправить приветствие")
            .accessibilityIdentifier("chat.greeting")
            Text(isSending ? "Отправляем…" : (failed ? "Не удалось отправить. Попробуйте ещё раз." : "Нажмите на стикер, чтобы поздороваться"))
                .font(.subheadline)
                .foregroundStyle(failed ? Palette.danger : Palette.textSecondary)
        }
        .padding()
        .task(id: partnerUserId) {
            sticker = await greetingLookup?(partnerUserId)
        }
    }

    private static var builtInSticker: some View {
        Image(systemName: "hand.wave.fill")
            .font(.system(size: 96))
            .foregroundStyle(Palette.accent)
            .frame(width: 160, height: 160)
    }

    private func send() async {
        isSending = true
        failed = false
        defer { isSending = false }
        var data: Data?
        var ext = ".png"
        if let sticker, let loaded = await mediaLoader?.data(for: sticker.urlS3) {
            data = loaded
            ext = sticker.extension.isEmpty ? ".png" : sticker.extension
        } else {
            let renderer = ImageRenderer(content: Self.builtInSticker.background(Color.clear))
            renderer.scale = 3
            data = renderer.uiImage?.pngData()
        }
        guard let data else {
            failed = true
            return
        }
        let mime = UTType(filenameExtension: String(ext.dropFirst()))?.preferredMIMEType ?? "image/png"
        failed = !(await model.sendGreeting(data: data, filename: "Приветствие\(ext)", mimeType: mime))
    }
}

/// Баннер идущего группового звонка (`ActiveGroupCallJoinButton.tsx`).
private struct ActiveCallBanner: View {
    let record: GroupCallRecord
    let canJoin: Bool
    let onJoin: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "phone.fill").foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Текущий звонок").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.textPrimary)
                if let startedAt = record.startedAt {
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text("\(CallView.duration(from: startedAt, to: context.date)), \(Self.participants(record.participantUserIds.count))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Palette.textSecondary)
                    }
                } else {
                    Text(Self.participants(record.participantUserIds.count)).font(.caption).foregroundStyle(Palette.textSecondary)
                }
            }
            Spacer()
            Button("Присоединиться", action: onJoin)
                .buttonStyle(.borderedProminent)
                .disabled(!canJoin)
                .accessibilityIdentifier("chat.joinCall")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Palette.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.border).frame(height: 0.5) }
        .accessibilityElement(children: .contain)
    }

    static func participants(_ count: Int) -> String {
        let mod10 = count % 10, mod100 = count % 100
        let word = mod10 == 1 && mod100 != 11 ? "участник" : ((2...4).contains(mod10) && !(12...14).contains(mod100) ? "участника" : "участников")
        return "\(count) \(word)"
    }
}

private struct PendingAttachmentChip: View {
    let attachment: PendingAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            switch attachment.state {
            case .uploading:
                if let progress = attachment.progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Palette.textSecondary)
                        .accessibilityIdentifier("chat.pending.progress")
                } else {
                    ProgressView().controlSize(.small)
                }
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
            .foregroundStyle(highlighted ? Palette.accent : Palette.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(highlighted ? Color.clear : Palette.surface.opacity(0.85), in: Capsule())
            .frame(maxWidth: .infinity)
            .background {
                if highlighted { Rectangle().fill(Palette.accent.opacity(0.6)).frame(height: 1).padding(.horizontal, 6) }
            }
            .padding(.vertical, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    let isOwn: Bool
    let showAuthor: Bool
    var isSelecting = false
    var isSelected = false
    var onSelect: () -> Void = {}
    let onOpenAttachment: (ChatAttachment) -> Void
    let onRetry: () -> Void
    let onDiscard: () -> Void
    let onDelete: () -> Void

    var body: some View {
        if let summary = message.callSummary {
            CallSummaryPill(summary: summary, time: message.createdAt)
        } else {
            HStack {
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Palette.accent : Palette.textSecondary)
                        .accessibilityHidden(true)
                }
                if isOwn { Spacer(minLength: 48) }
                bubble
                    .allowsHitTesting(!isSelecting)
                if !isOwn { Spacer(minLength: 48) }
            }
            .contentShape(Rectangle())
            .onTapGesture { if isSelecting { onSelect() } }
            .background(isSelected ? Palette.accent.opacity(0.12) : .clear)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }

    /// Пузырь веб-клиента: 10px со срезанным нижним левым углом 3px.
    private static let bubbleShape = UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 3, bottomTrailingRadius: 10, topTrailingRadius: 10)

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showAuthor, !isOwn {
                Text(message.guestName ?? message.username)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.messageName)
            }
            ForEach(message.attachments, id: \.self) { attachment in
                if attachment.kind == .voiceMessage {
                    VoiceMessagePlayer(attachment: attachment, isOwn: isOwn)
                } else if attachment.kind == .videoMessage {
                    VideoCirclePlayer(attachment: attachment)
                } else {
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
            }
            if !message.text.isEmpty {
                Text(FormattedMessageText.attributed(message))
                    .foregroundStyle(isOwn ? Palette.onOwnBubble : Palette.onOtherBubble)
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
            .foregroundStyle((isOwn ? Palette.onOwnBubble : Palette.onOtherBubble).opacity(0.7))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(isOwn ? Palette.ownBubble : Palette.otherBubble, in: Self.bubbleShape)
        .overlay { Self.bubbleShape.strokeBorder((isOwn ? Palette.onOwnBubble : Palette.onOtherBubble).opacity(0.1)) }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat.message.\(message.id)")
        .contextMenu {
            if !message.text.isEmpty {
                Button("Копировать", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
            }
            if message.delivery == .sent, !message.id.hasPrefix("local-") {
                Button("Выделить", systemImage: "checkmark.circle", action: onSelect)
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

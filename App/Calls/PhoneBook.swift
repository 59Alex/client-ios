import Contacts
import Foundation

/// Номера телефонной книги для поиска знакомых; наружу уходят только результаты поиска.
enum PhoneBook {
    enum Failure: Error {
        case denied
    }

    static func numbers() async throws -> [String] {
        let store = CNContactStore()
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .denied || status == .restricted { throw Failure.denied }
        if status == .notDetermined {
            guard try await store.requestAccess(for: .contacts) else { throw Failure.denied }
        }
        return try await Task.detached(priority: .userInitiated) {
            let request = CNContactFetchRequest(keysToFetch: [CNContactPhoneNumbersKey as CNKeyDescriptor])
            var numbers: [String] = []
            try CNContactStore().enumerateContacts(with: request) { contact, _ in
                numbers.append(contentsOf: contact.phoneNumbers.map(\.value.stringValue))
            }
            return numbers
        }.value
    }
}

/// Приветствие «С вами в connect!» живёт только на устройстве, пока новый чат не открыли (`contactSync.ts`).
enum SyncGreetings {
    private static func key(_ userId: String) -> String { "connect.contact-sync.greetings.\(userId)" }

    static func remember(_ roomIds: [String], userId: String) {
        let current = Set(UserDefaults.standard.stringArray(forKey: key(userId)) ?? [])
        UserDefaults.standard.set(Array(current.union(roomIds)), forKey: key(userId))
    }

    static func contains(_ roomId: String, userId: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: key(userId)) ?? []).contains(roomId)
    }

    static func forget(_ roomId: String, userId: String) {
        let remaining = (UserDefaults.standard.stringArray(forKey: key(userId)) ?? []).filter { $0 != roomId }
        UserDefaults.standard.set(remaining, forKey: key(userId))
    }
}

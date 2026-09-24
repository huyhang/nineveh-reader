import Foundation
import NinevehCore
import Security

public actor KeychainCredentialStore: CredentialStoring {
  private let service: String

  public init(service: String = "com.nineveh.reader.credentials") {
    self.service = service
  }

  public func save(password: String, for connection: ServerConnection) throws {
    let account = connection.identity
    let query = baseQuery(account: account)
    SecItemDelete(query as CFDictionary)

    var insert = query
    insert[kSecValueData as String] = Data(password.utf8)
    insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let status = SecItemAdd(insert as CFDictionary, nil)
    guard status == errSecSuccess else { throw KeychainError(status: status) }
  }

  public func password(for connection: ServerConnection) throws -> String? {
    var query = baseQuery(account: connection.identity)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess,
      let data = item as? Data,
      let password = String(data: data, encoding: .utf8)
    else {
      throw KeychainError(status: status)
    }
    return password
  }

  public func removePassword(for connection: ServerConnection) throws {
    let status = SecItemDelete(baseQuery(account: connection.identity) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainError(status: status)
    }
  }

  private func baseQuery(account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: false,
    ]
  }
}

public struct KeychainError: LocalizedError, Sendable {
  public let status: OSStatus

  public var errorDescription: String? {
    SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
  }
}

public actor UserDefaultsConnectionStore: ConnectionStoring {
  private let defaults: UserDefaults
  private let key: String

  public init(defaults: UserDefaults = .standard, key: String = "savedConnection") {
    self.defaults = defaults
    self.key = key
  }

  public func save(_ connection: ServerConnection) throws {
    defaults.set(try JSONEncoder().encode(connection), forKey: key)
  }

  public func load() throws -> ServerConnection? {
    guard let data = defaults.data(forKey: key) else { return nil }
    return try JSONDecoder().decode(ServerConnection.self, from: data)
  }

  public func remove() {
    defaults.removeObject(forKey: key)
  }
}

public actor UserDefaultsReadingPreferenceStore: ReadingPreferenceStoring {
  private let defaults: UserDefaults
  private let key: String
  private let modeKey: String

  public init(
    defaults: UserDefaults = .standard,
    key: String = "readingDirections",
    modeKey: String = "readingMode"
  ) {
    self.defaults = defaults
    self.key = key
    self.modeKey = modeKey
  }

  public func direction(for identifier: String) -> ReadingDirectionPreference? {
    guard let rawValue = defaults.dictionary(forKey: key)?[identifier] as? String else {
      return nil
    }
    return ReadingDirectionPreference(rawValue: rawValue)
  }

  public func save(direction: ReadingDirectionPreference, for identifier: String) {
    var values = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    // Automatic is the absence of a choice, so it follows the publication
    // even if its category is corrected later.
    values[identifier] = direction == .automatic ? nil : direction.rawValue
    defaults.set(values, forKey: key)
  }

  public func preferredMode() -> ReadingMode? {
    defaults.string(forKey: modeKey).flatMap(ReadingMode.init(rawValue:))
  }

  public func save(preferredMode: ReadingMode) {
    defaults.set(preferredMode.rawValue, forKey: modeKey)
  }
}

public actor UserDefaultsLibraryVisibilityStore: LibraryVisibilityStoring {
  private let defaults: UserDefaults
  private let key: String

  public init(defaults: UserDefaults = .standard, key: String = "hiddenLibraries") {
    self.defaults = defaults
    self.key = key
  }

  public func hiddenLibraries(for connectionID: String) -> Set<String> {
    Set(defaults.dictionary(forKey: key)?[connectionID] as? [String] ?? [])
  }

  public func save(hiddenLibraries: Set<String>, for connectionID: String) {
    var values = defaults.dictionary(forKey: key) as? [String: [String]] ?? [:]
    values[connectionID] = hiddenLibraries.isEmpty ? nil : hiddenLibraries.sorted()
    defaults.set(values, forKey: key)
  }
}

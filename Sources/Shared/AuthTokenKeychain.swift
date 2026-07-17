import Foundation
import Security

struct AuthTokenKeychainClient {
    typealias Result = (status: OSStatus, value: Any?)

    let add: ([String: Any]) -> Result
    let update: ([String: Any], [String: Any]) -> OSStatus
    let copyMatching: ([String: Any]) -> Result
    let delete: ([String: Any]) -> OSStatus

    static let security = AuthTokenKeychainClient(
        add: { query in
            var result: CFTypeRef?
            let status = SecItemAdd(query as CFDictionary, &result)
            return (status, result)
        },
        update: { query, attributes in
            SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        },
        copyMatching: { query in
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result)
        },
        delete: { query in
            SecItemDelete(query as CFDictionary)
        }
    )
}

/// Shared Keychain storage for profile authentication tokens.
///
/// The containing app creates and updates the item; the packet-tunnel
/// extension resolves the persistent reference stored in
/// `NETunnelProviderProtocol.passwordReference`. Both targets carry the same
/// keychain-access-group entitlement.
enum AuthTokenKeychain {
    static let service = "ezvpn.auth-token"
    static let accessGroupInfoKey = "EZVPNKeychainAccessGroup"

    static func store(
        _ token: String,
        for profileID: UUID,
        client: AuthTokenKeychainClient = .security
    ) throws -> Data {
        guard !token.isEmpty, let tokenData = token.data(using: .utf8) else {
            throw AuthTokenKeychainError.invalidToken
        }

        var addQuery = try identityQuery(for: profileID)
        addQuery[kSecValueData as String] = tokenData
        addQuery[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        addQuery[kSecReturnPersistentRef as String] = true

        let (addStatus, result) = client.add(addQuery)
        switch addStatus {
        case errSecSuccess:
            guard let reference = result as? Data else {
                throw AuthTokenKeychainError.missingPersistentReference
            }
            return reference
        case errSecDuplicateItem:
            let attributes: [String: Any] = [
                kSecValueData as String: tokenData,
                kSecAttrAccessible as String:
                    kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            let updateStatus = client.update(
                try identityQuery(for: profileID), attributes)
            guard updateStatus == errSecSuccess else {
                throw AuthTokenKeychainError.security(
                    operation: "update auth token", status: updateStatus)
            }
            return try persistentReference(for: profileID, client: client)
        default:
            throw AuthTokenKeychainError.security(
                operation: "store auth token", status: addStatus)
        }
    }

    #if os(iOS)
    /// iOS-only: resolve the token through the `passwordReference` persistent
    /// ref stored on the `NETunnelProviderProtocol`. The ref already encodes
    /// the item's identity and access group. Adding kSecClass,
    /// kSecAttrAccessGroup, kSecMatchLimit, or kSecUseDataProtectionKeychain
    /// alongside kSecValuePersistentRef makes SecItemCopyMatching fail with
    /// errSecParam (-50, "one or more parameters passed to a function were
    /// not valid").
    static func token(
        for persistentReference: Data,
        client: AuthTokenKeychainClient = .security
    ) throws -> String {
        try decodeToken(client.copyMatching([
            kSecValuePersistentRef as String: persistentReference,
            kSecReturnData as String: true,
        ]))
    }
    #endif

    /// Resolve the token by item identity (service + profile UUID + access
    /// group) in the data-protection keychain. macOS uses this everywhere:
    /// the packet-tunnel system extension is a root daemon with no legacy
    /// keychain search list, and resolving a persistent reference routes
    /// through the legacy engine, which fails there with errSecNotAvailable
    /// ("No keychain is available"). An identity query stays entirely in the
    /// data-protection keychain, which daemons can read.
    static func token(
        forProfileID profileID: UUID,
        client: AuthTokenKeychainClient = .security
    ) throws -> String {
        var query = try identityQuery(for: profileID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return try decodeToken(client.copyMatching(query))
    }

    private static func decodeToken(
        _ result: AuthTokenKeychainClient.Result
    ) throws -> String {
        guard result.status == errSecSuccess else {
            throw AuthTokenKeychainError.security(
                operation: "load auth token", status: result.status)
        }
        guard
            let data = result.value as? Data,
            let token = String(data: data, encoding: .utf8),
            !token.isEmpty
        else {
            throw AuthTokenKeychainError.invalidToken
        }
        return token
    }

    static func delete(
        for profileID: UUID,
        client: AuthTokenKeychainClient = .security
    ) throws {
        let status = client.delete(try identityQuery(for: profileID))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AuthTokenKeychainError.security(
                operation: "delete auth token", status: status)
        }
    }

    private static func persistentReference(
        for profileID: UUID,
        client: AuthTokenKeychainClient
    ) throws -> Data {
        var query = try identityQuery(for: profileID)
        query[kSecReturnPersistentRef as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let (status, result) = client.copyMatching(query)
        guard status == errSecSuccess else {
            throw AuthTokenKeychainError.security(
                operation: "load auth token reference", status: status)
        }
        guard let reference = result as? Data else {
            throw AuthTokenKeychainError.missingPersistentReference
        }
        return reference
    }

    private static func identityQuery(for profileID: UUID) throws -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString,
            kSecAttrAccessGroup as String: try accessGroup(),
            // Required on macOS for access-group and accessibility attributes
            // to use the data-protection Keychain.
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private static func accessGroup() throws -> String {
        guard
            let accessGroup = Bundle.main.object(
                forInfoDictionaryKey: accessGroupInfoKey
            ) as? String,
            !accessGroup.isEmpty,
            !accessGroup.contains("$(")
        else {
            throw AuthTokenKeychainError.missingAccessGroup
        }
        return accessGroup
    }
}

enum AuthTokenKeychainError: LocalizedError {
    case missingAccessGroup
    case missingPersistentReference
    case invalidToken
    case security(operation: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingAccessGroup:
            return "The shared Keychain access group is not configured."
        case .missingPersistentReference:
            return "The Keychain did not return an auth-token reference."
        case .invalidToken:
            return "The Keychain auth token is empty or invalid."
        case .security(let operation, let status):
            let detail = SecCopyErrorMessageString(status, nil) as String?
                ?? "OSStatus \(status)"
            return "Could not \(operation): \(detail)."
        }
    }
}

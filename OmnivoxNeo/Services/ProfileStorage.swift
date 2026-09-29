//
//  ProfileStorage.swift
//  OmnivoxNeo
//
//  Profile-scoped storage utilities
//

import Foundation

/// Helper for profile-scoped UserDefaults storage
struct ProfileStorage {
    let profileID: UUID

    init(profileID: UUID) {
        self.profileID = profileID
    }

    // MARK: - Scoped Keys

    func key(_ baseKey: String) -> String {
        return "\(profileID.uuidString).\(baseKey)"
    }

    func filePath(_ filename: String) -> URL {
        let baseDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let profileDir = baseDir
            .appendingPathComponent("profiles")
            .appendingPathComponent(profileID.uuidString)

        // Create directory if needed
        try? FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)

        return profileDir.appendingPathComponent(filename)
    }

    // MARK: - UserDefaults Helpers

    func bool(forKey key: String) -> Bool {
        return UserDefaults.standard.bool(forKey: self.key(key))
    }

    func set(_ value: Bool, forKey key: String) {
        UserDefaults.standard.set(value, forKey: self.key(key))
    }

    func string(forKey key: String) -> String? {
        return UserDefaults.standard.string(forKey: self.key(key))
    }

    func set(_ value: String?, forKey key: String) {
        UserDefaults.standard.set(value, forKey: self.key(key))
    }

    func data(forKey key: String) -> Data? {
        return UserDefaults.standard.data(forKey: self.key(key))
    }

    func set(_ value: Data?, forKey key: String) {
        UserDefaults.standard.set(value, forKey: self.key(key))
    }

    func removeObject(forKey key: String) {
        UserDefaults.standard.removeObject(forKey: self.key(key))
    }
}

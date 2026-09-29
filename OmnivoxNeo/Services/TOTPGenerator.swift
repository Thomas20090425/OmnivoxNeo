//
//  TOTPGenerator.swift
//  OmnivoxNeo
//
//  TOTP (Time-based One-Time Password) generator for OmniVox authentication
//

import Foundation
import CryptoKit

struct TOTPGenerator {
    private let secret: Data
    private let digits: Int
    private let period: TimeInterval

    init(secret: String, digits: Int = 6, period: TimeInterval = 30) throws {
        // Decode Base32 secret
        guard let secretData = Self.base32Decode(secret) else {
            throw TOTPError.invalidSecret
        }
        self.secret = secretData
        self.digits = digits
        self.period = period
    }

    /// Generate TOTP code for current time
    func generateCode(at date: Date = Date()) -> String {
        let counter = UInt64(date.timeIntervalSince1970 / period)
        return generateCode(counter: counter)
    }

    /// Get remaining seconds until code expires
    func remainingSeconds(at date: Date = Date()) -> Int {
        let elapsed = date.timeIntervalSince1970.truncatingRemainder(dividingBy: period)
        return Int(period - elapsed)
    }

    /// Get progress (0.0 to 1.0) through current code period
    func progress(at date: Date = Date()) -> Double {
        let elapsed = date.timeIntervalSince1970.truncatingRemainder(dividingBy: period)
        return elapsed / period
    }

    private func generateCode(counter: UInt64) -> String {
        var counterBytes = counter.bigEndian
        let counterData = Data(bytes: &counterBytes, count: MemoryLayout<UInt64>.size)

        // HMAC-SHA1
        let key = SymmetricKey(data: secret)
        let hmac = HMAC<Insecure.SHA1>.authenticationCode(for: counterData, using: key)
        let hmacData = Data(hmac)

        // Dynamic truncation
        let offset = Int(hmacData[hmacData.count - 1] & 0x0f)
        let truncatedHash = hmacData.subdata(in: offset..<offset + 4)

        var code = truncatedHash.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        code &= 0x7fff_ffff
        code = code % UInt32(pow(10, Double(digits)))

        return String(format: "%0\(digits)d", code)
    }

    // Base32 decoding (RFC 4648)
    private static func base32Decode(_ string: String) -> Data? {
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
        var bits = 0
        var buffer = 0
        var output = Data()

        for char in string.uppercased() {
            guard let index = alphabet.firstIndex(of: char) else {
                if char == "=" { break }
                continue
            }

            buffer = (buffer << 5) | alphabet.distance(from: alphabet.startIndex, to: index)
            bits += 5

            if bits >= 8 {
                bits -= 8
                output.append(UInt8((buffer >> bits) & 0xff))
            }
        }

        return output.isEmpty ? nil : output
    }
}

enum TOTPError: Error {
    case invalidSecret
    case notConfigured
}

// TOTP Secret storage in Keychain
struct TOTPSecret: Codable {
    let profileID: UUID
    let secret: String
    let enrolledAt: Date
}

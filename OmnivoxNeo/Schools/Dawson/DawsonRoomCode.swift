import Foundation

/// A Dawson room code, split into the parts the code itself encodes.
///
/// Dawson writes rooms as `<floor><wing>.<room>` — `4H.15` is room 15 in wing H
/// on the 4th floor. That grammar is a Dawson fact, which is why this type
/// lives in Dawson's folder: another college's codes will not parse this way,
/// and should not be forced through this parser.
struct DawsonRoomCode: Equatable, Sendable {
    let raw: String
    let floor: Int
    let wing: String
    let room: String?

    /// Human names for each wing letter.
    ///
    /// Deliberately empty: the letters are real, the names are campus knowledge
    /// this file has no source for. Fill this in and the Campus tab starts
    /// naming wings instead of only lettering them — nothing else needs to
    /// change. This dictionary is exactly the kind of per-school hard-coded
    /// value the sandbox exists to hold.
    static let wingNames: [String: String] = [:]

    var wingName: String? {
        Self.wingNames[wing.uppercased()]
    }

    /// `4H.15` → floor 4, wing H, room 15. Returns nil for anything that is not
    /// in Dawson's format, rather than guessing: a code this parser cannot read
    /// should be shown to the student untouched, not mis-decoded.
    static func parse(_ value: String) -> DawsonRoomCode? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var index = trimmed.startIndex

        // Floor: one or two leading digits.
        var digits = ""
        while index < trimmed.endIndex, trimmed[index].isNumber {
            digits.append(trimmed[index])
            index = trimmed.index(after: index)
        }
        guard digits.count == 1 || digits.count == 2, let floor = Int(digits) else {
            return nil
        }

        // Wing: a single letter.
        guard index < trimmed.endIndex, trimmed[index].isLetter else { return nil }
        let wing = String(trimmed[index]).uppercased()
        index = trimmed.index(after: index)

        // Room: optional, after an optional "." or "-".
        var room: String?
        if index < trimmed.endIndex {
            if trimmed[index] == "." || trimmed[index] == "-" {
                index = trimmed.index(after: index)
            }
            let remainder = trimmed[index...].trimmingCharacters(in: .whitespaces)
            guard !remainder.isEmpty,
                  remainder.count <= 4,
                  remainder.allSatisfy({ $0.isLetter || $0.isNumber })
            else { return nil }
            room = remainder
        }

        return DawsonRoomCode(raw: trimmed, floor: floor, wing: wing, room: room)
    }

    /// Each ordinal is its own key rather than a number glued to "th": French
    /// writes "1er étage" and then "2e", so the suffix is not a rule that
    /// survives translation.
    @MainActor
    var floorLabel: String {
        switch floor {
        case 1: Loc.text("1st floor")
        case 2: Loc.text("2nd floor")
        case 3: Loc.text("3rd floor")
        default: Loc.text("%lldth floor", floor)
        }
    }

    @MainActor
    var wingLabel: String {
        if let wingName { return Loc.text("%@ (wing %@)", wingName, wing) }
        return Loc.text("Wing %@", wing)
    }

    @MainActor
    var roomLabel: String {
        guard let room else { return Loc.text("No room number") }
        return Loc.text("Room %@", room)
    }
}

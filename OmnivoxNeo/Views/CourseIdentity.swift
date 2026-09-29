import SwiftUI

/// One subject a course can belong to, and what it looks like.
///
/// Recognised two ways, because neither is reliable alone. Quebec ministry
/// course codes carry the discipline in their first three digits — `201-MA1-DW`
/// is mathematics at every CEGEP in the province — which is exact where it
/// applies and useless where it does not. Words in the course's own name apply
/// anywhere and are merely a good guess. So the code is tried first and the
/// title second, and the student can overrule both.
struct CourseSubject: Identifiable, Hashable {
    /// A stable key, safe to write to disk. Never shown; `name` is what a
    /// reader sees, and that is translated.
    let id: String
    let symbol: String
    let name: LocalizedStringKey
    let palette: CoursePalette
    /// Quebec discipline codes that mean this subject.
    let disciplineCodes: [String]
    /// Word *stems* that name this subject in a course title, in both of the
    /// app's languages. Stems rather than whole words so "mathematics",
    /// "mathématiques" and "math" all match on "math".
    let titleStems: [String]

    static func == (lhs: CourseSubject, rhs: CourseSubject) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A named two-stop colour, dark enough that white sits on it at AA.
struct CoursePalette: Identifiable, Hashable, Sendable {
    let id: String
    let start: Color
    let end: Color

    var gradient: LinearGradient {
        LinearGradient(colors: [start, end], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    init(_ id: String, _ start: UInt32, _ end: UInt32) {
        self.id = id
        self.start = Color(hex: start)
        self.end = Color(hex: end)
    }

    init(id: String, start: Color, end: Color) {
        self.id = id
        self.start = start
        self.end = end
    }
}

/// What the student chose for one course, when they chose anything.
///
/// Both halves are optional and independent: picking a different icon should
/// not silently repaint the card, and vice versa.
struct CourseAppearance: Codable, Hashable, Sendable {
    var symbol: String?
    var paletteID: String?

    var isEmpty: Bool { symbol == nil && paletteID == nil }
}

/// What a course *looks* like, once everything has been taken into account.
///
/// The colour is never the only signal. Every place one of these is drawn also
/// prints the symbol and the words, because a student who cannot tell teal from
/// green — or who is listening rather than looking — has to get the same screen.
struct CourseIdentity {
    let symbol: String
    let subject: LocalizedStringKey
    let start: Color
    let end: Color

    var gradient: LinearGradient {
        LinearGradient(colors: [start, end], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// The identity for a course, honouring the student's own choice first.
    ///
    /// - Parameters:
    ///   - code: the course code, in whatever shape the school uses.
    ///   - title: the course's name, used when the code means nothing here.
    ///   - override: what the student picked, if they picked anything.
    static func resolve(
        code: String,
        title: String,
        override: CourseAppearance? = nil
    ) -> CourseIdentity {
        let matched = CourseCatalog.subject(code: code, title: title)
        let base = matched.map {
            CourseIdentity(symbol: $0.symbol, subject: $0.name, start: $0.palette.start, end: $0.palette.end)
        } ?? Self.unknown(for: code.isEmpty ? title : code)

        guard let override, !override.isEmpty else { return base }
        let palette = override.paletteID.flatMap(CourseCatalog.palette(id:))
        return CourseIdentity(
            symbol: override.symbol ?? base.symbol,
            subject: base.subject,
            start: palette?.start ?? base.start,
            end: palette?.end ?? base.end
        )
    }

    /// A course nothing recognised still gets told apart from its neighbours:
    /// the hue comes from its own name, so it never changes between launches
    /// the way a random colour would.
    private static func unknown(for seed: String) -> CourseIdentity {
        let hue = Double(abs(CourseCatalog.stableHash(seed)) % 360) / 360
        return CourseIdentity(
            symbol: "graduationcap.fill",
            subject: "Course",
            start: Color(hue: hue, saturation: 0.62, brightness: 0.74),
            end: Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.70, brightness: 0.56)
        )
    }
}

@MainActor
extension CourseIdentity {
    /// The identity to draw for a course, including whatever the student chose.
    ///
    /// Every view that calls this must also observe `Personalization.shared`,
    /// or a change made in the editor will not reach the screen behind it.
    static func forCourse(code: String, title: String) -> CourseIdentity {
        resolve(
            code: code,
            title: title,
            override: Personalization.shared.courseAppearance(for: code)
        )
    }
}

// MARK: - The catalog

enum CourseCatalog {
    /// Every subject the app can recognise, in the order a picker should list
    /// them: the ones a CEGEP student is likeliest to be taking, first.
    static let subjects: [CourseSubject] = [
        CourseSubject(
            id: "mathematics", symbol: "function", name: "Mathematics",
            palette: CoursePalette("indigo", 0x5B5BD6, 0x3F35A8),
            disciplineCodes: ["201"],
            titleStems: ["math", "calcul", "algebr", "algèbr", "geometr", "géométr",
                         "statistic", "statistiq", "trigonometr", "trigonométr", "linear"]
        ),
        CourseSubject(
            id: "biology", symbol: "leaf.fill", name: "Biology",
            palette: CoursePalette("green", 0x2E9E5B, 0x1F7A4A),
            disciplineCodes: ["101"],
            titleStems: ["biolog", "anatom", "genetic", "génétiq", "ecolog", "écolog", "cell", "cellul"]
        ),
        CourseSubject(
            id: "chemistry", symbol: "testtube.2", name: "Chemistry",
            palette: CoursePalette("teal", 0x1F9C8F, 0x14706E),
            disciplineCodes: ["202"],
            titleStems: ["chemist", "chimie", "chimiq", "organic", "organiqu"]
        ),
        CourseSubject(
            id: "physics", symbol: "atom", name: "Physics",
            palette: CoursePalette("sky", 0x2D8FD8, 0x1C5FA8),
            disciplineCodes: ["203"],
            titleStems: ["physic", "physiqu", "mechanic", "mécaniq", "electricit", "électricit", "wave", "optic", "optiqu"]
        ),
        CourseSubject(
            id: "humanities", symbol: "lightbulb.fill", name: "Humanities",
            palette: CoursePalette("amber", 0xC9862B, 0x9B5F16),
            disciplineCodes: ["345"],
            titleStems: ["humanit", "knowledge", "worldview", "ethic", "éthiq"]
        ),
        CourseSubject(
            id: "philosophy", symbol: "quote.bubble.fill", name: "Philosophy",
            palette: CoursePalette("slate", 0x6C6F8F, 0x454868),
            disciplineCodes: ["340"],
            titleStems: ["philosoph", "logic", "logiqu", "rationalit"]
        ),
        CourseSubject(
            id: "english", symbol: "book.fill", name: "English",
            palette: CoursePalette("royal", 0x3C64B8, 0x244288),
            disciplineCodes: ["603", "604"],
            titleStems: ["english", "anglais", "literatur", "littératur", "shakespear", "composition"]
        ),
        CourseSubject(
            id: "french", symbol: "text.book.closed.fill", name: "Français",
            palette: CoursePalette("violet", 0x8B4FBF, 0x63308F),
            disciplineCodes: ["601", "602"],
            titleStems: ["français", "francais", "french"]
        ),
        CourseSubject(
            id: "languages", symbol: "character.bubble.fill", name: "Languages",
            palette: CoursePalette("rust", 0xB5603F, 0x8A3D22),
            disciplineCodes: ["607", "609"],
            titleStems: ["spanish", "espagnol", "german", "allemand", "italian", "italien",
                         "mandarin", "chinese", "chinois", "arabic", "arabe", "japanese", "japonais"]
        ),
        CourseSubject(
            id: "socialscience", symbol: "globe.americas.fill", name: "Social Science",
            palette: CoursePalette("ocean", 0x3D7FC1, 0x255B96),
            disciplineCodes: ["300"],
            titleStems: ["social science", "research method", "méthode de recherch", "sciences humain"]
        ),
        CourseSubject(
            id: "psychology", symbol: "brain.head.profile", name: "Psychology",
            palette: CoursePalette("rose", 0xC4527F, 0x94325F),
            disciplineCodes: ["350"],
            titleStems: ["psycholog", "behaviour", "behavior", "comportement", "cognitio"]
        ),
        CourseSubject(
            id: "sociology", symbol: "person.3.fill", name: "Sociology",
            palette: CoursePalette("orchid", 0x8C5BC4, 0x613A94),
            disciplineCodes: ["387"],
            titleStems: ["sociolog", "societ", "sociét"]
        ),
        CourseSubject(
            id: "anthropology", symbol: "figure.2", name: "Anthropology",
            palette: CoursePalette("magenta", 0xA35BB8, 0x763A8C),
            disciplineCodes: ["381"],
            titleStems: ["anthropolog", "ethnograph", "ethnograf"]
        ),
        CourseSubject(
            id: "economics", symbol: "chart.line.uptrend.xyaxis", name: "Economics",
            palette: CoursePalette("azure", 0x2F7ED1, 0x1B57A0),
            disciplineCodes: ["383"],
            titleStems: ["econom", "économ", "macro", "micro", "market", "marché"]
        ),
        CourseSubject(
            id: "politics", symbol: "building.columns.fill", name: "Political Science",
            palette: CoursePalette("brick", 0xC15438, 0x93341F),
            disciplineCodes: ["385"],
            titleStems: ["politic", "politiq", "government", "gouvernement", "democrac", "démocrat"]
        ),
        CourseSubject(
            id: "history", symbol: "building.columns.fill", name: "History",
            palette: CoursePalette("sepia", 0x9A6B42, 0x6F4726),
            disciplineCodes: ["330"],
            titleStems: ["histor", "histoir", "civilisation", "civilization", "western world"]
        ),
        CourseSubject(
            id: "geography", symbol: "map.fill", name: "Geography",
            palette: CoursePalette("moss", 0x2E9C7A, 0x1B7059),
            disciplineCodes: ["320"],
            titleStems: ["geograph", "géograph", "climat", "territoir"]
        ),
        CourseSubject(
            id: "business", symbol: "briefcase.fill", name: "Business Administration",
            palette: CoursePalette("navy", 0x3A5E96, 0x22406E),
            disciplineCodes: ["401", "410", "412"],
            titleStems: ["business", "administrat", "management", "gestion", "accounting", "comptabilit", "entrepreneur", "marketing"]
        ),
        CourseSubject(
            id: "computing", symbol: "chevron.left.forwardslash.chevron.right", name: "Computer Science",
            palette: CoursePalette("cobalt", 0x4463B4, 0x2A3F85),
            disciplineCodes: ["420"],
            titleStems: ["comput", "programm", "informatiq", "software", "logiciel", "algorithm", "algorithmiq", "data structur"]
        ),
        CourseSubject(
            id: "physed", symbol: "figure.run", name: "Physical Education",
            palette: CoursePalette("jade", 0x27A08C, 0x17796E),
            disciplineCodes: ["109"],
            titleStems: ["physical education", "éducation physiqu", "education physiqu", "fitness",
                         "activité physiqu", "health and", "sport"]
        ),
        CourseSubject(
            id: "nursing", symbol: "cross.case.fill", name: "Nursing",
            palette: CoursePalette("crimson", 0xD8506B, 0xAB3352),
            disciplineCodes: ["180"],
            titleStems: ["nursing", "soins infirmier", "clinical", "cliniqu"]
        ),
        CourseSubject(
            id: "socialwork", symbol: "hands.and.sparkles.fill", name: "Social Work",
            palette: CoursePalette("fuchsia", 0xC25E8E, 0x943D6C),
            disciplineCodes: ["388"],
            titleStems: ["social work", "travail social", "intervention"]
        ),
        CourseSubject(
            id: "visualarts", symbol: "paintpalette.fill", name: "Visual Arts",
            palette: CoursePalette("clay", 0xD1743F, 0xA34C21),
            disciplineCodes: ["510", "570", "574"],
            titleStems: ["drawing", "dessin", "painting", "peintur", "sculpture", "design", "illustrat", "photograph"]
        ),
        CourseSubject(
            id: "arthistory", symbol: "photo.artframe", name: "Art History",
            palette: CoursePalette("bronze", 0xA8703F, 0x7C4B22),
            disciplineCodes: ["520"],
            titleStems: ["art history", "histoire de l'art", "histoire de lart"]
        ),
        CourseSubject(
            id: "cinema", symbol: "film.fill", name: "Cinema",
            palette: CoursePalette("plum", 0x6B5BC4, 0x453A94),
            disciplineCodes: ["502", "582", "585"],
            titleStems: ["cinema", "cinéma", "film", "animation", "multimedia", "multimédia", "video", "vidéo"]
        ),
        CourseSubject(
            id: "music", symbol: "music.note", name: "Music",
            palette: CoursePalette("grape", 0x8452C4, 0x5B3394),
            disciplineCodes: ["540", "550"],
            titleStems: ["music", "musiq", "harmon", "instrument", "choir", "chorale"]
        ),
        CourseSubject(
            id: "theatre", symbol: "theatermasks.fill", name: "Dramatic Arts",
            palette: CoursePalette("carmine", 0xC4577D, 0x95315B),
            disciplineCodes: ["500", "560"],
            titleStems: ["theatre", "theater", "théâtre", "drama", "dance", "danse", "arts and letters", "arts et lettres"]
        ),
        CourseSubject(
            id: "media", symbol: "antenna.radiowaves.left.and.right", name: "Media",
            palette: CoursePalette("steel", 0x3E86AE, 0x265F84),
            disciplineCodes: ["530", "393"],
            titleStems: ["media", "médi", "journalism", "journalisme", "communicat"]
        ),
        CourseSubject(
            id: "methods", symbol: "list.bullet.clipboard.fill", name: "Integrative Methods",
            palette: CoursePalette("graphite", 0x5C7A99, 0x3A5573),
            disciplineCodes: ["360"],
            titleStems: ["integrative", "intégrat", "integrating activity", "épreuve synthès", "capstone"]
        ),
        CourseSubject(
            id: "engineering", symbol: "cpu.fill", name: "Engineering Technology",
            palette: CoursePalette("iron", 0x4A6FA5, 0x2F4A78),
            disciplineCodes: ["210", "221", "235", "241", "243"],
            titleStems: ["electronic", "électroniq", "mechanical", "mécaniqu", "civil", "circuit", "robotic", "robotiq"]
        )
    ]

    /// Extra symbols offered in the picker beyond the subjects' own, so a
    /// student can mark a course by what it means to them rather than by what
    /// department it belongs to.
    static let extraSymbols: [String] = [
        "star.fill", "heart.fill", "flame.fill", "bolt.fill", "sparkles",
        "graduationcap.fill", "pencil.and.ruler.fill", "books.vertical.fill",
        "camera.fill", "gamecontroller.fill", "airplane", "globe.europe.africa.fill",
        "leaf.circle.fill", "moon.stars.fill", "sun.max.fill", "puzzlepiece.fill"
    ]

    /// Every symbol a course can be given, subjects first, without repeats.
    static let symbols: [String] = {
        var seen = Set<String>()
        return (subjects.map(\.symbol) + extraSymbols).filter { seen.insert($0).inserted }
    }()

    static let palettes: [CoursePalette] = {
        var seen = Set<String>()
        return subjects.map(\.palette).filter { seen.insert($0.id).inserted }
    }()

    static func palette(id: String) -> CoursePalette? {
        palettes.first { $0.id == id }
    }

    static func subject(id: String) -> CourseSubject? {
        subjects.first { $0.id == id }
    }

    // MARK: Recognition

    private static let byDiscipline: [String: CourseSubject] = {
        var map: [String: CourseSubject] = [:]
        for subject in subjects {
            for code in subject.disciplineCodes where map[code] == nil {
                map[code] = subject
            }
        }
        return map
    }()

    /// The subject a course belongs to, or nil if nothing recognised it.
    ///
    /// The code is authoritative where it is understood, because it is assigned
    /// rather than written. The title is the fallback, and only ever a guess —
    /// which is why the student can override the answer.
    static func subject(code: String, title: String) -> CourseSubject? {
        if let discipline = disciplineCode(in: code), let match = byDiscipline[discipline] {
            return match
        }
        return subject(matchingTitle: title)
    }

    /// The leading run of digits in a course code, when there are exactly three
    /// of them — which is what a Quebec discipline code is.
    ///
    /// Anything else returns nil rather than a partial match: a school whose
    /// codes read `MATH 1010` has no discipline code, and pretending the "101"
    /// in it means Biology would be worse than admitting nothing is known.
    private static func disciplineCode(in code: String) -> String? {
        let digits = code.drop { !$0.isNumber }.prefix { $0.isNumber }
        guard digits.count == 3, code.first?.isNumber == true else { return nil }
        return String(digits)
    }

    /// Matches a course title against the subjects' word stems.
    ///
    /// Compared token by token rather than by searching the whole string, so
    /// "Particle Physics" does not match on the "art" in "Particle". Accents
    /// are folded, so a French title matches whether or not the portal sent it
    /// with them.
    static func subject(matchingTitle title: String) -> CourseSubject? {
        let normalized = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        guard !normalized.isEmpty else { return nil }

        let tokens = normalized.split { !$0.isLetter && $0 != "'" }.map(String.init)
        guard !tokens.isEmpty else { return nil }

        var best: (subject: CourseSubject, score: Int)?
        for subject in subjects {
            var score = 0
            for stem in subject.titleStems {
                let folded = stem.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                if folded.contains(" ") {
                    // A multi-word stem is a phrase; it has to appear as one.
                    if normalized.contains(folded) { score += folded.count * 2 }
                } else if tokens.contains(where: { $0.hasPrefix(folded) }) {
                    // Longer stems are more specific, so they outrank a short
                    // one that happened to match too.
                    score += folded.count
                }
            }
            if score > 0, score > (best?.score ?? 0) {
                best = (subject, score)
            }
        }
        return best?.subject
    }

    /// `Hasher` is seeded per process, so it would hand the same course a
    /// different colour every launch.
    static func stableHash(_ text: String) -> Int {
        text.unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) }
    }
}

extension Color {
    /// A colour from a `0xRRGGBB` literal, for the palettes above.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

// MARK: - Course titles

extension String {
    /// Léa shouts every course name in capitals. This says it once, normally.
    ///
    /// Only applied to text that is *entirely* uppercase: a title a teacher took
    /// the trouble to case themselves is left exactly as they wrote it. Roman
    /// numerals stay up, because "Calculus i" is a typo rather than a style.
    var sentenceCasedCourseTitle: String {
        let trimmed = replacingOccurrences(of: "...", with: "…")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .lowercaseLetters) == nil else {
            return trimmed
        }

        // A word starts a sentence if it is the first, or follows one that
        // ended in a colon or a dash.
        var isStart = true
        var words: [String] = []
        for word in trimmed.split(separator: " ", omittingEmptySubsequences: false) {
            defer {
                if !word.isEmpty {
                    isStart = word.hasSuffix(":") || word.hasSuffix("—") || word.hasSuffix("-")
                }
            }

            let bare = word.trimmingCharacters(in: CharacterSet(charactersIn: ":.,;—-()"))
            guard !bare.isEmpty else {
                words.append(String(word))
                continue
            }
            if Self.romanNumerals.contains(bare.uppercased()) {
                words.append(String(word))
                continue
            }

            let lower = word.lowercased()
            if !isStart, Self.minorWords.contains(bare.lowercased()) {
                words.append(lower)
            } else {
                words.append(lower.prefix(1).uppercased() + lower.dropFirst())
            }
        }
        return words.joined(separator: " ")
    }

    private static let romanNumerals: Set<String> = [
        "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X", "XI", "XII"
    ]

    /// Words a title keeps lowercase, in both of the app's languages.
    private static let minorWords: Set<String> = [
        "a", "an", "and", "as", "at", "but", "by", "for", "from", "in", "into",
        "nor", "of", "on", "or", "the", "to", "with", "vs",
        "à", "au", "aux", "dans", "de", "des", "du", "en", "et", "la", "le",
        "les", "par", "pour", "sur", "un", "une"
    ]
}

import Foundation

/// Everything the demo shows in place of a real account.
///
/// The schedule already had fixtures; Léa and MIO did not, so the demo tour
/// arrived at two of the app's four tabs and found them empty or erroring.
/// Somebody shown the app that way concludes those parts do not work, which
/// is the opposite of what a demo is for.
///
/// Written as plausible college mail and coursework rather than lorem ipsum.
/// A screen full of "Message 1 / Message 2" demonstrates a layout; a screen
/// with a cancelled class, a late-work question and a bursary deadline on it
/// demonstrates the app.
///
/// Compiled into release builds for the same reason `DemoAccount` is — a demo
/// you can only show next to Xcode is not much of a demo.
enum DemoFixtures {

    // MARK: - Rooms

    /// Dawson numbers its rooms `<floor><wing>.<number>`: 4H.15, 3C.2, 5E.19.
    ///
    /// The old fixtures used "A-101" and "B-204", which is nobody's building.
    /// A student looking at the demo should recognise the room format as their
    /// own — it is one of the few details that says the app knows this college
    /// rather than colleges in general.
    static let rooms = ["4H.15", "3C.2", "5E.19", "2D.7", "7B.12", "4F.2"]

    // MARK: - Léa

    static func leaOverview(fetchedAt: Date) -> LeaOverview {
        LeaOverview(
            terms: [
                LeaTerm(value: "demo-fall", title: "Fall 2026", isCurrent: true),
                LeaTerm(value: "demo-winter", title: "Winter 2026", isCurrent: false)
            ],
            selectedTerm: "demo-fall",
            courses: [
                course(
                    code: "201-NYA-05",
                    title: "Calculus I",
                    teacher: "Georgeana Bobos-Kristof",
                    days: "Mon 10:00, Wed 10:00, Fri 12:00",
                    palette: 0,
                    documents: 14,
                    newDocuments: 2,
                    assignments: 3,
                    grade: ("38.5/50", "77%"),
                    announcements: [
                        ("Oct-06", "Midterm covers chapters 1 to 4", true),
                        ("Sep-28", "Office hours moved to Thursday", false)
                    ]
                ),
                course(
                    code: "603-101-MQ",
                    title: "Introduction to College English",
                    teacher: "Luke Reid",
                    days: "Tue 08:30, Thu 08:30",
                    palette: 3,
                    documents: 9,
                    newDocuments: 0,
                    assignments: 2,
                    grade: ("17/20", "85%"),
                    announcements: [
                        ("Oct-07", "Essay 2 prompt is posted", true)
                    ]
                ),
                course(
                    code: "350-102-RE",
                    title: "Introduction to Psychology",
                    teacher: "Marie-Claude Tremblay",
                    days: "Mon 13:00, Wed 13:00",
                    palette: 6,
                    documents: 21,
                    newDocuments: 5,
                    assignments: 1,
                    grade: ("44/60", "73%"),
                    announcements: [
                        ("Oct-05", "Lab groups for the memory experiment", true),
                        ("Sep-30", "Reading week schedule", false)
                    ]
                ),
                course(
                    code: "109-101-MQ",
                    title: "Physical Education: Fitness",
                    teacher: "Daniel Okonkwo",
                    days: "Fri 09:00",
                    palette: 8,
                    documents: 4,
                    newDocuments: 0,
                    assignments: 0,
                    grade: nil,
                    announcements: []
                )
            ],
            isEmptyTerm: false,
            fetchedAt: fetchedAt
        )
    }

    private static func course(
        code: String,
        title: String,
        teacher: String,
        days: String,
        palette: Int,
        documents: Int,
        newDocuments: Int,
        assignments: Int,
        grade: (String, String)?,
        announcements: [(String, String, Bool)]
    ) -> LeaCourse {
        var sections: [LeaSection] = [
            LeaSection(
                kind: .documents,
                label: "Documents and videos",
                trailingText: nil,
                url: nil,
                metrics: [
                    LeaMetric(
                        label: "Documents",
                        count: documents,
                        text: nil,
                        detail: nil,
                        isNew: false
                    ),
                    LeaMetric(
                        label: "New since your last visit",
                        count: newDocuments,
                        text: nil,
                        detail: nil,
                        isNew: newDocuments > 0
                    )
                ].filter { $0.count ?? 0 > 0 },
                announcements: [],
                events: []
            )
        ]

        if assignments > 0 {
            sections.append(
                LeaSection(
                    kind: .assignments,
                    label: "Assignments",
                    trailingText: nil,
                    url: nil,
                    metrics: [
                        LeaMetric(
                            label: "To hand in",
                            count: assignments,
                            text: nil,
                            detail: nil,
                            isNew: false
                        )
                    ],
                    announcements: [],
                    events: []
                )
            )
        }

        if let grade {
            sections.append(
                LeaSection(
                    kind: .grades,
                    label: "Grades",
                    trailingText: nil,
                    url: nil,
                    metrics: [
                        LeaMetric(
                            label: "Your current grade",
                            count: nil,
                            text: grade.0,
                            detail: grade.1,
                            isNew: false
                        )
                    ],
                    announcements: [],
                    events: []
                )
            )
        }

        if !announcements.isEmpty {
            sections.append(
                LeaSection(
                    kind: .announcements,
                    label: "Announcements",
                    trailingText: nil,
                    url: nil,
                    metrics: [],
                    announcements: announcements.map {
                        LeaAnnouncementSummary(
                            date: $0.0,
                            title: $0.1,
                            url: nil,
                            isNew: $0.2
                        )
                    },
                    events: []
                )
            )
        }

        return LeaCourse(
            code: code,
            title: title,
            subtitle: "sect. 00001 - \(days), \(teacher)",
            teacher: teacher,
            paletteIndex: palette,
            sections: sections
        )
    }

    // MARK: - Léa, one course deep

    /// Grades for a course, built from its code so each one differs.
    ///
    /// The demo used to stop at the course list: tapping into Grades reported
    /// "Léa did not publish this section for this course", which is the app
    /// telling the truth about a fixture that was not there and reads as the
    /// screen being broken.
    static func leaGrades(for course: LeaCourse) -> LeaGrades {
        let items: [LeaGradeItem]
        let summary: LeaGradeSummary

        if course.code.hasPrefix("201") {
            items = [
                gradeItem("1.", "Assignment 1", "9.5/10", "95%", "8.4/10", "5%"),
                gradeItem("2.", "Assignment 2", "8/10", "80%", "7.9/10", "5%"),
                gradeItem("3.", "Midterm", "38.5/50", "77%", "35.2/50", "25%"),
                gradeItem("4.", "Assignment 3", nil, nil, nil, "5%"),
                gradeItem("5.", "Final examination", nil, nil, nil, "40%")
            ]
            summary = LeaGradeSummary(
                currentGrade: "56/70",
                currentPercent: "80%",
                statistics: [
                    LeaGradeStatistic(label: "Class average", value: "74%"),
                    LeaGradeStatistic(label: "Median", value: "76%"),
                    LeaGradeStatistic(label: "Standard deviation", value: "9.1%")
                ],
                progression: []
            )
        } else if course.code.hasPrefix("603") {
            items = [
                gradeItem("1.", "Reading response", "17/20", "85%", "15.8/20", "10%"),
                gradeItem("2.", "Essay 1", "22/25", "88%", "20.1/25", "20%"),
                gradeItem("3.", "Essay 2", nil, nil, nil, "25%")
            ]
            summary = LeaGradeSummary(
                currentGrade: "39/45",
                currentPercent: "87%",
                statistics: [
                    LeaGradeStatistic(label: "Class average", value: "79%"),
                    LeaGradeStatistic(label: "Median", value: "81%")
                ],
                progression: []
            )
        } else {
            items = [
                gradeItem("1.", "Quiz 1", "14/20", "70%", "15.1/20", "10%"),
                gradeItem("2.", "Lab report", "30/40", "75%", "28.8/40", "20%"),
                gradeItem("3.", "Research paper", nil, nil, nil, "30%")
            ]
            summary = LeaGradeSummary(
                currentGrade: "44/60",
                currentPercent: "73%",
                statistics: [
                    LeaGradeStatistic(label: "Class average", value: "71%"),
                    LeaGradeStatistic(label: "Median", value: "72%")
                ],
                progression: []
            )
        }

        return LeaGrades(
            teacher: course.teacher,
            // One unnamed category, which is also the shape a teacher who
            // groups nothing produces — the case the parser had to learn.
            categories: [
                LeaGradeCategory(
                    name: "",
                    weightText: nil,
                    averageText: nil,
                    dropRule: nil,
                    items: items
                )
            ],
            summary: summary
        )
    }

    private static func gradeItem(
        _ position: String,
        _ title: String,
        _ mark: String?,
        _ percent: String?,
        _ average: String?,
        _ weight: String
    ) -> LeaGradeItem {
        LeaGradeItem(
            position: position,
            title: title,
            date: nil,
            mark: mark,
            markPercent: percent,
            classAverage: average,
            weight: weight,
            weightPoints: nil,
            isDiscarded: false,
            discardNote: nil,
            comment: nil
        )
    }

    static func leaDocuments(for course: LeaCourse) -> [LeaDocumentCategory] {
        [
            LeaDocumentCategory(
                name: "Course outline",
                documents: [
                    document("Course outline \(course.code).pdf", "182 Kb", unread: false)
                ]
            ),
            LeaDocumentCategory(
                name: "Lecture notes",
                documents: [
                    document("Week 5 — slides.pdf", "1.4 Mb", unread: true),
                    document("Week 4 — slides.pdf", "1.2 Mb", unread: false),
                    document("Week 3 — slides.pdf", "980 Kb", unread: false)
                ]
            ),
            LeaDocumentCategory(
                name: "Practice",
                documents: [
                    document("Practice set 3.pdf", "320 Kb", unread: true),
                    document("Practice set 3 — solutions.pdf", "410 Kb", unread: false)
                ]
            )
        ]
    }

    private static func document(_ name: String, _ size: String, unread: Bool) -> LeaDocument {
        LeaDocument(
            title: name,
            detail: nil,
            requiredBy: nil,
            availableSince: "since Oct 2, 2026",
            isUnread: unread,
            destination: .file(
                name: name,
                size: size,
                // Deliberately unreachable. Nothing in the demo should leave
                // the device, and a fixture that quietly fetched something
                // would be a demo that needs a network.
                url: URL(string: "https://demo.invalid/\(name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "file")")!
            )
        )
    }

    static func leaAssignments(for course: LeaCourse) -> [LeaAssignment] {
        [
            LeaAssignment(
                category: "Assignments",
                title: "Practice set 3",
                dueText: "Oct-14, 2026 at 23:59",
                dueVia: "via Léa",
                isOverdue: false,
                hasUnreadInstructions: true,
                instructionsURL: nil,
                submissionText: nil,
                submissionURL: nil,
                correctedCopyURL: nil
            ),
            LeaAssignment(
                category: "Assignments",
                title: "Practice set 2",
                dueText: "Oct-01, 2026 at 23:59",
                dueVia: "via Léa",
                isOverdue: false,
                hasUnreadInstructions: false,
                instructionsURL: nil,
                submissionText: "practice-set-2.pdf",
                submissionURL: nil,
                correctedCopyURL: nil
            )
        ]
    }

    static func leaAnnouncement() -> LeaAnnouncement {
        LeaAnnouncement(
            title: "Midterm covers chapters 1 to 4",
            courseLine: "201-NYA-05 — Calculus I",
            byline: "Georgeana Bobos-Kristof, Oct-06",
            bodyHTML: """
            <p>Hello everyone,</p>
            <p>The midterm on <b>Wednesday</b> covers chapters 1 to 4. You may             bring one handwritten sheet, both sides.</p>
            <ul>
              <li>Limits and continuity</li>
              <li>The derivative, from the definition</li>
              <li>Product, quotient and chain rules</li>
              <li>Implicit differentiation</li>
            </ul>
            <p>Practice set 3 is the best preparation. Solutions are posted             under Documents.</p>
            """
        )
    }

    // MARK: - MIO

    static func mioOverview(fetchedAt: Date) -> MioOverview {
        MioOverview(
            folders: [
                MioFolder(key: "demo-inbox", kind: .inbox, name: "Inbox", unreadCount: 3),
                MioFolder(key: "demo-sent", kind: .sent, name: "Sent", unreadCount: nil),
                MioFolder(key: "demo-drafts", kind: .drafts, name: "Draft", unreadCount: nil),
                MioFolder(key: "demo-flagged", kind: .flagged, name: "Flagged", unreadCount: 1),
                MioFolder(key: "demo-deleted", kind: .deleted, name: "Deleted Items", unreadCount: nil)
            ],
            fetchedAt: fetchedAt
        )
    }

    static func mioMessages(in folderKey: String) -> MioMessageList {
        let messages: [MioMessage]
        switch folderKey {
        case "demo-sent":
            messages = sentMessages
        case "demo-drafts":
            messages = []
        case "demo-flagged":
            messages = inboxMessages.filter(\.isFlagged)
        case "demo-deleted":
            messages = [
                message(
                    id: "demo-d1",
                    name: "Bookstore",
                    subject: "Your textbook order is ready",
                    preview: "Your order is waiting at the counter in 2C.1 until Friday.",
                    date: "2026-09-24",
                    state: .read,
                    who: .employee,
                    role: "Employee"
                )
            ]
        default:
            messages = inboxMessages
        }
        return MioMessageList(
            folderKey: folderKey,
            messages: messages,
            totalText: messages.isEmpty ? nil : "\(messages.count) messages"
        )
    }

    private static let inboxMessages: [MioMessage] = [
        message(
            id: "demo-1",
            name: "Georgeana Bobos-Kristof",
            subject: "Wednesday's class is moved to 4H.15",
            preview: "Dear students, Note that our Wednesday class has been moved from the forum to…",
            date: "08:42",
            state: .unread,
            who: .employee,
            role: "Employee"
        ),
        message(
            id: "demo-2",
            name: "Financial Aid Office",
            subject: "Bursary applications close on 31 October",
            preview: "Hello, You are receiving this MIO because you may be eligible for the fall…",
            date: "Yesterday",
            state: .unread,
            who: .manager,
            role: "Manager",
            attachment: "1 attached file",
            attachmentSize: "248 Kb"
        ),
        message(
            id: "demo-3",
            name: "Luke Reid",
            subject: "Re: Extension on Essay 2",
            preview: "Hi Thomas, No problem at all — hand it in by Monday morning and I will mark…",
            date: "Yesterday",
            state: .unread,
            who: .employee,
            role: "Employee",
            flagged: true
        ),
        message(
            id: "demo-4",
            name: "student bulletin",
            subject: "Your Dawson Insider for Oct. 2",
            preview: "Dear Dawson student, From events and activities to important reminders, you'll…",
            date: "2026-10-02",
            state: .read,
            who: .manager,
            role: "Manager"
        ),
        message(
            id: "demo-5",
            name: "Marie-Claude Tremblay",
            subject: "Memory experiment: sign up for a lab group",
            preview: "Hello everyone, The sign-up sheet for the memory experiment is now open. Each…",
            date: "2026-09-30",
            state: .replied,
            who: .employee,
            role: "Employee",
            secondRead: true
        ),
        message(
            id: "demo-6",
            name: "Registrar",
            subject: "Course change deadline",
            preview: "This is a reminder that the deadline to drop a course without academic penalty…",
            date: "2026-09-26",
            state: .read,
            who: .manager,
            role: "Manager"
        )
    ]

    private static let sentMessages: [MioMessage] = [
        message(
            id: "demo-s1",
            name: "Luke Reid",
            subject: "Extension on Essay 2",
            preview: "Hello, I was unwell for most of last week and I am a little behind on the…",
            date: "2026-10-06",
            state: .sent,
            who: .employee,
            role: "Employee",
            isSent: true,
            receipt: MioReadReceipt(read: 1, total: 1)
        ),
        message(
            id: "demo-s2",
            name: "Daniel Okonkwo",
            subject: "Absence on Friday",
            preview: "Good afternoon, I have a medical appointment on Friday morning and will miss…",
            date: "2026-10-01",
            state: .sent,
            who: .employee,
            role: "Employee",
            isSent: true,
            receipt: MioReadReceipt(read: 0, total: 1)
        )
    ]

    private static func message(
        id: String,
        name: String,
        subject: String,
        preview: String,
        date: String,
        state: MioMessage.State,
        who: MioMessage.Correspondent,
        role: String,
        flagged: Bool = false,
        secondRead: Bool = false,
        attachment: String? = nil,
        attachmentSize: String? = nil,
        isSent: Bool = false,
        receipt: MioReadReceipt? = nil
    ) -> MioMessage {
        MioMessage(
            id: id,
            messageID: id,
            isSent: isSent,
            state: state,
            correspondent: who,
            correspondentLabel: role,
            name: name,
            subject: subject,
            preview: preview,
            dateText: date,
            isFlagged: flagged,
            needsSecondRead: secondRead,
            attachmentNote: attachment,
            attachmentSize: attachmentSize,
            category: nil,
            readReceipt: receipt,
            openURL: nil
        )
    }

    /// One opened message. Written as real HTML because that is what the
    /// reader renders — the demo should exercise the same path a teacher's
    /// formatting goes through, not a plain-text shortcut around it.
    static func mioDetail(for token: String) -> MioMessageDetail {
        let body: String
        let subject: String
        let sender: String

        switch token {
        case "demo-2":
            subject = "Bursary applications close on 31 October"
            sender = "Financial Aid Office"
            body = """
            <p>Hello,</p>
            <p>You are receiving this MIO because you may be eligible for the \
            fall bursary. Applications close on <b>31 October</b>.</p>
            <p>You will need:</p>
            <ul>
              <li>Proof of enrolment for the current term</li>
              <li>Your most recent notice of assessment</li>
              <li>A short statement of need</li>
            </ul>
            <p>The form is attached. Bring the completed copy to <b>2D.7</b>, \
            or reply to this message with it.</p>
            <p>Financial Aid Office</p>
            """
        case "demo-3":
            subject = "Re: Extension on Essay 2"
            sender = "Luke Reid"
            body = """
            <p>Hi Thomas,</p>
            <p>No problem at all — hand it in by <b>Monday morning</b> and I \
            will mark it with the rest of the batch. No late penalty.</p>
            <p>Get well,<br>Luke</p>
            """
        default:
            subject = "Wednesday's class is moved to 4H.15"
            sender = "Georgeana Bobos-Kristof"
            body = """
            <p>Dear students,</p>
            <p>Note that our Wednesday class has been moved from the forum to \
            <b>4H.15</b> for the rest of the term.</p>
            <p>We will spend Wednesday on the review for the midterm, which \
            covers chapters 1 to 4. Please bring your own worked solutions to \
            the practice set — we will go through the ones people found hardest \
            rather than all of them.</p>
            <p>See you then,<br>Georgeana</p>
            """
        }

        return MioMessageDetail(
            subject: subject,
            sender: sender,
            recipients: ["Thomas Demo"],
            dateText: "Wed Oct-07-2026 at 08:42",
            bodyHTML: body,
            baseURL: nil,
            attachments: token == "demo-2"
                ? [
                    MioAttachment(
                        name: "Bursary-application.pdf",
                        sizeText: "248 Kb",
                        url: URL(string: "https://example.invalid/demo.pdf")!
                    )
                ]
                : [],
            readReceipt: nil,
            canReply: true,
            canReplyAll: true
        )
    }
}

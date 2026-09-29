import SwiftUI

struct HomeView: View {
    private enum Tab: Hashable {
        case schedule
        case lea
        case mio
        case me
    }

    @ObservedObject var model: AppModel
    @StateObject private var lea: LeaStore
    @StateObject private var mio: MioStore
    @State private var selection: Tab

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// Whether there is room to show a list and what it points at side by side.
    ///
    /// Decided once, here, and handed down: every screen that can split needs
    /// the same answer, and asking the size class in each of them is how two
    /// screens end up disagreeing about what device they are on. A Mac window
    /// is always wide enough; an iPhone, and an iPad running two apps in a
    /// narrow slice, are not.
    private var prefersSplitLayout: Bool {
        #if os(iOS)
        horizontalSizeClass == .regular
        #else
        true
        #endif
    }

    init(model: AppModel) {
        self.model = model
        // One store per profile, built from that profile's own cookie jar, so
        // Léa is the same signed-in student as the rest of the app.
        _lea = StateObject(
            wrappedValue: LeaStore(
                institution: model.institution,
                websiteDataStore: model.portalWebsiteDataStore
            )
        )
        _mio = StateObject(
            wrappedValue: MioStore(
                institution: model.institution,
                websiteDataStore: model.portalWebsiteDataStore
            )
        )

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--demo-me") {
            _selection = State(initialValue: .me)
        } else {
            _selection = State(initialValue: .schedule)
        }
        #else
        _selection = State(initialValue: .schedule)
        #endif
    }

    /// Four tabs, and every one of them is a place rather than a feed.
    ///
    /// Agenda and Updates used to sit here too. They were two views of the same
    /// portal data — dated items and freshly-changed items — and splitting them
    /// across two tabs meant a student had to guess which one held the thing
    /// they half-remembered. They are now one screen behind the bell on Home.
    var body: some View {
        TabView(selection: $selection) {
            ScheduleView(model: model)
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }
                .tag(Tab.schedule)

            // Coursework sits second: after Home it is the thing school is
            // actually made of, and the one most days start with.
            LeaView(model: model, store: lea)
                .tabItem {
                    Label(
                        LocalizedStringKey(model.institution.conventions.courseworkDisplayName),
                        systemImage: "books.vertical.fill"
                    )
                }
                .badge(lea.unreadCount)
                .tag(Tab.lea)

            // Messages next to it, under the name the college actually uses
            // rather than "Messages": a teacher who says "check your MIO" has
            // named a place, and a tab called something else is not it.
            MioView(model: model, store: mio)
                .tabItem {
                    Label(
                        LocalizedStringKey(model.institution.conventions.messagingDisplayName),
                        systemImage: "envelope.fill"
                    )
                }
                .badge(mio.unreadCount)
                .tag(Tab.mio)

            MeView(model: model)
                .tabItem {
                    Label("Account", systemImage: "person.crop.circle.fill")
                }
                .tag(Tab.me)
        }
        .environment(\.prefersSplitLayout, prefersSplitLayout)
        .onAppear {
            // Handed over here rather than looked up later: a sheet's
            // coordinator is built before it has an environment to read.
            LeaWebSession.shared.adopt(model.portalWebsiteDataStore)
        }
        // Léa clips its course names to fit its own card and prints what is
        // left in capitals. The timetable already carries the whole name, so
        // it is lent to Léa rather than shown twice in two shapes.
        .onChange(of: model.courses, initial: true) {
            lea.adoptCourseTitles(
                model.courses.map { (label: $0.courseLabel ?? "", title: $0.title) }
            )
        }
        // Léa is read ahead of the tap, so its badge is right before anyone
        // looks at it and the tab opens on courses rather than on "Opening
        // Léa…". Held until the schedule's own read has settled: both drive the
        // same portal session through a web view of their own, and overlapping
        // them is how one navigation lands on the other's page.
        .task(id: model.portalIsIdle) {
            guard model.portalIsIdle else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, model.portalIsIdle else { return }
            lea.loadIfNeeded()
            // Mail reads on the same schedule and for the same reason: the
            // badge should be right before anybody looks at it, and neither
            // should hold up the first screen of the app. Staggered behind Léa
            // because both drive a web view through the same signed-in session.
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, model.portalIsIdle else { return }
            mio.loadIfNeeded()
        }
        .sheet(isPresented: $model.showTOTPSetupPrompt) {
            FirstTimeTOTPPromptView(model: model)
                // A swipe down is an answer too. Without this it was the one
                // remaining way to be asked again tomorrow.
                .onDisappear { model.markTOTPPromptShown() }
        }
    }
}

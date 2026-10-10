import Combine
import Foundation
import WebKit

@MainActor
final class AppModel: NSObject, ObservableObject {
    enum Screen: Equatable {
        case launching
        case locked
        case login
        case verification
        case securitySetupGuidance
        case securitySetup
        case schedule
    }

    @Published private(set) var screen: Screen = .launching
    @Published private(set) var isBusy = false
    @Published private(set) var courses: [CourseMeeting] = []
    @Published private(set) var calendarEvents: [PortalCalendarEvent] = []
    @Published private(set) var portalUpdates: [PortalUpdate] = []
    @Published private(set) var userFirstName: String?
    @Published private(set) var lastScheduleRefresh: Date?
    @Published private(set) var isRefreshingSchedule = false
    @Published private(set) var biometricLockEnabled: Bool
    @Published private(set) var securitySetupIsBusy = false
    @Published private(set) var securitySetupError: String?
    @Published private(set) var verificationState: VerificationState = .loading
    @Published private(set) var verificationIsBusy = false
    @Published private(set) var verificationNotice: String?
    @Published var showTOTPSetupPrompt = false
    @Published var autoTOTPInProgress = false
    @Published var autoTOTPStep: String?
    @Published var autoTOTPError: String?
    @Published var loginError: String?
    @Published var sessionError: String?
    @Published var loginStudentID: String {
        didSet {
            let normalized = Self.normalizedStudentID(loginStudentID)
            guard normalized.count == 7 else { return }
            preferences.set(normalized, forKey: Self.studentIDPreferenceKey)
        }
    }

    let institution: Institution
    let webView: WKWebView
    let biometricCapability: BiometricCapability
    /// Which agenda categories this account mirrors into the phone's calendar.
    let calendarSubscription: CalendarSubscription
    /// What has changed in the agenda since this account last looked.
    let agendaReadState: AgendaReadState

    private enum NavigationContext: Equatable {
        case none
        case restoringSession
        case biometricSessionValidation
        case biometricReauthentication
        case manualSignIn
        case authenticated
        case clearingSession
    }

    private enum SubmissionState {
        case none
        case ready
        case submitted
    }

    private struct Credentials {
        let studentID: String
        let password: String
    }

    private struct PageProbe: Decodable {
        let kind: String
        let title: String?
        let error: String?
        let verification: VerificationProbe?
    }

    private struct VerificationProbe: Decodable {
        let mode: String
        let instruction: String
        let destination: String?
        let canRequestNewCode: Bool
        let canChooseAnotherMethod: Bool
        let canGoBack: Bool
        let trustedDeviceSelected: Bool
        let methods: [VerificationMethodProbe]
        let codeMethodKind: String?
        let methodReference: String?
    }

    private struct VerificationMethodProbe: Decodable {
        let index: Int
        let kind: String
        let title: String
        let detail: String
        let reference: String?
    }

    private struct ScheduleDOMPayload: Decodable {
        let ready: Bool
        let records: [PortalCourseRecord]
        let events: [PortalCalendarRecord]
        let updates: [PortalUpdateRecord]
        let profileName: String?
    }

    private static let biometricPreferenceKey = "security.biometric-lock-enabled"
    private static let securitySetupKey = "security.initial-setup-complete"
    private static let studentIDPreferenceKey = "login.last-student-id"
    private static let authenticatorReferenceKeyPrefix = "totp.method-reference."
    /// Shared with `LeaService`, which opens a second web view into the same
    /// session and must look like the same client.
    static let portalUserAgentProduct = "OmnivoxNeoClientApp"

    private let preferences: UserDefaults
    private let scheduleCache: ScheduleCache
    private let portalCredentialVault: PortalCredentialVault
    private let portalTrustedStateVault: PortalTrustedStateVault
    private var navigationContext: NavigationContext = .none
    private var submissionState: SubmissionState = .none
    private var pendingCredentials: Credentials?
    private var submittedCredentials: Credentials?
    private var biometricCredentials: Credentials?
    private var credentialsAwaitingBiometricEnrollment: Credentials?
    private var authenticatedNavigationHandled = false
    private var extractionGeneration = UUID()
    private var dashboardProbeAttempt = 0
    private var verificationProbeAttempt = 0
    private var hasCachedScheduleSnapshot = false
    private var needsPortalContentCacheMigration = false
    private var screenBeforeLock: Screen = .schedule
    /// The language the in-flight portal request asked for.
    private var lastRequestedPortalLanguage = AppLanguageStore.shared.effectiveLanguageCode
    private var shouldUnlockWhenActive = false
    private var shouldReauthenticateWhenActive = false
    private var applicationIsActive = false
    private var authenticationGeneration = UUID()
    /// True while the app is showing fixtures rather than a real session.
    ///
    /// Not `#if DEBUG`, even though the `--demo-*` launch arguments that set it
    /// are. `DemoAccount` reaches the same configurators from the sign-in
    /// screen in **every** configuration, and the three places that ask about
    /// it — the portal-idle check and the two refresh paths — are not behind
    /// the flag either. Declaring it debug-only meant a release build had five
    /// references to a property that did not exist, so the app has never
    /// compiled for a device.
    ///
    /// Readable from outside because the Léa and MIO stores are owned by
    /// `HomeView`, not by this model, and they have to be told to show
    /// fixtures rather than reach for a session the demo does not have.
    private(set) var isDemoMode = false
    private var restoredTrustedPortalState = false
    private var trustedStatePersistenceGeneration = UUID()
    private var autoTOTPTask: Task<Void, Never>?
    private var autoTOTPAttemptedGeneration: UUID?

    // Profile system
    private let profileStore = PortalProfileStore.shared
    private var currentProfileID: UUID?

    /// The profile this session is bound to, for views that need to reason
    /// about accounts. An `AppModel` never changes profile — a switch builds a
    /// new one — so this is constant for the model's lifetime.
    var activeProfileID: UUID? { currentProfileID }

    var activeProfile: PortalProfile? {
        guard let currentProfileID else { return nil }
        return profileStore.profiles.first { $0.id == currentProfileID }
    }

    init(
        institution: Institution = .dawson,
        startsAutomatically: Bool = true,
        preferences: UserDefaults = .standard,
        websiteDataStore: WKWebsiteDataStore? = nil,
        profileID: UUID? = nil
    ) {
        self.institution = institution
        self.preferences = preferences

        // Determine which profile to use
        if let profileID = profileID {
            // Deliberately not `switchTo` here: this runs inside SwiftUI's view
            // construction, and publishing a change from there is undefined
            // behaviour. The caller has already made this profile active; the
            // last-used stamp is refreshed later, from `start()`.
            currentProfileID = profileID
        } else {
            currentProfileID = profileStore.activeProfileID ?? profileStore.createProfile(institutionID: institution.id)
        }

        guard let activeProfileID = currentProfileID else {
            fatalError("Failed to establish active profile")
        }

        // Prefill from this profile, not from whoever signed in last. The
        // shared key is a first-run convenience only: once the device has more
        // than one account, an empty profile is an "Add Account" in progress
        // and must start blank rather than suggesting someone else's ID.
        let profileStudentID = profileStore.profiles
            .first { $0.id == activeProfileID }?
            .studentID ?? ""
        // Adding an account starts blank. Coming back after a logout prefills
        // whoever signed in last, so they only have to type a password.
        loginStudentID = Self.normalizedStudentID(
            profileStudentID.isEmpty && !profileStore.isAddingAccount
                ? (preferences.string(forKey: Self.studentIDPreferenceKey) ?? "")
                : profileStudentID
        )
        scheduleCache = ScheduleCache(profileID: activeProfileID)
        calendarSubscription = CalendarSubscription(profileID: activeProfileID)
        agendaReadState = AgendaReadState(profileID: activeProfileID)
        portalCredentialVault = PortalCredentialVault(profileID: activeProfileID)
        portalTrustedStateVault = PortalTrustedStateVault(
            profileID: activeProfileID,
            institutionHost: institution.host,
            portalDomainSuffix: institution.conventions.portalDomainSuffix,
            sessionOnlyCookieNames: institution.conventions.sessionOnlyCookieNames,
            sessionOnlyCookiePrefixes: institution.conventions.sessionOnlyCookiePrefixes
        )
        portalTrustedStateVault.migrateLegacyArchiveIfNeeded()
        biometricCapability = .current
        // Face ID, onboarding and guidance are account settings, not device
        // settings. A second student must not inherit the first one's.
        let profileIsBound = profileStore.profiles
            .first { $0.id == activeProfileID }?.isBound ?? false
        // Defaults to on for an account that already has a biometric lock:
        // the saved copy is what that account has been running on, and
        // silently taking it away on upgrade would look like a regression.
        // A new account is asked during setup.
        let fastUnlockKey = "\(Self.fastUnlockPreferenceKey).\(activeProfileID.uuidString)"
        fastUnlockEnabled = preferences.object(forKey: fastUnlockKey) == nil
            ? true
            : preferences.bool(forKey: fastUnlockKey)
        biometricLockEnabled = Self.scopedFlag(
            preferences,
            base: Self.biometricPreferenceKey,
            profileID: activeProfileID,
            inheritingLegacyValue: profileIsBound
        )

        let configuration = WKWebViewConfiguration()
        // Use profile-specific data store for cookie isolation
        if #available(iOS 17.0, macOS 14.0, *) {
            configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: activeProfileID)
        } else {
            configuration.websiteDataStore = websiteDataStore ?? .default()
        }
        configuration.applicationNameForUserAgent = Self.portalUserAgentProduct
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: configuration)

        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.configuration.websiteDataStore.httpCookieStore.add(self)
        webView.allowsBackForwardNavigationGestures = true

        #if os(iOS)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        #endif

        #if DEBUG
        if startsAutomatically, ProcessInfo.processInfo.arguments.contains("--demo-login") {
            isDemoMode = true
            loginStudentID = ""
            screen = .login
            return
        }
        if startsAutomatically, ProcessInfo.processInfo.arguments.contains("--demo-verification") {
            configureDemoVerification()
            return
        }
        if startsAutomatically, ProcessInfo.processInfo.arguments.contains("--demo-schedule") {
            configureDemoSchedule(studentID: "1234567", displayName: "Thomas")
            return
        }
        // A name long enough to prove the greeting walks rather than truncates.
        if startsAutomatically, ProcessInfo.processInfo.arguments.contains("--demo-long-name") {
            configureDemoSchedule(
                studentID: "1234567",
                displayName: "Bartholomew Maximilian"
            )
            return
        }
        // The choices a student is offered once, on their first sign-in.
        if startsAutomatically, ProcessInfo.processInfo.arguments.contains("--demo-security-setup") {
            isDemoMode = true
            screen = .securitySetup
            return
        }
        // The two ways the app runs on what it already has. Reachable without
        // unplugging anything, because neither is easy to produce on purpose.
        if startsAutomatically, ProcessInfo.processInfo.arguments.contains("--demo-offline") {
            configureDemoSchedule(studentID: "1234567", displayName: "Thomas")
            limitation = .offline
            return
        }
        if startsAutomatically, ProcessInfo.processInfo.arguments.contains("--demo-countdown") {
            configureDemoSchedule(studentID: "1234567", displayName: "Thomas")
            // Through the real call, not by setting the state: the part worth
            // demonstrating is that the clock actually runs out.
            demandSignIn("demo")
            return
        }
        // The screen a college's own interstitial lands on. Reachable without
        // credentials because the only other way to see it is to have the
        // college actually be waiting on something.
        if startsAutomatically, ProcessInfo.processInfo.arguments.contains("--demo-school-action") {
            isDemoMode = true
            unrecognizedPageAddress = institution.origin
                .appending(path: "/intr/Module/Identification/PhotoEtudiant.aspx")
                .absoluteString
            verificationState = VerificationState(
                mode: .schoolActionRequired,
                title: Loc.text("%@ needs something from you", institution.displayName),
                instruction: Loc.text("There is something waiting for you on the official %@ website, and OmniVox will not go any further until it has been taken care of. Open it, deal with what it asks for, then come back and try again.", institution.displayName),
                destination: nil,
                methods: [],
                canRequestNewCode: false,
                canChooseAnotherMethod: false,
                canGoBack: false,
                trustedDeviceSelected: false,
                errorMessage: nil
            )
            screen = .verification
            return
        }
        #endif

        if startsAutomatically {
            Task { [weak self] in
                await self?.start()
            }
        }
    }

    /// Per-account security flag. Reads the profile-scoped key, falling back
    /// once to the pre-profile global value for an account that already
    /// existed before settings were scoped.
    private static func scopedFlag(
        _ preferences: UserDefaults,
        base: String,
        profileID: UUID,
        inheritingLegacyValue: Bool
    ) -> Bool {
        let key = "\(base).\(profileID.uuidString)"
        if preferences.object(forKey: key) != nil {
            return preferences.bool(forKey: key)
        }
        guard inheritingLegacyValue, preferences.object(forKey: base) != nil else {
            return false
        }
        let inherited = preferences.bool(forKey: base)
        preferences.set(inherited, forKey: key)
        return inherited
    }

    private func scopedSecurityKey(_ base: String) -> String {
        guard let currentProfileID else { return base }
        return "\(base).\(currentProfileID.uuidString)"
    }

    static func securityGuidanceKey(for profileID: UUID) -> String {
        "security-guidance-shown.\(profileID.uuidString)"
    }

    func start() async {
        loginError = nil
        sessionError = nil
        // Safe now: we are past view construction.
        profileStore.touchActiveProfile()

        let generation = authenticationGeneration

        // Restore trusted cookies FIRST, before any web navigation
        await restoreTrustedPortalStateIfNeeded()

        // Give WebKit time to fully integrate the cookies before first request
        try? await Task.sleep(for: .milliseconds(150))

        guard
            generation == authenticationGeneration,
            navigationContext != .clearingSession
        else {
            return
        }

        if let snapshot = scheduleCache.load() {
            courses = snapshot.courses
            calendarEvents = snapshot.events ?? []
            portalUpdates = snapshot.updates ?? []
            userFirstName = snapshot.firstName
            lastScheduleRefresh = snapshot.refreshedAt
            hasCachedScheduleSnapshot = true
            needsPortalContentCacheMigration =
                snapshot.contentVersion != ScheduleSnapshot.currentContentVersion
                || snapshot.events == nil
                || snapshot.updates == nil
                || (snapshot.events?.isEmpty == true && !snapshot.courses.isEmpty)
        }

        // Neither a brand-new account nor a signed-out one has a saved
        // credential behind Face ID, so prompting would scan the user's face
        // only to find nothing to unlock. Send them straight to the form.
        let hasNothingToUnlock = activeProfileIsPlaceholder || activeProfile?.isSignedOut == true

        // A sign-in this app demanded and never got.
        //
        // It outlives the app deliberately. Force-quitting during the
        // countdown is the obvious thing to try, and it must not work: the
        // demand is only ever cleared by a sign-in that OmniVox accepts, so
        // quitting at the password screen lands right back here.
        if hasUnmetSignInDemand, !hasNothingToUnlock {
            presentCredentialFallback(
                message: Loc.text("Please sign in again to continue.")
            )
            return
        }

        if biometricLockEnabled, !hasNothingToUnlock {
            screen = .locked
            shouldUnlockWhenActive = true
            if applicationIsActive {
                await applicationBecameActive()
            }
        } else if hasCachedScheduleSnapshot, !activeProfileIsPlaceholder {
            navigationContext = .authenticated
            screen = .schedule

            // Show TOTP setup prompt for first-time users after successful auth
            if shouldShowTOTPSetupPrompt() {
                showTOTPSetupPrompt = true
            }

            refreshSchedule()
        } else {
            restorePortalSession()
        }
    }

    func unlock() async {
        guard biometricLockEnabled else {
            restorePortalSession()
            return
        }

        let generation = authenticationGeneration
        screen = .locked
        isBusy = true
        sessionError = nil

        let authentication = await BiometricAuthenticator.authenticateSession(
            reason: Loc.text("Unlock your %@ information.", institution.displayName)
        )

        guard
            generation == authenticationGeneration,
            navigationContext != .clearingSession
        else {
            return
        }

        if let authentication {
            biometricCredentials = credentials(
                from: portalCredentialVault.load(using: authentication)
            )
            validatePortalSessionAfterBiometricUnlock()
        } else {
            isBusy = false
            sessionError = Loc.text("Your schedule is still locked. Try again or sign in with your OmniVox password.")
        }
    }

    func usePasswordInstead() {
        clearPortalData(
            disableBiometricLock: false,
            preserveTrustedDevice: true
        )
    }

    /// Throws away *everything* about this session, trusted device included.
    ///
    /// The escape hatch from the one failure that has no other way out. When
    /// sign-in lands on a page the app cannot classify, clearing the session
    /// but keeping the trusted-device cookies puts the next attempt back into
    /// exactly the state that failed — which is a loop, and until now the only
    /// way out of it was to delete the app and install it again. This is that,
    /// without losing the app.
    ///
    /// It costs one more two-factor challenge. That is the correct price for
    /// getting out of a dead end.
    func startAgainFromScratch() {
        clearPortalData(
            disableBiometricLock: false,
            preserveTrustedDevice: false
        )
    }

    /// Runs the whole sign-in again, keeping everything.
    ///
    /// The way back from the screen that says the college is waiting on
    /// something. The student goes and settles it on the college's own site,
    /// comes back, and presses this: Face ID, and straight on with their day.
    ///
    /// Nothing is thrown away — not the saved password, not this device's
    /// trusted status — because nothing on this end was ever wrong. Clearing
    /// the session here would charge them a fresh two-factor code for a page
    /// the college put in front of them, and if the thing still is not settled
    /// they would pay it again on the next try. So the attempt simply repeats,
    /// and lands back on this screen if the college is still waiting.
    func tryPortalSignInAgain() {
        unrecognizedPageAddress = nil
        verificationState = .loading
        verificationNotice = nil
        isBusy = true

        if biometricLockEnabled {
            requestBiometricReauthentication()
        } else {
            restorePortalSession()
        }
    }

    /// The last page sign-in could not make sense of.
    ///
    /// Recorded rather than discarded so the failure can be diagnosed from
    /// what actually happened instead of from a guess. Shown on the dead-end
    /// screen itself, because the person who can read it out is the person
    /// looking at it.
    /// Running on what was already on the device, and why.
    ///
    /// Nil is the ordinary case: signed in, live, everything available.
    @Published private(set) var limitation: SessionLimitation?

    /// Whether a copy of this student's information may be kept on the device.
    ///
    /// What it buys is the whole of the fast unlock and everything that works
    /// without a connection — those are one thing, because they are one
    /// mechanism: a saved copy, and a face scan standing in front of it.
    ///
    /// Tied to the biometric lock rather than offered beside it. Without a
    /// scan there is nothing guarding the copy, and keeping it then would be
    /// leaving a student's timetable on the device for anyone who picks it up.
    @Published private(set) var fastUnlockEnabled: Bool = false

    /// True only when the saved copy may actually be used.
    var keepsInformationOnDevice: Bool {
        biometricLockEnabled && fastUnlockEnabled
    }

    /// True while the app is already up on saved information and the portal is
    /// being checked quietly behind it.
    ///
    /// This is what makes a face scan feel instant. The scan is the check; the
    /// college agreeing is a formality that should happen behind the schedule
    /// rather than in front of a spinner. Everything that would normally seize
    /// the screen — the login form, a two-factor step, a page the app cannot
    /// read — is turned into a countdown instead while this is set.
    private var isRestoringQuietly = false
    private var forcedSignInTask: Task<Void, Never>?
    private var quietRestoreWatchdog: Task<Void, Never>?

    private static let reauthenticationDeadlineKey = "security.reauthentication-deadline"
    private static let fastUnlockPreferenceKey = "security.fast-unlock-enabled"

    @Published private(set) var unrecognizedPageAddress: String?

    /// Turns the saved copy on or off.
    ///
    /// Turning it off throws the copy away there and then. Leaving it behind
    /// would mean the student had asked for it not to be kept and it was kept
    /// anyway, which is the one outcome this switch must never produce.
    func setFastUnlockEnabled(_ enabled: Bool) {
        fastUnlockEnabled = enabled
        preferences.set(enabled, forKey: scopedSecurityKey(Self.fastUnlockPreferenceKey))
        guard !enabled else { return }
        scheduleCache.clear()
        hasCachedScheduleSnapshot = false
        limitation = nil
        endQuietRestore()
    }

    // MARK: - Running on saved information

    /// A sign-in this app demanded and never got.
    ///
    /// Stored rather than held in memory because the countdown has to survive
    /// the app being killed. Quitting during it is the obvious way to try to
    /// dodge it, and it must not work.
    private var hasUnmetSignInDemand: Bool {
        preferences.object(forKey: scopedSecurityKey(Self.reauthenticationDeadlineKey)) != nil
    }

    private var storedSignInDeadline: Date? {
        guard let raw = preferences.object(
            forKey: scopedSecurityKey(Self.reauthenticationDeadlineKey)
        ) as? Double else { return nil }
        return Date(timeIntervalSinceReferenceDate: raw)
    }

    private func clearSignInDemand() {
        forcedSignInTask?.cancel()
        forcedSignInTask = nil
        preferences.removeObject(forKey: scopedSecurityKey(Self.reauthenticationDeadlineKey))
    }

    /// The portal will not take the saved session. Start the clock.
    ///
    /// The student keeps what is already on the device for a minute — enough
    /// to finish reading whatever they opened the app for — and then the app
    /// takes them to a real sign-in. Nothing is thrown away here: the password
    /// and the trusted device are still theirs, it is the *session* that has
    /// stopped being accepted.
    private func demandSignIn(_ reason: String) {
        print("🔐 Sign-in demanded: \(reason)")
        endQuietRestore()
        if case .mustSignInAgain = limitation { return }

        // A stored deadline is reused so that quitting and reopening does not
        // hand out a fresh minute — but only while it is still in the future.
        // A stale one from an earlier run would otherwise expire instantly.
        let stored = storedSignInDeadline
        let deadline = (stored != nil && stored! > Date())
            ? stored!
            : Date().addingTimeInterval(SessionLimitation.graceSeconds)
        preferences.set(
            deadline.timeIntervalSinceReferenceDate,
            forKey: scopedSecurityKey(Self.reauthenticationDeadlineKey)
        )
        limitation = .mustSignInAgain(deadline: deadline)

        navigationContext = .authenticated
        isBusy = false
        isRefreshingSchedule = false
        screen = .schedule

        forcedSignInTask?.cancel()
        forcedSignInTask = Task { [weak self] in
            let seconds = deadline.timeIntervalSinceNow
            if seconds > 0 {
                try? await Task.sleep(for: .seconds(seconds))
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.takeStudentToSignIn() }
        }
    }

    /// The clock ran out. The demand itself is deliberately **not** cleared —
    /// it is cleared when a sign-in actually succeeds, so killing the app at
    /// the password screen does not put the student back on a face scan.
    private func takeStudentToSignIn() {
        forcedSignInTask?.cancel()
        forcedSignInTask = nil
        limitation = nil
        endQuietRestore()
        clearPortalData(disableBiometricLock: false, preserveTrustedDevice: true)
    }

    /// Lets a student go now rather than waiting out the rest of the minute.
    func signInNow() {
        takeStudentToSignIn()
    }

    /// The college could not be reached. Nobody is signed out over that.
    private func fallBackToSavedInformation() {
        guard keepsInformationOnDevice, limitation == nil else { return }
        endQuietRestore()
        navigationContext = .authenticated
        isBusy = false
        isRefreshingSchedule = false
        limitation = .offline
    }

    /// Catches anything that would have taken the screen while the app is up
    /// on saved information, and turns it into the countdown instead.
    ///
    /// Returns true when it handled it and the caller should stop.
    private func interceptQuietInterruption(_ reason: String) -> Bool {
        guard isRestoringQuietly else { return false }
        demandSignIn(reason)
        return true
    }

    /// Stops the quiet restore, however it ended.
    ///
    /// Always through here, so the flag cannot be left armed — a stray page
    /// arriving minutes later would otherwise be read as the session being
    /// refused and start a countdown over a session that is perfectly fine.
    /// Starts a restore that happens behind a screen the student is using.
    private func beginQuietRestore() {
        isRestoringQuietly = true
        quietRestoreWatchdog?.cancel()
        quietRestoreWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.isRestoringQuietly else { return }
                print("🔐 Quiet restore never resolved; leaving saved information alone.")
                self.endQuietRestore()
                self.navigationContext = .authenticated
                self.isBusy = false
                self.isRefreshingSchedule = false
            }
        }
    }

    private func endQuietRestore() {
        isRestoringQuietly = false
        quietRestoreWatchdog?.cancel()
        quietRestoreWatchdog = nil
    }

    func signIn(studentID: String, password: String) {
        let normalizedID = Self.normalizedStudentID(studentID)
        guard normalizedID.count == 7 else {
            loginError = Loc.text("Enter your 7-digit student ID.")
            return
        }
        guard !password.isEmpty else {
            loginError = Loc.text("Enter your OmniVox password.")
            return
        }

        // Answered before the duplicate check and before any navigation: the
        // demo pair is not an account, so there is nothing to merge with and
        // nothing to authenticate against.
        if DemoAccount.matches(studentID: normalizedID, password: password) {
            loginError = nil
            isBusy = false
            loginStudentID = normalizedID
            preferences.set(normalizedID, forKey: Self.studentIDPreferenceKey)
            configureDemoSchedule(
                studentID: DemoAccount.studentID,
                displayName: DemoAccount.displayName
            )
            return
        }

        // Catch a duplicate before authenticating rather than after: the
        // account that already exists owns the authenticator and the trusted
        // device, and a second copy could never inherit either.
        if let existing = profileStore.existingProfile(
            institutionID: institution.id,
            studentID: normalizedID,
            excluding: currentProfileID
        ) {
            profileStore.mergeIntoExisting(
                placeholder: activeProfileIsPlaceholder ? currentProfileID : nil,
                existing: existing,
                message: Loc.text("%@ is already on this device, so there’s no need to add it again. Switched to it.", existing.accountLabel)
            )
            return
        }

        loginStudentID = normalizedID
        preferences.set(normalizedID, forKey: Self.studentIDPreferenceKey)
        credentialsAwaitingBiometricEnrollment = nil
        biometricCredentials = nil
        beginFreshSignIn(
            Credentials(studentID: normalizedID, password: password),
            context: .manualSignIn
        )
    }

    /// True while this session is a freshly created "Add Account" entry that has
    /// never signed in.
    var activeProfileIsPlaceholder: Bool {
        activeProfile?.isBound == false
    }

    /// Whether the add-account flow can be backed out of. Only when there is
    /// another account to fall back to — otherwise cancelling would leave the
    /// device with nothing to show.
    var canCancelAccountSetup: Bool {
        profileStore.isAddingAccount
            && activeProfileIsPlaceholder
            && profileStore.profiles.count > 1
    }

    /// Abandons an add-account attempt and returns to the previous account.
    func cancelAccountSetup() async {
        guard canCancelAccountSetup, let placeholder = activeProfile else { return }

        endSession()
        await ProfileEraser.erase(placeholder)
        profileStore.forgetProfile(placeholder.id)
        profileStore.endAddingAccount()

        if let next = profileStore.profiles.max(by: { $0.lastUsedAt < $1.lastUsedAt }) {
            profileStore.switchTo(next.id)
        }
    }

    /// Hands the widget the minimum it needs to draw a Home Screen tile.
    ///
    /// Only what is displayed crosses into the shared container — titles,
    /// times, rooms. No credentials, no cookies, no authenticator secret: a
    /// widget extension is a separate process, and nothing goes there that it
    /// does not draw.
    ///
    /// Widgets follow whichever account used the app last, because a Home
    /// Screen has no way to ask which student is looking.
    func publishScheduleToWidgets() {
        // Only today and the days after it: a widget never looks backwards, and
        // a whole term of history would bloat the shared file for nothing.
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let upcoming = courses
            .filter { $0.end >= startOfToday }
            .sorted { $0.start < $1.start }
            .prefix(40)
            .map {
                SharedCourse(
                    title: $0.title,
                    courseLabel: $0.courseLabel,
                    location: $0.location,
                    start: $0.start,
                    end: $0.end
                )
            }

        let snapshot = SharedSchedule(
            accountLabel: activeProfile?.accountLabel ?? "",
            schoolName: institution.displayName,
            accentID: Personalization.shared.accent.rawValue,
            updatedAt: Date(),
            courses: Array(upcoming)
        )
        snapshot.write()
        WidgetRefresh.reload()
    }

    /// Mirror the freshly scraped agenda into the phone's Calendar app.
    ///
    /// Runs after every successful refresh, which is what makes a subscription
    /// worth having: a new Léa assignment appears in the student's calendar
    /// because they signed in, not because they remembered to come back here
    /// and press something.
    ///
    /// Silent by design. It reports nothing on success, and on failure it stays
    /// quiet too — a calendar that could not be written is not a reason to
    /// interrupt someone checking their timetable. The sync screen is where the
    /// state is shown, and where a failure is surfaced with an explanation.
    func syncSubscribedCalendarIfNeeded() {
        guard
            calendarSubscription.isSubscribed,
            CalendarSyncService.isAuthorized,
            let profileID = currentProfileID
        else {
            return
        }

        let events = calendarEvents
        let institution = institution
        let subscription = calendarSubscription

        Task {
            _ = try? await CalendarSyncService.sync(
                events: events,
                institution: institution,
                profileID: profileID,
                subscription: subscription
            )
        }
    }

    /// Stops work that must not outlive this profile's session.
    ///
    /// Switching accounts tears the model down while an automatic sign-in may
    /// still be in flight. Left running, it would keep driving a WebView nobody
    /// is looking at and could still decide to discard that profile's
    /// authenticator on the way out.
    func endSession() {
        autoTOTPTask?.cancel()
        autoTOTPTask = nil
        autoTOTPInProgress = false
        autoTOTPStep = nil
        authenticationGeneration = UUID()
        webView.stopLoading()
    }

    private func beginFreshSignIn(
        _ credentials: Credentials,
        context: NavigationContext
    ) {
        loginError = nil
        sessionError = nil
        securitySetupError = nil
        verificationState = .loading
        verificationNotice = nil
        verificationIsBusy = false
        autoTOTPTask?.cancel()
        autoTOTPTask = nil
        autoTOTPInProgress = false
        autoTOTPStep = nil
        autoTOTPError = nil
        pendingCredentials = credentials
        submittedCredentials = nil
        submissionState = .ready
        navigationContext = context
        authenticatedNavigationHandled = context == .biometricReauthentication
        isBusy = true
        // Not while the app is already up on saved information — replacing
        // the schedule with a spinner is the very thing the quiet path exists
        // to avoid.
        if context == .biometricReauthentication, !isRestoringQuietly {
            screen = .launching
        }

        authenticationGeneration = UUID()
        let generation = authenticationGeneration
        guard
            generation == authenticationGeneration,
            navigationContext == context
        else {
            return
        }
        load(institution.loginURL)
    }

    func completeSecuritySetup(requireBiometricLock: Bool) async {
        let generation = authenticationGeneration
        securitySetupError = nil

        if requireBiometricLock {
            guard biometricCapability.isAvailable else {
                securitySetupError = Loc.text("Device authentication is not available.")
                return
            }

            securitySetupIsBusy = true
            let enabled = await setBiometricLockEnabled(true)
            guard
                generation == authenticationGeneration,
                navigationContext != .clearingSession
            else {
                return
            }
            securitySetupIsBusy = false
            guard enabled else {
                if securitySetupError == nil {
                    securitySetupError = Loc.text("Authentication was not completed. Try again or turn this option off.")
                }
                return
            }
        } else {
            _ = await setBiometricLockEnabled(false)
        }

        guard
            generation == authenticationGeneration,
            navigationContext != .clearingSession
        else {
            return
        }

        preferences.set(true, forKey: scopedSecurityKey(Self.securitySetupKey))
        credentialsAwaitingBiometricEnrollment = nil
        screen = .schedule

        // Show TOTP setup prompt for first-time users after security setup
        if shouldShowTOTPSetupPrompt() {
            showTOTPSetupPrompt = true
        }
    }

    func proceedToSecuritySetup() {
        screen = .securitySetup
    }

    /// Setup TOTP authenticator for current student
    func setupTOTP() async throws -> TOTPSecret {
        guard let profileID = currentProfileID else {
            throw TOTPError.notConfigured
        }

        let normalizedID = Self.normalizedStudentID(loginStudentID)
        guard normalizedID.count == 7 else {
            throw TOTPError.notConfigured
        }

        let automation = TOTPSetupAutomation(
            webView: webView,
            institution: institution,
            studentID: normalizedID
        )

        let secretString = try await automation.execute()

        let secret = TOTPSecret(
            profileID: profileID,
            secret: secretString,
            enrolledAt: Date()
        )

        // Save to keychain
        let vault = TOTPVault(profileID: profileID)
        vault.save(secret)

        return secret
    }

    /// Get TOTP code for auto-fill if configured
    func getTOTPCodeIfAvailable() -> String? {
        guard let profileID = currentProfileID else { return nil }
        let vault = TOTPVault(profileID: profileID)
        guard let secret = vault.load() else { return nil }

        guard let generator = try? TOTPGenerator(secret: secret.secret) else {
            return nil
        }
        return generator.generateCode()
    }

    /// Check if TOTP is configured for current profile
    func hasTOTPSecret() -> Bool {
        guard let profileID = currentProfileID else { return false }
        let vault = TOTPVault(profileID: profileID)
        return vault.exists()
    }

    /// Get TOTP secret for current profile
    func getTOTPSecret() -> TOTPSecret? {
        guard let profileID = currentProfileID else { return nil }
        let vault = TOTPVault(profileID: profileID)
        return vault.load()
    }

    /// Check if we should show TOTP setup prompt
    func shouldShowTOTPSetupPrompt() -> Bool {
        guard let profileID = currentProfileID else { return false }
        let vault = TOTPVault(profileID: profileID)

        // Don't show if already configured
        if vault.exists() {
            return false
        }

        // Check if we already showed the prompt for this profile
        let key = "totp.prompt-shown.\(profileID.uuidString)"
        if preferences.bool(forKey: key) {
            return false
        }

        return true
    }

    /// Mark TOTP prompt as shown for current profile
    func markTOTPPromptShown() {
        guard let profileID = currentProfileID else { return }
        let key = "totp.prompt-shown.\(profileID.uuidString)"
        preferences.set(true, forKey: key)
    }

    func setBiometricLockEnabled(_ enabled: Bool) async -> Bool {
        securitySetupError = nil
        if !enabled {
            portalCredentialVault.clear()
            biometricCredentials = nil
            credentialsAwaitingBiometricEnrollment = nil
            biometricLockEnabled = false
            preferences.set(false, forKey: scopedSecurityKey(Self.biometricPreferenceKey))
            return true
        }

        guard biometricCapability.isAvailable else { return false }
        let generation = authenticationGeneration

        print("🔐 Requesting biometric authentication...")
        let authentication = await BiometricAuthenticator.authenticateSession(
            reason: Loc.text("Confirm that you want to protect your %@ information.", institution.displayName)
        )

        print("🔐 Authentication result: \(authentication != nil ? "success" : "failed/canceled")")
        print("🔐 Credentials awaiting enrollment: \(credentialsAwaitingBiometricEnrollment != nil)")

        guard
            let authentication,
            generation == authenticationGeneration,
            navigationContext != .clearingSession
        else {
            print("🔐 Authentication guard failed")
            return false
        }

        if let credential = credentialsAwaitingBiometricEnrollment {
            print("🔐 Saving credentials to vault...")
            guard portalCredentialVault.save(portalCredential(from: credential), using: authentication) else {
                print("🔐 Failed to save credentials")
                securitySetupError = Loc.text("Could not save credentials securely.")
                return false
            }
            print("🔐 Credentials saved successfully")
        } else if portalCredentialVault.load(using: authentication) == nil {
            print("🔐 No credentials found in vault and none awaiting enrollment")
            securitySetupError = Loc.text("Sign in with your OmniVox password once before enabling Face ID.")
            return false
        }

        biometricLockEnabled = true
        preferences.set(true, forKey: scopedSecurityKey(Self.biometricPreferenceKey))
        print("🔐 Biometric lock enabled successfully")
        return true
    }

    /// True once this session's own portal read has settled.
    ///
    /// Léa is served from a second web view sharing this session's cookies, and
    /// the two both navigate the portal to get started. Beginning a Léa read
    /// while the schedule is still being extracted is two navigations sharing
    /// one session rather than two independent fetches, so the preload waits
    /// for this. Demo sessions never reach the portal at all.
    /// Whether the portal web view is free for Léa and MIO to take a turn.
    ///
    /// The quiet restore counts as busy. Showing the schedule immediately made
    /// this true while the restore was still navigating, so Léa and MIO began
    /// driving the same signed-in session at the same moment — which is the
    /// exact collision the staggering below exists to avoid, and they were
    /// reaching the portal before it had agreed we were signed in at all.
    ///
    /// Going false and then true again is also what *starts* them: the moment
    /// the restore finishes, both load.
    var portalIsIdle: Bool {
        screen == .schedule
            && !isRefreshingSchedule
            && !isDemoMode
            && !isRestoringQuietly
            && limitation == nil
    }

    func refreshSchedule() {
        // Demo mode has no portal session; refreshing would navigate to the
        // real sign-in page and replace the fixture data being shown.
        if isDemoMode { return }
        guard !isRefreshingSchedule, navigationContext != .clearingSession else { return }

        // Pulling a list down is not a request to sign in again.
        //
        // If the session has lapsed, the old path answered a refresh with a
        // face scan, a locked screen and a full sign-in — so a student who
        // pulled to refresh was scanned, made to wait, and handed back to the
        // lock. Behind a screen they are already using, a refresh is exactly
        // the quiet case: retry silently if there is a password in hand, and
        // otherwise say plainly that a sign-in is due.
        if keepsInformationOnDevice, screen == .schedule, hasCachedScheduleSnapshot, limitation == nil {
            beginQuietRestore()
        }

        navigationContext = .restoringSession
        isRefreshingSchedule = true
        load(institution.portalURL)
    }

    /// Re-fetches everything in the app's current language.
    ///
    /// The cached schedule and agenda are in whatever language they were
    /// scraped in, so switching the app's language leaves French chrome around
    /// English course titles until the portal is read again. Nothing else is
    /// needed to make that happen: the request built by `load(_:)` carries the
    /// language, so asking for the portal again is the whole mechanism.
    ///
    /// Only while signed in. On the sign-in screen there is no session to
    /// re-read, and navigating the WebView there would interrupt someone
    /// halfway through typing a password.
    func reloadPortalForLanguageChange() {
        // Same reason as `refreshSchedule`: there is no portal behind the demo,
        // and the fixtures are already drawn in the new language by the views.
        if isDemoMode { return }
        guard screen == .schedule else { return }
        refreshSchedule()
    }

    private func refreshPortalContentAfterCacheMigrationIfNeeded() {
        guard needsPortalContentCacheMigration else { return }
        refreshSchedule()
    }

    func signOut() {
        preferences.removeObject(forKey: scopedSecurityKey(Self.securitySetupKey))
        clearPortalData(disableBiometricLock: true)
    }

    func submitVerificationCode(_ value: String) {
        guard screen == .verification,
              verificationState.mode == .code,
              !verificationIsBusy else { return }
        let code = Self.normalizedVerificationCode(value)
        guard code.count == 6 else {
            verificationState.errorMessage = Loc.text("Enter the 6-digit security code.")
            return
        }

        performVerificationAction(
            PortalVerificationScript.submit(institution.conventions),
            arguments: ["code": code]
        )
    }

    func requestNewVerificationCode() {
        let script = #"""
        const button = Array.from(document.querySelectorAll('button')).find(element =>
            /request a new code|new code|demander.*code|nouveau code/i.test(element.innerText || '')
        );
        if (!button) return false;
        button.click();
        return true;
        """#
        performVerificationAction(script, successNotice: Loc.text("A new security code was requested."))
    }

    func showVerificationMethods() {
        let script = #"""
        const link = document.querySelector('a[href*="' + methodsFragment + '"]');
        if (!link) return false;
        link.click();
        return true;
        """#
        performVerificationAction(
            script,
            arguments: ["methodsFragment": institution.conventions.mfaMethodsPathFragment]
        )
    }

    func chooseVerificationMethod(_ method: VerificationMethodOption) {
        // Prefer the portal's own identifier: the card order changes whenever a
        // method is added or removed, but the href does not.
        let script = #"""
        const cards = Array.from(document.querySelectorAll(cardSelector));
        const card = (methodReference
            ? cards.find(candidate => (candidate.getAttribute('href') || '').includes(methodReference))
            : null) || cards[methodIndex];
        if (!card) return false;
        card.click();
        return true;
        """#
        performVerificationAction(
            script,
            arguments: [
                "methodIndex": method.id,
                "methodReference": method.reference ?? "",
                "cardSelector": institution.conventions.methodCardSelector
            ]
        )
    }

    func returnToVerificationCode() {
        // Never fall back to the first validate-method anchor: on the methods
        // page those are the method cards, and clicking one sends a real code.
        let script = #"""
        const link = Array.from(
            document.querySelectorAll('a[href*="' + validateFragment + '"]')
        ).find(anchor => !anchor.matches(cardSelector));
        if (!link) return false;
        link.click();
        return true;
        """#
        performVerificationAction(
            script,
            arguments: [
                "validateFragment": institution.conventions.mfaValidateMethodPathFragment,
                "cardSelector": institution.conventions.methodCardSelector
            ],
            failureMessage: Loc.text("There is no step to go back to. Choose a verification method above.")
        )
    }

    // MARK: - Automatic authenticator sign-in

    /// A generated code is only ever submitted to a page we can prove belongs to
    /// the authenticator app. Anything else — an OmniVox Mobile push page, an
    /// emailed code, a page that says nothing about itself — is left alone, and
    /// a failed attempt never destroys the enrolled secret.
    func performAutoTOTPLogin() async {
        guard !autoTOTPInProgress else {
            print("🤖 AUTO TOTP: Ignoring duplicate start — an attempt is already running")
            return
        }
        guard hasTOTPSecret() else {
            print("🤖 AUTO TOTP: No saved authenticator for this profile")
            return
        }

        print("🤖 AUTO TOTP: Starting automatic authenticator sign-in")
        let generation = authenticationGeneration
        autoTOTPInProgress = true
        autoTOTPStep = Loc.text("Checking your authenticator…")
        autoTOTPError = nil

        let outcome = await runAutoTOTPLogin(generation: generation)

        // Clear the spinner unconditionally: if the sign-in was superseded while
        // we were working, the user must still get the screen back.
        autoTOTPInProgress = false
        autoTOTPStep = nil
        guard generation == authenticationGeneration else { return }

        switch outcome {
        case .succeeded:
            autoTOTPError = nil
            print("🤖 AUTO TOTP: ✅ Signed in with the saved authenticator")
        case .cancelled:
            autoTOTPError = nil
            print("🤖 AUTO TOTP: Attempt cancelled")
        case .failed(let reason):
            autoTOTPError = reason
            print("🤖 AUTO TOTP: ❌ \(reason)")
        }
    }

    /// Abandons the running attempt and hands the verification screen back to
    /// the user, so a stalled portal can never trap them behind a spinner.
    func cancelAutoTOTPLogin() {
        guard autoTOTPInProgress else { return }
        autoTOTPTask?.cancel()
        autoTOTPTask = nil
        autoTOTPInProgress = false
        autoTOTPStep = nil
        autoTOTPError = nil
    }

    private enum AutoTOTPOutcome {
        case succeeded
        case cancelled
        case failed(String)
    }

    /// Computed rather than stored so it is resolved in whatever language is
    /// in effect when it is shown, not whichever one happened to be active the
    /// first time this type was touched.
    private static var wrongPageMessage: String {
        Loc.text("This verification step isn’t for your authenticator app. Enter the code you received, or pick the authenticator app below.")
    }

    private func runAutoTOTPLogin(generation: UUID) async -> AutoTOTPOutcome {
        var reachedAuthenticator = codePageIsAuthenticator
        if reachedAuthenticator {
            print("🤖 AUTO TOTP: Already on the authenticator code page")
        } else {
            switch await openAuthenticatorCodePage(generation: generation) {
            case .succeeded:
                reachedAuthenticator = true
            case .cancelled:
                return .cancelled
            case .failed(let reason):
                return .failed(reason)
            }
        }

        guard generation == authenticationGeneration, !Task.isCancelled else { return .cancelled }
        guard reachedAuthenticator, screen == .verification, verificationState.mode == .code else {
            return .failed(Self.wrongPageMessage)
        }

        // Remember which validate-method page the authenticator lives behind so
        // the next sign-in can recognize it without walking the methods list.
        if let reference = verificationState.methodReference {
            rememberedAuthenticatorReference = reference
        }

        return await submitAutoTOTPCode(generation: generation)
    }

    /// Walks the portal from wherever we are to the authenticator's code page,
    /// identifying the method by its card rather than by guesswork.
    private func openAuthenticatorCodePage(generation: UUID) async -> AutoTOTPOutcome {
        if verificationState.mode == .code {
            guard verificationState.canChooseAnotherMethod else {
                return .failed(Self.wrongPageMessage)
            }
            print("🤖 AUTO TOTP: Code page is not identifiable as the authenticator — opening the methods list")
            autoTOTPStep = Loc.text("Opening your verification methods…")
            guard await waitForVerification(generation: generation, timeout: .seconds(10), until: { [self] in
                !verificationIsBusy
            }) else { return .cancelled }

            showVerificationMethods()
            _ = await waitForVerification(generation: generation, timeout: .seconds(12), until: { [self] in
                (verificationState.mode == .methods && !verificationState.methods.isEmpty)
                    || (verificationState.errorMessage?.isEmpty == false && !verificationIsBusy)
            })
            guard generation == authenticationGeneration, !Task.isCancelled else { return .cancelled }
            guard verificationState.mode == .methods, !verificationState.methods.isEmpty else {
                return .failed(Loc.text("Your verification methods could not be opened. Enter the code manually."))
            }
        }

        guard verificationState.mode == .methods, !verificationState.methods.isEmpty else {
            return .failed(Self.wrongPageMessage)
        }

        for method in verificationState.methods {
            print("🤖 AUTO TOTP: Method — \(method.title) (\(method.kind.rawValue))")
        }

        guard let authenticator = verificationState.methods.first(where: { $0.kind == .authenticator }) else {
            // The account itself lists no authenticator app, so the stored
            // secret is provably stale. This is the only evidence strong enough
            // to justify discarding it.
            forgetStoredAuthenticator(reason: "the account no longer lists an authenticator app")
            return .failed(Loc.text("Your OmniVox account no longer has an authenticator app. Choose another verification method below."))
        }

        rememberedAuthenticatorReference = authenticator.reference
        autoTOTPStep = Loc.text("Selecting your authenticator app…")
        guard await waitForVerification(generation: generation, timeout: .seconds(10), until: { [self] in
            !verificationIsBusy
        }) else { return .cancelled }

        chooseVerificationMethod(authenticator)
        _ = await waitForVerification(generation: generation, timeout: .seconds(12), until: { [self] in
            verificationState.mode == .code
                || (verificationState.errorMessage?.isEmpty == false && !verificationIsBusy)
        })
        guard generation == authenticationGeneration, !Task.isCancelled else { return .cancelled }
        guard verificationState.mode == .code else {
            return .failed(Loc.text("The authenticator step could not be opened. Enter the code manually."))
        }
        return .succeeded
    }

    private func submitAutoTOTPCode(generation: UUID) async -> AutoTOTPOutcome {
        guard let stored = getTOTPSecret() else {
            return .failed(Loc.text("No saved authenticator was found. Enter the code manually."))
        }
        guard let generator = try? TOTPGenerator(secret: stored.secret) else {
            return .failed(Loc.text("The saved authenticator could not be read. Set it up again from the Me tab."))
        }

        autoTOTPStep = Loc.text("Generating your code…")
        guard await waitForVerification(generation: generation, timeout: .seconds(10), until: { [self] in
            !verificationIsBusy
        }) else { return .cancelled }

        // Generate the code as late as possible, and never hand over one that is
        // about to roll over while the portal is still validating it.
        if generator.remainingSeconds() < 4 {
            do { try await Task.sleep(for: .seconds(4)) } catch { return .cancelled }
            guard generation == authenticationGeneration,
                  screen == .verification,
                  verificationState.mode == .code,
                  !verificationIsBusy
            else { return .cancelled }
        }
        let code = generator.generateCode()

        autoTOTPStep = Loc.text("Signing you in…")
        print("🤖 AUTO TOTP: Submitting a generated code")
        submitVerificationCode(code)

        // Success means the portal moved us off the verification screen. A
        // rejected code comes back as an error on a still-idle code page.
        let settled = await waitForVerification(generation: generation, timeout: .seconds(25), until: { [self] in
            screen != .verification
                || (verificationState.errorMessage?.isEmpty == false && !verificationIsBusy)
        })

        guard generation == authenticationGeneration, !Task.isCancelled else { return .cancelled }
        if screen != .verification { return .succeeded }
        guard settled else {
            return .failed(Loc.text("Signing in with your authenticator timed out. Enter the code manually."))
        }
        return .failed(Loc.text("Your authenticator code was rejected — it may be out of sync. Enter the code manually."))
    }

    /// True only when the portal itself identified this code page as the
    /// authenticator app's, or the page matches the method we previously
    /// reached by clicking the authenticator card.
    private var codePageIsAuthenticator: Bool {
        guard verificationState.mode == .code else { return false }
        if verificationState.codeMethodKind == .authenticator { return true }
        if let reference = verificationState.methodReference,
           let remembered = rememberedAuthenticatorReference,
           reference == remembered {
            return true
        }
        return false
    }

    private func shouldStartAutoTOTPLogin(for mode: VerificationState.Mode) -> Bool {
        guard mode == .code || mode == .methods else { return false }
        guard !autoTOTPInProgress else { return false }
        // One attempt per sign-in: the verification page is re-probed every few
        // hundred milliseconds, and each probe used to launch another attempt.
        guard autoTOTPAttemptedGeneration != authenticationGeneration else { return false }
        // A code page we cannot identify and cannot navigate away from is a dead
        // end — submitting a generated code there would just burn an attempt.
        if mode == .code, !codePageIsAuthenticator, !verificationState.canChooseAnotherMethod {
            return false
        }
        return true
    }

    private func startAutoTOTPLoginIfPossible(for mode: VerificationState.Mode) {
        guard hasTOTPSecret() else {
            print("🔐 Not starting auto TOTP — no saved authenticator")
            return
        }
        guard shouldStartAutoTOTPLogin(for: mode) else {
            print("🔐 Not starting auto TOTP — mode: \(mode), already attempted this sign-in or page is unusable")
            return
        }

        autoTOTPAttemptedGeneration = authenticationGeneration
        autoTOTPTask?.cancel()
        autoTOTPTask = Task { [weak self] in
            await self?.performAutoTOTPLogin()
        }
    }

    private func forgetStoredAuthenticator(reason: String) {
        guard let profileID = currentProfileID else { return }
        TOTPVault(profileID: profileID).delete()
        rememberedAuthenticatorReference = nil
        print("🤖 AUTO TOTP: Removed the stored authenticator — \(reason)")
    }

    /// The portal-assigned method id of the authenticator app, learned the first
    /// time we reach it through the methods list.
    private var rememberedAuthenticatorReference: String? {
        get {
            guard let profileID = currentProfileID else { return nil }
            return preferences.string(
                forKey: Self.authenticatorReferenceKeyPrefix + profileID.uuidString
            )
        }
        set {
            guard let profileID = currentProfileID else { return }
            let key = Self.authenticatorReferenceKeyPrefix + profileID.uuidString
            if let newValue, !newValue.isEmpty {
                preferences.set(newValue, forKey: key)
            } else {
                preferences.removeObject(forKey: key)
            }
        }
    }

    /// Polls the verification state until `condition` holds. Returns false if it
    /// times out, the sign-in was superseded, or the attempt was cancelled.
    private func waitForVerification(
        generation: UUID,
        timeout: Duration,
        until condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while true {
            guard generation == authenticationGeneration, !Task.isCancelled else { return false }
            if condition() { return true }
            guard ContinuousClock.now < deadline else { return false }
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return false }
        }
    }

    func applicationDidEnterBackground() {
        applicationIsActive = false
        persistTrustedPortalStateNow()
        guard biometricLockEnabled else { return }

        if screen == .locked, isBusy {
            authenticationGeneration = UUID()
            biometricCredentials = nil
            isBusy = false
            shouldUnlockWhenActive = true
            return
        }

        if screen == .locked {
            shouldUnlockWhenActive = true
            return
        }

        if screen == .launching,
           navigationContext == .biometricSessionValidation
            || navigationContext == .biometricReauthentication
        {
            authenticationGeneration = UUID()
            extractionGeneration = UUID()
            webView.stopLoading()
            navigationContext = .none
            pendingCredentials = nil
            submittedCredentials = nil
            biometricCredentials = nil
            isBusy = false
            isRefreshingSchedule = false
            shouldUnlockWhenActive = true
            screen = .locked
            return
        }

        guard screen == .schedule || screen == .securitySetup else { return }

        screenBeforeLock = screen
        shouldUnlockWhenActive = true
        screen = .locked
    }

    /// The cookie jar this profile's portal session lives in.
    ///
    /// Handed to `LeaService` so its own web view is the same signed-in student
    /// rather than an anonymous second visitor.
    var portalWebsiteDataStore: WKWebsiteDataStore {
        webView.configuration.websiteDataStore
    }

    func applicationBecameActive() async {
        let wasAlreadyActive = applicationIsActive
        applicationIsActive = true
        if shouldUnlockWhenActive, screen == .locked {
            shouldUnlockWhenActive = false
            if shouldReauthenticateWhenActive {
                await reauthenticateExpiredPortalSession()
            } else {
                await unlock()
            }
            return
        }

        if !wasAlreadyActive,
           !biometricLockEnabled,
           screen == .schedule,
           !isRefreshingSchedule
        {
            refreshSchedule()
        }
    }

    static func normalizedStudentID(_ value: String) -> String {
        String(value.filter { "0" ... "9" ~= $0 }.prefix(7))
    }

    static func normalizedVerificationCode(_ value: String) -> String {
        String(value.filter { "0" ... "9" ~= $0 }.prefix(6))
    }

    private func credentials(from credential: PortalCredential?) -> Credentials? {
        guard let credential,
              Self.normalizedStudentID(credential.studentID).count == 7,
              !credential.password.isEmpty
        else {
            return nil
        }
        return Credentials(
            studentID: Self.normalizedStudentID(credential.studentID),
            password: credential.password
        )
    }

    private func portalCredential(from credentials: Credentials) -> PortalCredential {
        PortalCredential(
            studentID: credentials.studentID,
            password: credentials.password
        )
    }

    private func performVerificationAction(
        _ script: String,
        arguments: [String: Any] = [:],
        successNotice: String? = nil,
        failureMessage: String? = nil
    ) {
        guard !verificationIsBusy else { return }
        let generation = authenticationGeneration
        verificationIsBusy = true
        verificationNotice = nil
        verificationState.errorMessage = nil
        // Any fresh verification step supersedes the last automatic attempt's
        // banner, whether the user or the automation triggered it.
        autoTOTPError = nil

        Task { [weak self] in
            guard let self else { return }

            let performed: Bool
            do {
                let value = try await self.webView.callAsyncJavaScript(
                    script,
                    arguments: arguments,
                    in: nil,
                    contentWorld: .page
                )
                performed = (value as? Bool) == true
            } catch {
                performed = false
            }

            guard
                generation == self.authenticationGeneration,
                self.navigationContext != .clearingSession
            else {
                return
            }

            guard performed else {
                self.verificationIsBusy = false
                self.verificationState.errorMessage = failureMessage
                    ?? Loc.text("That verification action is not available. Cancel and try signing in again.")
                return
            }

            self.verificationNotice = successNotice
            try? await Task.sleep(for: .milliseconds(650))
            guard generation == self.authenticationGeneration else { return }
            if self.screen == .verification {
                self.inspectLoadedPage()
            }
            try? await Task.sleep(for: .milliseconds(850))
            guard generation == self.authenticationGeneration else { return }
            if self.screen == .verification {
                self.inspectLoadedPage()
            }
            self.verificationIsBusy = false
        }
    }

    private func restorePortalSession() {
        screen = .launching
        isBusy = true
        navigationContext = .restoringSession
        submissionState = .none
        pendingCredentials = nil
        submittedCredentials = nil
        biometricCredentials = nil
        authenticatedNavigationHandled = false
        verificationState = .loading
        verificationNotice = nil
        load(institution.portalURL)
    }

    private func validatePortalSessionAfterBiometricUnlock() {
        // Straight in, when there is something to go straight in to.
        //
        // The face was the check. Making somebody watch a spinner afterwards
        // while the college gets round to agreeing is charging them twice for
        // the same thing — and the college is slow. The schedule they already
        // have goes up immediately and the portal is checked behind it.
        if keepsInformationOnDevice, hasCachedScheduleSnapshot, !activeProfileIsPlaceholder {
            beginQuietRestore()
            screen = .schedule
            isBusy = false
        } else {
            screen = .launching
            isBusy = true
        }
        navigationContext = .biometricSessionValidation
        submissionState = .none
        pendingCredentials = nil
        submittedCredentials = nil
        authenticatedNavigationHandled = true
        verificationState = .loading
        verificationNotice = nil
        load(institution.portalURL)
    }

    private func requestBiometricReauthentication() {
        guard biometricLockEnabled else {
            presentCredentialFallback()
            return
        }

        navigationContext = .biometricReauthentication
        submissionState = .none
        pendingCredentials = nil
        submittedCredentials = nil
        biometricCredentials = nil
        verificationState = .loading
        verificationNotice = nil
        screen = .locked
        isBusy = true
        isRefreshingSchedule = false
        sessionError = nil
        shouldReauthenticateWhenActive = true

        if applicationIsActive {
            Task { [weak self] in
                await self?.reauthenticateExpiredPortalSession()
            }
        } else {
            shouldUnlockWhenActive = true
        }
    }

    private func reauthenticateExpiredPortalSession() async {
        guard biometricLockEnabled else {
            shouldReauthenticateWhenActive = false
            presentCredentialFallback()
            return
        }

        let generation = authenticationGeneration
        screen = .locked
        isBusy = true
        sessionError = nil

        let authentication = await BiometricAuthenticator.authenticateSession(
            reason: Loc.text("Sign in to %@ again.", institution.displayName)
        )
        guard
            generation == authenticationGeneration,
            navigationContext != .clearingSession
        else {
            return
        }

        guard let authentication else {
            shouldReauthenticateWhenActive = false
            isBusy = false
            sessionError = Loc.text("Sign-in is still locked. Try again or use your OmniVox password.")
            return
        }

        guard let storedCredential = portalCredentialVault.load(using: authentication),
              let credentials = credentials(from: storedCredential)
        else {
            shouldReauthenticateWhenActive = false
            presentCredentialFallback(
                message: Loc.text("Enter your OmniVox password once to finish setting up Face ID sign-in.")
            )
            return
        }

        shouldReauthenticateWhenActive = false
        beginFreshSignIn(credentials, context: .biometricReauthentication)
    }

    private func presentCredentialFallback(message: String? = nil) {
        navigationContext = .none
        submissionState = .none
        pendingCredentials = nil
        submittedCredentials = nil
        biometricCredentials = nil
        shouldReauthenticateWhenActive = false
        shouldUnlockWhenActive = false
        isBusy = false
        isRefreshingSchedule = false
        screen = .login
        loginError = message
    }

    /// Loads a portal page in the app's language.
    ///
    /// Everything the app knows comes out of these pages, so the portal has to
    /// be answering in the same language the app is drawing in — otherwise a
    /// French build shows French chrome wrapped around English course titles.
    ///
    /// Asked for twice, because neither lever is reliable alone: the
    /// `Accept-Language` header is what any server would honour, and the query
    /// parameter is what OmniVox stamps on its own links. A page that ignores
    /// one usually respects the other, and a page that ignores both simply
    /// answers in its default.
    private func load(_ url: URL) {
        // Recorded per request, not read back at parse time: the student can
        // change language while a scrape is already in flight, and the events
        // that come back belong to the language this request asked for.
        lastRequestedPortalLanguage = AppLanguageStore.shared.effectiveLanguageCode

        let localized = institution.conventions.localizedPortalURL(
            url,
            languageCode: AppLanguageStore.shared.portalLanguageCode
        )

        var request = URLRequest(
            url: localized,
            cachePolicy: .reloadRevalidatingCacheData,
            timeoutInterval: 30
        )
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if let header = AppLanguageStore.shared.acceptLanguageHeader {
            request.setValue(header, forHTTPHeaderField: "Accept-Language")
        }
        webView.load(request)
    }

    private func inspectLoadedPage() {
        let generation = authenticationGeneration
        let script = #"""
        (() => {
            // Paths and selectors for this student's school. See PortalConventions.
            const NEO = \#(institution.conventions.javascriptDescriptor);
            const loginForm = document.querySelector(NEO.loginForm);
            const path = window.location.pathname.toLowerCase();
            const heading = document.querySelector('h1')?.innerText?.trim() || document.title || '';
            const normalize = value => (value || '').replace(/\s+/g, ' ').trim();
            const error = normalize(
                document.querySelector('.msg-erreur, .MuiFormHelperText-root, .MuiAlert-message, [role="alert"]')?.innerText
            );

            let kind = 'other';
            var verification = null;
            if (loginForm && document.querySelector(NEO.studentIDField)) {
                kind = 'login';
            } else if (path.startsWith(NEO.mfaPrefix.toLowerCase())) {
                kind = 'verification';

                const trustedPattern = /trusted device|appareil.*confiance|ordinateur.*confiance/i;
                const labels = Array.from(document.querySelectorAll('label'));
                const trustedLabel = labels.find(label =>
                    trustedPattern.test(normalize(label.innerText))
                );
                const nestedTrustedCheckbox = trustedLabel?.querySelector('input[type="checkbox"]');
                const labelledTrustedCheckbox = trustedLabel?.htmlFor
                    ? document.getElementById(trustedLabel.htmlFor)
                    : null;
                const availableCheckboxes = Array.from(
                    document.querySelectorAll('input[type="checkbox"]:not(:disabled)')
                );
                const trustedCheckbox = nestedTrustedCheckbox
                    || (labelledTrustedCheckbox?.matches?.('input[type="checkbox"]')
                        ? labelledTrustedCheckbox
                        : null)
                    || (trustedPattern.test(document.body?.innerText || '')
                        && availableCheckboxes.length === 1
                        ? availableCheckboxes[0]
                        : null);
                const codeInput = document.querySelector(NEO.verificationCodeField);
                if (codeInput) {
                    codeInput.setAttribute('inputmode', 'numeric');
                    codeInput.setAttribute('pattern', '[0-9]*');
                    codeInput.setAttribute('autocomplete', 'one-time-code');
                }

                const bodyText = normalize(document.body?.innerText);
                const destination = normalize(
                    document.querySelector(NEO.verificationDestination)?.innerText
                ) || null;
                const buttons = Array.from(document.querySelectorAll('button'));
                const methodCards = Array.from(document.querySelectorAll(NEO.methodCard));
                const hasResend = buttons.some(button =>
                    /request a new code|new code|demander.*code|nouveau code/i.test(normalize(button.innerText))
                );
                const hasOtherMethods = !!document.querySelector(
                    'a[href*="' + NEO.mfaMethodsFragment + '"]'
                );
                // Every method card is also an anchor to a validate-method page,
                // so a document-wide match would report "back" on every methods
                // page — and clicking it would pick a method instead.
                const backLink = Array.from(
                    document.querySelectorAll('a[href*="' + NEO.mfaValidateFragment + '"]')
                ).find(anchor => !anchor.matches(NEO.methodCard));
                const hasBack = !!backLink;

                // The portal never labels a code page with a machine-readable
                // method, so classify it from its own content only. Text beats
                // icons: a stray icon in the page chrome must not be read as
                // proof that this page belongs to the authenticator app.
                const methodReferencePattern = new RegExp(
                    NEO.mfaValidateFragment.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
                        + '([^/?#]+)',
                    'i'
                );
                const methodReferenceFrom = value => {
                    const match = (value || '').match(methodReferencePattern);
                    return match ? match[1] : null;
                };
                const authenticatorText = /authenticat(?:or|ion)\s+app(?:lication)?|app(?:lication)?\s+d['’]authentification/i;
                const mobileText = /omnivox\s*mobile|mobile app|application omnivox/i;
                const emailText = /email address|courriel|adresse.*mail/i;
                const contentRoot = document.querySelector('main, [role="main"]') || document.body;
                const contentText = normalize(contentRoot?.innerText);
                const contentIcons = Array.from(contentRoot?.querySelectorAll('svg[data-testid]') || [])
                    .map(icon => icon.getAttribute('data-testid') || '').join(' ');
                const kindFromText = authenticatorText.test(contentText) ? 'authenticator'
                    : mobileText.test(contentText) ? 'mobile'
                    : emailText.test(contentText) ? 'email'
                    : null;
                const authenticatorIcon = NEO.authenticatorIcon.toLowerCase();
                const kindFromIcon = contentIcons.toLowerCase().includes(authenticatorIcon) ? 'authenticator'
                    : /SmartphoneIcon/i.test(contentIcons) ? 'mobile'
                    : /EmailIcon/i.test(contentIcons) ? 'email'
                    : null;
                const codeMethodKind = codeInput ? (kindFromText || kindFromIcon || 'other') : 'other';

                let instruction = 'Enter the 6-digit security code you received.';
                if (codeMethodKind === 'email' || emailText.test(bodyText)) {
                    instruction = 'A 6-digit security code was sent to your email address.';
                } else if (codeMethodKind === 'mobile' || mobileText.test(bodyText)) {
                    instruction = 'A 6-digit security code was sent to the OmniVox Mobile app.';
                }
                if (codeMethodKind === 'authenticator') {
                    instruction = 'Enter the 6-digit code from your authenticator app.';
                }

                const methods = methodCards.map((card, index) => {
                    const detail = normalize(card.innerText);
                    const testID = card.querySelector('svg[data-testid]')?.getAttribute('data-testid') || '';
                    const svgTitle = card.querySelector('svg title')?.textContent || '';
                    let methodKind = 'other';
                    let methodTitle = 'Verification method';

                    // Most specific first: an authenticator card carries no
                    // address or phone number to fall back on.
                    if (testID.toLowerCase().includes(authenticatorIcon)
                        || authenticatorText.test(svgTitle)
                        || authenticatorText.test(detail)) {
                        methodKind = 'authenticator';
                        methodTitle = 'Authenticator app';
                    } else if (/smartphone/i.test(testID)) {
                        methodKind = 'mobile';
                        methodTitle = 'OmniVox Mobile';
                    } else if (/email/i.test(testID) || detail.includes('@')) {
                        methodKind = 'email';
                        methodTitle = 'Email';
                    }
                    return {
                        index,
                        kind: methodKind,
                        title: methodTitle,
                        detail,
                        reference: methodReferenceFrom(card.getAttribute('href'))
                    };
                });

                verification = {
                    mode: codeInput ? 'code' : (methods.length ? 'methods' : 'loading'),
                    instruction,
                    destination,
                    canRequestNewCode: hasResend,
                    canChooseAnotherMethod: hasOtherMethods,
                    canGoBack: hasBack,
                    trustedDeviceSelected: trustedCheckbox?.checked === true,
                    methods,
                    codeMethodKind,
                    methodReference: methodReferenceFrom(window.location.pathname)
                };
            } else if (document.querySelector(NEO.dashboardReady)) {
                kind = 'authenticated';
            } else if (path === NEO.dashboardLoadingPath.toLowerCase()) {
                kind = 'dashboard-loading';
            }

            return JSON.stringify({
                kind,
                title: heading.slice(0, 120),
                error: error.slice(0, 240),
                verification
            });
        })();
        """#

        webView.evaluateJavaScript(script) { [weak self] value, _ in
            let payload = value as? String
            Task { @MainActor [weak self] in
                guard let self, generation == self.authenticationGeneration else { return }
                guard let payload, let data = payload.data(using: .utf8) else {
                    self.handleUnknownPage()
                    return
                }

                guard let probe = try? JSONDecoder().decode(PageProbe.self, from: data) else {
                    self.handleUnknownPage()
                    return
                }
                self.handle(probe)
            }
        }
    }

    private func handle(_ probe: PageProbe) {
        switch probe.kind {
        case "login":
            handleLoginPage(errorMessage: probe.error)
        case "verification":
            handleVerificationPage(probe)
        case "authenticated":
            handleAuthenticatedPage()
        case "dashboard-loading":
            waitForAuthenticatedDashboard()
        default:
            handleUnknownPage()
        }
    }

    private func handleVerificationPage(_ probe: PageProbe) {
        // A two-factor step is a manual sign-in by another name.
        if interceptQuietInterruption("two-factor step") { return }

        screen = .verification
        isBusy = false

        guard let details = probe.verification else {
            verificationState = .loading
            waitForVerificationContent()
            return
        }

        let mode: VerificationState.Mode
        switch details.mode {
        case "code": mode = .code
        case "methods": mode = .methods
        case "loading": mode = .loading
        default: mode = .unavailable
        }

        // The page probe runs in JavaScript, where there is no bundle to look a
        // translation up in, so it labels what it found in English. Those labels
        // are catalog keys: translated here, on the way into the view, and
        // falling back to the English the probe wrote if a key is missing.
        let methods = details.methods.map { method in
            VerificationMethodOption(
                id: method.index,
                kind: VerificationMethodOption.Kind(rawValue: method.kind) ?? .other,
                title: Loc.text(method.title),
                detail: method.detail,
                reference: method.reference
            )
        }

        verificationState = VerificationState(
            mode: mode,
            title: (probe.title?.isEmpty == false) ? probe.title! : Loc.text("Verify your identity"),
            instruction: Loc.text(details.instruction),
            destination: details.destination,
            methods: methods,
            canRequestNewCode: details.canRequestNewCode,
            canChooseAnotherMethod: details.canChooseAnotherMethod,
            canGoBack: details.canGoBack,
            trustedDeviceSelected: details.trustedDeviceSelected,
            errorMessage: (probe.error?.isEmpty == false) ? probe.error : nil,
            codeMethodKind: details.codeMethodKind
                .flatMap(VerificationMethodOption.Kind.init(rawValue:)) ?? .other,
            methodReference: details.methodReference
        )

        if mode == .loading {
            waitForVerificationContent()
            return
        }

        verificationProbeAttempt = 0

        print("🔐 Verification mode: \(mode)")
        print("🔐 Verification destination: \(verificationState.destination ?? "none")")
        print("🔐 Code page method: \(verificationState.codeMethodKind.rawValue)")
        print("🔐 Method reference: \(verificationState.methodReference ?? "none")")
        print("🔐 Can choose another method: \(verificationState.canChooseAnotherMethod)")
        print("🔐 Available methods: \(verificationState.methods.map { "\($0.title) (\($0.kind.rawValue))" }.joined(separator: ", "))")

        startAutoTOTPLoginIfPossible(for: mode)
    }

    private func waitForVerificationContent() {
        guard verificationProbeAttempt < 16 else {
            verificationState.mode = .unavailable
            verificationState.instruction = Loc.text("This verification step could not be prepared. Cancel and try signing in again.")
            return
        }

        verificationProbeAttempt += 1
        let expectedURL = webView.url
        let generation = authenticationGeneration
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard
                let self,
                generation == self.authenticationGeneration,
                self.webView.url == expectedURL
            else {
                return
            }
            self.inspectLoadedPage()
        }
    }

    private func waitForAuthenticatedDashboard() {
        guard dashboardProbeAttempt < 12 else {
            // Slow is not refused. Behind a screen the student is already
            // using, a dashboard that never finished loading means this
            // refresh did not happen — nothing more. Say nothing, leave what
            // they have, and let the next refresh try again.
            if isRestoringQuietly {
                endQuietRestore()
                navigationContext = .authenticated
                isBusy = false
                isRefreshingSchedule = false
                return
            }
            handleUnknownPage()
            return
        }

        dashboardProbeAttempt += 1
        let expectedURL = webView.url
        let generation = authenticationGeneration
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard
                let self,
                generation == self.authenticationGeneration,
                self.webView.url == expectedURL
            else {
                return
            }
            self.inspectLoadedPage()
        }
    }

    private func handleLoginPage(errorMessage: String?) {
        // Only once the saved password has actually been **sent** and OmniVox
        // has bounced us back here. `submissionState == .submitted` is what
        // says that.
        //
        // Without that condition this fired the moment the login *form*
        // finished loading — which is a normal, expected step of the silent
        // retry, arriving before the password is submitted. So the retry never
        // ran, and a student with an entirely valid password was told to sign
        // in again while their schedule sat there saying "updated just now".
        if navigationContext == .biometricReauthentication,
           submissionState == .submitted,
           interceptQuietInterruption("saved password was not accepted")
        {
            return
        }

        if navigationContext == .restoringSession {
            if isRestoringQuietly {
                // Behind a screen in use. Try the saved password without
                // asking for anything; if there is none in hand, this is a
                // sign-in the student has to do, on the clock.
                if let credentials = biometricCredentials {
                    biometricCredentials = nil
                    beginFreshSignIn(credentials, context: .biometricReauthentication)
                } else {
                    demandSignIn("the session lapsed and there is no saved password in hand")
                }
                return
            }
            if biometricLockEnabled {
                requestBiometricReauthentication()
            } else {
                presentCredentialFallback()
            }
            return
        }

        if navigationContext == .biometricSessionValidation {
            if let credentials = biometricCredentials {
                biometricCredentials = nil
                beginFreshSignIn(credentials, context: .biometricReauthentication)
            } else {
                presentCredentialFallback(
                    message: Loc.text("Enter your OmniVox password once to finish setting up Face ID sign-in.")
                )
            }
            return
        }

        if navigationContext == .biometricReauthentication,
           submissionState == .none,
           screen == .locked
        {
            return
        }

        switch submissionState {
        case .ready:
            submitPendingCredentials()
        case .submitted:
            let wasBiometricReauthentication = navigationContext == .biometricReauthentication
            if wasBiometricReauthentication {
                portalCredentialVault.clear()
            }
            pendingCredentials = nil
            submittedCredentials = nil
            submissionState = .none
            navigationContext = .none
            screen = .login
            isBusy = false
            if errorMessage?.isEmpty == false {
                loginError = errorMessage
            } else if wasBiometricReauthentication {
                loginError = Loc.text("Your saved OmniVox password was not accepted. Enter your current password to update Face ID sign-in.")
            } else {
                loginError = Loc.text("Sign-in was not accepted. Check your ID and password, then try again.")
            }
        case .none:
            screen = .login
            isBusy = false
        }
    }

    private func handleUnknownPage() {
        if institution.owns(webView.url),
           submissionState == .submitted
            || navigationContext == .restoringSession
            || navigationContext == .biometricSessionValidation
            || (navigationContext == .biometricReauthentication && submissionState != .none)
        {
            // Inside the guard, not above it. Sign-in walks through pages this
            // app does not recognise on its way to ones it does, and the
            // conditions above are what already tell a real dead end from a
            // step along the road. Asking before them turned every one of
            // those steps into a countdown.
            if interceptQuietInterruption("page the app cannot read: \(webView.url?.absoluteString ?? "—")") { return }

            unrecognizedPageAddress = webView.url?.absoluteString
            // Not a broken sign-in step — a college holding sign-in up over
            // something of its own. OmniVox puts these in the middle of the
            // login flow: an ID photo it wants uploaded, a form, an agreement
            // to accept. They are real pages, served correctly, that this app
            // has no business trying to drive. It used to call them unsafe and
            // stop dead, which told the student nothing and left them looping.
            verificationState = VerificationState(
                mode: .schoolActionRequired,
                title: Loc.text("%@ needs something from you", institution.displayName),
                instruction: Loc.text("There is something waiting for you on the official %@ website, and OmniVox will not go any further until it has been taken care of. Open it, deal with what it asks for, then come back and try again.", institution.displayName),
                destination: nil,
                methods: [],
                canRequestNewCode: false,
                canChooseAnotherMethod: false,
                canGoBack: false,
                trustedDeviceSelected: false,
                errorMessage: nil
            )
            screen = .verification
            isBusy = false
            return
        }

        if navigationContext == .clearingSession { return }

        isBusy = false
        if screen == .launching {
            screen = .login
            loginError = Loc.text("The %@ sign-in page could not be recognized. Please try again.", institution.displayName)
        }
    }

    private func submitPendingCredentials() {
        guard let credentials = pendingCredentials else {
            submissionState = .none
            screen = .login
            isBusy = false
            return
        }

        submittedCredentials = credentials
        submissionState = .submitted

        let script = #"""
        const NEO = \#(institution.conventions.javascriptDescriptor);
        const identifier = document.querySelector(NEO.studentIDField);
        const passwordInput = document.querySelector(NEO.passwordField);
        const form = document.querySelector(NEO.loginForm);

        if (!identifier || !passwordInput || !form) {
            return false;
        }

        const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value')?.set;
        if (setter) {
            setter.call(identifier, studentID);
            setter.call(passwordInput, password);
        } else {
            identifier.value = studentID;
            passwordInput.value = password;
        }

        for (const input of [identifier, passwordInput]) {
            input.dispatchEvent(new Event('input', { bubbles: true }));
            input.dispatchEvent(new Event('change', { bubbles: true }));
        }

        const submitButton = form.querySelector('button[type="submit"], input[type="submit"]');
        if (submitButton) {
            submitButton.click();
        } else if (form.requestSubmit) {
            form.requestSubmit();
        } else {
            form.submit();
        }
        return true;
        """#

        Task { [weak self] in
            guard let self else { return }

            let submitted: Bool
            do {
                let value = try await self.webView.callAsyncJavaScript(
                    script,
                    arguments: [
                        "studentID": credentials.studentID,
                        "password": credentials.password
                    ],
                    in: nil,
                    contentWorld: .page
                )
                submitted = (value as? Bool) == true
            } catch {
                submitted = false
            }

            if submitted {
                if self.submissionState == .submitted {
                    self.pendingCredentials = nil
                }
                return
            }
            self.pendingCredentials = nil
            self.submittedCredentials = nil
            self.submissionState = .none
            self.navigationContext = .none
            self.screen = .login
            self.isBusy = false
            self.loginError = Loc.text("The %@ sign-in form changed. Sign-in could not be completed safely.", self.institution.displayName)
        }
    }

    private func handleAuthenticatedPage() {
        // Accepted. Any demand for a sign-in is satisfied by this and only by
        // this — which is what stops a force-quit at the password screen from
        // putting the student back on a face scan.
        let cameInQuietly = isRestoringQuietly
        endQuietRestore()
        limitation = nil
        clearSignInDemand()

        let isBiometricFlow = navigationContext == .biometricSessionValidation
            || navigationContext == .biometricReauthentication
        let authenticatedCredentials = submittedCredentials ?? pendingCredentials

        if let authenticatedCredentials {
            loginStudentID = authenticatedCredentials.studentID
            preferences.set(
                authenticatedCredentials.studentID,
                forKey: Self.studentIDPreferenceKey
            )

            // Bind the current profile to this student ID
            profileStore.bindActiveProfile(
                studentID: authenticatedCredentials.studentID,
                displayName: nil // Will be updated when we scrape the portal
            )
            // A live session clears the "Logged Out" badge in the switcher.
            if let profileID = currentProfileID {
                profileStore.markSignedIn(profileID)
            }
            profileStore.endAddingAccount()

            if biometricLockEnabled {
                if navigationContext != .biometricReauthentication {
                    Task {
                        let saved = await portalCredentialVault.update(portalCredential(from: authenticatedCredentials))
                        if !saved {
                            await MainActor.run {
                                sessionError = Loc.text("Face ID sign-in could not save your updated password.")
                            }
                        }
                    }
                }
            } else {
                credentialsAwaitingBiometricEnrollment = authenticatedCredentials
            }
        }

        if !isBiometricFlow {
            navigationContext = .authenticated
        }
        submissionState = .none
        pendingCredentials = nil
        submittedCredentials = nil
        biometricCredentials = nil
        isBusy = isBiometricFlow && !cameInQuietly
        verificationIsBusy = false
        verificationNotice = nil

        if cameInQuietly {
            // They are already looking at their schedule. Put a spinner over it
            // now and the face scan has bought nothing — which is precisely
            // what this did: straight in, then straight back out to
            // `.launching` the moment the portal answered.
            //
            // The refresh below is unchanged and still runs in full. The cache
            // is what makes the first screen instant; it is not a reason to
            // skip anything.
            authenticatedNavigationHandled = true
            navigationContext = .authenticated
            screen = .schedule
        } else if isBiometricFlow {
            authenticatedNavigationHandled = true
            screen = .launching
        } else if !authenticatedNavigationHandled {
            authenticatedNavigationHandled = true
            let setupComplete = preferences.bool(forKey: scopedSecurityKey(Self.securitySetupKey))
            let guidanceShown = currentProfileID.map {
                preferences.bool(forKey: Self.securityGuidanceKey(for: $0))
            } ?? false

            if setupComplete {
                screen = .schedule

                // Show TOTP setup prompt for first-time users after successful auth
                if shouldShowTOTPSetupPrompt() {
                    showTOTPSetupPrompt = true
                }
            } else if guidanceShown {
                screen = .securitySetup
            } else {
                screen = .securitySetupGuidance
            }
        } else if screen != .securitySetup && screen != .securitySetupGuidance {
            screen = .schedule

            // Show TOTP setup prompt for first-time users after successful auth
            if shouldShowTOTPSetupPrompt() {
                showTOTPSetupPrompt = true
            }
        }

        persistTrustedPortalStateNow()
        scheduleTrustedPortalStatePersistence()
        extractSchedule(attempt: 0)
    }

    private func extractSchedule(attempt: Int) {
        let generation: UUID
        if attempt == 0 {
            extractionGeneration = UUID()
            isRefreshingSchedule = true
            sessionError = nil
        }
        generation = extractionGeneration

        let script = #"""
        (() => {
            const NEO = \#(institution.conventions.javascriptDescriptor);
            const ORIGIN = window.location.origin;
            const root = document.querySelector(NEO.calendarRoot);
            if (!root) {
                return JSON.stringify({ ready: false, records: [], events: [], updates: [] });
            }

            const normalize = value => (value || '').replace(/\s+/g, ' ').trim();
            const profileName = normalize(
                document.querySelector(NEO.profileName)?.textContent
            ) || null;

            // Parsed once per fragment so the text and the links come from the
            // same tree. Reading them separately meant parsing every
            // description twice and having the two drift apart.
            const fragment = value => {
                const container = document.createElement('div');
                container.innerHTML = value || '';
                return container;
            };
            const textOf = node => {
                if (!node) return '';
                const clone = node.cloneNode(true);
                clone.querySelectorAll('br').forEach(element => element.replaceWith(' '));
                clone.querySelectorAll(
                    'svg, [aria-hidden="true"], script, style, template, noscript'
                ).forEach(element => element.remove());
                return normalize(clone.textContent);
            };
            const linksOf = node => {
                const found = [];
                if (!node) return found;
                for (const anchor of node.querySelectorAll('a[href]')) {
                    const href = anchor.getAttribute('href') || '';
                    // In-page anchors go nowhere, and a javascript: href is a
                    // page behaviour rather than a destination.
                    if (!href || href.startsWith('#')) continue;
                    if (/^javascript:/i.test(href.trim())) continue;
                    let absolute;
                    try {
                        absolute = new URL(href, ORIGIN).href;
                    } catch (error) {
                        continue;
                    }
                    found.push({
                        title: normalize(anchor.textContent).slice(0, 200),
                        url: absolute.slice(0, 2000)
                    });
                    if (found.length >= 12) break;
                }
                return found;
            };
            const textFromHTML = value => textOf(fragment(value));

            const records = [];
            const calendarRecords = [];
            const updates = [];
            const seenCourses = new Set();
            const seenEvents = new Set();
            const eventElements = root.querySelectorAll(NEO.event);

            for (const event of eventElements) {
                const modal = event.querySelector(NEO.eventData);
                const day = event.closest(NEO.eventDay);
                const dateRange = day?.dataset?.date || '';
                const dateParts = dateRange.split('|');
                const isoDate = dateParts[0];
                const isoEndDate = dateParts[1] || null;
                const categoryCode = (event.dataset?.cat || 'OTHER').toUpperCase();
                const descriptionElement = event.querySelector(NEO.eventDescription);
                const visibleDescription = descriptionElement?.textContent || '';
                // Both builds of the portal: "10:00 to 11:30" in English,
                // "10 h 00 à 11 h 30" in French. The single-time fallbacks
                // insist on minutes so a room code like "3H.19" is not read as
                // three o'clock.
                const visibleTime = visibleDescription.match(
                    /\d{1,2}:\d{2}\s*(?:à|a|to|–|—|-)\s*\d{1,2}:\d{2}/i
                )?.[0] || visibleDescription.match(
                    /\b\d{1,2}\s*h\s*\d{2}?\s*(?:à|a|to|–|—|-)\s*\d{1,2}\s*h\s*\d{2}?/i
                )?.[0] || visibleDescription.match(/\d{1,2}:\d{2}/)?.[0]
                    || visibleDescription.match(/\b\d{1,2}\s*h\s*\d{2}\b/i)?.[0] || '';
                const titleElement = event.querySelector(NEO.eventTitle);
                const visibleTitle = normalize(titleElement?.textContent);
                const titleNode = fragment(modal?.dataset?.titre || '');
                const title = visibleTitle || textOf(titleNode);
                const timeText = normalize(modal?.dataset?.heure || visibleTime);
                const category = textFromHTML(modal?.dataset?.nomCategorie || '');
                const courseLabel = normalize(
                    event.querySelector(NEO.eventCourseCode)?.textContent
                ) || normalize(
                    event.querySelector(NEO.eventTypeDetail)?.textContent
                ) || category
                    // The portal doubles the category up as "COURS COURSE" in
                    // English and "COURS COURS" in French, so the second word
                    // is dropped by position rather than by spelling.
                    .replace(new RegExp('^' + NEO.classMeetingCode + '\\s+\\S+', 'i'), '')
                    .trim();
                const location = textFromHTML(modal?.dataset?.local || '')
                    || event.querySelector(NEO.eventRoom)?.textContent?.trim()
                    || '';
                const descriptionNode = fragment(modal?.dataset?.description || '');
                const detail = textOf(descriptionNode).slice(0, 1200);

                // A coursework item is itself a link — the portal puts the
                // anchor in the title — so both places are swept.
                const links = [
                    ...linksOf(titleNode),
                    ...linksOf(titleElement),
                    ...linksOf(descriptionNode)
                ].slice(0, 12);

                if (!isoDate || !normalize(title)) continue;

                const calendarRecord = {
                    isoStartDate: isoDate,
                    isoEndDate,
                    categoryCode,
                    title: title.slice(0, 300),
                    timeText: timeText || null,
                    subtitle: normalize(courseLabel || category).slice(0, 400) || null,
                    detail: detail || null,
                    location: normalize(location).slice(0, 300) || null,
                    links,
                    communityTitle: normalize(modal?.dataset?.titreCommunaute || '') || null,
                    communityURL: normalize(modal?.dataset?.urlCommunaute || '') || null
                };
                const eventKey = JSON.stringify(calendarRecord);
                if (!seenEvents.has(eventKey)) {
                    seenEvents.add(eventKey);
                    calendarRecords.push(calendarRecord);
                }

                if (categoryCode === NEO.classMeetingCode && timeText) {
                    const courseRecord = {
                        isoDate,
                        title,
                        timeRange: timeText,
                        courseLabel: normalize(courseLabel) || null,
                        location: normalize(location) || null
                    };
                    const courseKey = JSON.stringify(courseRecord);
                    if (!seenCourses.has(courseKey)) {
                        seenCourses.add(courseKey);
                        records.push(courseRecord);
                    }
                }
            }

            // Only "what's new". The general news feed is the college talking
            // to everyone; it is not this student's portal changing, so it is
            // no longer collected at all.
            for (const card of document.querySelectorAll(NEO.whatsNewCard)) {
                const title = normalize(card.querySelector(NEO.cardTitle)?.textContent);
                const detail = normalize(card.querySelector(NEO.cardDetail)?.textContent);
                if (!title) continue;
                updates.push({
                    kind: 'whatsNew',
                    title: title.slice(0, 300),
                    detail: detail.slice(0, 700) || null
                });
            }

            const hasExplicitEmptyState = !!root.querySelector(NEO.emptyAgenda);
            const ready = eventElements.length > 0 || hasExplicitEmptyState;
            return JSON.stringify({
                ready,
                records,
                events: calendarRecords,
                updates,
                profileName
            });
        })();
        """#

        webView.evaluateJavaScript(script) { [weak self] value, _ in
            let payload = value as? String
            Task { @MainActor [weak self] in
                guard let self, generation == self.extractionGeneration else { return }

                let domPayload: ScheduleDOMPayload?
                if
                    let payload,
                    let data = payload.data(using: .utf8),
                    let decoded = try? JSONDecoder().decode(ScheduleDOMPayload.self, from: data)
                {
                    domPayload = decoded
                } else {
                    domPayload = nil
                }

                if domPayload?.ready != true, attempt < 10 {
                    try? await Task.sleep(for: .milliseconds(600))
                    guard generation == self.extractionGeneration else { return }
                    self.extractSchedule(attempt: attempt + 1)
                    return
                }

                self.isRefreshingSchedule = false

                guard let domPayload, domPayload.ready else {
                    self.reportPortalContentFailure(
                        Loc.text("The schedule is not available yet. Pull to refresh in a moment.")
                    )
                    return
                }

                let parsedCourses = ScheduleParser.parse(
                    domPayload.records,
                    institution: self.institution
                )
                let parsedEvents = PortalContentParser.parseEvents(
                    domPayload.events,
                    institution: self.institution
                )
                let parsedUpdates = PortalContentParser.parseUpdates(domPayload.updates)
                // The greeting wants the first name; the account list wants the
                // whole name, so the profile stores the full version.
                if let fullName = PortalContentParser.parseFullName(domPayload.profileName) {
                    self.profileStore.updateActiveProfileName(fullName)
                    self.userFirstName = PortalContentParser.parseFirstName(fullName)
                }
                if !domPayload.records.isEmpty, parsedCourses.isEmpty {
                    self.reportPortalContentFailure(
                        Loc.text("%@ returned schedule data in an unexpected format.", self.institution.displayName)
                    )
                    return
                }
                if !domPayload.events.isEmpty, parsedEvents.isEmpty {
                    self.reportPortalContentFailure(
                        Loc.text("%@ returned agenda data in an unexpected format.", self.institution.displayName)
                    )
                    return
                }

                let refreshedAt = Date()
                self.courses = parsedCourses
                self.calendarEvents = parsedEvents
                self.portalUpdates = parsedUpdates
                self.lastScheduleRefresh = refreshedAt
                self.hasCachedScheduleSnapshot = true
                self.needsPortalContentCacheMigration = false
                self.scheduleCache.save(
                    ScheduleSnapshot(
                        refreshedAt: refreshedAt,
                        courses: parsedCourses,
                        events: parsedEvents,
                        updates: parsedUpdates,
                        firstName: self.userFirstName
                    )
                )
                self.agendaReadState.reconcile(
                    with: parsedEvents,
                    language: self.lastRequestedPortalLanguage
                )
                self.publishScheduleToWidgets()
                self.syncSubscribedCalendarIfNeeded()

                if self.navigationContext == .biometricSessionValidation
                    || self.navigationContext == .biometricReauthentication
                {
                    self.navigationContext = .authenticated
                    self.isBusy = false
                    self.screen = .schedule
                }
                self.scheduleTrustedPortalStatePersistence()
            }
        }
    }

    private func reportPortalContentFailure(_ message: String) {
        isRefreshingSchedule = false
        if navigationContext == .biometricSessionValidation
            || navigationContext == .biometricReauthentication
        {
            navigationContext = .none
            isBusy = false
            screen = .locked
            sessionError = Loc.text("Couldn’t refresh your live OmniVox information. Try unlocking again.")
        } else {
            sessionError = message
        }
    }

    private func restoreTrustedPortalStateIfNeeded() async {
        guard !restoredTrustedPortalState else { return }
        restoredTrustedPortalState = true

        let savedCookies = portalTrustedStateVault.load()

        #if DEBUG
        print("🔐 Restoring trusted portal state: \(savedCookies.count) cookies")
        for cookie in savedCookies {
            print("  📦 \(cookie.name) = \(cookie.value.prefix(20))... (domain: \(cookie.domain), expires: \(cookie.expiresDate?.description ?? "never"))")
        }
        #endif

        guard !savedCookies.isEmpty else {
            #if DEBUG
            print("⚠️ No saved cookies to restore - will require MFA")
            #endif
            return
        }

        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        let existingCookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            cookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        let existingIdentities = Set(existingCookies.map(cookieIdentity))

        var restoredCount = 0
        for cookie in savedCookies where !existingIdentities.contains(cookieIdentity(cookie)) {
            await withCheckedContinuation { continuation in
                cookieStore.setCookie(cookie) {
                    continuation.resume()
                }
            }
            restoredCount += 1
        }

        #if DEBUG
        print("✅ Restored \(restoredCount) trusted cookies to WebView")
        #endif
    }

    private func scheduleTrustedPortalStatePersistence() {
        guard canPersistTrustedPortalState else { return }

        trustedStatePersistenceGeneration = UUID()
        let persistenceGeneration = trustedStatePersistenceGeneration
        let expectedAuthenticationGeneration = authenticationGeneration
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard
                let self,
                persistenceGeneration == self.trustedStatePersistenceGeneration,
                expectedAuthenticationGeneration == self.authenticationGeneration,
                self.canPersistTrustedPortalState
            else {
                return
            }
            await self.persistTrustedPortalState(
                authenticationGeneration: expectedAuthenticationGeneration
            )
        }
    }

    private func persistTrustedPortalStateNow() {
        guard canPersistTrustedPortalState else { return }

        let expectedAuthenticationGeneration = authenticationGeneration
        Task { [weak self] in
            await self?.persistTrustedPortalState(
                authenticationGeneration: expectedAuthenticationGeneration
            )
        }
    }

    private func persistTrustedPortalState(authenticationGeneration: UUID) async {
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            cookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        guard
            authenticationGeneration == self.authenticationGeneration,
            canPersistTrustedPortalState
        else {
            return
        }

        #if DEBUG
        let durableCookies = cookies.filter(portalTrustedStateVault.isDurablePortalCookie)
        print("💾 Persisting trusted portal state: \(durableCookies.count) of \(cookies.count) cookies")
        for cookie in durableCookies {
            print("  💾 \(cookie.name) (domain: \(cookie.domain))")
        }
        #endif

        portalTrustedStateVault.save(cookies)
    }

    private var canPersistTrustedPortalState: Bool {
        navigationContext == .authenticated
            || (navigationContext == .biometricSessionValidation && authenticatedNavigationHandled)
            || (navigationContext == .biometricReauthentication && authenticatedNavigationHandled)
    }

    private func cookieIdentity(_ cookie: HTTPCookie) -> String {
        [cookie.name, cookie.domain.lowercased(), cookie.path].joined(separator: "\n")
    }

    private func clearPortalData(
        disableBiometricLock: Bool,
        preserveTrustedDevice: Bool = false
    ) {
        let currentStudentID = Self.normalizedStudentID(loginStudentID)
        let savedStudentID = Self.normalizedStudentID(
            preferences.string(forKey: Self.studentIDPreferenceKey) ?? ""
        )
        let retainedStudentID = currentStudentID.count == 7
            ? currentStudentID
            : savedStudentID
        if retainedStudentID.count == 7 {
            preferences.set(retainedStudentID, forKey: Self.studentIDPreferenceKey)
            loginStudentID = retainedStudentID
        }

        authenticationGeneration = UUID()
        let resetGeneration = authenticationGeneration
        trustedStatePersistenceGeneration = UUID()
        shouldUnlockWhenActive = false
        shouldReauthenticateWhenActive = false
        screenBeforeLock = .schedule
        webView.stopLoading()
        navigationContext = .clearingSession
        submissionState = .none
        pendingCredentials = nil
        submittedCredentials = nil
        biometricCredentials = nil
        credentialsAwaitingBiometricEnrollment = nil
        authenticatedNavigationHandled = false
        extractionGeneration = UUID()
        autoTOTPTask?.cancel()
        autoTOTPTask = nil
        autoTOTPInProgress = false
        autoTOTPStep = nil
        autoTOTPError = nil
        scheduleCache.clear()
        hasCachedScheduleSnapshot = false
        needsPortalContentCacheMigration = false
        courses = []
        calendarEvents = []
        portalUpdates = []
        userFirstName = nil
        isBusy = true
        isRefreshingSchedule = false
        sessionError = nil
        loginError = nil
        verificationState = .loading
        verificationNotice = nil
        verificationIsBusy = false
        securitySetupIsBusy = false
        securitySetupError = nil

        if disableBiometricLock {
            portalCredentialVault.clear()
            portalTrustedStateVault.clear()
            biometricLockEnabled = false
            preferences.set(false, forKey: scopedSecurityKey(Self.biometricPreferenceKey))
        }

        webView.load(URLRequest(url: URL(string: "about:blank")!))
        let store = webView.configuration.websiteDataStore
        if preserveTrustedDevice {
            Task { [weak self] in
                guard let self else { return }
                await self.clearPortalSessionData(in: store)
                self.finishPortalReset(
                    retainedStudentID: retainedStudentID,
                    generation: resetGeneration
                )
            }
        } else {
            store.removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                modifiedSince: .distantPast
            ) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.finishPortalReset(
                        retainedStudentID: retainedStudentID,
                        generation: resetGeneration
                    )
                }
            }
        }
    }

    private func clearPortalSessionData(in store: WKWebsiteDataStore) async {
        let cookieStore = store.httpCookieStore
        let cookies = await withCheckedContinuation { continuation in
            cookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }

        for cookie in cookies where cookie.isSessionOnly && institutionOwns(cookie) {
            await withCheckedContinuation { continuation in
                cookieStore.delete(cookie) {
                    continuation.resume()
                }
            }
        }

        await withCheckedContinuation { continuation in
            store.removeData(
                ofTypes: [WKWebsiteDataTypeSessionStorage],
                modifiedSince: .distantPast
            ) {
                continuation.resume()
            }
        }
    }

    private func institutionOwns(_ cookie: HTTPCookie) -> Bool {
        let host = institution.host.lowercased()
        let cookieDomain = cookie.domain
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return host == cookieDomain || host.hasSuffix(".\(cookieDomain)")
    }

    private func finishPortalReset(
        retainedStudentID: String,
        generation: UUID
    ) {
        guard
            authenticationGeneration == generation,
            navigationContext == .clearingSession
        else {
            return
        }
        if retainedStudentID.count == 7 {
            loginStudentID = retainedStudentID
        }
        navigationContext = .none
        isBusy = false
        screen = .login
    }

    // MARK: - Demo fixtures
    //
    // Not `#if DEBUG`: `DemoAccount` reaches these from the sign-in screen in
    // every configuration, which is what makes the demo showable on a phone
    // that has never seen Xcode.

    private func configureDemoVerification() {
        isDemoMode = true
        verificationState = VerificationState(
            mode: .code,
            title: Loc.text("Verify your identity"),
            instruction: Loc.text("A 6-digit security code was sent to your email address."),
            destination: "student••••@example.com",
            methods: [],
            canRequestNewCode: true,
            canChooseAnotherMethod: true,
            canGoBack: false,
            trustedDeviceSelected: true,
            errorMessage: nil
        )
        screen = .verification
    }

    private func configureDemoSchedule(studentID: String, displayName: String) {
        isDemoMode = true
        // Bind only a profile that has never signed in, so switching between
        // demo accounts does not overwrite the one being switched to — and so
        // a real account that is merely signed out is never renamed by a demo.
        if profileStore.activeProfile?.isBound != true {
            profileStore.bindActiveProfile(studentID: studentID, displayName: displayName)
        }
        let now = Date()
        // Agenda fixtures are anchored to the start of a day rather than to
        // this instant. An event's identity includes its timestamp, so
        // `now + 4h` gave every launch a brand-new event and the unread badge
        // could never be cleared — the demo would have disproved a fix that
        // was working.
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let day = { (offset: Int, hour: Double) in
            calendar.date(byAdding: .day, value: offset, to: today)!
                .addingTimeInterval(hour * 60 * 60)
        }
        userFirstName = displayName.split(separator: " ").first.map(String.init) ?? displayName
        // A real week, not two placeholder blocks.
        //
        // Course codes and room numbers are written the way Dawson writes
        // them — `201-NYA-05`, `4H.15` — because that is one of the few
        // details that tells a student the app knows *their* college rather
        // than colleges in general. "ABC-123" in "A-101" is nobody's timetable.
        //
        // Several days carry more than one class, so the day picker has
        // something to show and the "up next" card has something to choose
        // between. Today keeps one class in progress and one later, which is
        // what the hero card is there to say.
        let meeting = { (offset: Int, from: Double, to: Double, title: String, code: String, room: String) in
            CourseMeeting(
                institutionID: self.institution.id,
                title: title,
                courseLabel: code,
                location: room,
                start: day(offset, from),
                end: day(offset, to)
            )
        }
        // Today is measured from the clock rather than pinned to the hour, so
        // the demo opens on a class in progress whenever it is run. Three of
        // them, spaced so they cannot collide: one finished, one running, one
        // to come. Pinning these to real times meant a demo opened at eleven
        // at night showed a single class and an empty afternoon.
        let fromNow = { (hours: Double) in now.addingTimeInterval(hours * 60 * 60) }
        courses = [
            CourseMeeting(
                institutionID: institution.id,
                title: "Introduction to College English",
                courseLabel: "603-101-MQ",
                location: "3C.2",
                start: fromNow(-3),
                end: fromNow(-1.5)
            ),
            CourseMeeting(
                institutionID: institution.id,
                title: "Calculus I",
                courseLabel: "201-NYA-05",
                location: "4H.15",
                start: now.addingTimeInterval(-30 * 60),
                end: now.addingTimeInterval(75 * 60)
            ),
            CourseMeeting(
                institutionID: institution.id,
                title: "Introduction to Psychology",
                courseLabel: "350-102-RE",
                location: "5E.19",
                start: fromNow(2),
                end: fromNow(3.5)
            ),

            meeting(1, 8.5, 10, "Introduction to College English", "603-101-MQ", "3C.2"),
            meeting(1, 10.5, 12, "Calculus I", "201-NYA-05", "4H.15"),
            meeting(1, 13, 14.5, "Introduction to Psychology", "350-102-RE", "5E.19"),

            meeting(2, 10, 11.5, "Calculus I", "201-NYA-05", "4H.15"),
            meeting(2, 13, 14.5, "Introduction to Psychology", "350-102-RE", "2D.7"),

            meeting(3, 8.5, 10, "Introduction to College English", "603-101-MQ", "3C.2"),

            meeting(4, 9, 10.5, "Physical Education: Fitness", "109-101-MQ", "7B.12"),
            meeting(4, 12, 13.5, "Calculus I", "201-NYA-05", "4H.15")
        ]
        calendarEvents = [
            PortalCalendarEvent(
                institutionID: institution.id,
                category: .coursework,
                title: "Chapter review",
                subtitle: "Applied Research",
                detail: "Review the posted material before the next class.",
                location: nil,
                start: day(1, 14),
                end: nil,
                isAllDay: false,
                links: [
                    PortalLink(
                        title: "Chapter review",
                        url: institution.origin.appending(path: "intr/Module/Documents")
                    )
                ]
            ),
            PortalCalendarEvent(
                institutionID: institution.id,
                category: .academic,
                title: "Course-change deadline",
                subtitle: "Academic calendar",
                detail: nil,
                location: nil,
                start: day(1, 0),
                end: nil,
                isAllDay: true
            ),
            PortalCalendarEvent(
                institutionID: institution.id,
                category: .community,
                title: "Student club information session",
                subtitle: "Student community",
                detail: "Meet the club and learn about upcoming activities.",
                location: "2C.1",
                start: day(2, 18),
                end: day(2, 19),
                isAllDay: false,
                links: [
                    PortalLink(
                        title: "Register here",
                        url: URL(string: "https://example.org/clubs")!
                    )
                ],
                community: PortalLink(
                    title: "Students",
                    url: institution.origin.appending(path: "intr/students/")
                )
            )
        ]
        portalUpdates = [
            PortalUpdate(
                kind: .whatsNew,
                title: "3 new course documents",
                detail: "New material is available from your teachers."
            )
        ]
        lastScheduleRefresh = now
        // Through the real reconciler, not a force-mark: the fixtures arrive as
        // news the first time so the tour shows what unread looks like, and
        // then obey "Mark All as Read" like anything else. Force-marking them
        // meant every relaunch undid whatever the student had just cleared.
        agendaReadState.reconcile(
            with: calendarEvents,
            language: AppLanguageStore.shared.effectiveLanguageCode,
            treatingFirstSightAsNew: true
        )
        screen = .schedule
        publishScheduleToWidgets()
    }
}

extension AppModel: WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        scheduleTrustedPortalStatePersistence()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        if let targetFrame = navigationAction.targetFrame, !targetFrame.isMainFrame {
            decisionHandler(.allow)
            return
        }

        if url.scheme == "about" || institution.owns(url) {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        dashboardProbeAttempt = 0
        verificationProbeAttempt = 0
        if navigationContext != .clearingSession,
           !(biometricLockEnabled && screen == .locked)
        {
            isBusy = true
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigationContext != .clearingSession else { return }
        guard !(biometricLockEnabled && screen == .locked) else { return }
        inspectLoadedPage()
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        handleNavigationFailure(error)
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        handleNavigationFailure(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard navigationContext != .clearingSession else { return }
        guard !(biometricLockEnabled && screen == .locked) else { return }
        if navigationContext == .biometricSessionValidation
            || navigationContext == .biometricReauthentication
        {
            navigationContext = .none
            isBusy = false
            isRefreshingSchedule = false
            screen = .locked
            sessionError = Loc.text("Couldn’t verify your OmniVox session. Try unlocking again.")
            return
        }
        if screen == .schedule, hasCachedScheduleSnapshot {
            sessionError = Loc.text("The live connection paused. Your saved information is still available.")
            return
        }
        webView.reload()
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url, institution.owns(url) {
            webView.load(navigationAction.request)
        }
        return nil
    }

    private func handleNavigationFailure(_ error: Error) {
        let code = (error as NSError).code
        guard code != NSURLErrorCancelled, navigationContext != .clearingSession else { return }
        guard !(biometricLockEnabled && screen == .locked) else { return }

        isBusy = false
        isRefreshingSchedule = false

        // The college could not be reached. That is not a reason to sign
        // anybody out, and — while the app is already up on saved information
        // — not a reason to take the screen away either.
        if isRestoringQuietly || (screen == .schedule && hasCachedScheduleSnapshot) {
            fallBackToSavedInformation()
            return
        }

        if navigationContext == .biometricSessionValidation
            || navigationContext == .biometricReauthentication
        {
            navigationContext = .none
            screen = .locked
            shouldUnlockWhenActive = false
            sessionError = Loc.text("Couldn’t verify your OmniVox session. Check your connection and try again.")
        } else if screen == .verification {
            verificationState.errorMessage = Loc.text("The verification service could not connect. Check your connection and try again.")
        } else if screen == .schedule, hasCachedScheduleSnapshot {
            navigationContext = .authenticated
            sessionError = Loc.text("Couldn’t refresh right now. Your saved information is still available.")
        } else {
            screen = .login
            loginError = Loc.text("%@ could not be reached. Check your connection and try again.", institution.displayName)
        }
    }
}

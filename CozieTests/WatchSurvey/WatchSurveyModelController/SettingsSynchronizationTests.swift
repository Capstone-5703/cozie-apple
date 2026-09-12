import Testing
import Foundation
@testable import Cozie

// Issue #104: transport regressions without depending on a paired watch.
import WatchConnectivity

@Suite("Settings synchronization", .serialized)
@MainActor
struct SettingsSynchronizationTests {
    private func surveyData() throws -> Data {
        let survey = try JSONDecoder().decode(WatchSurveyModelController.self, from: TestSurveyData.surveyStub)
        survey.firstQuestionID = survey.survey.first?.questionID
        return try JSONEncoder().encode(survey)
    }

    private func send(_ manager: WatchConnectivityManagerPhone, password: String = "password",
                      completion: ((Error?) -> Void)? = nil) throws {
        manager.sendAll(data: try surveyData(), writeApiURL: "https://example.com", writeApiKey: "key",
                        userID: "participant", expID: "experiment", password: password,
                        userOneSignalID: "provided-player-id", timeInterval: 10,
                        healthCutoffTimeInterval: 3, completion: completion)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test func offlineSettingsAreQueuedAndSentWhenReachable() async throws {
        let transport = SettingsSessionStub()
        let name = "settings-sync-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let manager = WatchConnectivityManagerPhone(session: transport, defaults: defaults, supported: true)
        var results: [Bool] = []
        try send(manager) { results.append($0 == nil) }
        await drainMainQueue()
        #expect(transport.contexts.count == 1)
        #expect(transport.messages.isEmpty)
        #expect(results.isEmpty) // Queued is not the same as confirmed.
        #expect(transport.contexts.first?[CommunicationKeys.userOneSignalIDKey.rawValue] as? String == "provided-player-id")

        transport.isReachable = true
        manager.sessionReachabilityDidChange(WCSession.default)
        await drainMainQueue()
        #expect(transport.messages.count == 1)
        let revision = try #require(transport.messages.first?[CommunicationKeys.settingsRevision.rawValue] as? String)
        transport.reply?([CommunicationKeys.received.rawValue: true,
                          CommunicationKeys.settingsRevision.rawValue: revision])
        await drainMainQueue()
        #expect(results == [true])
        manager.session(WCSession.default, didReceiveApplicationContext: [CommunicationKeys.received.rawValue: true,
                         CommunicationKeys.settingsRevision.rawValue: revision])
        await drainMainQueue()
        #expect(results == [true]) // Duplicate acknowledgement cannot complete twice.
    }

    @Test func activationDoesNotRequireReachability() async throws {
        let transport = SettingsSessionStub()
        transport.activationState = .notActivated
        let name = "settings-sync-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let manager = WatchConnectivityManagerPhone(session: transport, defaults: defaults, supported: true)
        try send(manager)
        await drainMainQueue()
        #expect(transport.contexts.isEmpty)
        transport.activationState = .activated
        manager.session(WCSession.default, activationDidCompleteWith: .activated, error: nil)
        await drainMainQueue()
        #expect(transport.contexts.count == 1)
        #expect(transport.messages.isEmpty)
    }

    @Test func pendingTimeoutReleasesUIButRetainsSnapshotAcrossRestart() async throws {
        let transport = SettingsSessionStub()
        let name = "settings-sync-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let manager = WatchConnectivityManagerPhone(session: transport, defaults: defaults,
                                                    supported: true, acknowledgementTimeout: 0.01)
        defer { withExtendedLifetime(manager) {} }
        let error: Error? = try await withCheckedThrowingContinuation { continuation in
            do { try send(manager) { continuation.resume(returning: $0) } }
            catch { continuation.resume(throwing: error) }
        }
        #expect((error as? WatchConnectivityManagerPhone.WatchConnectivityManagerError) == .pending)
        let restoredTransport = SettingsSessionStub()
        let restored = WatchConnectivityManagerPhone(session: restoredTransport, defaults: defaults, supported: true)
        restored.session(WCSession.default, activationDidCompleteWith: .activated, error: nil)
        await drainMainQueue()
        #expect(restoredTransport.contexts.first?[CommunicationKeys.settingsRevision.rawValue] as? String ==
                transport.contexts.first?[CommunicationKeys.settingsRevision.rawValue] as? String)
    }

    @Test func oldAcknowledgementCannotCompleteNewSettings() async throws {
        let transport = SettingsSessionStub()
        let name = "settings-sync-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let manager = WatchConnectivityManagerPhone(session: transport, defaults: defaults, supported: true)
        try send(manager)
        await drainMainQueue()
        let oldRevision = try #require(transport.contexts.last?[CommunicationKeys.settingsRevision.rawValue] as? String)
        var results: [Bool] = []
        try send(manager) { results.append($0 == nil) }
        await drainMainQueue()
        manager.session(WCSession.default, didReceiveApplicationContext: [CommunicationKeys.received.rawValue: true,
                        CommunicationKeys.settingsRevision.rawValue: oldRevision])
        await drainMainQueue()
        #expect(results.isEmpty)
        let newRevision = try #require(transport.contexts.last?[CommunicationKeys.settingsRevision.rawValue] as? String)
        manager.session(WCSession.default, didReceiveApplicationContext: [CommunicationKeys.received.rawValue: true,
                        CommunicationKeys.settingsRevision.rawValue: newRevision])
        await drainMainQueue()
        #expect(results == [true])
    }

    @Test func invalidSettingsNeverReachTransport() async throws {
        let transport = SettingsSessionStub()
        let name = "settings-sync-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let manager = WatchConnectivityManagerPhone(session: transport, defaults: defaults, supported: true)
        var error: Error?
        try send(manager, password: "") { error = $0 }
        await drainMainQueue()
        #expect((error as? WatchConnectivityManagerPhone.WatchConnectivityManagerError) == .invalidSettings)
        #expect(transport.contexts.isEmpty)
        #expect(transport.messages.isEmpty)
    }

    @Test func immediateFailureKeepsBackgroundDelivery() async throws {
        let transport = SettingsSessionStub()
        transport.isReachable = true
        transport.sendError = NSError(domain: "SettingsSyncTest", code: 1)
        let name = "settings-sync-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let manager = WatchConnectivityManagerPhone(session: transport, defaults: defaults, supported: true)
        var results: [Bool] = []
        try send(manager) { results.append($0 == nil) }
        await drainMainQueue()
        await drainMainQueue()
        #expect(results.isEmpty)
        let revision = try #require(transport.contexts.last?[CommunicationKeys.settingsRevision.rawValue] as? String)
        manager.session(WCSession.default, didReceiveApplicationContext: [CommunicationKeys.received.rawValue: true,
                        CommunicationKeys.settingsRevision.rawValue: revision])
        await drainMainQueue()
        #expect(results == [true])
    }

    @Test func emptySurveyLinkCompletesWithError() {
        let interactor = Cozie.WatchSurveyInteractor(surveyManager: SurveyManager(), storage: EmptySurveyLinkStorage())
        var completed = false
        interactor.loadSelectedWatchSurveyJSON { _, error in
            completed = true
            #expect(error != nil)
        }
        #expect(completed)
    }

    @Test func surveyDatabaseFailureCompletesWithError() async throws {
        let database = DataBaseStorageMock()
        database.updateSurveyError = NSError(domain: "SettingsSyncTest", code: 104)
        let data = try surveyData()
        let error: Error? = await withCheckedContinuation { continuation in
            SurveyManager().update(surveyListData: data, storage: database, selected: true) { _, error in
                continuation.resume(returning: error)
            }
        }
        #expect((error as NSError?)?.code == 104)
    }

    @Test func malformedSurveyIsRejected() async throws {
        let transport = SettingsSessionStub()
        let name = "settings-sync-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let manager = WatchConnectivityManagerPhone(session: transport, defaults: defaults, supported: true)
        try send(manager)
        await drainMainQueue()
        var payload = try #require(transport.contexts.first)
        #expect(SettingsSyncPayload.isValid(payload))
        payload[CommunicationKeys.jsonKey.rawValue] = Data("invalid JSON".utf8)
        #expect(!SettingsSyncPayload.isValid(payload))
    }
}

private final class SettingsSessionStub: WatchSettingsSession {
    weak var delegate: WCSessionDelegate?
    var activationState: WCSessionActivationState = .activated
    var isReachable = false
    var contexts: [[String: Any]] = []
    var messages: [[String: Any]] = []
    var reply: (([String: Any]) -> Void)?
    var sendError: Error?
    func activate() {}
    func updateApplicationContext(_ applicationContext: [String: Any]) throws { contexts.append(applicationContext) }
    func sendMessage(_ message: [String: Any], replyHandler: (([String: Any]) -> Void)?, errorHandler: ((Error) -> Void)?) {
        messages.append(message)
        reply = replyHandler
        if let sendError { errorHandler?(sendError) }
    }
}

private struct EmptySurveyLinkStorage: SurveyStorageProtocol {
    func selectedWSInfoLink() -> String { "" }
    func playerID() -> String { "" }
}

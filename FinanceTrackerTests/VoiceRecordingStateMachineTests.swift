import XCTest
@testable import FinanceTracker

/// Covers `VoiceRecordingStateMachine` — the pure, dependency-free transition rules
/// `VoiceExpenseRecorder` (in `Views/AddTransactionView.swift`) uses to track a recording
/// session's state (permission, recording, stopping, final transcript, timeout, empty). Exercised
/// directly here rather than through `VoiceExpenseRecorder` itself, since that class needs a live
/// microphone/recognizer; the state machine has no such dependency.
final class VoiceRecordingStateMachineTests: XCTestCase {
    // MARK: - isProcessing (drives the Phase 6 "Processing" UI state)

    /// `AddTransactionView`/`HomeView` show a "Processing" state between "Listening" and a
    /// result driven entirely by this — `.stopping` is the only phase where the capture has
    /// ended but Speech (or the bounded timeout) hasn't resolved it to an outcome yet.
    func testOnlyStoppingIsProcessing() {
        XCTAssertTrue(VoiceRecordingPhase.stopping.isProcessing)

        let nonProcessingPhases: [VoiceRecordingPhase] = [
            .idle, .requestingPermission, .recording,
            .finalTranscript("taxi"), .empty, .timedOut("taxi"),
            .permissionDenied("no"), .error("no")
        ]
        for phase in nonProcessingPhases {
            XCTAssertFalse(phase.isProcessing, "\(phase) must not be treated as processing")
        }
    }

    // MARK: - Happy path

    func testRequestPermissionMovesFromIdleToRequestingPermission() {
        let phase = VoiceRecordingStateMachine.transition(from: .idle, on: .requestPermission)
        XCTAssertEqual(phase, .requestingPermission)
    }

    func testRecordingStartedMovesFromRequestingPermissionToRecording() {
        let phase = VoiceRecordingStateMachine.transition(from: .requestingPermission, on: .recordingStarted)
        XCTAssertEqual(phase, .recording)
    }

    func testStopRequestedMovesFromRecordingToStopping() {
        let phase = VoiceRecordingStateMachine.transition(from: .recording, on: .stopRequested)
        XCTAssertEqual(phase, .stopping)
    }

    func testFinalResultWithTextMovesToFinalTranscript() {
        let phase = VoiceRecordingStateMachine.transition(from: .stopping, on: .finalResult("20 euros on taxi"))
        XCTAssertEqual(phase, .finalTranscript("20 euros on taxi"))
    }

    /// A genuine final result can also arrive while still `.recording`, before `stopRecording()`
    /// was ever called (e.g. Speech marks a very short utterance final immediately).
    func testFinalResultAlsoResolvesFromRecording() {
        let phase = VoiceRecordingStateMachine.transition(from: .recording, on: .finalResult("taxi"))
        XCTAssertEqual(phase, .finalTranscript("taxi"))
    }

    // MARK: - Empty final vs. timeout

    func testFinalResultWithNoWordsMovesToEmptyNotFinalTranscript() {
        let phase = VoiceRecordingStateMachine.transition(from: .stopping, on: .finalResult(""))
        XCTAssertEqual(phase, .empty)
    }

    func testTimeoutFiredCarriesWhateverTranscriptExisted() {
        let withText = VoiceRecordingStateMachine.transition(from: .stopping, on: .timeoutFired("taxi"))
        XCTAssertEqual(withText, .timedOut("taxi"))

        let withoutText = VoiceRecordingStateMachine.transition(from: .stopping, on: .timeoutFired(""))
        XCTAssertEqual(withoutText, .timedOut(""))
    }

    /// The bounded fallback is only meaningful once stopping has actually been requested — a
    /// stray timeout event while still `.recording` (shouldn't happen, but the rule must still be
    /// safe) is a no-op.
    func testTimeoutFiredOnlyAppliesWhileStopping() {
        let phase = VoiceRecordingStateMachine.transition(from: .recording, on: .timeoutFired("taxi"))
        XCTAssertEqual(phase, .recording)
    }

    // MARK: - Permission and engine failures

    func testPermissionDeniedOnlyAppliesWhileRequestingPermission() {
        let denied = VoiceRecordingStateMachine.transition(from: .requestingPermission, on: .permissionDenied("Allow Microphone access."))
        XCTAssertEqual(denied, .permissionDenied("Allow Microphone access."))

        let unaffected = VoiceRecordingStateMachine.transition(from: .recording, on: .permissionDenied("Allow Microphone access."))
        XCTAssertEqual(unaffected, .recording, "a stray denial event after recording already started must not overwrite it")
    }

    func testEngineFailedOnlyAppliesWhileRequestingPermission() {
        let failed = VoiceRecordingStateMachine.transition(from: .requestingPermission, on: .engineFailed("Couldn't start the microphone."))
        XCTAssertEqual(failed, .error("Couldn't start the microphone."))
    }

    // MARK: - Never processing two final results

    /// Once a session has genuinely resolved (final transcript, empty, timeout, denial or error),
    /// it must report itself terminal so `VoiceExpenseRecorder` never invokes `onFinalTranscript`
    /// a second time for the same recording.
    func testTerminalPhasesAreExactlyTheResolvedOutcomes() {
        XCTAssertFalse(VoiceRecordingStateMachine.isTerminal(.idle))
        XCTAssertFalse(VoiceRecordingStateMachine.isTerminal(.requestingPermission))
        XCTAssertFalse(VoiceRecordingStateMachine.isTerminal(.recording))
        XCTAssertFalse(VoiceRecordingStateMachine.isTerminal(.stopping))

        XCTAssertTrue(VoiceRecordingStateMachine.isTerminal(.finalTranscript("taxi")))
        XCTAssertTrue(VoiceRecordingStateMachine.isTerminal(.empty))
        XCTAssertTrue(VoiceRecordingStateMachine.isTerminal(.timedOut("taxi")))
        XCTAssertTrue(VoiceRecordingStateMachine.isTerminal(.permissionDenied("denied")))
        XCTAssertTrue(VoiceRecordingStateMachine.isTerminal(.error("failed")))
    }

    /// The exact race `VoiceExpenseRecorder` guards against: a genuine final result resolves the
    /// session first, so the bounded timeout that was already scheduled must not resolve it
    /// again once it fires.
    func testAGenuineFinalResultThenALateTimeoutOnlyResolvesOnce() {
        var phase = VoiceRecordingPhase.recording
        phase = VoiceRecordingStateMachine.transition(from: phase, on: .stopRequested)
        phase = VoiceRecordingStateMachine.transition(from: phase, on: .finalResult("taxi"))
        XCTAssertEqual(phase, .finalTranscript("taxi"))

        // The bounded fallback still fires afterwards — a real caller would check `isTerminal`
        // before ever applying this event, but the transition itself must also be inert.
        let afterLateTimeout = VoiceRecordingStateMachine.transition(from: phase, on: .timeoutFired("taxi"))
        XCTAssertEqual(afterLateTimeout, phase, "a late timeout after a genuine final must never change the resolved phase")
    }

    /// The opposite ordering: the timeout resolves the session first (the real final result never
    /// arrives), so a final result that turns up after must not overwrite it either.
    func testATimeoutThenALateFinalResultOnlyResolvesOnce() {
        var phase = VoiceRecordingPhase.recording
        phase = VoiceRecordingStateMachine.transition(from: phase, on: .stopRequested)
        phase = VoiceRecordingStateMachine.transition(from: phase, on: .timeoutFired("taxi"))
        XCTAssertEqual(phase, .timedOut("taxi"))

        let afterLateFinal = VoiceRecordingStateMachine.transition(from: phase, on: .finalResult("something else"))
        XCTAssertEqual(afterLateFinal, phase, "a late genuine final after a timeout already resolved the session must never change the phase")
    }

    /// A second, distinct final result arriving after the first already resolved the session
    /// (e.g. a stale callback from a session that should have been superseded) must not change
    /// which transcript was resolved.
    func testASecondFinalResultAfterResolutionIsIgnored() {
        var phase = VoiceRecordingPhase.recording
        phase = VoiceRecordingStateMachine.transition(from: phase, on: .finalResult("first"))
        XCTAssertEqual(phase, .finalTranscript("first"))

        let afterSecond = VoiceRecordingStateMachine.transition(from: phase, on: .finalResult("second"))
        XCTAssertEqual(afterSecond, .finalTranscript("first"))
    }

    // MARK: - A fresh session always supersedes a previous terminal one

    /// `VoiceExpenseRecorder.startRecording()` fires `.requestPermission` unconditionally, so a
    /// brand-new press always starts a clean session even if the previous one ended resolved.
    func testRequestPermissionSupersedesAnyPreviousTerminalPhase() {
        for previous: VoiceRecordingPhase in [.finalTranscript("taxi"), .empty, .timedOut(""), .permissionDenied("no"), .error("no")] {
            let phase = VoiceRecordingStateMachine.transition(from: previous, on: .requestPermission)
            XCTAssertEqual(phase, .requestingPermission)
        }
    }
}

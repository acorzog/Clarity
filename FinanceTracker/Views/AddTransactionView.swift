import SwiftUI
import SwiftData
import AVFoundation
import Speech

/// Explicit, observable phase of a single voice-recording session. This is instrumentation for
/// the recording flow's existing behavior, not a behavior change: `VoiceExpenseRecorder` still
/// exposes `isRecording`/`transcript`/`errorMessage` exactly as before, and no host view is
/// required to read `phase`. Its value is computed only by `VoiceRecordingStateMachine.transition`
/// (see below), so every state — including the "did we already resolve this session's final
/// result" question — has one inspectable, independently testable source of truth instead of
/// being inferred from a handful of separate flags.
enum VoiceRecordingPhase: Equatable {
    case idle
    case requestingPermission
    case recording
    case stopping
    /// A genuine `isFinal` Speech result arrived with recognizable words.
    case finalTranscript(String)
    /// A genuine `isFinal` Speech result arrived, but Speech recognized no words.
    case empty
    /// No genuine final result arrived before `stopRecording()`'s bounded fallback fired; carries
    /// whatever transcript existed at that point (itself possibly empty).
    case timedOut(String)
    case permissionDenied(String)
    case error(String)

    /// Whether the capture has definitively ended (the mic was released/tapped to stop) but
    /// Speech — or the bounded timeout fallback — hasn't resolved it to an outcome yet. Both
    /// `AddTransactionView` and `HomeView` drive their "Processing" UI state from this alone, so
    /// the rule that defines "processing" lives in one place and is covered by
    /// `VoiceRecordingStateMachineTests` rather than duplicated per view.
    var isProcessing: Bool {
        self == .stopping
    }
}

/// The events `VoiceExpenseRecorder` reports to `VoiceRecordingStateMachine` at each point its
/// state actually changes — one call site per case, listed on the case itself.
enum VoiceRecordingEvent: Equatable {
    /// `startRecording()`, superseding any previous session unconditionally — mirrors that
    /// method's own unconditional `recognitionSessionID = UUID()`.
    case requestPermission
    /// Speech Recognition or Microphone access was denied.
    case permissionDenied(String)
    /// The audio engine and recognition task started successfully.
    case recordingStarted
    /// The recognizer was unavailable, or the audio engine/session failed to start.
    case engineFailed(String)
    /// `stopRecording()` was called (by the UI, or by the recognition callback itself).
    case stopRequested
    /// A genuine `isFinal` Speech result arrived.
    case finalResult(String)
    /// `stopRecording()`'s bounded fallback fired before a genuine final result arrived.
    case timeoutFired(String)
}

/// Pure, dependency-free transition rules for a voice-recording session — deliberately separate
/// from `VoiceExpenseRecorder`'s AVFoundation/Speech glue so the rules governing permission,
/// recording, stopping, final-transcript, timeout and empty-result handling are unit-testable
/// without a live microphone or recognizer. `VoiceExpenseRecorder` is this type's only caller.
enum VoiceRecordingStateMachine {
    /// Same event from the same phase always produces the same next phase; an event that
    /// doesn't apply to the current phase (e.g. a stray `.finalResult` after the session is
    /// already terminal) leaves it unchanged rather than erroring.
    static func transition(from phase: VoiceRecordingPhase, on event: VoiceRecordingEvent) -> VoiceRecordingPhase {
        switch event {
        case .requestPermission:
            return .requestingPermission
        case .permissionDenied(let message):
            guard phase == .requestingPermission else { return phase }
            return .permissionDenied(message)
        case .recordingStarted:
            guard phase == .requestingPermission else { return phase }
            return .recording
        case .engineFailed(let message):
            guard phase == .requestingPermission else { return phase }
            return .error(message)
        case .stopRequested:
            guard phase == .recording else { return phase }
            return .stopping
        case .finalResult(let text):
            guard phase == .recording || phase == .stopping else { return phase }
            return text.isEmpty ? .empty : .finalTranscript(text)
        case .timeoutFired(let text):
            guard phase == .stopping else { return phase }
            return .timedOut(text)
        }
    }

    /// Whether this session has already resolved to an outcome — a genuine final result (empty
    /// or not), a timeout, a denied permission, or an engine error. `VoiceExpenseRecorder` guards
    /// every delivery of a final transcript on this, which is what guarantees at most one
    /// `onFinalTranscript` call per recording session: once terminal, a later genuine final
    /// arriving after the bounded fallback already fired (or vice versa) is a no-op.
    static func isTerminal(_ phase: VoiceRecordingPhase) -> Bool {
        switch phase {
        case .finalTranscript, .empty, .timedOut, .permissionDenied, .error:
            return true
        case .idle, .requestingPermission, .recording, .stopping:
            return false
        }
    }
}

/// Owns the short-lived system speech-recognition session used by the expense
/// form. Uses Speech's own default recognizer choice (Apple's network-based
/// service where available) rather than forcing on-device recognition, since
/// on-device models trade accuracy for privacy/speed and this phrase-style
/// input benefits more from the more accurate server recognizer. The app
/// itself never sends recordings to its categorization API.
@MainActor
final class VoiceExpenseRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    /// Updates continuously with partial results while recording — meant only for a live
    /// "here's what I'm hearing" display. Never parse/apply this directly; a partial transcript
    /// can be a truncated mid-sentence fragment. Use `onFinalTranscript` instead.
    @Published private(set) var transcript = ""
    @Published private(set) var errorMessage: String?
    /// Normalized (0...1) input volume, refreshed on every audio buffer while recording — drives
    /// the Siri-style breathing/pulse animation on the mic control. Purely presentational; never
    /// read by recognition itself (Speech reads straight from the buffers via `request.append`).
    @Published private(set) var audioLevel: Double = 0
    /// Mirrors this session's progress through `VoiceRecordingStateMachine` — see
    /// `VoiceRecordingPhase`'s doc comment. Purely observational; nothing here reads it to decide
    /// its own behavior except `deliverFinalTranscriptIfNeeded`'s single-delivery guard below.
    @Published private(set) var phase: VoiceRecordingPhase = .idle

    /// Invoked exactly once per recording session, with the recognizer's *final* transcript —
    /// never a partial one. This is the only signal callers should act on to actually parse/
    /// apply a spoken expense. Not called if the session ends without ever producing a final
    /// result (a recognizer error, or a press so brief no audio was captured).
    var onFinalTranscript: ((String) -> Void)?

    private let audioEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: .current)
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionSessionID = UUID()

    private func transition(on event: VoiceRecordingEvent) {
        phase = VoiceRecordingStateMachine.transition(from: phase, on: event)
    }

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    /// Starts a new press-to-record session. Calling this while already
    /// recording is intentionally harmless, which makes it suitable for a
    /// long-press/drag gesture as well as the form's regular button.
    func startRecording() {
        guard !isRecording else { return }
        // A just-finished recognizer can still be delivering its final text.
        // Supersede it cleanly if the person begins another press immediately.
        recognitionSessionID = UUID()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        // Unconditional, same as `recognitionSessionID` above: starting a new session always
        // supersedes whatever phase the previous one ended in, terminal or not.
        transition(on: .requestPermission)
        requestPermissionsAndStart()
    }

    func stopRecording() {
        transition(on: .stopRequested)
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        // Do not cancel here: ending the audio lets Speech deliver its final
        // transcription after a press is released. The callback clears both
        // objects once that result arrives; `deinit` still cancels a session
        // that is being abandoned entirely.
        isRecording = false
        audioLevel = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        // Speech should deliver a result with `isFinal == true` shortly after `endAudio()`, but
        // on-device recognition in particular can occasionally never mark a result final at all
        // (a known Speech framework limitation, not something this code can prevent). Without a
        // fallback, that silently drops the entire recording — transcribed on screen, but never
        // turned into an expense. Guarantee forward progress instead: if no real final result
        // arrives within a couple of seconds, use whatever transcript we have by then.
        let sessionID = recognitionSessionID
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard self.recognitionSessionID == sessionID else { return }
            self.deliverFinalTranscriptIfNeeded(self.transcript, viaTimeout: true)
        }
    }

    /// Invokes `onFinalTranscript` at most once per recording session — called both by the real
    /// final result (immediate, the common case, `viaTimeout: false`) and by `stopRecording()`'s
    /// bounded fallback (only if the real final never arrives, `viaTimeout: true`). Guarded on
    /// `VoiceRecordingStateMachine.isTerminal`, so whichever of the two resolves this session
    /// first wins and the other becomes a no-op — see that function's doc comment. Ignores an
    /// empty transcript when actually invoking the callback so a press that never captured any
    /// recognizable speech doesn't fire it with nothing to act on, but a genuinely empty final
    /// result still marks the session resolved (`.empty` is terminal), exactly like a non-empty
    /// one — there's nothing left to wait for once Speech has concluded, even with no words.
    private func deliverFinalTranscriptIfNeeded(_ text: String, viaTimeout: Bool = false) {
        guard !VoiceRecordingStateMachine.isTerminal(phase) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        transition(on: viaTimeout ? .timeoutFired(trimmed) : .finalResult(trimmed))
        guard !trimmed.isEmpty else { return }
        onFinalTranscript?(text)
    }

    /// Checks both permissions' already-granted status synchronously first — both are instant
    /// local reads, no daemon round-trip — and only falls through to the async `requestAuthorization`
    /// / `requestRecordPermission` APIs when actually needed (typically only the very first
    /// recording ever). Re-requesting an already-granted permission every single press was adding
    /// real, avoidable latency between touch-down and the mic actually listening.
    private func requestPermissionsAndStart() {
        errorMessage = nil
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                guard status == .authorized else {
                    let message = "Allow Speech Recognition to record an expense by voice."
                    Task { @MainActor in
                        self?.errorMessage = message
                        self?.transition(on: .permissionDenied(message))
                    }
                    return
                }
                Task { @MainActor in self?.requestMicrophonePermissionAndStart() }
            }
            return
        }
        requestMicrophonePermissionAndStart()
    }

    private func requestMicrophonePermissionAndStart() {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            beginRecognition()
        case .denied:
            let message = "Allow Microphone access to record an expense by voice."
            errorMessage = message
            transition(on: .permissionDenied(message))
        default:
            AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
                Task { @MainActor in
                    guard granted else {
                        let message = "Allow Microphone access to record an expense by voice."
                        self?.errorMessage = message
                        self?.transition(on: .permissionDenied(message))
                        return
                    }
                    self?.beginRecognition()
                }
            }
        }
    }

    private func beginRecognition() {
        guard recognizer?.isAvailable == true else {
            errorMessage = "Speech recognition is unavailable right now."
            transition(on: .engineFailed(errorMessage!))
            return
        }

        transcript = ""
        audioLevel = 0
        let sessionID = recognitionSessionID
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            // Biases toward a naturally-spoken sentence ("20 euros on taxi") rather than Speech's
            // generic default, which measurably improves recognition for this phrase style.
            request.taskHint = .dictation
            recognitionRequest = request
            let inputNode = audioEngine.inputNode
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputNode.outputFormat(forBus: 0)) { [weak self] buffer, _ in
                request.append(buffer)
                let level = VoiceExpenseRecorder.normalizedLevel(from: buffer)
                Task { @MainActor in
                    guard let self, self.recognitionSessionID == sessionID else { return }
                    self.audioLevel = level
                }
            }
            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
            transition(on: .recordingStarted)
            recognitionTask = recognizer?.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    guard self.recognitionSessionID == sessionID else { return }
                    if let result {
                        self.transcript = result.bestTranscription.formattedString
                        // Only ever hand a *final* transcript to callers — a partial one can be
                        // a truncated mid-sentence fragment (see `onFinalTranscript`'s doc comment).
                        if result.isFinal { self.deliverFinalTranscriptIfNeeded(self.transcript) }
                    }
                    if error != nil || result?.isFinal == true {
                        self.stopRecording()
                        self.recognitionTask = nil
                        self.recognitionRequest = nil
                    }
                }
            }
        } catch {
            errorMessage = "Couldn't start the microphone. Please try again."
            transition(on: .engineFailed(errorMessage!))
            stopRecording()
        }
    }

    // `deinit` is nonisolated even for a `@MainActor` class, so it cannot call
    // `stopRecording()`. End the recognition task directly, and mirror
    // `stopRecording()`'s own cleanup (stop the engine *and* remove its input
    // tap) in case this instance is torn down mid-recording — leaving a tap
    // installed on a deallocating `AVAudioEngine` is a known crash/warning risk.
    deinit {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    /// A rough, presentation-only loudness reading for one audio buffer — root-mean-square
    /// amplitude converted to decibels, then mapped from a typical speaking range (roughly -50dB
    /// silence to -10dB loud/close speech) onto 0...1. Not a calibrated meter; only ever drives
    /// the mic's breathing animation, never anything recognition-related.
    private static func normalizedLevel(from buffer: AVAudioPCMBuffer) -> Double {
        guard let channelData = buffer.floatChannelData?[0] else { return 0 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }
        var sumOfSquares: Float = 0
        for frame in 0..<frameLength {
            let sample = channelData[frame]
            sumOfSquares += sample * sample
        }
        let rms = sqrt(sumOfSquares / Float(frameLength))
        let decibels = 20 * log10(max(rms, 0.000_001))
        let normalized = (decibels + 50) / 40
        return Double(min(max(normalized, 0), 1))
    }
}

struct AddTransactionView: View {
    /// Pass an existing Entry to edit it in place; nil creates a new one.
    var entry: Entry?
    /// Date a new entry defaults to (ignored when editing an existing entry). Lets callers
    /// like the Calendar day sheet pre-fill the day the user tapped instead of today.
    var initialDate: Date = .now
    /// Entry type a new entry defaults to (ignored when editing). Lets callers like the
    /// Wallets screen's transfer shortcut open straight into Transfer mode.
    var initialType: EntryType = .expense
    /// Wallet a new entry defaults to (ignored when editing). Falls back to the user's
    /// default wallet, then the first available one, when nil.
    var initialWallet: Wallet?
    /// Category a new entry defaults to (ignored when editing an existing entry). Lets callers
    /// like Remaining's category drill-down (`CategoryEntriesDetailView`) pre-fill the category
    /// the user was already looking at, instead of falling back to Settings' configured default.
    var initialCategory: Category?
    /// Optional values supplied by another capture surface (for example the
    /// Home screen's press-to-record microphone). They remain fully editable.
    var initialAmount: Decimal? = nil
    var initialNote: String? = nil
    /// Called with the created/edited Entry right before this view dismisses itself — mirrors
    /// `CategoryEditorView.onSave`'s exact precedent. Lets a caller like Goals' Add Money flow
    /// (Phase 2N-C1) capture the resulting Entry to link a `GoalContribution` to it, without this
    /// view needing to know anything about Goals.
    var onSave: ((Entry) -> Void)?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Wallet.name) private var allWallets: [Wallet]
    @Query(sort: \Category.name) private var allCategories: [Category]
    @Query private var allBudgets: [Budget]
    @ObservedObject private var preferences = AppPreferencesStore.shared

    private var wallets: [Wallet] { allWallets.filter { !$0.isArchived } }

    @State private var amountText = ""
    @State private var entryType: EntryType = .expense
    @State private var selectedCategory: Category?
    @State private var selectedWallet: Wallet?
    @State private var destinationWallet: Wallet?
    /// When true for an expense, the amount also moves to `destinationWallet` — e.g. money
    /// spent from a shared wallet that should be accounted as moved into another one, rather
    /// than just leaving the system. Wallet balance math already supports any entry carrying a
    /// `destinationWallet` regardless of type, so this only needs UI + validation, no model change.
    @State private var includesTransferToWallet = false
    @State private var note = ""
    @State private var date = Date.now
    @State private var recurrence: RecurrenceRule = .none
    @State private var excludeFromBudget = false
    @State private var isPlannedExpense = false

    @State private var showingCategoryPicker = false
    @State private var showingSourceWalletPicker = false
    @State private var showingDestinationWalletPicker = false
    @State private var showingDatePicker = false

    @State private var hasLoaded = false
    /// The note text as loaded — auto-categorization only fires once this diverges,
    /// so opening an existing entry for editing doesn't immediately re-suggest/spend an API call.
    @State private var noteAtLoad = ""
    @State private var showingSharedEvent = false
    @StateObject private var voiceRecorder = VoiceExpenseRecorder()
    /// User-facing feedback for a recording that produced *some* transcript but nothing
    /// `VoiceExpenseParser` could turn into an expense — distinct from `voiceRecorder.
    /// errorMessage` (a permission/engine failure). See `handleVoiceButtonTap`.
    @State private var voiceFeedbackMessage: String?
    /// Set inside `applyVoiceExpense` the moment `onFinalTranscript` fires for the current
    /// session (whether parsing succeeded or not) — lets the bounded fallback in
    /// `handleVoiceButtonTap` tell "Speech genuinely produced nothing at all" apart from
    /// "already handled," without adding any signal to `VoiceExpenseRecorder` itself.
    @State private var didHandleFinalTranscript = false
    /// Bumped on every new recording so the fallback in `handleVoiceButtonTap` can tell its own
    /// session apart from a later one — same reasoning as `HomeView.voiceHoldSessionID`.
    @State private var voiceSessionID = UUID()
    /// Bumped synchronously at the very top of every `handleVoiceButtonTap` call, independent of
    /// any async permission/engine work — drives `.sensoryFeedback` below so the tap always gets
    /// an instant haptic acknowledgment, not one delayed until recording actually starts.
    @State private var voiceButtonTapCount = 0
    /// Set once a voice recording saves — no review step, see `handleVoiceFinalTranscript`. Its
    /// presence swaps `voiceExpenseControl` from the mic button to a brief confirmation, then the
    /// whole form dismisses (`dismissAfterVoiceQuickSave`'s guard is the same session-ID pattern
    /// used everywhere else in this file for a bounded, supersede-safe delay).
    @State private var voiceQuickSaveEntries: [Entry]?
    @State private var voiceQuickSaveDismissSessionID = UUID()

    @FocusState private var amountFieldFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                amountField

                if entry == nil && entryType != .transfer {
                    voiceExpenseControl
                }

                Picker("Type", selection: $entryType) {
                    Text("Expense").tag(EntryType.expense)
                    Text("Income").tag(EntryType.income)
                    Text("Transfer").tag(EntryType.transfer)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 12)

                Form {
                    Section {
                        if entryType == .transfer {
                            SelectionRow(
                                title: "From Account",
                                iconName: selectedWallet?.icon,
                                iconColorHex: selectedWallet?.colorHex,
                                valueName: selectedWallet?.name
                            ) {
                                showingSourceWalletPicker = true
                            }
                            SelectionRow(
                                title: "To Account",
                                iconName: destinationWallet?.icon,
                                iconColorHex: destinationWallet?.colorHex,
                                valueName: destinationWallet?.name
                            ) {
                                showingDestinationWalletPicker = true
                            }
                        } else {
                            SelectionRow(
                                title: "Category",
                                iconName: selectedCategory?.customIcon ?? selectedCategory?.headCategory.icon,
                                iconColorHex: selectedCategory?.headCategory.colorHex,
                                valueName: selectedCategory?.name
                            ) {
                                showingCategoryPicker = true
                            }

                            if entryType == .expense {
                                HStack(spacing: 8) {
                                    SelectionRow(
                                        title: includesTransferToWallet ? "From Account" : "Account",
                                        iconName: selectedWallet?.icon,
                                        iconColorHex: selectedWallet?.colorHex,
                                        valueName: selectedWallet?.name
                                    ) {
                                        showingSourceWalletPicker = true
                                    }
                                    transferToggleButton
                                }

                                if includesTransferToWallet {
                                    SelectionRow(
                                        title: "To Account",
                                        iconName: destinationWallet?.icon,
                                        iconColorHex: destinationWallet?.colorHex,
                                        valueName: destinationWallet?.name
                                    ) {
                                        showingDestinationWalletPicker = true
                                    }
                                }
                            } else {
                                SelectionRow(
                                    title: "Account",
                                    iconName: selectedWallet?.icon,
                                    iconColorHex: selectedWallet?.colorHex,
                                    valueName: selectedWallet?.name
                                ) {
                                    showingSourceWalletPicker = true
                                }
                            }
                        }
                    }
                    .listRowBackground(Color.white.opacity(0.05))

                    Section {
                        TextField("Note", text: $note)
                            .foregroundStyle(.white)
                    }
                    .listRowBackground(Color.white.opacity(0.05))

                    Section {
                        dateRow
                    }
                    .listRowBackground(Color.white.opacity(0.05))

                    Section {
                        Picker("Repeat", selection: $recurrence) {
                            Text("None").tag(RecurrenceRule.none)
                            Text("Weekly").tag(RecurrenceRule.weekly)
                            Text("Monthly").tag(RecurrenceRule.monthly)
                            Text("Yearly").tag(RecurrenceRule.yearly)
                        }
                        .tint(.white.opacity(0.7))
                    }
                    .listRowBackground(Color.white.opacity(0.05))

                    Section {
                        Toggle("Exclude from Budget", isOn: $excludeFromBudget)
                            .tint(.emerald)
                    }
                    .listRowBackground(Color.white.opacity(0.05))

                    if entryType == .expense {
                        Section {
                            Toggle("Planned Expense", isOn: $isPlannedExpense)
                                .tint(.emerald)
                        } footer: {
                            Text("A known, already-budgeted expense like rent or a tax bill — it still counts toward your budget, but won't drag down your Clarity Score just for landing all at once.")
                        }
                        .listRowBackground(Color.white.opacity(0.05))
                    }

                    if let event = entry?.sharedSettlement?.event {
                        Section {
                            Button {
                                showingSharedEvent = true
                            } label: {
                                HStack {
                                    Label("From Shared Expense", systemImage: "person.2.fill")
                                        .foregroundStyle(.white)
                                    Spacer()
                                    Text(event.title)
                                        .foregroundStyle(.white.opacity(0.6))
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(.white.opacity(0.3))
                                }
                            }
                        }
                        .listRowBackground(Color.white.opacity(0.05))
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .background(Color.appBackground.ignoresSafeArea())
            .foregroundStyle(.white)
            .navigationTitle(entry == nil ? "New Transaction" : "Edit Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!isValid)
                        .fontWeight(.semibold)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear(perform: loadInitialState)
        .onChange(of: entryType) { _, newValue in
            // Expense/income draw from disjoint category lists, and transfers have none at
            // all. For a new entry (not editing), re-apply that type's default category
            // instead of always going blank.
            selectedCategory = entry == nil ? defaultCategory(for: newValue) : nil
            includesTransferToWallet = false
            if newValue != .transfer {
                destinationWallet = nil
            }
        }
        .sheet(isPresented: $showingCategoryPicker) {
            CategoryPickerView(selection: $selectedCategory, isIncome: entryType == .income)
        }
        .sheet(isPresented: $showingSourceWalletPicker) {
            WalletPickerView(selection: $selectedWallet, excluding: destinationWallet)
        }
        .sheet(isPresented: $showingDestinationWalletPicker) {
            WalletPickerView(selection: $destinationWallet, excluding: selectedWallet)
        }
        .sheet(isPresented: $showingDatePicker) {
            DatePickerSheet(date: $date)
        }
        .sheet(isPresented: $showingSharedEvent) {
            if let event = entry?.sharedSettlement?.event {
                NavigationStack {
                    SharedEventDetailView(event: event)
                }
                .preferredColorScheme(.dark)
            }
        }
        .task(id: note) {
            guard entryType != .transfer else { return }
            guard !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            // Skip the fire-on-appear call when editing: the note hasn't actually changed yet.
            guard note != noteAtLoad else { return }

            // Debounce: restarts (cancelling the previous sleep) every time `note` changes.
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }

            if let suggestion = await CategorizationService.suggestCategory(for: note, isIncome: entryType == .income) {
                selectedCategory = suggestion
            }
        }
        .onAppear {
            // Only the recognizer's final transcript should ever save an expense — see
            // `VoiceExpenseRecorder.onFinalTranscript`'s doc comment. Set here (not `.onChange`)
            // so this never re-runs on every partial transcript update.
            voiceRecorder.onFinalTranscript = handleVoiceFinalTranscript
        }
    }

    /// Whether the button has been tapped to stop and `VoiceExpenseRecorder` is winding the
    /// session down — Speech may still be finishing recognition, or the bounded timeout fallback
    /// may still be pending. Driven entirely by `voiceRecorder.phase` (see `VoiceRecordingPhase`);
    /// nothing here duplicates or reimplements that state.
    private var isProcessingVoice: Bool {
        voiceRecorder.phase.isProcessing
    }

    private var voiceButtonLabelText: String {
        if voiceRecorder.isRecording { return "Listening… tap to finish" }
        if isProcessingVoice { return "Processing…" }
        return "Record by voice"
    }

    private var voiceButtonSystemImage: String {
        if voiceRecorder.isRecording { return "mic.fill" }
        if isProcessingVoice { return "hourglass" }
        return "mic"
    }

    @ViewBuilder
    private var voiceExpenseControl: some View {
        if let savedEntries = voiceQuickSaveEntries {
            voiceQuickSaveConfirmation(for: savedEntries)
        } else {
            voiceExpenseRecordingControl
        }
    }

    /// Shown briefly in place of the mic button/status area once a voice recording has already
    /// saved — the form dismisses shortly after (see `handleVoiceFinalTranscript`), so this is
    /// only ever on screen for about a second, just long enough to confirm what happened.
    private func voiceQuickSaveConfirmation(for entries: [Entry]) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.emerald)
            Text(voiceQuickSaveSummary(for: entries))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 11)
        .background(Color.emerald.opacity(0.13), in: Capsule())
        .padding(.horizontal)
        .padding(.bottom, 12)
        .accessibilityElement(children: .combine)
    }

    private func voiceQuickSaveSummary(for entries: [Entry]) -> String {
        guard entries.count == 1, let only = entries.first else {
            return "Saved \(entries.count) transactions"
        }
        let label = only.note.isEmpty ? (only.category?.name ?? "Uncategorized") : only.note
        return "Saved \(only.amount.currencyFormatted) — \(label)"
    }

    private var voiceExpenseRecordingControl: some View {
        VStack(spacing: 10) {
            Button(action: handleVoiceButtonTap) {
                Label(voiceButtonLabelText, systemImage: voiceButtonSystemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(voiceRecorder.isRecording ? .black : Color.emerald)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(voiceRecorder.isRecording ? Color.emerald : Color.emerald.opacity(0.13), in: Capsule())
                    // The same real-volume breathing effect as Home's floating mic, so both entry
                    // points feel like the same Siri-like listening control.
                    .scaleEffect(voiceRecorder.isRecording ? 1 + voiceRecorder.audioLevel * 0.05 : 1)
                    .animation(.easeOut(duration: 0.09), value: voiceRecorder.audioLevel)
                    .opacity(isProcessingVoice ? 0.7 : 1)
            }
            .buttonStyle(.plain)
            // Disabled (rather than just visually dimmed) while processing: releasing, then
            // immediately tapping again before the session resolves would otherwise start a
            // brand-new recording out from under the one still being resolved.
            .disabled(isProcessingVoice)
            .sensoryFeedback(.impact(weight: .light), trigger: voiceButtonTapCount)
            .accessibilityHint("Say an amount and what it's for, for example 20 euros on taxi, or recibí 1500 euros de nómina")

            if voiceRecorder.isRecording {
                Text(voiceRecorder.transcript.isEmpty ? "Say an amount and what it was for…" : voiceRecorder.transcript)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(voiceRecorder.transcript.isEmpty ? Color.textTertiary : Color.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, ClaritySpacing.md)
                    .animation(.easeOut(duration: 0.12), value: voiceRecorder.transcript)
            } else if isProcessingVoice {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Making sense of what you said…")
                }
                .font(.subheadline)
                .foregroundStyle(Color.textSecondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Processing what you said")
            } else if let message = voiceRecorder.errorMessage ?? voiceFeedbackMessage {
                Label {
                    Text(message)
                } icon: {
                    Image(systemName: "exclamationmark.circle.fill")
                }
                .font(.caption)
                .foregroundStyle(Color.expense)
                .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 12)
    }

    /// Toggles whether this expense also moves its amount into a second wallet — tapping it
    /// on reveals the "To Wallet" row below; tapping it off clears that destination again.
    private var transferToggleButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                includesTransferToWallet.toggle()
                if !includesTransferToWallet {
                    destinationWallet = nil
                }
            }
        } label: {
            Image(systemName: "arrow.left.arrow.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(includesTransferToWallet ? .black : .white.opacity(0.6))
                .frame(width: 26, height: 26)
                .background(
                    includesTransferToWallet ? AnyShapeStyle(Color.emerald) : AnyShapeStyle(Color.white.opacity(0.08)),
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
    }

    private var amountField: some View {
        AmountField(text: $amountText, style: .hero, focus: $amountFieldFocused)
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
            .padding(.bottom, 16)
    }

    private var dateRow: some View {
        HStack {
            Button {
                date = Calendar.current.date(byAdding: .day, value: -1, to: date) ?? date
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.6))

            Spacer()

            Button {
                showingDatePicker = true
            } label: {
                Text(dateLabel)
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                date = Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.6))
        }
    }

    private var dateLabel: String {
        if Calendar.current.isDateInToday(date) {
            return "Today"
        } else if Calendar.current.isDateInYesterday(date) {
            return "Yesterday"
        } else if Calendar.current.isDateInTomorrow(date) {
            return "Tomorrow"
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private var amountValue: Decimal? {
        guard let value = Decimal(decimalInput: amountText), value > 0 else { return nil }
        return value
    }

    private var isValid: Bool {
        guard amountValue != nil, let selectedWallet else { return false }
        switch entryType {
        case .expense:
            guard selectedCategory != nil else { return false }
            guard includesTransferToWallet else { return true }
            guard let destinationWallet else { return false }
            return destinationWallet !== selectedWallet
        case .income:
            return selectedCategory != nil
        case .transfer:
            guard let destinationWallet else { return false }
            return destinationWallet !== selectedWallet
        }
    }

    /// Whether this entry should carry a `destinationWallet` on save — true for a plain
    /// transfer, or an expense with the "also moves to another wallet" toggle on.
    private var savesDestinationWallet: Bool {
        entryType == .transfer || (entryType == .expense && includesTransferToWallet)
    }

    private func loadInitialState() {
        guard !hasLoaded else { return }
        hasLoaded = true

        if let entry {
            // `"\(entry.amount)"` would always use "." regardless of locale, which the
            // amount field's `.onChange` sanitizer then strips because it only recognizes the
            // current locale's decimal separator — silently collapsing e.g. "8.1" into "81"
            // for a locale (like Spanish) that uses "," instead. `editableText()` formats with
            // the locale's actual separator so the sanitizer round-trips it correctly.
            amountText = entry.amount.editableText()
            entryType = entry.type
            selectedCategory = entry.category
            selectedWallet = entry.wallet
            destinationWallet = entry.destinationWallet
            includesTransferToWallet = entry.type == .expense && entry.destinationWallet != nil
            note = entry.note
            noteAtLoad = entry.note
            date = entry.date
            recurrence = entry.recurrence
            excludeFromBudget = entry.excludeFromBudget
            isPlannedExpense = entry.isPlannedExpense
        } else {
            selectedWallet = initialWallet ?? wallets.first(where: \.isDefault) ?? wallets.first
            entryType = initialType
            date = initialDate
            selectedCategory = initialCategory ?? defaultCategory(for: initialType)
            if let initialAmount { amountText = initialAmount.editableText() }
            if let initialNote { note = initialNote }
            amountFieldFocused = true
        }
    }

    /// The category set as the default for `type` in Settings, if it still exists and matches
    /// (a category renamed/archived/deleted since being set as default just falls back to nil,
    /// same as if no default were configured).
    private func defaultCategory(for type: EntryType) -> Category? {
        let name: String?
        switch type {
        case .expense: name = preferences.defaultExpenseCategoryName
        case .income: name = preferences.defaultIncomeCategoryName
        case .transfer: name = nil
        }
        guard let name else { return nil }
        return allCategories.first { $0.name == name && $0.isIncome == (type == .income) && !$0.isArchived }
    }

    /// Starts/stops recording, resetting or bounding the voice-feedback state around each
    /// session so `voiceFeedbackMessage` always reflects the *current* attempt, never a stale
    /// one. Wraps `voiceRecorder.toggleRecording()` rather than passing it directly as the
    /// button action — see the doc comments below for why.
    private func handleVoiceButtonTap() {
        voiceButtonTapCount += 1
        if voiceRecorder.isRecording {
            voiceRecorder.stopRecording()
            // `handleVoiceFinalTranscript` (via `onFinalTranscript`) handles every case where
            // Speech produces *some* transcript, however long that takes. The one thing it can
            // never cover is total silence — `VoiceExpenseRecorder` never calls back at all when
            // the transcript stayed empty. Waiting strictly longer than its own 2-second bounded
            // fallback safely distinguishes "nothing was ever recognized" from "still being
            // handled," without adding any new signal to the recorder itself.
            let sessionID = voiceSessionID
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2.5))
                guard voiceSessionID == sessionID, !didHandleFinalTranscript else { return }
                didHandleFinalTranscript = true
                voiceFeedbackMessage = "I didn't hear anything — try again."
            }
        } else {
            voiceFeedbackMessage = nil
            voiceQuickSaveEntries = nil
            didHandleFinalTranscript = false
            voiceSessionID = UUID()
            voiceRecorder.startRecording()
        }
    }

    /// Only ever called with `VoiceExpenseRecorder`'s *final* transcript (wired via
    /// `onFinalTranscript`, not `.onChange(of: voiceRecorder.transcript)`), so a truncated
    /// mid-sentence partial can never trigger a save from a fragment.
    ///
    /// Saves immediately via `VoiceQuickSave` — no review step — using whichever wallet is
    /// already selected in this form, so a wallet the person picked before switching to voice is
    /// still respected. `entryType`/category are resolved per parsed clause exactly as before
    /// (income verbs like "recibí"/"cobré" set `.income`; a plain phrase defaults to `.expense`),
    /// but a multi-clause phrase now saves *every* clause instead of only ever filling the form
    /// with the first one and silently dropping the rest.
    private func handleVoiceFinalTranscript(_ transcript: String) {
        didHandleFinalTranscript = true
        let expenses = VoiceExpenseParser.parseAll(transcript)
        guard entry == nil, entryType != .transfer, !expenses.isEmpty else {
            voiceFeedbackMessage = "Didn't catch an expense in that — try saying an amount and what it was for, like \"20 euros on taxi.\""
            return
        }
        guard let savedEntries = VoiceQuickSave.save(expenses, wallet: selectedWallet, categories: allCategories, modelContext: modelContext) else {
            voiceFeedbackMessage = "Set up an account in Clarity before saving expenses."
            return
        }
        voiceFeedbackMessage = nil
        for savedEntry in savedEntries { onSave?(savedEntry) }
        voiceQuickSaveEntries = savedEntries

        let sessionID = UUID()
        voiceQuickSaveDismissSessionID = sessionID
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.1))
            guard voiceQuickSaveDismissSessionID == sessionID else { return }
            dismiss()
        }
    }

    private func save() {
        guard let amountValue, let selectedWallet, isValid else { return }

        let savedEntry: Entry
        if let entry {
            entry.amount = amountValue
            entry.date = date
            entry.note = note
            entry.type = entryType
            entry.category = entryType == .transfer ? nil : selectedCategory
            entry.wallet = selectedWallet
            entry.destinationWallet = savesDestinationWallet ? destinationWallet : nil
            entry.recurrence = recurrence
            entry.excludeFromBudget = excludeFromBudget
            let autoPlanned = entryType == .expense
                && allBudgets.matchesFixedPlannedAmount(amountValue, for: selectedCategory, month: date)
            entry.isPlannedExpense = (entryType == .expense && isPlannedExpense) || autoPlanned
            savedEntry = entry
        } else {
            savedEntry = TransactionSaving.createEntry(
                amount: amountValue,
                date: date,
                note: note,
                type: entryType,
                category: selectedCategory,
                wallet: selectedWallet,
                destinationWallet: savesDestinationWallet ? destinationWallet : nil,
                recurrence: recurrence,
                excludeFromBudget: excludeFromBudget,
                isPlannedExpense: entryType == .expense && isPlannedExpense,
                modelContext: modelContext
            )
        }
        // Explicit save rather than relying on SwiftData's lazy autosave: `RootView` calls
        // `modelContext.rollback()` on every foreground transition and every cross-process store
        // change (needed to pick up entries the widget/Siri/a Shortcut write in their own
        // process) — without this, an edit made here could still be sitting unsaved when one of
        // those rollbacks fires (e.g. switching back to the app right after running a Shortcut is
        // itself a foreground transition) and get silently discarded.
        try? modelContext.save()
        onSave?(savedEntry)
        dismiss()
    }
}

#Preview {
    AddTransactionView()
        .modelContainer(for: [HeadCategory.self, Category.self, Wallet.self, Entry.self, Budget.self], inMemory: true)
}

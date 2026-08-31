//
//  ModelRunnerView.swift
//  KataGo Anytime
//
//  Created by Chin-Chang Yang on 2025/5/19.
//

import SwiftUI
import KataGoUICore

/// The app's root. It used to be a two-way switch — model picker OR board —
/// which is why the board could not exist before a model did.
///
/// It no longer switches anything: `ContentView` (and therefore the whole board
/// tree) mounts on the first frame, with no engine, no model and possibly no
/// game. The picker is a SHEET over it, and the engine comes and goes
/// underneath through `AppEngineController`. What is left here is the wiring:
/// the objects whose lifetime must span every engine (session, controller,
/// lifecycle, the top-level UI state), the launch decision, and the one place
/// that turns "the user picked a net" into "launch or relaunch".
struct ModelRunnerView: View {
    /// The net the user has chosen. Nil means *Absent* — a real, displayable
    /// state now, not a screen.
    @State private var selectedModel: NeuralNetworkModel?
    @State private var engineLifecycle = EngineLifecycle()
    @State private var controller = AppEngineController()
    /// Born here, not in `ContentView`: the session outlives every engine, and
    /// `ContentView` is never unmounted any more.
    @State private var session = GameSession()
    @State private var navigationContext = NavigationContext()
    @State private var topUIState = TopUIState()
    @State private var hasDecidedRecovery = false

    var body: some View {
        @Bindable var topUIState = topUIState

        ContentView(session: session,
                    controller: controller,
                    navigationContext: navigationContext,
                    topUIState: topUIState)
        .sheet(isPresented: $topUIState.presentingModelPicker,
               onDismiss: {
                   // A dismissal without a pick drops the sparkle's intent (a
                   // pick consumed it before dismissing, so this is a no-op
                   // on that path).
                   topUIState.analysisArmOnPick = false
               }) {
            ModelPickerView(selectedModel: $selectedModel)
                // The sheet is presented from HERE, above every environment
                // injection `ContentView` makes into the board tree, so the
                // values the picker needs are handed over explicitly:
                // whether an engine is running — which decides whether the
                // Core ML routing probe and Clear Cache run directly or have
                // to unload the engine first — the controller whose
                // `restart(performingWhileStopped:)` is that unload, and the
                // board size the status header's Held hint reads.
                //
                // The live book and the eye come across for the same reason:
                // the Opening Books screen hangs off this picker, and importing,
                // deleting or re-choosing an active book has to reconcile the
                // book the current game is playing from. That screen reads all
                // three NON-optionally now, so dropping one from this chain
                // traps on arrival — the way it once left a stale book loaded
                // until the game was reopened, with only a log line to say so.
                .environment(session.engineStatus)
                .environment(session.board)
                .environment(session.bookLookup)
                .environment(session.gobanState)
                .environment(controller)
        }
        .onAppear {
            configureAndDecideRecovery()
        }
        .onChange(of: selectedModel) { _, newValue in
            guard let newValue else { return }
            // CONSUME the choice. `selectedModel` is a momentary intent, not a
            // record of what is running — `controller.activeModel` is that.
            // Clearing it is what makes choosing the SAME net again register as
            // a change, and "Play on the running model restarts it" (settled
            // design, decision 10) depends on exactly that: the picker is
            // reachable with a live engine now, so re-picking it is the natural
            // way to apply a changed backend or Max Board Size.
            selectedModel = nil
            // The sparkle's remedy tap opened this picker wanting analysis: a
            // pick arms a cleared preference back to run. `.pause`/`.run` are
            // left alone — the preference is the user's, and the existing
            // resync auto-resumes anything that is not `.clear` (ADR 0010).
            if topUIState.analysisArmOnPick {
                topUIState.analysisArmOnPick = false
                if session.gobanState.analysisStatus == .clear {
                    session.gobanState.analysisStatus = .run
                    session.analysis.resetVisitsPerSecondSession()
                }
            }
            // Then dismiss: the picker's job is done, and leaving it up over a
            // board that is already relaunching just hides the status line that
            // explains the wait.
            topUIState.presentingModelPicker = false
            controller.start(model: newValue)
        }
        .onChange(of: engineLifecycle.lastLoadedModelTitle) { _, newValue in
            guard let newValue else { return }
            controller.noteLoadSucceeded(title: newValue)
        }
    }

    /// Wire the controller and run the launch decision, exactly once.
    ///
    /// Guarded against re-appearance (scene lifecycle transitions) so a
    /// backgrounded-and-restored app does not relaunch its engine or re-present
    /// the picker over a board the user is using.
    private func configureAndDecideRecovery() {
        guard !hasDecidedRecovery else { return }
        hasDecidedRecovery = true

        controller.configure(session: session,
                             engineLifecycle: engineLifecycle,
                             navigationContext: navigationContext)

        // The two ways out the engine states offer (reached from the sparkle
        // and the remedy surface's status header, ADR 0010). They live here
        // because this is the only view that owns both the picker's
        // presentation and the controller. Bound to locals so the escaping
        // closure holds the two objects rather than a copy of this struct.
        let topUIState = self.topUIState
        let controller = self.controller
        session.engineStatus.onAction = { action in
            switch action {
            case .chooseModel:
                topUIState.presentingModelPicker = true
            case .retry:
                controller.retry()
            }
        }

        #if DEBUG
        let isDebug = true
        #else
        let isDebug = false
        #endif

        switch RecoveryDecision.decide(
            pendingLoadModelTitle: controller.pendingLoadTitle,
            selectedModelTitle: controller.persistedSelectionTitle,
            // A screenshot run must not stop at the picker, so
            // `--screenshot-seed` makes the launch take the RELEASE path:
            // auto-restore the last-good net (or the built-in one) and boot
            // the engine with no tap. ONLY this call site changes —
            // `RecoveryDecision.decide` stays the pure function
            // `RecoveryDecisionTests` pins.
            isDebug: isDebug && !ScreenshotSeed.isActive,
            builtInTitle: NeuralNetworkModel.builtInModel?.title ?? ""
        ) {
        case .autoRestore(let title):
            guard let model = NeuralNetworkModel.allAvailable.first(where: { $0.title == title })
                    ?? NeuralNetworkModel.builtInModel else {
                controller.presentAbsent()
                return
            }
            // Assigning `selectedModel` drives the launch through the one
            // `onChange` above, so auto-restore and a user tap take the same
            // path — including the missing-file fallback.
            selectedModel = model

        case .presentPicker:
            // The board mounts in Absent and the picker comes up over it.
            // `presentAbsent` also seeds the `.chooseModel` action, which the
            // sparkle's remedy tap performs — so the picker stays reachable
            // from the board if this presentation is ever dropped.
            controller.presentAbsent()
            topUIState.presentingModelPicker = true

        case .failedLastLaunch(let title):
            controller.presentFailedLastLaunch(title: title)
        }
    }
}

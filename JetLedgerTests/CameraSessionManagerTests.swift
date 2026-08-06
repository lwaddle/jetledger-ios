//
//  CameraSessionManagerTests.swift
//  JetLedgerTests
//
//  Covers session ownership: an AVCaptureSession must never resume unless
//  something actually asked for it.
//

import Testing
import Foundation
@testable import JetLedger

@MainActor
@Suite
struct CameraSessionManagerTests {

    /// The bug this guards: backgrounding the app interrupts the session, and
    /// foregrounding fired interruptionEnded, which restarted the camera behind
    /// the receipt list with no UI and nothing to ever stop it. The iOS privacy
    /// indicator then stayed lit for the life of the process.
    @Test
    func interruptionEndedDoesNotResumeASessionNobodyAskedFor() {
        let manager = CameraSessionManager()
        #expect(!manager.isSessionWanted)

        manager.handleInterruptionEnded()

        // `isSessionWanted` is the assertion that can actually fail: a resume
        // runs through `startRunning()`, which sets the flag synchronously.
        // `state` is written from `sessionQueue` via `DispatchQueue.main.async`
        // and so is still `.idle` at this point either way — asserting on it
        // here would pass with the guard removed.
        #expect(!manager.isSessionWanted, "no capture UI exists — nothing should have started")
    }

    /// An interruption with no camera on screen must not leave `.failed` behind
    /// for the next capture flow to read.
    @Test
    func anInterruptionWithNoCaptureUIDoesNotPoisonTheState() {
        let manager = CameraSessionManager()

        manager.handleInterruption()

        #expect(manager.state == .idle)
    }

    /// The flag is what the handlers key off, so it has to track the two calls
    /// that bracket a capture flow.
    @Test
    func startingAndStoppingTracksSessionOwnership() {
        let manager = CameraSessionManager()

        manager.startRunning()
        #expect(manager.isSessionWanted)

        manager.stopRunning()
        #expect(!manager.isSessionWanted)
    }

    /// Fix round 1: closing the capture UI schedules a stop but the session
    /// keeps physically running through its 30s grace window. If the flag
    /// stayed true through that window, an interruption landing inside it
    /// (e.g. backgrounding the app right after closing the scanner) would
    /// read as "wanted" on return and resume the camera behind the receipt
    /// list — with the pending stop cancelled and nothing left to ever stop
    /// it again. The flag must clear the moment the stop is scheduled, not
    /// when the work item eventually fires.
    @Test
    func aScheduledStopStopsReadingAsWantedForTheGraceWindow() {
        let manager = CameraSessionManager()

        manager.startRunning()
        #expect(manager.isSessionWanted)

        manager.scheduleStop(after: 30)
        #expect(!manager.isSessionWanted, "capture UI is gone — nothing wants the session anymore")

        manager.handleInterruptionEnded()
        // Deliberately not `state == .idle`: that assertion cannot fail. A
        // resume would go through `startRunning()`, whose `state` write is
        // hopped to the main queue from `sessionQueue` and never lands inside
        // a synchronous test — but whose `isSessionWanted = true` is immediate.
        #expect(!manager.isSessionWanted,
                "an interruption inside the grace window must not resume the session")
    }

    /// The scheduled stop must stop the session even when an interruption got
    /// there first. Backgrounding inside the grace window takes the session
    /// down, so `isRunning` is already false when the work item fires; a
    /// `guard isRunning` there made the stop a no-op and left AVFoundation's
    /// own post-interruption resume free to bring the camera back with nobody
    /// wanting it and nothing pending to stop it.
    @Test
    func stoppingAnAlreadyStoppedSessionStillClearsOwnership() {
        let manager = CameraSessionManager()

        manager.startRunning()
        #expect(manager.isSessionWanted)

        // The session never physically started here (no camera in the test
        // host), which is precisely the "already stopped" shape.
        manager.stopRunning()
        #expect(!manager.isSessionWanted)

        manager.handleInterruptionEnded()
        #expect(!manager.isSessionWanted,
                "a stop taken against a stopped session must still be a real stop")
    }
}

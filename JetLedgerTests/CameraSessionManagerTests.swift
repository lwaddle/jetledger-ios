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

        #expect(!manager.isSessionWanted)
        #expect(manager.state == .idle, "no capture UI exists — nothing should have started")
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
        #expect(manager.state == .idle, "an interruption inside the grace window must not resume the session")
    }
}

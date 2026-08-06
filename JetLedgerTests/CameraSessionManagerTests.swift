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
}

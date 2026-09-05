import Foundation
import Testing

@testable import DoryMachinePC

@Suite struct DoryPCAPICTests {
  @Test func spuriousVectorAcceptsArchitecturalVirtualWireValue() throws {
    let apic = DoryPCLocalAPIC(apicID: 0)

    try apic.configureSpuriousVector(0x0F, softwareEnabled: true)

    #expect(apic.snapshot().spuriousVector == 0x0F)
    #expect(apic.snapshot().softwareEnabled)
    #expect(throws: DoryPCAPICError.invalidVector(0x0F)) {
      try apic.inject(vector: 0x0F)
    }
  }

  @Test func localAPICSelectsByPriorityAndTracksInServiceVectors() throws {
    let apic = DoryPCLocalAPIC(apicID: 3)
    try apic.configureSpuriousVector(0xFF, softwareEnabled: true)
    apic.setTaskPriority(0x20)
    try apic.inject(vector: 0x21)
    try apic.inject(vector: 0x31)
    try apic.inject(vector: 0x41)

    #expect(apic.acknowledge(interruptsEnabled: false) == nil)
    #expect(apic.acknowledge(interruptsEnabled: true) == 0x41)
    #expect(apic.acknowledge(interruptsEnabled: true) == nil)
    #expect(apic.endOfInterrupt() == 0x41)
    #expect(apic.acknowledge(interruptsEnabled: true) == 0x31)
    #expect(apic.endOfInterrupt() == 0x31)
    #expect(apic.acknowledge(interruptsEnabled: true) == nil)

    let snapshot = apic.snapshot()
    #expect(snapshot.interruptRequest == [0x21])
    #expect(snapshot.inService.isEmpty)
  }

  @Test func localAPICPredictsAcceptanceWithoutMutatingState() throws {
    let apic = DoryPCLocalAPIC(apicID: 0)
    #expect(!apic.canAccept(vector: 0x40, interruptsEnabled: true))
    try apic.configureSpuriousVector(0xFF, softwareEnabled: true)
    apic.setTaskPriority(0x30)
    #expect(!apic.canAccept(vector: 0x30, interruptsEnabled: true))
    #expect(apic.canAccept(vector: 0x40, interruptsEnabled: true))
    #expect(!apic.canAccept(vector: 0x40, interruptsEnabled: false))
    #expect(!apic.canAccept(vector: 0x40, interruptsEnabled: true, externalPriority: 0x40))
    #expect(apic.snapshot().interruptRequest.isEmpty)
  }

  @Test func periodicTimerRearmsAndCoalescesPendingExpirations() throws {
    let apic = DoryPCLocalAPIC(apicID: 0)
    try apic.configureSpuriousVector(0xFF, softwareEnabled: true)
    try apic.configureTimer(vector: 0x50, masked: false, mode: .periodic, initialCount: 10)

    apic.advanceTimer(by: 26)

    let snapshot = apic.snapshot()
    #expect(snapshot.timer.currentCount == 4)
    #expect(snapshot.interruptRequest == [0x50])
    #expect(apic.acknowledge(interruptsEnabled: true) == 0x50)
    #expect(apic.endOfInterrupt() == 0x50)
  }

  @Test func ioAPICPreservesEdgeAndLevelTriggerSemantics() throws {
    let local = DoryPCLocalAPIC(apicID: 0)
    try local.configureSpuriousVector(0xFF, softwareEnabled: true)
    let io = DoryPCIOAPIC()
    try io.attach(local)
    io.seal()
    try io.configure(
      pin: 4,
      route: .init(vector: 0x34, destinationAPICID: 0, masked: false)
    )
    try io.configure(
      pin: 9,
      route: .init(
        vector: 0x39,
        destinationAPICID: 0,
        masked: false,
        levelTriggered: true
      )
    )

    try io.setAsserted(true, pin: 4)
    try io.setAsserted(true, pin: 4)
    #expect(local.acknowledge(interruptsEnabled: true) == 0x34)
    #expect(local.endOfInterrupt() == 0x34)
    #expect(local.acknowledge(interruptsEnabled: true) == nil)
    try io.setAsserted(false, pin: 4)
    try io.setAsserted(true, pin: 4)
    #expect(local.acknowledge(interruptsEnabled: true) == 0x34)
    #expect(local.endOfInterrupt() == 0x34)

    try io.setAsserted(true, pin: 9)
    #expect(local.acknowledge(interruptsEnabled: true) == 0x39)
    #expect(local.endOfInterrupt() == 0x39)
    try io.endOfInterrupt(vector: 0x39, destinationAPICID: 0)
    #expect(local.acknowledge(interruptsEnabled: true) == 0x39)
    #expect(local.endOfInterrupt() == 0x39)
    try io.setAsserted(false, pin: 9)
    try io.endOfInterrupt(vector: 0x39, destinationAPICID: 0)
    #expect(local.acknowledge(interruptsEnabled: true) == nil)
  }

  @Test func ioAPICRouteDecodesLegacySnapshotsAsFixedPhysicalDelivery() throws {
    let json = #"""
      {
        "vector": 65,
        "destinationAPICID": 2,
        "masked": false,
        "levelTriggered": true,
        "activeLow": true
      }
      """#.data(using: .utf8)!

    let route = try JSONDecoder().decode(DoryPCIOAPICRoute.self, from: json)

    #expect(route.vector == 0x41)
    #expect(route.destinationAPICID == 2)
    #expect(route.deliveryMode == .fixed)
    #expect(route.destinationMode == .physical)
    #expect(!route.masked)
    #expect(route.levelTriggered)
    #expect(route.activeLow)
  }

  @Test func topologyAndInputValidationFailClosed() throws {
    let local = DoryPCLocalAPIC(apicID: 1)
    let io = DoryPCIOAPIC(pinCount: 2)
    try io.attach(local)
    #expect(throws: DoryPCAPICError.duplicateLocalAPICID(1)) { try io.attach(local) }
    io.seal()
    #expect(throws: DoryPCAPICError.sealed) {
      try io.attach(DoryPCLocalAPIC(apicID: 2))
    }
    #expect(throws: DoryPCAPICError.invalidPin(2)) {
      try io.setAsserted(true, pin: 2)
    }
    #expect(throws: DoryPCAPICError.invalidVector(0x0F)) {
      try local.inject(vector: 0x0F)
    }
  }
}

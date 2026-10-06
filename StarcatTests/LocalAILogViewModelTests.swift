//
//  LocalAILogViewModelTests.swift
//  StarcatTests
//
//  只验证展示状态，不创建窗口、不操作用户桌面。UI 指针与视觉验收留给用户。
//

import Foundation
import AppKit
import SwiftUI
import Testing
@testable import Starcat

@Suite("Local AI log presentation") @MainActor
struct LocalAILogViewModelTests {
    private func event(_ sequence: UInt64, model: LocalAIModelCatalogEntry = LocalAIModelCatalog.llmMiniCPM5) -> LocalAILogEvent {
        var event = LocalAILogEvent(stage: "test.event", message: "Event \(sequence)",
            context: .init(modelName: model.displayName, feature: "repo_note"))
        event.sequence = sequence
        return event
    }

    @Test("Pause freezes display, resume catches up, and clear-view survives resume")
    func pauseResumeAndClearView() {
        let vm = LocalAILogViewModel(store: .init(persistenceEnabled: false))
        let first = event(1)
        let second = event(2)
        vm.receive(.init(events: [first], revision: 1, lastSequence: 1))
        vm.isPaused = true
        vm.receive(.init(events: [first, second], revision: 2, lastSequence: 2))
        #expect(vm.rows == [first])
        #expect(vm.unreadCount == 1)
        vm.isPaused = false
        #expect(vm.rows == [first, second])
        vm.clearView()
        vm.isPaused = true
        vm.isPaused = false
        #expect(vm.rows.isEmpty)
        let third = event(3)
        vm.receive(.init(events: [first, second, third], revision: 3, lastSequence: 3))
        #expect(vm.rows == [third])
    }

    @Test("A stale subscription frame cannot undo a clear-all barrier, including while paused")
    func clearBarrierRejectsStaleSnapshots() {
        let vm = LocalAILogViewModel(store: .init(persistenceEnabled: false))
        let old = LocalAILogSnapshot(events: [event(1)], revision: 1, lastSequence: 1)
        vm.receive(old)
        vm.isPaused = true
        vm.receive(.init(revision: 2, clearGeneration: 1, lastSequence: 1))
        vm.receive(old)
        #expect(vm.rows.isEmpty)
        vm.isPaused = false
        #expect(vm.rows.isEmpty)
        vm.receive(.init(events: [event(2)], revision: 3, clearGeneration: 1, lastSequence: 2))
        #expect(vm.rows.count == 1)
    }

    @Test("Model menu only contains selected or logged models and preserves a scoped empty filter")
    func selectedAndLoggedModelsOnly() {
        let vm = LocalAILogViewModel(store: .init(persistenceEnabled: false))
        vm.setSelectedModels([
            LocalAIModelCatalog.llmMiniCPM5.id: LocalAIModelCatalog.llmMiniCPM5.displayName
        ])
        vm.selectModel(LocalAIModelCatalog.llmMiniCPM5.id)
        #expect(Set(vm.models.keys) == [LocalAIModelCatalog.llmMiniCPM5.id])
        let qwen = event(1, model: LocalAIModelCatalog.llmLite)
        vm.receive(.init(events: [qwen], revision: 1, lastSequence: 1))
        #expect(vm.models.count == 2)
        #expect(vm.rows.isEmpty)
        #expect(vm.modelID == LocalAIModelCatalog.llmMiniCPM5.id)
        vm.modelID = nil
        #expect(vm.rows == [qwen])
        vm.search = "not present"
        #expect(vm.rows.isEmpty)
    }

    @Test("A selected Laya model keeps its stable filter identity without joining the generic catalog")
    func layaModelIdentity() {
        let descriptor = LayaDecisionModelCatalog.multilingual
        let vm = LocalAILogViewModel(store: .init(persistenceEnabled: false))
        vm.setSelectedModels([descriptor.id: descriptor.displayName])
        vm.selectModel(descriptor.id)

        var event = LocalAILogEvent(
            stage: "inference.completed",
            message: "Laya decision inference completed.",
            context: .init(
                modelID: descriptor.id,
                modelName: descriptor.displayName,
                feature: "decision"
            )
        )
        event.sequence = 1
        vm.receive(.init(events: [event], revision: 1, lastSequence: 1))

        #expect(event.modelID == descriptor.id)
        #expect(vm.models[descriptor.id] == descriptor.displayName)
        #expect(vm.rows == [event])
    }

    @Test("Reading older lines does not mark new records as seen")
    func unreadTail() {
        let vm = LocalAILogViewModel(store: .init(persistenceEnabled: false))
        let first = event(1)
        vm.receive(.init(events: [first], revision: 1, lastSequence: 1))
        vm.followsTail = false
        vm.receive(.init(events: [first, event(2)], revision: 2, lastSequence: 2))
        #expect(vm.rows.count == 2)
        #expect(vm.unreadCount == 1)
        vm.followsTail = true
        #expect(vm.unreadCount == 0)
        vm.releaseDisplay()
        #expect(vm.rows.isEmpty)
    }

    @Test("Search accepts a full request ID and level filtering keeps global warnings")
    func requestAndLevelFilters() {
        let vm = LocalAILogViewModel(store: .init(persistenceEnabled: false))
        let first = event(1)
        var warning = LocalAILogEvent(level: .warning, stage: "memory.pressure", message: "Memory pressure detected.")
        warning.sequence = 2
        vm.selectModel(LocalAIModelCatalog.llmMiniCPM5.id)
        vm.receive(.init(events: [first, warning], revision: 1, lastSequence: 2))
        vm.search = first.requestID ?? "missing"
        #expect(vm.rows == [first])
        vm.search = ""
        vm.level = .warning
        #expect(vm.rows == [warning])
    }

    @Test("Native text appends, trims UTF16 selections and resets without opening a window")
    func nativeTextAppendAndTrim() throws {
        let scroll = LocalAILogTextView.makeScrollView()
        scroll.frame = NSRect(x: 0, y: 0, width: 640, height: 200)
        let text = try #require(scroll.documentView as? NSTextView)
        var followsTail = false
        let coordinator = LocalAILogTextView.Coordinator(followsTail: .init(
            get: { followsTail }, set: { followsTail = $0 }))
        let rows = (1...40).map { event(UInt64($0)) }
        coordinator.update(rows: rows, in: scroll, fontSize: 12)
        #expect(text.string == rows.map { $0.line + "\n" }.joined())
        #expect(text.isSelectable && !text.isEditable)
        let removed = (rows[0].line + "\n").utf16.count
        let selection = NSRange(location: removed + 4, length: 8)
        text.setSelectedRange(selection)
        coordinator.update(rows: Array(rows.dropFirst()), in: scroll, fontSize: 12)
        #expect(text.selectedRange() == NSRange(location: 4, length: 8))
        #expect(text.string == rows.dropFirst().map { $0.line + "\n" }.joined())
        coordinator.update(rows: [], in: scroll, fontSize: 12)
        #expect(text.string.isEmpty)
        followsTail = true
        coordinator.update(rows: rows, in: scroll, fontSize: 12)
        #expect(text.frame.height > scroll.contentSize.height)
        #expect(scroll.contentView.bounds.maxY >= text.bounds.maxY - 30)
    }
}

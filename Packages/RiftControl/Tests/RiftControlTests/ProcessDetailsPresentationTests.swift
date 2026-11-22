import Foundation
import RiftCore
import RiftIPC
import Testing
@testable import RiftControl

@Test func oneProcessShowsItsIDAndPath() throws {
    let details = FlowProcessDetails(
        process: ObservedProcess(processID: 812, executablePath: "/usr/local/bin/sync-tool"),
        app: nil
    )
    let rows = ProcessDetailsPresentation.rows(for: details)
    #expect(rows.map(\.title) == ["Process ID", "Path"])
    #expect(rows[0].value == "812")
    #expect(!rows[0].isPath)
    #expect(rows[1].value == DisplaySanitizer.plainText("/usr/local/bin/sync-tool"))
    #expect(rows[1].isPath)
}

@Test func aHelperAndItsAppAreBothShownAndLabelled() throws {
    let details = FlowProcessDetails(
        process: ObservedProcess(processID: 812, executablePath: "/Applications/Sync.app/Contents/Helpers/net"),
        app: ObservedProcess(processID: 640, executablePath: "/Applications/Sync.app/Contents/MacOS/Sync")
    )
    let rows = ProcessDetailsPresentation.rows(for: details)
    #expect(rows.map(\.title) == ["App process ID", "App path", "Helper process ID", "Helper path"])
    #expect(rows.map(\.value)[0] == "640")
    #expect(rows.map(\.value)[2] == "812")
    #expect(Set(rows.map(\.id)).count == rows.count)
}

@Test func missingDetailsAndMissingPathsShowNothingExtra() throws {
    #expect(ProcessDetailsPresentation.rows(for: nil).isEmpty)
    let exited = FlowProcessDetails(
        process: ObservedProcess(processID: 31, executablePath: nil), app: nil
    )
    #expect(ProcessDetailsPresentation.rows(for: exited).map(\.title) == ["Process ID"])
}

@Test func aLongPathIsShownWhole() throws {
    let path = "/" + String(repeating: "a", count: 900)
    let rows = ProcessDetailsPresentation.rows(for: FlowProcessDetails(
        process: ObservedProcess(processID: 5, executablePath: path), app: nil
    ))
    #expect(rows.last?.value.unicodeScalars.count == path.unicodeScalars.count + 2)
}

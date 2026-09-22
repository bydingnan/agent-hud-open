import AgentHUDCore
import XCTest
@testable import AgentHUDDesktop

/// How a request waiting for its user behaves on the island, next to news that expires on its own.
@MainActor
final class PermissionAlertTests: XCTestCase {
    private func request(_ id: String) -> PermissionRequest {
        PermissionRequest(id: id, source: .claude, sessionID: "s", toolName: "Bash",
                          summary: "Remove the build output", detail: "rm -rf .build", cwd: "/Users/me/agent-hud", at: Date())
    }

    private func completion() -> IslandAlert {
        .completion(SessionCompletion(sessionID: "s", vendor: "Claude", turnID: "t", task: "Build the dashboard",
                                      model: "opus", startedAt: nil, completedAt: Date()))
    }

    func testARequestHoldsTheIslandAndNewsDoesNotWaitBehindIt() async throws {
        let queue = IslandAlertQueue()
        var expired = 0
        queue.onExpire = { expired += 1 }

        XCTAssertTrue(queue.show(.permission(request("a")), inUsagePanel: false))
        XCTAssertFalse(queue.show(completion(), inUsagePanel: false), "news never takes a question's place")
        XCTAssertFalse(queue.show(.permission(request("b")), inUsagePanel: false), "a second request waits its turn")

        try await Task.sleep(for: IslandAlertQueue.visibleDuration + .milliseconds(200))
        XCTAssertEqual(expired, 0, "a request is not news: it stays until it is answered or withdrawn")
        XCTAssertEqual(queue.current?.alert.id, "a")

        // Answering the first hands over to the one that was waiting; the completion was dropped, not queued.
        let next = queue.remove(id: "a")
        XCTAssertTrue(next.removed)
        XCTAssertEqual(next.next?.id, "b")
    }

    func testAWithdrawnRequestIsTakenOutOfTheQueueWhereverItIs() {
        let queue = IslandAlertQueue()
        _ = queue.show(.permission(request("a")), inUsagePanel: false)
        _ = queue.show(.permission(request("b")), inUsagePanel: false)

        let waiting = queue.remove(id: "b")
        XCTAssertTrue(waiting.removed)
        XCTAssertNil(waiting.next, "the one on screen is still the one on screen")
        XCTAssertEqual(queue.current?.alert.id, "a")

        XCTAssertFalse(queue.remove(id: "gone").removed)
        let showing = queue.remove(id: "a")
        XCTAssertTrue(showing.removed)
        XCTAssertNil(showing.next)
        XCTAssertNil(queue.current)
    }

    func testBringingAStackedRequestForwardSwapsItWithTheOneOnScreen() {
        let queue = IslandAlertQueue()
        _ = queue.show(.permission(request("a")), inUsagePanel: false)
        _ = queue.show(.permission(request("b")), inUsagePanel: false)
        _ = queue.show(.permission(request("c")), inUsagePanel: false)

        XCTAssertTrue(queue.promote(id: "c"), "the card the user picked becomes the card being decided")
        XCTAssertEqual(queue.current?.alert.id, "c")
        XCTAssertFalse(queue.promote(id: "c"), "the one already in front cannot be brought forward again")
        XCTAssertFalse(queue.promote(id: "gone"))

        // The one it replaced keeps its place in the pile rather than going to the back of it.
        XCTAssertTrue(queue.promote(id: "b"))
        XCTAssertEqual(queue.current?.alert.id, "b")
        let answered = queue.remove(id: "b")
        XCTAssertEqual(answered.next?.id, "a", "answering hands over to the oldest one still waiting")
    }

    func testNewsStillExpiresOnItsOwn() async throws {
        let queue = IslandAlertQueue()
        var expired = 0
        queue.onExpire = { expired += 1 }
        XCTAssertTrue(queue.show(completion(), inUsagePanel: false))
        try await Task.sleep(for: IslandAlertQueue.visibleDuration + .milliseconds(200))
        XCTAssertEqual(expired, 1)
    }
}

/// What counts as pointing at the HUD, which decides whether a waiting request can be answered at all.
@MainActor
final class IslandHoverRegionTests: XCTestCase {
    private let marks = CGRect(x: 900, y: 1300, width: 200, height: 32)
    private let wings = CGRect(x: 640, y: 1300, width: 720, height: 38)
    private let panel = CGRect(x: 700, y: 1000, width: 470, height: 340)

    func testAnEventIsHoveredAnywhereItDraws() {
        // The wings carry the project, the state and the count; pointing at any of them opens the card.
        XCTAssertEqual(ScreenHUD.hoverRegion(open: false, panel: panel, alert: wings, marks: marks), wings)
        XCTAssertTrue(ScreenHUD.hoverRegion(open: false, panel: panel, alert: wings, marks: marks)
            .contains(CGPoint(x: 700, y: 1310)), "the left wing is part of the reminder")
        XCTAssertFalse(marks.contains(CGPoint(x: 700, y: 1310)), "and it is outside the silhouette the HUD idles at")
    }

    func testWithoutAnEventOnlyTheMarksAreHovered() {
        XCTAssertEqual(ScreenHUD.hoverRegion(open: false, panel: panel, alert: nil, marks: marks), marks,
                       "a collapsed HUD must let clicks through everywhere it is not drawing")
    }

    func testAnsweringTheLastRequestClosesTheIslandRatherThanOpeningThePanel() {
        // The pointer is on the button that was just pressed; the usage panel is not what that press asked for.
        XCTAssertTrue(ScreenHUD.closesAfterLastAlert(wasInUsagePanel: false, pointerInside: true))
        XCTAssertTrue(ScreenHUD.closesAfterLastAlert(wasInUsagePanel: false, pointerInside: false))
        // A request answered as a row inside the panel leaves the panel where the user had it.
        XCTAssertFalse(ScreenHUD.closesAfterLastAlert(wasInUsagePanel: true, pointerInside: true))
        XCTAssertTrue(ScreenHUD.closesAfterLastAlert(wasInUsagePanel: true, pointerInside: false))
    }

    func testTheWindowKeepsASurfaceUnderThePointerWhileTheCardShrinks() {
        // Opening a shorter request, or answering one and losing its row, makes the card shorter than the pointer
        // that asked for it. The window holds its height so the pointer still stands on the HUD; what it holds is
        // transparent, because the card is drawn at its own size.
        XCTAssertEqual(ScreenHUD.heldWindowHeight(card: 200, floor: 320, pointerInside: true), 320)
        // Growing is free, and raises the floor with it.
        XCTAssertEqual(ScreenHUD.heldWindowHeight(card: 420, floor: 320, pointerInside: true), 420)
        // The pointer gone, the window is the card again — nothing invisible is left behind.
        XCTAssertEqual(ScreenHUD.heldWindowHeight(card: 200, floor: 320, pointerInside: false), 200)
    }

    func testAnOpenPanelOwnsItsWholeFrame() {
        XCTAssertEqual(ScreenHUD.hoverRegion(open: true, panel: panel, alert: wings, marks: marks), panel)
    }
}

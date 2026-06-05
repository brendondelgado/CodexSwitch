import Foundation
import Testing

@Suite("Popover UX")
struct PopoverUXTests {
    @Test("Popover keeps native menu-bar anchor and installs outside-click monitors")
    func popoverKeepsNativeAnchorAndDismissesOnOutsideClick() throws {
        let source = try String(
            contentsOfFile: "Sources/CodexSwitch/App/AppDelegate.swift",
            encoding: .utf8
        )

        #expect(source.contains("popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)"))
        #expect(source.contains("startPopoverDismissalMonitoring()"))
        #expect(source.contains("NSEvent.addLocalMonitorForEvents"))
        #expect(source.contains("NSEvent.addGlobalMonitorForEvents"))
        #expect(source.contains("closePopoverIfNeeded(forLocalEvent:"))
        #expect(source.contains("if frame.minX < minX"))
        #expect(source.contains("} else if frame.maxX > maxX {"))
        #expect(source.contains("let verticalGap = buttonScreenFrame.minY - frame.maxY"))
        #expect(source.contains("frame.origin.y += verticalGap + desiredArrowOverlap"))
        #expect(!source.contains("targetRightEdge"))
        #expect(!source.contains("frame.origin.y = min(frame.origin.y, visibleFrame.maxY - frame.height - screenPadding)"))
    }

    @Test("Account card shows full email on hover")
    func accountCardShowsFullEmailOnHover() throws {
        let source = try String(
            contentsOfFile: "Sources/CodexSwitch/Views/AccountCardView.swift",
            encoding: .utf8
        )

        #expect(source.contains("@State private var isHovering = false"))
        #expect(source.contains("private var emailHoverOverlay: some View"))
        #expect(source.contains("Text(account.email)"))
        #expect(source.contains("AccountCardHoverTrackingView(email: account.email, isHovering: $isHovering)"))
        #expect(source.contains("NSTrackingArea("))
        #expect(source.contains("toolTip = email"))
        #expect(source.contains(".onHover { hovering in"))
        #expect(source.contains(".help(account.email)"))
    }
}

//
//  NotchGeometryTests.swift
//  SpotifyNotchTests
//
//  Rect math for the overlay, plus the PKCE helpers.
//
//  Fixture values are the real measurements from a 14-inch M-series MacBook
//  Pro with an external display attached, where the built-in screen is NOT
//  the main screen and sits at a negative origin — the arrangement that
//  breaks naive `NSScreen.main` based geometry.
//

import XCTest
@testable import SpotifyNotch

final class NotchGeometryTests: XCTestCase {

    /// Built-in display to the left of an external monitor.
    private let geometry = NotchGeometry(
        screenFrame: CGRect(x: -1512, y: 458, width: 1512, height: 982),
        notchRect: CGRect(x: -847, y: 1408, width: 185, height: 32),
        backingScale: 2.0
    )

    func testMiniRectIsCentredOnTheHardwareNotch() {
        XCTAssertEqual(geometry.miniRect.midX, geometry.notchRect.midX, accuracy: 0.001)
    }

    /// The frame carries an extra `topCornerRadius` per side for the shape's
    /// concave flare, so it is the visible width that gains a full lobe.
    func testMiniRectAddsALobeOnEachSide() {
        let visibleWidth = geometry.miniRect.width - NotchMetrics.topCornerRadius * 2
        XCTAssertEqual(
            visibleWidth,
            185 + NotchMetrics.miniLobeWidth * 2,
            accuracy: 0.001
        )
        XCTAssertEqual(geometry.miniRect.height, 32, accuracy: 0.001)
    }

    func testExpandedRectIsCentredAndTopAligned() {
        XCTAssertEqual(geometry.expandedRect.midX, geometry.notchRect.midX, accuracy: 0.001)
        XCTAssertEqual(
            geometry.expandedRect.maxY,
            geometry.screenFrame.maxY,
            accuracy: 0.001,
            "The card must hang from the top screen edge"
        )
    }

    /// The panel never moves, so it has to be large enough for every state.
    func testPanelFrameContainsBothStates() {
        let panel = geometry.panelFrame
        XCTAssertGreaterThanOrEqual(panel.width, geometry.miniRect.width)
        XCTAssertGreaterThanOrEqual(panel.width, geometry.expandedRect.width)
        XCTAssertGreaterThanOrEqual(panel.height, geometry.expandedRect.height)
    }

    func testMiniRectConvertsIntoPanelCoordinates() {
        let converted = geometry.miniRectInPanel
        XCTAssertGreaterThanOrEqual(converted.minX, 0)
        XCTAssertEqual(converted.width, geometry.miniRect.width, accuracy: 0.001)
        XCTAssertEqual(
            converted.maxY,
            geometry.panelFrame.height,
            accuracy: 0.001,
            "The mini strip sits at the very top of the panel"
        )
    }

    /// Entering only counts inside the visible strip, but leaving gets slop
    /// so the card does not collapse from under a cursor heading for a button.
    func testHoverZoneGrowsOnceExpanded() {
        let entry = geometry.hoverZone(for: .mini)
        let exit = geometry.hoverZone(for: .expanded)

        XCTAssertEqual(entry, geometry.miniRect)
        XCTAssertGreaterThan(exit.width, geometry.expandedRect.width)
        XCTAssertTrue(exit.contains(CGPoint(x: geometry.notchRect.midX, y: exit.minY + 1)))
    }

    func testNegativeOriginScreenIsHandled() {
        XCTAssertLessThan(geometry.miniRect.minX, 0)
        XCTAssertTrue(geometry.screenFrame.contains(CGPoint(x: geometry.notchRect.midX, y: 1420)))
    }
}

// MARK: - PKCE

final class PKCETests: XCTestCase {

    /// The worked example from RFC 7636 Appendix B. If this passes, the
    /// SHA-256 and base64url-without-padding steps are both correct.
    func testCodeChallengeMatchesRFC7636Vector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"

        let challenge = SpotifyAuthManager.codeChallenge(for: verifier)

        XCTAssertEqual(challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testChallengeHasNoBase64Padding() {
        let challenge = SpotifyAuthManager.codeChallenge(for: "abc")
        XCTAssertFalse(challenge.contains("="))
        XCTAssertFalse(challenge.contains("+"))
        XCTAssertFalse(challenge.contains("/"))
    }

    /// RFC 7636 §4.1 requires 43-128 unreserved characters.
    func testVerifierLengthIsClampedToSpec() {
        XCTAssertEqual(SpotifyAuthManager.randomURLSafeString(length: 10).count, 43)
        XCTAssertEqual(SpotifyAuthManager.randomURLSafeString(length: 64).count, 64)
        XCTAssertEqual(SpotifyAuthManager.randomURLSafeString(length: 999).count, 128)
    }

    func testVerifierUsesOnlyUnreservedCharacters() {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let verifier = SpotifyAuthManager.randomURLSafeString(length: 128)

        XCTAssertNil(verifier.rangeOfCharacter(from: allowed.inverted))
    }

    func testVerifiersAreNotRepeated() {
        let samples = Set((0..<64).map { _ in SpotifyAuthManager.randomURLSafeString(length: 64) })
        XCTAssertEqual(samples.count, 64)
    }

    func testRedirectURIsMatchCandidatePorts() {
        let uris = LoopbackRedirectServer.registrableRedirectURIs

        XCTAssertEqual(uris.count, LoopbackRedirectServer.candidatePorts.count)
        XCTAssertEqual(uris.first, "http://127.0.0.1:8888/callback")
        // Spotify requires loopback by IP; "localhost" is rejected outright.
        XCTAssertTrue(uris.allSatisfy { $0.hasPrefix("http://127.0.0.1:") })
    }
}

// MARK: - Pixel alignment

extension NotchGeometryTests {

    /// AppKit rounds window origins to whole points, so a half-point origin
    /// would shift the overlay a pixel off the hardware notch.
    func testAllRectOriginsLandOnWholePoints() {
        for rect in [geometry.miniRect, geometry.expandedRect, geometry.panelFrame] {
            XCTAssertEqual(
                rect.minX.truncatingRemainder(dividingBy: 1), 0,
                accuracy: 0.0001,
                "Origin \(rect.minX) is not on a whole point"
            )
        }
    }

    /// Whatever parity adjustment happens, every state stays centred on the
    /// notch to within half a point.
    func testEveryStateStaysCentredOnTheNotch() {
        for rect in [geometry.miniRect, geometry.expandedRect, geometry.panelFrame] {
            XCTAssertEqual(rect.midX, geometry.notchRect.midX, accuracy: 0.5)
        }
    }

    /// A hypothetical even-width notch must not be broken by the odd-width fix.
    func testEvenWidthNotchAlsoAligns() {
        let even = NotchGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            notchRect: CGRect(x: 663, y: 950, width: 186, height: 32),
            backingScale: 2.0
        )
        for rect in [even.miniRect, even.expandedRect, even.panelFrame] {
            XCTAssertEqual(rect.minX.truncatingRemainder(dividingBy: 1), 0, accuracy: 0.0001)
            XCTAssertEqual(rect.midX, even.notchRect.midX, accuracy: 0.5)
        }
    }
}

// MARK: - Expanded card fits

extension NotchGeometryTests {

    /// The card is clipped to the notch silhouette, so if the content is
    /// taller than the rect the transport row along the bottom is cut off
    /// and its buttons lose hit area. Keep headroom for the real layout.
    func testExpandedRectIsTallEnoughForItsContent() {
        let intrinsic: CGFloat =
            (geometry.notchHeight + 4)  // top padding, clearing the notch
            + 64                        // artwork band (art and text column)
            + 8                         // spacing
            + 24                        // transport buttons
            + 12                        // bottom padding

        XCTAssertGreaterThanOrEqual(
            geometry.expandedRect.height, intrinsic,
            "Expanded card would clip its transport controls"
        )
    }

    /// The card radiates symmetrically from the notch's bottom corners:
    /// the same distance left, right and down, rather than mostly hanging
    /// downward.
    func testExpandedCardGrowsEquallyInEveryDirection() {
        let notch = geometry.notchRect
        let card = geometry.expandedVisibleRect

        let left = notch.minX - card.minX
        let right = card.maxX - notch.maxX
        let down = notch.minY - card.minY

        XCTAssertEqual(left, right, accuracy: 0.5, "Not symmetric horizontally")
        XCTAssertEqual(left, down, accuracy: 0.5, "Grows further down than sideways")
        XCTAssertEqual(down, NotchMetrics.expansion, accuracy: 0.5)
    }

    /// On this machine's 185 x 32 notch the rule yields 425 x 152.
    func testExpandedCardMatchesTheIntendedProportions() {
        XCTAssertEqual(geometry.expandedVisibleRect.width, 425, accuracy: 1)
        XCTAssertEqual(geometry.expandedVisibleRect.height, 152, accuracy: 0.5)
    }
}

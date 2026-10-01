import Foundation
import PinballCore
import XCTest
@testable import EpicPinball

// The settings added by the enhanced-additions branches together (settings UX, replays / practice,
// attract mode, cabinet display, and the feat2 front-end / display options): a settings.json written by the build before all of them decodes
// with every new field at its default, and no new action takes a key the old file already uses.
// Synthetic data only.

final class IntegratedSettingsTests: XCTestCase {
    /// The format of the build before the merge (main 3f05982); K is also a left-flipper key here.
    static let oldFile = #"""
    {"version":1,
     "game":{"physicsMode":"enhanced","upscaleFilter":"xbrz","useHDPack":true,"dynamicLighting":true,
             "highRefresh":true,"fullTableView":false,"musicVolume":0.8,"sfxVolume":0.5},
     "frontEnd":{"controllerEnabled":true,"haptics":true,"startFullscreen":false,"pixelAspect":"square",
                 "masterVolume":0.9,"players":1,"ballsPerGame":1,"lastTable":10,"showStrip":true,
                 "keyBindings":{"leftFlipper":[56,123,40]}}}
    """#

    func testOldFileDecodesEveryNewFieldToItsDefault() {
        let s = StoredSettings.decode(Data(Self.oldFile.utf8))
        // Old fields kept.
        XCTAssertEqual(s.game.physicsMode, .enhanced)
        XCTAssertEqual(s.game.upscaleFilter, .xbrz)
        XCTAssertTrue(s.game.useHDPack)
        XCTAssertTrue(s.game.dynamicLighting)
        XCTAssertTrue(s.game.highRefresh)
        XCTAssertEqual(s.frontEnd.ballsPerGame, 1)
        XCTAssertEqual(s.frontEnd.lastTable, 10)
        // settings-ux
        XCTAssertEqual(s.game.lightingStrength, .subtle)
        XCTAssertEqual(s.game.outputScaling, .auto)
        XCTAssertEqual(s.game.enhancedPreset, .classicFeel)
        XCTAssertEqual(s.game.audioInterpolation, .original)
        XCTAssertTrue(s.frontEnd.pauseWhenInactive)
        XCTAssertEqual(s.frontEnd.screenshotFolder, "")
        XCTAssertFalse(s.frontEnd.showPerfOverlay)
        // attract
        XCTAssertTrue(s.frontEnd.attractMode)
        // cabinet-dist
        XCTAssertEqual(s.game.displayRotation, .none)
        XCTAssertFalse(s.game.scoreWindow)
        // frontend-rest (renderer options; defaults are RenderSettings' built-in values)
        XCTAssertEqual(s.game.crtScanlines, 0.75)
        XCTAssertEqual(s.game.crtCurvature, 0.025)
        XCTAssertEqual(s.game.crtMask, 0.18)
        XCTAssertTrue(s.game.roundDots)
        XCTAssertTrue(s.game.stripInFullTable)
        XCTAssertTrue(s.game.rotateFlippers)
        // display-rest
        XCTAssertEqual(s.game.scoreWindowRotation, .none)
        // Key bindings: the stored K stays on the left flipper; the practice save-state action,
        // new since that file, does not get K as well. The other new actions get their defaults.
        let b = s.frontEnd.keyBindings
        XCTAssertEqual(b.keys(.leftFlipper), [56, 123, KeyCode.k])
        XCTAssertFalse(b.keys(.saveState).contains(KeyCode.k))
        XCTAssertEqual(b.keys(.loadState), [KeyCode.l])
        XCTAssertEqual(b.keys(.screenshot), [KeyCode.f12])
        XCTAssertEqual(b.keys(.perfOverlay), [KeyCode.f10])
        XCTAssertEqual(b.actions(for: KeyCode.k), [.leftFlipper])
    }

    func testDefaultBindingsOfAllBranchesHaveNoSharedKey() {
        let b = KeyBindings.defaults
        var owner: [UInt16: GameAction] = [:]
        for a in GameAction.allCases {
            for k in b.keys(a) {
                if let o = owner[k] { XCTFail("key \(k) is on both \(o) and \(a)") }
                owner[k] = a
            }
        }
    }

    func testNewFieldsRoundTripTogether() throws {
        var s = StoredSettings()
        s.game.lightingStrength = .vivid
        s.game.outputScaling = .fill
        s.game.enhancedPreset = .modern
        s.game.audioInterpolation = .smooth
        s.game.displayRotation = .clockwise90
        s.game.scoreWindow = true
        s.game.crtScanlines = 0.5
        s.game.crtCurvature = 0.05
        s.game.crtMask = 0.4
        s.game.roundDots = false
        s.game.stripInFullTable = false
        s.game.rotateFlippers = false
        s.game.scoreWindowRotation = .clockwise270
        s.frontEnd.pauseWhenInactive = false
        s.frontEnd.showPerfOverlay = true
        s.frontEnd.attractMode = false
        s.frontEnd.screenshotFolder = "~/Desktop"
        let back = StoredSettings.decode(try s.encoded())
        XCTAssertEqual(back, s)
    }
}

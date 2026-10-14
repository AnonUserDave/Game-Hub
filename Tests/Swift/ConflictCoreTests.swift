import Foundation
import XCTest
@testable import GameHub

final class ConflictCoreTests: XCTestCase {
    func testEnemyAttackCoordinateResolutionShipInterceptsPlanet() {
        var game = fixture()
        game.ships[0] = ConflictUnit(x: 5100, y: 5000, energy: 20000)
        game.planets[0] = ConflictObject(x: 5100, y: 5000, energy: 30000)
        game.bases[0] = ConflictObject(x: 5100, y: 5000, energy: 30000)
        game.enemies[0] = ConflictUnit(x: 5000, y: 5000, energy: 20000)
        game.enemies[1].energy = -1
        game.advanceTurn()
        // Planet priority5 beats ship2 at the same distance, but BASIC1350
        // finds the ship first and jumps to1420, leaving planet and base intact.
        XCTAssertLessThan(game.ships[0].energy, 20000)
        XCTAssertEqual(game.planets[0].energy, 30000)
        XCTAssertEqual(game.bases[0].energy, 30000)
    }
    func testEnemyAttackDamagesEveryCoincidentPlanetAndBase() {
        var game = fixture()
        game.ships[0] = ConflictUnit(x: 9000, y: 9000, energy: 20000)
        game.planets = [ConflictObject(x: 5100, y: 5000, energy: 30000), ConflictObject(x: 5100, y: 5000, energy: 30000)]
        game.bases[0] = ConflictObject(x: 5100, y: 5000, energy: 30000)
        game.enemies[0] = ConflictUnit(x: 5000, y: 5000, energy: 20000)
        game.enemies[1].energy = -1
        game.advanceTurn()
        XCTAssertTrue(game.planets.allSatisfy { $0.energy < 30000 })
        XCTAssertLessThan(game.bases[0].energy, 30000)
        XCTAssertNotEqual(game.planets[0].energy, game.planets[1].energy)
    }
    private func fixture() -> ConflictSimulation {
        var game = ConflictSimulation(scenario: ConflictScenario(ships: 2, enemies: 2, planets: 1, bases: 1), seed: 1)
        game.ships = [ConflictUnit(x: 5000, y: 5000, energy: 20000), ConflictUnit(x: 9000, y: 9000, energy: 20000)]
        game.enemies = [ConflictUnit(x: 9000, y: 1000, energy: 10000), ConflictUnit(x: 11000, y: 1000, energy: 10000)]
        game.bases = [ConflictObject(x: 1000, y: 1000, energy: 30000)]
        game.planets = [ConflictObject(x: 13000, y: 1000, energy: 30000)]
        return game
    }

    func testRecoveredFiringFormulaAndOneShotPerTurn() {
        var game = fixture()
        game.enemies[0] = ConflictUnit(x: 5500, y: 5000, energy: 100)
        XCTAssertTrue(game.fire(angle: 90, power: 100))
        XCTAssertEqual(game.ships[0].energy, 15000)
        XCTAssertEqual(game.enemies[0].energy, 100 - 100 * 7) // FN A(500)=7, BASIC 910
        XCTAssertEqual(game.ships[0].kills, 1)
        XCTAssertFalse(game.fire(angle: 90, power: 100))
        XCTAssertEqual(game.shipPriority, 6) // source multiplies by1.5, then2
        game.advanceTurn()
        XCTAssertFalse(game.ships[0].fired)
    }

    func testFiringPrefilterIsStrictAndDoesNotRevealEnemiesOnMap() {
        var game = fixture()
        game.enemies[0] = ConflictUnit(x: 6290, y: 5000, energy: 10000)
        XCTAssertTrue(game.fire(angle: 90, power: 100))
        XCTAssertEqual(game.enemies[0].energy, 10000) // exactly1290 excluded
        XCTAssertEqual(game.mapCell(column: 6, row: 5), ".")
        XCTAssertEqual(game.mapCell(column: 5, row: 5), "0")
    }

    func testHeadingUsesSource57AndBoundaryStopsBeforeEnergyCharge() {
        var game = fixture()
        game.ships[0] = ConflictUnit(x: 13600, y: 5000, energy: 20000)
        XCTAssertTrue(game.changeCourse(speed: 5000, heading: 90))
        XCTAssertEqual(game.ships[0].dx, Int(floor(5000 * sin(90.0 / 57))))
        let dy = game.ships[0].dy
        game.advanceTurn()
        XCTAssertEqual(game.ships[0].x, 13700)
        XCTAssertEqual(game.ships[0].dx, 0)
        XCTAssertEqual(game.ships[0].energy, 20000 - abs(dy))
        XCTAssertEqual(ConflictUnit(x: 0, y: 0, energy: 1, dx: 0, dy: -10).displayedHeading, 0)
        XCTAssertEqual(ConflictUnit(x: 0, y: 0, energy: 1, dx: 0, dy: 10).displayedHeading, 180)
        XCTAssertEqual(ConflictUnit(x: 0, y: 0, energy: 1, dx: 10, dy: 0).displayedHeading, 0) // original status edge case
    }

    func testSourceDockThresholdsAndTransferredEnergy() {
        var game = fixture()
        game.bases[0] = ConflictObject(x: 5299, y: 5299, energy: 0) // source permits0
        game.ships[0].energy = 9999
        XCTAssertTrue(game.dock(.base))
        XCTAssertEqual(game.ships[0].energy, 10000)
        XCTAssertEqual(game.basePriority, 1.5)
        game.planets[0] = ConflictObject(x: 5300, y: 5000, energy: 30000)
        XCTAssertFalse(game.dock(.planet)) // strict300
        game.ships[1] = ConflictUnit(x: 5100, y: 5100, energy: 20000)
        XCTAssertTrue(game.dock(.ship, transfer: -5000))
        XCTAssertEqual(game.ships.map(\.energy), [15000, 15000])
        XCTAssertFalse(game.dock(.ship, transfer: Int.min))
        XCTAssertEqual(game.ships.map(\.energy), [15000, 15000])
    }

    func testMinePlacementArmingAndFriendlyBlast() {
        var game = fixture()
        XCTAssertTrue(game.setMine())
        XCTAssertEqual(game.placedMine, 1)
        XCTAssertFalse(game.setMine())
        XCTAssertTrue(game.armMine())
        // Enemy AI targets distant planets; two ships inside500MM both suffer
        // one mine, reflecting the source's inner loop without an energy recheck.
        game.ships[1] = ConflictUnit(x: 5100, y: 5000, energy: 20000)
        game.advanceTurn()
        XCTAssertEqual(game.mines[1].energy, 0)
        XCTAssertLessThan(game.ships[0].energy, 20000)
        XCTAssertLessThan(game.ships[1].energy, 20000)
    }

    func testScenarioBoundsAndDeterministicNativeSaveContinuation() throws {
        XCTAssertFalse(ConflictScenario(ships: 11).isValid)
        XCTAssertFalse(ConflictScenario(enemies: 21).isValid)
        var game = fixture()
        game.changeCourse(speed: 200, heading: 270)
        game.setMine(); game.armMine()
        let data = try JSONEncoder().encode(game.snapshot)
        let snapshot = try JSONDecoder().decode(ConflictSnapshot.self, from: data)
        var restored = try XCTUnwrap(ConflictSimulation(snapshot: snapshot))
        game.advanceTurn(); restored.advanceTurn()
        XCTAssertEqual(game.snapshot, restored.snapshot)
        var invalid = snapshot
        invalid.sourceIdentity = "different-edition"
        XCTAssertNil(ConflictSimulation(snapshot: invalid))
        invalid = snapshot; invalid.ships[0].dx = Int.min
        XCTAssertNil(ConflictSimulation(snapshot: invalid))
        invalid = snapshot; invalid.mineDetection = .nan
        XCTAssertNil(ConflictSimulation(snapshot: invalid))
    }

    func testFleetExhaustionEndsGameAndPercentVictoryRule() {
        var game = fixture()
        game.enemies[0].energy = -1; game.enemies[1].energy = -1
        game.advanceTurn()
        XCTAssertTrue(game.ended)
        XCTAssertTrue(game.victory)
        let before = game.snapshot
        game.advanceTurn()
        XCTAssertEqual(game.snapshot, before)
    }
}

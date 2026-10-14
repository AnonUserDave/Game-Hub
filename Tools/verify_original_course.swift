import Foundation

/// Build with PGACore.swift and PGAOriginalCollision.swift using the native
/// Swift compiler. This verifies geometric queries, not original physics.
@main
struct VerifyOriginalCourse {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw PGAOriginalCollision.LoadError.invalid("Usage: verify_original_course /absolute/path/terrain.ghpc")
        }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let source = try Data(contentsOf: url, options: .mappedIfSafe)
        let started = Date()
        let collision = try PGAOriginalCollision(data: source)
        let built = Date()
        var checked = 0, missing = 0, projectedDegenerate = 0, greatestError = 0.0
        source.withUnsafeBytes { bytes in
            func u32(_ offset: Int) -> UInt32 { UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
            func coordinate(_ vertex: UInt32, _ component: Int) -> Double {
                Double(Float(bitPattern: u32(44 + Int(vertex) * 24 + component * 4)))
            }
            let vertices = Int(u32(8)), start = 44 + vertices * 24
            for triangle in stride(from: 0, to: collision.triangleCount, by: 83) {
                let offset = start + triangle * 16
                let a = u32(offset), b = u32(offset + 4), c = u32(offset + 8)
                let area = (coordinate(b, 2) - coordinate(c, 2)) * (coordinate(a, 0) - coordinate(c, 0))
                    + (coordinate(c, 0) - coordinate(b, 0)) * (coordinate(a, 2) - coordinate(c, 2))
                // A vertical wall has no unique vertical-ray height at its XZ
                // centroid. It is not a floor-height correctness fixture.
                if abs(area) <= 1e-7 { projectedDegenerate += 1; continue }
                let x = (coordinate(a, 0) + coordinate(b, 0) + coordinate(c, 0)) / 3
                let y = (coordinate(a, 1) + coordinate(b, 1) + coordinate(c, 1)) / 3
                let z = (coordinate(a, 2) + coordinate(b, 2) + coordinate(c, 2)) / 3
                // Restrict the ray just above this source triangle to avoid a
                // genuine overlapping roof/upper surface hiding the triangle.
                if let hit = collision.sample(rawX: x, rawZ: z, maximumHeight: y + 0.001) {
                    greatestError = max(greatestError, abs(hit.rawHeight - y))
                } else { missing += 1 }
                checked += 1
            }
        }
        let finished = Date()
        let report: [String: Any] = [
            "source": url.lastPathComponent, "triangles": collision.triangleCount,
            "grid_references": collision.indexedReferences,
            "build_seconds": built.timeIntervalSince(started),
            "sampled_source_triangle_centroids": checked,
            "skipped_vertical_or_projected_degenerate_triangles": projectedDegenerate,
            "queries_seconds": finished.timeIntervalSince(built),
            "missing_intersections": missing,
            "maximum_height_error_raw_units": greatestError,
            "limitations": "Static geometry check and CPU query timing; no original runtime or ball-physics equivalence claim."
        ]
        let result = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: result, as: UTF8.self))
        fflush(stdout)
        if missing > 0 || greatestError > 0.001 {
            fputs("Original terrain centroid checks failed.\n", stderr)
            exit(1)
        }
    }
}

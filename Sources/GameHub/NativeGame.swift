import SwiftUI

/// Registry for future games compiled into the hub. External native .app and
/// Mach-O games need only a manifest and do not require a hub rebuild.
enum NativeGameFactory {
    static let availableIDs: Set<String> = ["pga2005-native-development", "pga2005-original-courses", "breakout-native-development", "conflict2500-native-development"]
}

struct NativeGameContainer: View {
    let game: GameManifest
    let onExit: () -> Void
    var body: some View {
        if game.launch?.builtin == "pga2005-native-development" {
            PGAGameView(onExit: onExit)
        } else if game.launch?.builtin == "pga2005-original-courses" {
            // "*" resumes the last course chosen in the setup screen (Pebble Beach first).
            PGAGameView(choice: .original(code: "*"), onExit: onExit)
        } else if game.launch?.builtin == "breakout-native-development" {
            BreakoutGameView(onExit: onExit)
        } else if game.launch?.builtin == "conflict2500-native-development" {
            ConflictGameView(onExit: onExit)
        } else {
        VStack(spacing: 20) {
            Image(systemName: "hammer").font(.system(size: 48)).foregroundStyle(game.tint)
            Text("Native module unavailable").font(.title)
            Text("This game needs a compiled native implementation before it can run.").foregroundStyle(.secondary)
            Button("Return to library", action: onExit).buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: "101318"))
        }
    }
}

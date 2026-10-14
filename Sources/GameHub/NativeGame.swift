import SwiftUI

/// Registry for future games compiled into the hub. External native .app and
/// Mach-O games need only a manifest and do not require a hub rebuild.
enum NativeGameFactory {
    static let availableIDs: Set<String> = ["pga2005-native-development", "pga2005-original-courses", "breakout-native-development", "conflict2500-native-development", "apple-panic-native-development", "crossfire-native-development", "night-driver-native-development", "asteroids2600-native-development", "asteroids7800-native-development", "asteroids8bit-native-development"]
}

struct NativeGameContainer: View {
    let game: GameManifest
    let root: URL
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
        } else if game.launch?.builtin == "apple-panic-native-development" {
            ApplePanicGameView(root: root, onExit: onExit)
        } else if game.launch?.builtin == "crossfire-native-development" {
            CrossfireGameView(root: root, onExit: onExit)
        } else if game.launch?.builtin == "night-driver-native-development" {
            NightDriverGameView(root: root, onExit: onExit)
        } else if game.launch?.builtin == "asteroids2600-native-development" {
            Asteroids2600GameView(root: root, onExit: onExit)
        } else if game.launch?.builtin == "asteroids7800-native-development" {
            Asteroids7800GameView(root: root, onExit: onExit)
        } else if game.launch?.builtin == "asteroids8bit-native-development" {
            Asteroids8BitGameView(root: root, onExit: onExit)
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

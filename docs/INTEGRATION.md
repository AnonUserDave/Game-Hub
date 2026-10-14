# Integrating a native game

Game Hub is a native SwiftUI application for Apple Silicon, running on macOS 14 or later. Native games can be separate `.app` bundles or Mach-O executables; they do not need to be compiled into the hub. The launcher checks for an executable arm64 slice when the library loads and again immediately before launch, accepts Universal builds, passes arguments without a shell, and returns to the library after the game exits. If a build is moved or replaced, press **Refresh** to update its library status. It does not load ROMs, mount disc images, run Windows binaries, or provide an emulator.

## Add an existing native game

Choose **Add game** and select a native `.app`, executable, or a `game.json` manifest. The importer records a reference to the build in `Library/Manifests/`; it does not move the game or its assets. Moving the referenced build later requires updating its launch path. Paths in an imported standalone JSON manifest resolve relative to that JSON file before being stored as absolute paths.

You can also create `Library/NativeGames/<stable-id>/game.json` and press **Refresh** in the hub. This folder is intended for your local native build and assets; keep large or proprietary files outside Git.

## Manifest schema 1

```json
{
  "schemaVersion": 1,
  "id": "my-native-game",
  "title": "My Native Game",
  "edition": "Native Mac",
  "platform": "macOS",
  "year": 2026,
  "genre": "Arcade",
  "summary": "A short description shown in the library.",
  "sourceArchive": null,
  "accent": "C2EF93",
  "artwork": "asteroids",
  "launch": {
    "kind": "app",
    "path": "Library/NativeGames/my-native-game/My Game.app",
    "arguments": []
  },
  "fidelity": "native",
  "notes": ["This build needs gameplay and controller validation."],
  "keyboard": ["Arrow keys: move", "Space: action", "Escape: pause"],
  "controller": ["Left stick: move", "A: action", "Menu: pause"]
}
```

All fields shown are required except `sourceArchive` and `launch`, which may be absent or `null`. Inside `launch`, only `kind` is always required; `path` is required for external games, and `builtin` is required for built-in games. `arguments` defaults to an empty list.

The `id` is unique across the entire library and uses lowercase letters, digits, hyphens, dots, or underscores. The first character must be a letter or digit. The accent is a six-digit RGB hex color. Built-in procedural artwork identifiers are `golf`, `skate`, `asteroids`, `breakout`, and `native`; other values use abstract pixel artwork. The artwork is original hub art, not a screenshot of the source game.

`path` is absolute or relative to the **library root**. The library root defaults to the folder containing `Game Hub.app`. `GAMEHUB_LIBRARY_ROOT` overrides it, and `Tools/run.sh` sets it to this checkout. If you move just the application, the starter catalog remains visible from its bundled resources, but original media and external native games still need their paths restored.

Launch kinds:

| Kind | Required data | Behavior |
| --- | --- | --- |
| `app` | `path` to a native `.app` | Uses `NSWorkspace`; arguments are passed to the application. |
| `executable` | `path` to an executable native Mach-O | Starts a child process with its own folder as working directory. |
| `builtin` | a registered `builtin` identifier | Opens a module compiled into the hub. |

Executable games receive `GAMEHUB_LIBRARY_ROOT` and `GAMEHUB_GAME_ID` environment variables. Arguments are passed as literal strings; shell expansion is never applied. The hub tracks one active game at a time. Separate games manage their own save files, rendering settings, pause behavior, and controller bindings. A manifest describes controls; it does not implement or translate them.

## Honest completion states

| `fidelity` | Meaning |
| --- | --- |
| `source` | Original media only. `launch` must be absent or `null`. |
| `prototype` | An available development implementation; original fidelity is incomplete. |
| `native` | An available native build, without a claim of original-game fidelity. |
| `verified` | A port whose original behavior, graphics, audio, input, saves, and modes have documented comparison evidence. |

Changing the string to `verified` is not a verification procedure. Record concrete comparison results and unresolved differences in the project documentation before using that status. Importing a Mac binary checks architecture, not gameplay correctness or graphics fidelity. The PGA practice and Pebble Beach modules are prototypes, while the original PGA 2005 entry remains in the port queue.

## Retina and controls

Render to the window's backing size, rather than assuming points are pixels. On this Mac, a 1280 × 800 point fullscreen drawable at a 2× backing scale is 2560 × 1600 pixels. Resizing and fullscreen transitions must resize native render targets. Rewrites should preserve the original presentation while validating any changes to geometry, filtering, lighting, aspect ratio, HUD scale, and frame pacing.

Use Apple's `GameController` extended profile for standard gamepads. The hub supports D-pad/left-stick library navigation, A to open, and B/Menu to clear filters. Built-in games own input while their session is active. Keyboard events stop navigating the hub while typing in search or while a game or sheet is open.

The controls sheet shows actual controller recognition, live buttons and sticks, triggers, and keyboard/click/scroll diagnostics. A USB connection by itself is insufficient. The attached BDA **XB1 Fusion Pro** exposes zero `GCController` profiles, so the hub now includes a native user-space USB adapter for this exact device. Neutral input-report reception was observed; physical bindings still need validation. See [controller evidence and integration](CONTROLLER.md). Imported external applications implement their own controller support.

## Add a built-in module

1. Implement the native module under `Sources/GameHub/`.
2. Register a stable identifier in `NativeGameFactory.availableIDs`.
3. Add a branch in `NativeGameContainer` and return through its `onExit` callback.
4. Create a `prototype` manifest using `{"kind":"builtin","builtin":"your-id"}`.
5. Add meaningful rules/physics/input tests, build, and validate real hardware before changing its status.

Current built-in identifiers: `pga2005-native-development` (generated practice holes and the Original Course Lab) and `pga2005-original-courses` (18 holes on each prepared original course, with incomplete original-game fidelity).

## Build

```sh
./Tools/build.sh
./Tools/test.sh
./Tools/run.sh
```

The build uses Xcode's installed Swift compiler and macOS SDK directly. It does not accept an Xcode license on your behalf, download dependencies, or require a paid developer account. `DEVELOPER_DIR` can select another Xcode installation. The resulting unsigned local application is `Game Hub.app` in the checkout. Distributing it to other Macs will require a separate signing and notarization decision.

## Original-media native development modules

Apple Panic, Crossfire and Night Driver are separate built-in **development reconstructions**, alongside Breakout/Conflict2500 and the two golf prototypes. Their original source records remain non-launching. No title is verified complete.

Run `Tools/prepare_retro_media.py`, then the title's `decode_apple_panic.py`, `decode_crossfire.py` or `decode_night_driver.py`, and refresh the library. The three entries require their bounded, source-identified original graphics; validation happens on a worker and again immediately before launch. They load asynchronously, report unavailable media explicitly, and stop session timers/load tasks on return. Local saves live under `~/Library/Application Support/GameHub/NativeRetro/` and restore paused after source/version validation. Night Driver saves include its provisional schedule fractions; Breakout schema2 rejects saves from the old approximate rules.

Original images/data stay in ignored `Library/Prepared/`, `Library/Imported/` or `Library/SourceMedia/`. Native source/tests/preparation tools and compact research receipts belong in Git. See [remaining-title gates](OTHER_REWRITES.md) before any completion claim.

# Ingot Engine — Developer Handoff Guide

## What is this?
A 2D game engine + editor for macOS, built from scratch with Metal and AppKit. The editor lets you design games visually, script with JavaScript, use AI to generate assets/code, and export to iPhone/iPad/Apple TV as `.swiftpm` packages.

## Quick Start
```bash
# Open in Xcode
open IngotEngine.xcodeproj

# Build & Run (Cmd+R)
# On first launch, you'll be prompted to select/create a project folder
# The editor opens with a demo scene (player, walls, camera)
# Click ▶ in the toolbar to enter Play mode (WASD to move)
```

## Tech Stack
- **Language:** Swift 5 (macOS 26.5+)
- **Rendering:** Metal + MetalKit (MTKView), MSL shaders
- **Math:** simd (simd_float2, simd_float4x4)
- **Scripting:** JavaScriptCore (built-in, no dependencies)
- **Physics:** Custom AABB (no external libraries)
- **Editor UI:** AppKit (NSOutlineView, NSSplitViewController, NSToolbar)
- **AI:** OpenAI, Claude, Gemini API support (optional, needs API keys)
- **Audio:** AVFoundation

## Build Notes
- The Metal toolchain may need downloading on first build: `xcodebuild -downloadComponent MetalToolchain`
- App Sandbox is disabled (`ENABLE_APP_SANDBOX = NO`) for audio and file access
- The project uses `PBXFileSystemSynchronizedRootGroup` — new files in `IngotEngine/` are auto-discovered by Xcode
- Swift default actor isolation is `MainActor` (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`)

---

## Architecture Overview (6,165 lines across 44 files)

```
IngotEngine/
├── Core/           ← Engine fundamentals (NO Metal/AppKit imports)
├── Logic/          ← Behavior rules + JavaScript scripting
├── Physics/        ← AABB collision detection & resolution
├── Platform/       ← OS-specific: input, audio, AI API calls
├── Rendering/      ← Metal shaders (.metal)
├── Scene/          ← Node tree, node types, serialization
└── AppShell/       ← macOS editor UI (AppKit)
```

### The Golden Rule
`Engine.swift` imports ONLY `Foundation`. It never touches Metal, AppKit, or UIKit. This enables headless mode (unit tests, CI, server-side simulation without a GPU).

### Frame Loop Order (§8 of the blueprint)
```
time → input → behavior → scene update → physics → animation → camera → render → audio
```
Implemented in `Engine.step(deltaTime:)`. The renderer (`ViewportViewController`) calls this, then reads the scene tree to draw.

---

## Directory Details

### Core/ (11 files)
| File | What it does |
|------|-------------|
| `Engine.swift` | The orchestrator. Owns GameClock, PhysicsWorld, AudioManager, MusicPlayer, TweenManager. `step()` runs the frame loop. `isPlaying` toggles design/play mode. |
| `GameClock.swift` | Tracks deltaTime, totalTime, fixed-step accumulator for deterministic physics. |
| `Math.swift` | `orthographicProjection()`, `translationMatrix()`, `rotationMatrix()`, `scaleMatrix()` — all return `simd_float4x4`. |
| `ProjectManager.swift` | Singleton. Manages project directory (Assets/, Scenes/, Scripts/). Saves/loads scenes as JSON. Manages project.json manifest. |
| `ProjectFile.swift` | Codable struct for `project.json`: gameName, entryScene, designWidth/Height, asset registry. |
| `Tween.swift` | Property interpolation: `Tween(from:to:duration:easing:setter:)`. TweenManager auto-removes completed tweens. |
| `FrameAnimation.swift` | Grid-based sprite sheet animation. `AnimationBehavior` drives frame cycling on SpriteNodes. |
| `AssetHandle.swift` | Type-safe `AssetHandle<T>` with string IDs. Phantom types: `TextureAsset`, `SoundAsset`. |
| `Log.swift` | Leveled logging (debug/info/warning/error) with optional editor chat sink. |
| `Node+JSExport.swift` | JSExport protocol bridging Node properties (x, y, name, zoom, setFrame) to JavaScript. |
| `AIConfiguration.swift` | `AIProvider` enum + `AISettings` struct for LLM/asset API keys. |

### Logic/ (4 files)
| File | What it does |
|------|-------------|
| `Behavior.swift` | The event-action rule system. Events: `onActionHeld`, `everyFrame`, `onStart`, `onCollision`, `onSignal`. Actions: `move`, `rotate`, `emitSignal`, `playSound`, `setProperty`, `destroy`. |
| `ScriptBehavior.swift` | Loads `.js` lifecycle files from Scripts/. Evaluates ONCE at load, then calls `Script.update(node, dt, time)` each frame via `JSValue.invokeMethod`. Injects `InputManager.shared` as `Input` into JS context. |
| `Signal.swift` | Observer pattern: array of closures, `emit()` calls all. |
| `EventBus.swift` | Global singleton pub/sub. `connect(to: "Collision") { ... }`, `emit("Collision")`. |

### Scene/ (11 files)
| File | What it does |
|------|-------------|
| `Node.swift` | Base class (extends NSObject for JSExport). Has: name, position/rotation/scale, parent/children, behaviors, physicsBody, isEnabled, groups. Computes localTransform and globalTransform. `update()` fires `ready()` once, runs behaviors, recurses children. Skips disabled nodes. |
| `SpriteNode.swift` | Textured quad with UV rect for sprite sheets. `setSpriteSheetFrame(gridWidth:gridHeight:column:row:)`. Placeholder texture support for async loading. |
| `CameraNode.swift` | Has `zoom`. Renderer inverts its globalTransform to produce the view matrix. |
| `ShapeNode.swift` | Colored rectangle (no texture file needed). Generates a 1×1 solid-color MTLTexture from its RGBA `color` property. |
| `TextNode.swift` | Renders text via Core Text → NSImage → MTLTexture. Regenerates only when text/font/color changes. |
| `AudioNode.swift` | Positional sound source with soundFile, playOnStart, loops, volume. |
| `CollisionNode.swift` | Invisible trigger zone. Has triggerSize and triggerSignal. Auto-creates a static PhysicsBody. |
| `Scene.swift` | Owns rootNode tree + activeCamera. `findNode(named:)`, `findNodes(inGroup:)`. |
| `DemoScene.swift` | Pre-built demo: player with WASD + JS animation, camera follow, 5 walls. |
| `SceneSerializer.swift` | Serializes EVERYTHING to JSON: nodes, transforms, physics, behaviors, scripts, UVs, camera refs. |
| `SceneDeserializer.swift` | Polymorphic deserialization (§12.1). Rebuilds the complete scene from JSON including behaviors and physics bodies. |

### Physics/ (2 files)
| File | What it does |
|------|-------------|
| `PhysicsBody.swift` | AABB body with size, isDynamic, computed boundingBox from globalTransform. |
| `PhysicsWorld.swift` | O(n²) pair check, skips static-vs-static, emits "Collision", resolves by pushing along shortest overlap axis. Fixed timestep via GameClock accumulator. |

### Platform/ (5 files)
| File | What it does |
|------|-------------|
| `InputManager.swift` | Singleton. Maps UInt16 keycodes → string action names. `setKeyPressed()` from viewport, `isActionPressed()` from behaviors/JS. JSExport-compatible. |
| `AudioManager.swift` | Array of AVAudioPlayers for concurrent SFX. `playSound(named:)` and `playSound(from:)`. |
| `MusicPlayer.swift` | Single-track background music with loop/pause/resume/volume. |
| `AssetGenerator.swift` | DALL-E 3 image gen + ElevenLabs sound gen. Saves to project Assets/. |
| `AssetDownloadQueue.swift` | Async asset pipeline: placeholder → background download → main thread swap. Never blocks the render loop. |

### Rendering/ (1 file)
| File | What it does |
|------|-------------|
| `Shaders.metal` | Instanced vertex shader: `viewProjection × model × local`. UV atlas remapping: `finalUV = uvRect.xy + baseUV * uvRect.zw`. Linear-filtered texture sampling. |

### AppShell/ (8 files — the macOS editor)
| File | What it does |
|------|-------------|
| `EditorViewController.swift` | NSSplitViewController root. Owns Engine, wires all panels. NSToolbarDelegate for Save/Load/Play/Export buttons. Manages undo (snapshot-based), AI prompt dispatch, play/stop, save/load, export. |
| `ViewportViewController.swift` | MTKView host. Renders the scene every frame with camera-aware viewProjection matrix. Forwards keyboard to InputManager, handles mouse picking + drag-to-move with undo integration. |
| `SidebarViewController.swift` | NSOutlineView scene hierarchy. SF Symbol icons per node type. Bottom action bar: +/- nodes (7 types), play/stop. |
| `InspectorViewController.swift` | Property editor. Frame-based layout in FlippedView. Sections: Identity (name, enabled), Transform (posX/Y, rotation, scaleX/Y), Script (assign/create .js files). |
| `ChatPanelViewController.swift` | AI copilot UI. Dark monospaced history view with color-coded messages. Prompt field fires onPromptSubmitted. |
| `EventSheetViewController.swift` | Visual scripting surface. Displays behavior rules as When/Do rows. Add/delete rule buttons. |
| `AssetBrowserViewController.swift` | NSTableView file browser showing Assets/, Scripts/, Scenes/ contents with type icons, names, and sizes. |
| `AIEngineBridge.swift` | LLM communication. Builds prompts with scene context, sends to OpenAI/Claude/Gemini, strips markdown, executes JSON commands (updateProperty, generateTexture, generateSound, attachScript, addRule). |
| `ProjectExporter.swift` | Generates .swiftpm packages for iPhone/iPad/Apple TV. Creates Package.swift, GameApp.swift (SwiftUI), GameViewController.swift (Metal+UIKit), copies assets/scripts/shaders. |

---

## Key Patterns

### Single Source of Truth
All panels (sidebar, inspector, viewport, AI copilot) hold references to the SAME Node objects. Mutating `node.position.x` in the inspector is immediately visible in the viewport — no sync needed. `refreshUI()` re-reads the node when something external (AI, undo) changes it.

### Snapshot Undo
`registerUndoSnapshot()` serializes the entire scene to JSON before any edit. Cmd+Z deserializes the snapshot, swaps the root node, re-registers physics, and refreshes all UI panels. Works for human edits, AI commands, and drag operations.

### JavaScript Bridge
Node inherits from NSObject for JSExport compatibility. Properties exposed: `x`, `y`, `name`, `jsZoom`, `setFrame()`. Scripts follow a lifecycle pattern:
```javascript
var Script = {
    start: function(node) { },
    update: function(node, dt, time) { node.x += 100 * dt; }
};
```
The JS file is parsed ONCE. Each frame calls the compiled `update` function.

### Instanced Rendering
All sprites share the same 6-vertex quad. Per-sprite data (transform + uvRect) is packed into a `SpriteData` buffer. One draw call renders all sprites via Metal instancing with `[[instance_id]]`.

### Camera System
CameraNode's globalTransform is inverted to produce the view matrix:
```
viewMatrix = translate(screenCenter) × scale(zoom) × translate(-camPos)
viewProjection = projection × viewMatrix
```
Mouse picking reverses this transform to convert screen coordinates to world space.

---

## Configuration

### AI Provider (in EditorViewController.viewDidLoad)
```swift
aiSettings.provider = .claude
aiSettings.claudeKey = "sk-ant-api03-..."
// or
aiSettings.provider = .openAI
aiSettings.openAIKey = "sk-..."
```

### Input Map (in InputManager.swift)
```swift
var inputMap: [UInt16: String] = [
    123: "move_left",   // ←
    124: "move_right",  // →
    126: "move_up",     // ↑
    125: "move_down",   // ↓
    0: "move_left",     // A
    2: "move_right",    // D
    13: "move_up",      // W
    1: "move_down",     // S
    49: "action",       // Space
]
```

---

## Known Gaps / TODO
1. No `.xcodeproj` generation — export uses `.swiftpm` only
2. No multi-texture rendering — all sprites share one texture binding per draw call
3. No scene instancing (prefabs) — nodes are cloned manually
4. No undo for node add/delete in sidebar (only property edits and AI commands)
5. No file-watching / hot-reload for scripts or assets
6. Texture references use node names, not proper asset IDs
7. Event sheet editor is display-only — no inline editing of rule parameters
8. No z-order / layer sorting control
9. Physics is O(n²) brute force — needs spatial partitioning for large scenes
10. Export doesn't auto-copy engine .swift files — user must copy manually

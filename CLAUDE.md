# Ingot Engine — Developer Handoff Guide

## What is this?
A 2D game engine + editor for macOS, built from scratch with Metal and AppKit. The editor lets you design games visually, script with JavaScript, use AI to generate assets/code/scenes, and export to iPhone/iPad/Apple TV as `.swiftpm` packages with touch controls. The feature set is modeled on Godot (nodes, signals, prefabs, tile maps, particles, timers, camera smoothing, collision layers) with the AI copilot as the primary authoring interface.

## Quick Start
```bash
# Open in Xcode
open IngotEngine.xcodeproj

# Build & Run (Cmd+R)
# On first launch, you'll be prompted to select/create a project folder
# The editor opens with a demo scene (player, particle trail, walls, follow camera)
# Click ▶ in the toolbar to enter Play mode (WASD to move)
```

## Tech Stack
- **Language:** Swift 5 (macOS 26.5+)
- **Rendering:** Metal + MetalKit (MTKView), MSL shaders
- **Math:** simd (simd_float2, simd_float4x4)
- **Scripting:** JavaScriptCore (built-in, no dependencies)
- **Physics:** Custom AABB with spatial-hash broadphase (no external libraries)
- **Editor UI:** AppKit (NSOutlineView, NSSplitViewController, NSToolbar)
- **AI:** OpenAI, Claude, Gemini API support (optional, needs API keys)
- **Audio:** AVFoundation

## Build Notes
- The Metal toolchain may need downloading on first build: `xcodebuild -downloadComponent MetalToolchain`
- App Sandbox is disabled (`ENABLE_APP_SANDBOX = NO`) for audio and file access
- The project uses `PBXFileSystemSynchronizedRootGroup` — new files in `IngotEngine/` are auto-discovered by Xcode
- Swift default actor isolation is `MainActor` (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`)

---

## Architecture Overview (~8,200 lines across 48 files)

```
IngotEngine/
├── Core/           ← Engine fundamentals (NO Metal/AppKit imports)
├── Logic/          ← Behavior rules + JavaScript scripting
├── Physics/        ← AABB collision detection & resolution
├── Platform/       ← OS-specific: input, audio, AI API calls
├── Rendering/      ← Metal shaders (.metal)
├── Scene/          ← Node tree, node types, serialization, prefabs
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
| `Engine.swift` | The orchestrator. Owns GameClock, PhysicsWorld, AudioManager, MusicPlayer, TweenManager. `step()` runs the frame loop and clears per-frame input edges. `isPlaying` toggles design/play mode. Publishes `PhysicsWorld.current` + `Engine.current`. Scene flow: `sceneLoader` (injected by the shell) + `requestScene(named:)` swap scenes safely at end-of-frame and emit "SceneChanged". |
| `GameClock.swift` | Tracks deltaTime, totalTime, fixed-step accumulator for deterministic physics. |
| `Math.swift` | `orthographicProjection()`, `translationMatrix()`, `rotationMatrix()`, `scaleMatrix()` — all return `simd_float4x4`. |
| `ProjectManager.swift` | Singleton. Manages project directory (Assets/, Scenes/, Scripts/, Prefabs/). Saves/loads scenes as JSON. Manages project.json manifest. |
| `ProjectFile.swift` | Codable struct for `project.json`: gameName, entryScene, designWidth/Height, asset registry. |
| `Tween.swift` | Property interpolation: `Tween(from:to:duration:easing:setter:)`. TweenManager auto-removes completed tweens. |
| `FrameAnimation.swift` | Grid-based sprite sheet animation. `AnimationBehavior` drives frame cycling on SpriteNodes. |
| `AssetHandle.swift` | Type-safe `AssetHandle<T>` with string IDs. Phantom types: `TextureAsset`, `SoundAsset`. |
| `Log.swift` | Leveled logging (debug/info/warning/error) with optional editor chat sink. |
| `Node+JSExport.swift` | JSExport bridge: x, y, rotationDegrees, scaleX/Y, zIndexJS, visible, name, jsZoom, setFrame(), getChild(), emitSignal(), setVelocity(), spawn(prefab,x,y), destroy(). |
| `AIConfiguration.swift` | `AIProvider` enum + `AISettings` struct for LLM/asset API keys. |

### Logic/ (4 files)
| File | What it does |
|------|-------------|
| `Behavior.swift` | The event-action rule system. Events: `onActionHeld`, `onActionJustPressed`, `everyFrame`, `onStart`, `onCollision`, `onSignal` (wired to the EventBus — timers/triggers drive rules). Actions: `move`, `rotate`, `emitSignal`, `playSound`, `setProperty`, `setVelocity`, `spawnPrefab`, `changeScene`, `destroy` (unregisters physics). |
| `ScriptBehavior.swift` | Loads `.js` lifecycle files from Scripts/. Evaluates ONCE at load, then calls `Script.update(node, dt, time)` each frame via `JSValue.invokeMethod`. Injects `InputManager.shared` as `Input` into JS context. |
| `Signal.swift` | Observer pattern: array of closures, `emit()` calls all. |
| `EventBus.swift` | Global singleton pub/sub. `connect(to: "Collision") { ... }`, `emit("Collision")`. Collisions also emit per-node `"Collision:<NodeName>"` signals. |

### Scene/ (15 files)
| File | What it does |
|------|-------------|
| `Node.swift` | Base class (extends NSObject for JSExport). Has: name, position/rotation/scale, `zIndex`, parent/children, behaviors, physicsBody, isEnabled, groups, `sceneRoot`. Computes localTransform and globalTransform. `update()` fires `ready()` once, runs behaviors, recurses children. Skips disabled nodes. |
| `SpriteNode.swift` | Textured quad with UV rect for sprite sheets + `modulate` RGBA tint (Godot's modulate). `setSpriteSheetFrame(gridWidth:gridHeight:column:row:)`. Placeholder texture support for async loading. |
| `CameraNode.swift` | Godot Camera2D parity: `zoom`, `followTargetName` + `followSmoothing` (smoothed follow of a named node), `shake(intensity:duration:)`. Renderer inverts its globalTransform to produce the view matrix. |
| `ShapeNode.swift` | Colored rectangle (no texture file needed). Generates a 1×1 solid-color MTLTexture from its RGBA `color` property. |
| `TextNode.swift` | Renders text via CoreText → CGContext → MTLTexture (no AppKit — the same file compiles on iOS/tvOS). Regenerates only when text/font/color changes. |
| `AudioNode.swift` | Positional sound source with soundFile, playOnStart, loops, volume. |
| `CollisionNode.swift` | Invisible trigger zone (Godot Area2D). Its PhysicsBody is `isTrigger` — PhysicsWorld calls `fireTrigger()` on overlap ENTER, emitting `triggerSignal`. |
| `TimerNode.swift` | Godot Timer: waitTime, oneShot, autostart; emits `timeoutSignal` on the EventBus on timeout. |
| `ParticleNode.swift` | Godot CPUParticles2D: CPU-simulated world-space particles with direction/spread/velocity/gravity, scale + color over lifetime, one-shot mode. Rendered as instanced quads with a shared soft-dot texture. |
| `TileMapNode.swift` | Godot TileMap: sparse tile grid over an atlas texture. `setTile`/`fillRect`, `solidTiles` generate static colliders (one PhysicsBody per solid tile via body `offset`). A whole map batches into one draw call. |
| `Prefab.swift` | Godot PackedScene: `PrefabLibrary.save/instantiate/list` (JSON files in Prefabs/), plus `Node.duplicate()`. Spawnable at runtime from rules, JS, and AI commands. |
| `Scene.swift` | Owns rootNode tree + activeCamera. `findNode(named:)`, `findNodes(inGroup:)`. Registers node + tile-map physics bodies. |
| `DemoScene.swift` | Pre-built demo: player with WASD + JS animation, particle trail, smoothed follow camera, 5 walls. |
| `SceneSerializer.swift` | Serializes EVERYTHING to JSON: nodes, transforms, physics, behaviors, scripts, UVs, modulate, particles, tile maps, timers, camera refs. `serializeSubtree` feeds prefabs. |
| `SceneDeserializer.swift` | Polymorphic deserialization (§12.1). Rebuilds the complete scene from JSON including behaviors and physics bodies. `buildRule` is shared with the AI bridge. |

### Physics/ (2 files)
| File | What it does |
|------|-------------|
| `PhysicsBody.swift` | AABB body with size, isDynamic, `velocity` (integrated by the world), `gravityScale`, `isTrigger`, `collisionLayer`/`collisionMask` bitfields, `offset` (for tile colliders), computed boundingBox from globalTransform. |
| `PhysicsWorld.swift` | Fixed-timestep simulation: velocity + gravity integration, spatial-hash broadphase (no more O(n²)), layer/mask filtering, trigger ENTER events, collision events (global + per-node + behavior flags), shortest-axis resolution with velocity kill. `PhysicsWorld.current` lets behaviors register runtime-spawned bodies. |

### Platform/ (5 files)
| File | What it does |
|------|-------------|
| `InputManager.swift` | Singleton. Maps UInt16 keycodes → string action names. `setKeyPressed()` from viewport, `isActionPressed()` + `isActionJustPressed()` from behaviors/JS. `setActionPressed()` for virtual joysticks (used by exported iOS games). JSExport-compatible. |
| `AudioManager.swift` | Array of AVAudioPlayers for concurrent SFX. `playSound(named:)` and `playSound(from:)`. |
| `MusicPlayer.swift` | Single-track background music with loop/pause/resume/volume. |
| `AssetGenerator.swift` | DALL-E 3 image gen + ElevenLabs sound gen. Saves to project Assets/. |
| `AssetDownloadQueue.swift` | Async asset pipeline: placeholder → background download → main thread swap. Never blocks the render loop. |

### Rendering/ (1 file)
| File | What it does |
|------|-------------|
| `Shaders.metal` | Instanced vertex shader: `viewProjection × model × local`. UV atlas remapping: `finalUV = uvRect.xy + baseUV * uvRect.zw`. Per-instance modulate color multiplied in the fragment shader. Linear-filtered texture sampling. |

### AppShell/ (10 files — the macOS editor)
| File | What it does |
|------|-------------|
| `EditorViewController.swift` | NSSplitViewController root. Owns Engine, wires all panels. NSToolbarDelegate for Save/Load/Play/Export buttons. Manages undo (snapshot-based), AI prompt dispatch, play/stop (re-registers physics each play), save/load, runtime scene-loader wiring, tile-paint wiring, export. |
| `ViewportViewController.swift` | MTKView host. Flattens the scene (sprites + tiles + particles) into RenderInstances, sorts by zIndex (stable), and draws per-texture instanced batches with `baseInstance` — multi-texture rendering in few draw calls. Dynamic instance buffer grows with the scene. Camera shake applied to the view matrix. Forwards keyboard to InputManager, handles mouse picking + drag-to-move with undo integration, and tile painting (left = paint, right = erase) when the inspector's Paint Mode is on. |
| `SidebarViewController.swift` | NSOutlineView scene hierarchy. SF Symbol icons per node type, double-click renames in place (undoable). Refreshes after AI commands and inspector edits. Bottom action bar: +/- nodes (10 types incl. particles/tile map/timer, with undo), play/stop. |
| `InspectorViewController.swift` | Property editor with dynamic per-type sections — the form is rebuilt per selection so only relevant sections exist (no gaps). Every node type is hand-editable: Identity, Transform, Camera (zoom/follow/smoothing), Shape (color well, size), Text (string/font/color), Sprite (modulate tint), Audio, Trigger, Timer, Particles (full emission config + color wells), Tile Map (atlas/solid tiles/paint controls), Physics (add/edit/remove body), Script. Closure-bound rows: adding a property = one line. |
| `ChatPanelViewController.swift` | AI copilot UI. Dark monospaced history view with color-coded messages. Prompt field fires onPromptSubmitted. |
| `EventSheetViewController.swift` | Visual scripting surface. Displays behavior rules as When/Do rows with edit (✎) and delete buttons; + Add Rule opens the rule editor. |
| `RuleEditorViewController.swift` | Sheet for editing one rule inline: event dropdown + parameter field, editable action rows (type dropdown + up to 3 params), add/remove actions, Save builds the Rule. |
| `AssetBrowserViewController.swift` | NSTableView file browser showing Assets/, Scripts/, Scenes/ contents with type icons, names, and sizes. |
| `AIEngineBridge.swift` | LLM communication. Builds prompts with full scene context + prefab list, sends to OpenAI/Claude/Gemini, strips markdown, executes 20 JSON command types (createNode, deleteNode, updateProperty, setColor, setText, addPhysicsBody, setVelocity, setGravity, configureParticles, configureTileMap, paintTiles, setCameraFollow, configureTimer, savePrefab, spawnPrefab, addToGroup, addRule, attachScript, generateTexture, generateSound). |
| `ProjectExporter.swift` | Generates .swiftpm packages for iPhone/iPad/Apple TV. Creates Package.swift (`.iOSApplication` app product on iPhone/iPad — real installable app with bundle ID/orientations), GameApp.swift (SwiftUI), GameViewController.swift (Metal+UIKit, mirrors the editor renderer incl. tile maps/particles/z-order, design-resolution scaling, runtime scene loader), TouchControls.swift (virtual joystick + action button), ControllerInput.swift (GameController → InputManager, incl. Siri Remote). Copies assets/scripts/prefabs/ALL scenes/shaders, and auto-copies engine sources when `IngotEngineSourcePath` is set. |

---

## Key Patterns

### Single Source of Truth
All panels (sidebar, inspector, viewport, AI copilot) hold references to the SAME Node objects. Mutating `node.position.x` in the inspector is immediately visible in the viewport — no sync needed. `refreshUI()` re-reads the node when something external (AI, undo) changes it.

### Snapshot Undo
`registerUndoSnapshot()` serializes the entire scene to JSON before any edit. Cmd+Z deserializes the snapshot, swaps the root node, re-registers physics, and refreshes all UI panels. Works for human edits, AI commands, and drag operations.

### JavaScript Bridge
Node inherits from NSObject for JSExport compatibility. Scripts follow a lifecycle pattern:
```javascript
var Script = {
    start: function(node) { },
    update: function(node, dt, time) {
        if (Input.isActionJustPressed("action")) node.setVelocity(0, 600); // jump
        node.x += 100 * dt;
    }
};
```
The JS file is parsed ONCE. Each frame calls the compiled `update` function.
Node API: `x`, `y`, `rotationDegrees`, `scaleX/Y`, `zIndexJS`, `visible`, `name`, `jsZoom`, `setFrame()`, `getChild(name)`, `emitSignal(name)`, `setVelocity(x,y)`, `spawn(prefab,x,y)`, `changeScene(name)`, `destroy()`.

### Batched Multi-Texture Rendering
All quads share the same 6-vertex geometry. The scene (sprites, tiles, particles) is flattened into a per-frame instance list, z-sorted, and drawn as one instanced draw call per texture run (`baseInstance` keeps `[[instance_id]]` aligned with the shared buffer). A 1,000-tile map with one atlas costs one draw call.

### Signals Everywhere (Godot-style)
`TimerNode` timeout → EventBus signal → `onSignal` rule fires actions. `CollisionNode` overlap-enter → `triggerSignal`. Collisions → `"Collision"` + `"Collision:<NodeName>"`. Any rule can `emitSignal` for others to hear. This is the decoupling backbone for AI-generated game logic.

### Prefab Workflow
Save any subtree as a prefab (`PrefabLibrary.save`), then instantiate it from the AI (`spawnPrefab`), from rules (the `spawnPrefab` action — e.g. a Timer signal spawning enemy waves), or from JS (`node.spawn("Enemy", x, y)`). Runtime spawns auto-register their physics bodies through `PhysicsWorld.current`.

### Camera System
CameraNode's globalTransform is inverted to produce the view matrix:
```
viewMatrix = translate(screenCenter) × scale(zoom) × translate(-camPos - shakeOffset)
viewProjection = projection × viewMatrix
```
Mouse picking reverses this transform to convert screen coordinates to world space. Set `followTargetName` + `followSmoothing` for Camera2D-style smoothed tracking.

### Scene Flow (menu → level 1 → level 2)
Any rule (`changeScene` action), JS call (`node.changeScene("Level2")`), or AI command can request a scene change. The Engine applies it at END of frame via the injected `sceneLoader` — the editor loads from Scenes/, exported games from their bundled Resources/Scenes/ (the exporter copies every saved scene). "SceneChanged" + "SceneChanged:<name>" fire on the EventBus.

### iOS-First Export
Exported games run the exact same engine code (all Scene/Logic/Physics/Core files are AppKit-free). The generated `TouchControls` overlay maps the left half of the screen to a virtual joystick and the right half to the action button, feeding the same `InputManager` action names the editor keyboard uses — behaviors and scripts run unchanged on iPhone/iPad. To make exports build out of the box, point the exporter at the engine sources once:
```bash
defaults write <editor-bundle-id> IngotEngineSourcePath /path/to/IngotEngine/IngotEngine
```

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
On iOS these same action names are driven by the exported TouchControls overlay.

### Physics (per scene, settable via AI "setGravity")
```swift
engine.physicsWorld.gravity = simd_float2(0, -980)  // platformer
engine.physicsWorld.gravity = simd_float2(0, 0)     // top-down (default)
```

---

## Known Gaps / TODO
1. No `.xcodeproj` generation — export uses `.swiftpm` only (the iPhone/iPad package is a runnable `.iOSApplication` app, though)
2. No file-watching / hot-reload for scripts or assets
3. Texture references use node names, not proper asset IDs
4. Dynamic-vs-dynamic collisions detect but don't resolve
5. EventBus connections are never disconnected (weak-captured no-ops accumulate across scene reloads)
6. No headless unit-test suite / CI yet (the engine core is GPU-free by design, so this is cheap to add)
7. Tile paint mode has no atlas-preview palette — the paint tile is chosen by index
8. Exported app icon uses the platform default (set one in Xcode after export)

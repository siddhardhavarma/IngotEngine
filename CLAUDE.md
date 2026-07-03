# Ingot Engine — Developer Handoff Guide

## What is this?
A 2D game engine + editor for macOS, built from scratch with Metal and AppKit. The editor lets you design games visually, script with JavaScript, use AI to generate assets/code/scenes, and export to iPhone/iPad/Apple TV as `.swiftpm` packages with touch controls. The feature set is modeled on Godot (nodes, signals, prefabs, tile maps, particles, timers, camera smoothing, collision layers) with the AI copilot as the primary authoring interface.

## Quick Start
```bash
# Open in Xcode
open IngotEngine.xcodeproj

# Build & Run (Cmd+R)
# The Project Launcher opens first (recent projects / New Project / Open)
# Choosing a project opens the editor with a demo scene (player, particle
# trail, walls, follow camera)
# Click ▶ in the toolbar to enter Play mode (WASD to move)
# Set AI provider + API keys via the ✦ AI Settings toolbar button
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
| `ProjectFile.swift` | Codable struct for `project.json`: gameName, entryScene (what exports boot into), lastOpenedScene (editor session restore), designWidth/Height, asset registry. |
| `Tween.swift` | Property interpolation: `Tween(from:to:duration:easing:setter:)`. TweenManager auto-removes completed tweens. |
| `FrameAnimation.swift` | Grid-based sprite sheet animation. `AnimationBehavior` drives frame cycling on SpriteNodes. |
| `AssetHandle.swift` | Type-safe `AssetHandle<T>` with string IDs. Phantom types: `TextureAsset`, `SoundAsset`. |
| `Log.swift` | Leveled logging (debug/info/warning/error) with optional editor chat sink. |
| `AnimationLibrary.swift` | Character-based sprite animations (Godot SpriteFrames-ish): `AnimationClip` (character, own sprite-sheet `textureName`, grid, frame range, fps, loop) stored per project in animations.json, keyed by "Character/clip". Playing a clip SWAPS the sprite's texture to the clip's sheet (via `SpriteNode.textureResolver`, injected by the shell). Played via `node.playAnimation("run_left")` / `("Player/run_left")` (JS), the playAnimation rule action, AI commands, or a sprite's auto-playing `defaultAnimationName`. |
| `Node+JSExport.swift` | JSExport bridge: x, y, rotationDegrees, scaleX/Y, zIndexJS, visible, name, jsZoom, setFrame(), getChild(), emitSignal(), setVelocity(), spawn(prefab,x,y), destroy(). |
| `AIConfiguration.swift` | `AIProvider` enum + `AISettings` struct: provider, per-provider model IDs (user-editable), API keys. `load()`/`save()` persist preferences to UserDefaults and keys to the Keychain. |

### Logic/ (4 files)
| File | What it does |
|------|-------------|
| `Behavior.swift` | The event-action rule system. Events: `onActionHeld`, `onActionJustPressed`, `everyFrame`, `onStart`, `onCollision`, `onSignal` (wired to the EventBus — timers/triggers drive rules). Actions: `move`, `rotate`, `emitSignal`, `playSound`, `setProperty`, `setVelocity`, `spawnPrefab`, `playAnimation`, `changeScene`, `destroy` (unregisters physics). |
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
| `KeychainStore.swift` | Minimal Keychain wrapper (generic-password items) for API keys — secrets never live in source, project files, or exports. |

### Rendering/ (1 file)
| File | What it does |
|------|-------------|
| `Shaders.metal` | Instanced vertex shader: `viewProjection × model × local`. UV atlas remapping: `finalUV = uvRect.xy + baseUV * uvRect.zw`. Per-instance modulate color multiplied in the fragment shader. Linear-filtered texture sampling. |

### AppShell/ (15 files — the macOS editor)

Editor layout (three columns, organized "what exists → what you see → what it is"):
```
┌───────────────┬──────────────────────────┬─────────────────┐
│ SCENE         │                          │ INSPECTOR       │
│ HIERARCHY     │        VIEWPORT          │ (per-type)      │
├───────────────┤──────────────────────────├─────────────────┤
│ ASSET LIBRARY │ LOGIC: Event Sheet |     │ ✦ AI COPILOT    │
│ import/assign │        Script Editor     │ (always open)   │
└───────────────┴──────────────────────────┴─────────────────┘
Toolbar: Save · Scenes ▾ · Animations · ▶ Play · Project · ✦ AI Settings · Export
```

State model (Godot-style — manual Save is never *required*):
- The editor reopens `lastOpenedScene` on launch (fresh projects save the demo as the entry scene immediately)
- Pressing ▶ Play saves the scene first; switching scenes saves the one you leave; quitting persists everything (`persistSession()`)
- project.json = settings (name, design size, entry scene — edited via the Project toolbar sheet); animations.json = clips; Scenes/, Scripts/, Prefabs/, Assets/ = everything else

| File | What it does |
|------|-------------|
| `ProjectLauncherViewController.swift` | The startup window (Godot-style project manager): recent projects list (UserDefaults-backed, double-click to open), New Project… (save panel creates the folder), Open Existing…. AppDelegate opens the editor after a project is chosen. |
| `AssetLibraryViewController.swift` | Left-dock asset hub: Import… accepts files AND folders (recursed, flattened) and copies png/jpg/wav/mp3 into Assets/; list shows real image thumbnails, filter popup (All/Art/Audio/Scripts/Prefabs/Animations). Double-click assigns: texture → selected Sprite/TileMap (records `textureName`), audio → selected AudioNode, script → assigned to selection AND opened in the Script Editor, prefab → placed in the scene, animation → opens the Animations window. |
| `ScriptEditorViewController.swift` | Built-in code editor tab: script picker + New/Save, JS syntax highlighting + line-number ruler, Save hot-reloads every ScriptBehavior using the file (live during Play). AI assist bar rewrites the script from a natural-language request, grounded in the full engine scripting reference + current scene nodes. |
| `AISettingsViewController.swift` | Settings sheet (✦ toolbar): provider picker, per-provider model ID fields, secure API-key fields (stored in Keychain), readiness status. |
| `AnimationEditorViewController.swift` | The Animations window (toolbar button), character-based: character popup + New Character…, the selected character's clips (+/−), per-clip fields incl. its OWN sprite sheet, and a live preview playing from that sheet. Saves to animations.json. |
| `ProjectSettingsViewController.swift` | Project sheet (gear toolbar button): game name, design resolution, entry scene picker — writes project.json. |
| `EditorViewController.swift` | NSSplitViewController root building the three-column layout above. Owns Engine, wires all panels. Toolbar: Save, Scenes ▾ (switch scene — auto-saves the one you leave — plus New Scene…), Play/Stop, ✦ AI Settings, Export. Manages undo (snapshot-based), AI prompt dispatch, the project texture cache (loads Assets/ files by `textureName` on scene load), asset assignment, prefab placement, tile-paint wiring, runtime scene-loader wiring. |
| `ViewportViewController.swift` | MTKView host. Flattens the scene (sprites + tiles + particles) into RenderInstances, sorts by zIndex (stable), and draws per-texture instanced batches with `baseInstance` — multi-texture rendering in few draw calls. Design-mode editor camera: scroll pans, pinch zooms, Cmd+0 resets to the game camera (Play mode always uses the game camera + shake). Forwards keyboard to InputManager, handles mouse picking + drag-to-move with undo integration, and tile painting (left = paint, right = erase). |
| `SidebarViewController.swift` | NSOutlineView scene hierarchy. SF Symbol icons per node type, double-click renames in place (undoable). Refreshes after AI commands and inspector edits. Bottom action bar: +/- nodes (10 types incl. particles/tile map/timer, with undo), play/stop. |
| `InspectorViewController.swift` | Property editor with dynamic per-type sections — the form is rebuilt per selection so only relevant sections exist (no gaps). Every node type is hand-editable: Identity (incl. Save as Prefab), Transform, Camera (zoom/follow/smoothing), Shape (color well, size), Text (string/font/color), Sprite (modulate tint), Audio, Trigger, Timer, Particles (full emission config + color wells), Tile Map (atlas/solid tiles/paint controls), Physics (add/edit/remove body), Script. Closure-bound rows: adding a property = one line. |
| `ChatPanelViewController.swift` | AI copilot panel (right dock, always visible). Adaptive color-coded history, selection-context header ("Selected: Player"), busy spinner while requests run, errors in red. Prompt field fires onPromptSubmitted. |
| `EventSheetViewController.swift` | Visual scripting surface. Displays behavior rules as When/Do rows with edit (✎) and delete buttons; + Add Rule opens the rule editor. |
| `RuleEditorViewController.swift` | Sheet for editing one rule inline: event dropdown + parameter field, editable action rows (type dropdown + up to 3 params), add/remove actions, Save builds the Rule. |
| `AssetBrowserViewController.swift` | (Superseded by AssetLibraryViewController — no longer wired into the layout; kept for reference.) |
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
Node API: `x`, `y`, `rotationDegrees`, `scaleX/Y`, `zIndexJS`, `visible`, `name`, `jsZoom`, `setFrame()`, `getChild(name)`, `emitSignal(name)`, `setVelocity(x,y)`, `spawn(prefab,x,y)`, `playAnimation(clip)`, `stopAnimation()`, `changeScene(name)`, `destroy()`.

### Animation Workflow (character-based)
In the Animations window: New Character… ("Player"), then define each clip it performs (idle_up, run_left, …) with its OWN sprite sheet, grid, frame range, fps, loop — live preview plays from the clip's sheet. Because the sheet is saved on the clip, `node.playAnimation("run_left")` swaps the sprite's texture to run_left.png automatically (use "Player/run_left" if two characters share a clip name). Clips live in animations.json and travel into exports. Play from JS, rules (playAnimation action), AI (`defineAnimation` with character/textureName, `setDefaultAnimation`, `playAnimation`), or auto-play via the sprite's Animation field.

### AI Conversation Memory
The copilot sends a rolling window of the last few exchanges ("User: …" / "Executed: …") with each prompt, so follow-ups like "make it bigger" resolve against what was just built.

### Batched Multi-Texture Rendering
All quads share the same 6-vertex geometry. The scene (sprites, tiles, particles) is flattened into a per-frame instance list, z-sorted, and drawn as one instanced draw call per texture run (`baseInstance` keeps `[[instance_id]]` aligned with the shared buffer). A 1,000-tile map with one atlas costs one draw call.

### Signals Everywhere (Godot-style)
`TimerNode` timeout → EventBus signal → `onSignal` rule fires actions. `CollisionNode` overlap-enter → `triggerSignal`. Collisions → `"Collision"` + `"Collision:<NodeName>"`. Any rule can `emitSignal` for others to hear. This is the decoupling backbone for AI-generated game logic.

### Asset Workflow (import → assign → persist → export)
Import… in the Asset Library copies files into Assets/. Double-clicking a texture assigns it to the selected Sprite/TileMap and records `textureName` on the node; the serializer persists it, the editor reloads it from Assets/ on scene load (cached per file), and exported games resolve the same name from their bundled resources. Audio files assign to AudioNodes the same way.

### Prefab Workflow
Save any subtree as a prefab ("Save as Prefab" in the Inspector, or the AI's `savePrefab`), then instantiate it by double-clicking it in the Asset Library, from the AI (`spawnPrefab`), from rules (the `spawnPrefab` action — e.g. a Timer signal spawning enemy waves), or from JS (`node.spawn("Enemy", x, y)`). Runtime spawns auto-register their physics bodies through `PhysicsWorld.current`.

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

### AI Provider (✦ AI Settings in the toolbar)
Pick the provider (OpenAI / Claude / Gemini), optionally change the model ID
(defaults: `gpt-4o`, `claude-sonnet-5`, `gemini-2.5-flash`), and paste API
keys. Keys go to the macOS Keychain; provider/model choices to UserDefaults.
Nothing is hardcoded in source anymore — `AISettings.load()` restores the
configuration at launch.

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

## Testing & CI
- `swift test` at the repo root runs the headless engine tests (the root Package.swift compiles Core/Logic/Physics/Scene/Platform as a library — no GPU needed). Suites: serialization round-trips, physics (gravity/resolution/triggers/layers), behaviors & input edges, tile maps, animations, prefabs.
- `.github/workflows/ci.yml` runs `swift test` plus a full `xcodebuild` of the editor app on every push/PR.

## Known Gaps / TODO
1. No `.xcodeproj` generation — export uses `.swiftpm` only (the iPhone/iPad package is a runnable `.iOSApplication` app, though)
2. No file-watching for EXTERNAL script/asset edits (the built-in Script Editor does hot-reload on save, but changes made in other apps aren't noticed)
3. Dynamic-vs-dynamic collisions detect but don't resolve
4. EventBus connections are never disconnected (weak-captured no-ops accumulate across scene reloads)
5. Tile paint mode has no atlas-preview palette — the paint tile is chosen by index
6. Exported app icon uses the platform default (set one in Xcode after export)

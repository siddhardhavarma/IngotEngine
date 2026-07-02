//
//  CameraNode.swift
//  IngotEngine
//
//  A Node subclass that defines the rendering viewpoint.
//
//  The camera's position and zoom determine what part of the world
//  is visible on screen. Moving the camera pans the view; changing
//  zoom magnifies or shrinks the visible area.
//
//  In the rendering pipeline, the camera's transform is inverted to
//  produce a View Matrix. This is because a camera moving RIGHT
//  must shift all rendered vertices to the LEFT — see the explanation
//  in ViewportViewController.swift.
//
//  Godot Camera2D parity: the camera can follow a named node with
//  optional smoothing (position_smoothing), and supports screen shake.
//

import Foundation
import simd

class CameraNode: Node {

    /// Zoom factor. 1.0 = default. 2.0 = 2x magnification (see less of
    /// the world). 0.5 = zoom out (see more of the world).
    var zoom: Float = 1.0

    // MARK: - Follow (Godot Camera2D position smoothing)

    /// Name of the node to follow. nil = no following (manual camera).
    /// An alternative to parenting the camera under the target: a
    /// followed camera can lag smoothly behind instead of being rigid.
    var followTargetName: String?

    /// How quickly the camera catches up to its target, per second.
    /// 0 = snap instantly. ~5 = smooth chase. Higher = tighter.
    var followSmoothing: Float = 0

    // MARK: - Shake

    /// Current shake offset, applied by the renderer on top of the
    /// camera position. Decays to zero over the shake duration.
    private(set) var shakeOffset = simd_float2(0, 0)

    private var shakeIntensity: Float = 0
    private var shakeRemaining: Float = 0
    private var shakeDuration: Float = 0
    private var shakeClock: Float = 0

    override init() {
        super.init()
        name = "Camera"
    }

    /// Starts a screen shake: `intensity` pixels of displacement,
    /// decaying linearly over `duration` seconds.
    func shake(intensity: Float, duration: Float) {
        shakeIntensity = intensity
        shakeDuration = max(duration, 0.01)
        shakeRemaining = shakeDuration
    }

    override func update(deltaTime: CFTimeInterval, input: InputManager) {
        guard isEnabled else { return }
        super.update(deltaTime: deltaTime, input: input)

        let dt = Float(deltaTime)

        // --- Follow target ---
        if let targetName = followTargetName,
           let target = resolveTarget(named: targetName) {
            let targetWorld = target.globalTransform.columns.3
            var desired = simd_float2(targetWorld.x, targetWorld.y)

            // Convert world → this camera's parent space (assumes the
            // parent chain is unrotated/unscaled — true for cameras
            // parented to the scene root, the common case).
            if let parent = parent {
                let parentWorld = parent.globalTransform.columns.3
                desired -= simd_float2(parentWorld.x, parentWorld.y)
            }

            if followSmoothing <= 0 {
                position = desired
            } else {
                let t = min(followSmoothing * dt, 1)
                position += (desired - position) * t
            }
        }

        // --- Shake decay ---
        if shakeRemaining > 0 {
            shakeRemaining = max(shakeRemaining - dt, 0)
            shakeClock += dt
            let decay = shakeRemaining / shakeDuration
            let strength = shakeIntensity * decay
            // Deterministic wobble: two incommensurate frequencies read
            // as noise without needing a random source every frame.
            shakeOffset = simd_float2(sin(shakeClock * 47) * strength,
                                      cos(shakeClock * 31) * strength)
        } else {
            shakeOffset = simd_float2(0, 0)
        }
    }

    private func resolveTarget(named name: String) -> Node? {
        let root = sceneRoot
        if root.name == name { return root }
        let target = root.findChild(named: name)
        return target === self ? nil : target
    }

    /// JS-accessible zoom property (overrides the no-op base).
    override var jsZoom: Float {
        get { zoom }
        set { zoom = newValue }
    }
}

//
//  ParticleNode.swift
//  IngotEngine
//
//  §4.4 Scene System — A CPU-simulated 2D particle emitter.
//
//  Modeled after Godot's CPUParticles2D. Particles are simulated on the
//  CPU in world space (so a moving emitter leaves a trail) and rendered
//  through the existing instanced sprite pipeline — each live particle
//  becomes one instance with its own transform and modulate color.
//
//  Uses: explosions, sparkles, smoke, rain, pickup effects, thrusters.
//

import MetalKit
import simd

class ParticleNode: Node {

    /// One live particle. Position/velocity are in WORLD space.
    struct Particle {
        var position: simd_float2
        var velocity: simd_float2
        var rotation: Float
        var angularVelocity: Float
        var life: Float          // Seconds remaining.
        var maxLife: Float       // Total lifetime for interpolation.
    }

    // MARK: - Emission configuration (Godot CPUParticles2D parity)

    /// Whether the emitter is currently spawning new particles.
    var emitting: Bool = true

    /// Target number of live particles (spawn rate = amount / lifetime).
    var amount: Int = 32

    /// How long each particle lives, in seconds.
    var lifetime: Float = 1.0

    /// If true, emits `amount` particles once, then stops emitting.
    var oneShot: Bool = false

    /// Base emission direction in degrees (0 = +X, 90 = +Y).
    var direction: Float = 90

    /// Random cone around `direction`, in degrees (180 = full circle).
    var spread: Float = 45

    /// Initial particle speed in pixels/second.
    var initialVelocity: Float = 200

    /// Random variation applied to initial speed (0–1 fraction).
    var velocityRandomness: Float = 0.3

    /// Constant acceleration applied to every particle (pixels/s²).
    var gravity = simd_float2(0, -300)

    /// Particle quad size in pixels at the start / end of its life.
    var startScale: Float = 12
    var endScale: Float = 2

    /// Modulate color at the start / end of a particle's life (RGBA 0–1).
    var startColor = simd_float4(1, 1, 1, 1)
    var endColor = simd_float4(1, 1, 1, 0)

    /// Spin applied to each particle, in degrees/second (randomized ±).
    var angularVelocityDegrees: Float = 0

    // MARK: - Simulation state

    private(set) var particles: [Particle] = []
    private var spawnAccumulator: Float = 0
    private var oneShotEmitted = 0

    override init() {
        super.init()
        name = "Particles"
    }

    /// Restarts emission from scratch (also re-arms one-shot emitters).
    func restart() {
        particles.removeAll()
        spawnAccumulator = 0
        oneShotEmitted = 0
        emitting = true
    }

    // MARK: - Per-frame simulation

    override func update(deltaTime: CFTimeInterval, input: InputManager) {
        guard isEnabled else { return }
        super.update(deltaTime: deltaTime, input: input)

        let dt = Float(deltaTime)

        // --- Spawn new particles ---
        if emitting {
            if oneShot {
                while oneShotEmitted < amount {
                    spawnParticle()
                    oneShotEmitted += 1
                }
                emitting = false
            } else {
                spawnAccumulator += dt * Float(amount) / max(lifetime, 0.01)
                while spawnAccumulator >= 1 {
                    spawnAccumulator -= 1
                    if particles.count < amount * 2 { spawnParticle() }
                }
            }
        }

        // --- Advance and cull ---
        for i in particles.indices {
            particles[i].velocity += gravity * dt
            particles[i].position += particles[i].velocity * dt
            particles[i].rotation += particles[i].angularVelocity * dt
            particles[i].life -= dt
        }
        particles.removeAll { $0.life <= 0 }
    }

    private func spawnParticle() {
        let origin = globalTransform.columns.3
        let halfSpread = spread / 2
        let angleDegrees = direction + Float.random(in: -halfSpread...halfSpread)
        let angle = angleDegrees * .pi / 180

        let speedJitter = 1 + Float.random(in: -velocityRandomness...velocityRandomness)
        let speed = initialVelocity * speedJitter

        let spinRange = abs(angularVelocityDegrees) * .pi / 180
        let spin = spinRange > 0 ? Float.random(in: -spinRange...spinRange) : 0

        particles.append(Particle(
            position: simd_float2(origin.x, origin.y),
            velocity: simd_float2(cos(angle), sin(angle)) * speed,
            rotation: 0,
            angularVelocity: spin,
            life: lifetime,
            maxLife: lifetime
        ))
    }

    // MARK: - Per-particle rendering helpers

    /// Progress through the particle's life, 0 (born) → 1 (dying).
    private func progress(of particle: Particle) -> Float {
        1 - max(particle.life, 0) / max(particle.maxLife, 0.01)
    }

    /// Interpolated modulate color for a particle.
    func color(of particle: Particle) -> simd_float4 {
        let t = progress(of: particle)
        return startColor + (endColor - startColor) * t
    }

    /// Interpolated quad size (pixels) for a particle.
    func size(of particle: Particle) -> Float {
        let t = progress(of: particle)
        return max(startScale + (endScale - startScale) * t, 0.1)
    }

    /// World-space model matrix for a particle. The shared quad is 100
    /// units (±50), so scale = size / 100.
    func modelMatrix(of particle: Particle) -> simd_float4x4 {
        let t = translationMatrix(tx: particle.position.x, ty: particle.position.y)
        let r = rotationMatrix(angle: particle.rotation)
        let s = size(of: particle) / 100.0
        return t * r * scaleMatrix(sx: s, sy: s)
    }

    // MARK: - Particle texture (soft radial dot, generated once per device)

    private static var cachedTexture: MTLTexture?
    private static var cachedDevice: MTLDevice?

    /// A 32×32 soft circular gradient texture shared by all emitters.
    /// Tinted per-particle via the instance modulate color.
    static func particleTexture(device: MTLDevice) -> MTLTexture? {
        if let cached = cachedTexture, cachedDevice === device {
            return cached
        }

        let side = 32
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: side, height: side, mipmapped: false
        )
        descriptor.usage = .shaderRead

        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let center = Float(side - 1) / 2
        for y in 0..<side {
            for x in 0..<side {
                let dx = (Float(x) - center) / center
                let dy = (Float(y) - center) / center
                let dist = sqrt(dx * dx + dy * dy)
                // Soft falloff: opaque center, transparent edge.
                let alpha = max(0, min(1, 1 - dist))
                let a = UInt8(alpha * alpha * 255)
                let i = (y * side + x) * 4
                pixels[i] = 255; pixels[i + 1] = 255; pixels[i + 2] = 255; pixels[i + 3] = a
            }
        }
        texture.replace(region: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0,
                        withBytes: pixels, bytesPerRow: side * 4)

        cachedTexture = texture
        cachedDevice = device
        return texture
    }
}

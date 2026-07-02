//
//  Tween.swift
//  IngotEngine
//
//  §4.10 Animation System — Property interpolation over time.
//
//  A Tween smoothly transitions a property from a start value to an
//  end value over a duration, with configurable easing. Tweens are
//  attached to nodes via behaviors or the animation system.
//
//  Usage:
//    let tween = Tween(from: 0, to: 100, duration: 1.0, easing: .easeInOut) { value in
//        node.position.x = value
//    }
//

import Foundation

/// Easing functions that control the acceleration curve of the interpolation.
enum EasingFunction {
    case linear
    case easeIn
    case easeOut
    case easeInOut

    func apply(_ t: Float) -> Float {
        switch self {
        case .linear:    return t
        case .easeIn:    return t * t
        case .easeOut:   return t * (2 - t)
        case .easeInOut:
            if t < 0.5 {
                return 2 * t * t
            } else {
                return -1 + (4 - 2 * t) * t
            }
        }
    }
}

class Tween {

    let from: Float
    let to: Float
    let duration: Float
    let easing: EasingFunction
    let setter: (Float) -> Void

    /// Optional callback fired when the tween completes.
    var onComplete: (() -> Void)?

    private(set) var elapsed: Float = 0
    private(set) var isComplete: Bool = false

    init(from: Float, to: Float, duration: Float,
         easing: EasingFunction = .linear, setter: @escaping (Float) -> Void) {
        self.from = from
        self.to = to
        self.duration = max(duration, 0.001)  // Prevent division by zero.
        self.easing = easing
        self.setter = setter
    }

    /// Advances the tween by deltaTime seconds. Returns true if still running.
    @discardableResult
    func update(deltaTime: Float) -> Bool {
        guard !isComplete else { return false }

        elapsed += deltaTime

        let t = min(elapsed / duration, 1.0)
        let easedT = easing.apply(t)
        let value = from + (to - from) * easedT

        setter(value)

        if t >= 1.0 {
            isComplete = true
            onComplete?()
            return false
        }

        return true
    }
}

/// Manages a collection of active tweens, auto-removing completed ones.
class TweenManager {

    private var activeTweens: [Tween] = []

    func add(_ tween: Tween) {
        activeTweens.append(tween)
    }

    /// Advances all tweens and removes completed ones.
    func update(deltaTime: Float) {
        activeTweens.removeAll { tween in
            !tween.update(deltaTime: deltaTime)
        }
    }

    var count: Int { activeTweens.count }
}

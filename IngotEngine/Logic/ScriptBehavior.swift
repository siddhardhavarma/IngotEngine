//
//  ScriptBehavior.swift
//  IngotEngine
//
//  A Behavior that loads and runs a JavaScript lifecycle component file.
//
//  Script files live in the project's Scripts/ directory and follow
//  a standard lifecycle pattern:
//
//    var Script = {
//        start: function(node) {
//            // Called once when the behavior starts.
//        },
//        update: function(node, dt, time) {
//            // Called every frame.
//        }
//    };
//
//  WHY FILE-BASED LIFECYCLE SCRIPTING PREVENTS RE-PARSING 60x/SEC:
//
//  The old approach called context.evaluateScript(code) every frame.
//  evaluateScript parses the JS string into an AST, compiles it to
//  bytecode, and executes it — all 60 times per second. For a 50-line
//  script, that's thousands of wasted parse/compile cycles.
//
//  The new approach evaluates the file ONCE at load time. This produces
//  a compiled Script object with pre-compiled start/update functions.
//  Each frame, we call the already-compiled update function via
//  JSValue.call(withArguments:), which is a simple function invocation —
//  no parsing, no compilation, just execution. This is the same
//  difference as running a compiled .exe vs. re-compiling from source
//  every frame.
//

import Foundation
import JavaScriptCore

class ScriptBehavior: Behavior {

    /// The name of the .js file in the project's Scripts/ directory.
    var scriptName: String

    /// The JSContext — one per behavior so scripts don't interfere.
    let context: JSContext

    /// The compiled Script object extracted from the JS file.
    /// Contains .start and .update function references.
    private var scriptObject: JSValue?

    /// Accumulated elapsed time for the `time` parameter.
    private var elapsedTime: Float = 0

    init(scriptName: String) {
        self.scriptName = scriptName
        self.context = JSContext()!

        super.init(rules: [])

        context.exceptionHandler = { _, exception in
            if let error = exception {
                print("JS Error [\(scriptName)]: \(error)")
            }
        }

        // Inject the InputManager into JS as "Input".
        // JS scripts can query: Input.isActionPressed("move_left")
        context.setObject(InputManager.shared, forKeyedSubscript: "Input" as NSString)

        loadScript()
    }

    /// Loads and evaluates the .js file from the project's Scripts/ directory.
    /// The file is parsed and compiled ONCE. The resulting Script object
    /// is stored as a JSValue for repeated function calls.
    private func loadScript() {
        guard let scriptsDir = ProjectManager.shared.scriptsURL else {
            print("ScriptBehavior: No project open, cannot load \(scriptName)")
            return
        }

        let fileName = scriptName.hasSuffix(".js") ? scriptName : "\(scriptName).js"
        let fileURL = scriptsDir.appendingPathComponent(fileName)

        guard let code = try? String(contentsOf: fileURL, encoding: .utf8) else {
            print("ScriptBehavior: Could not read \(fileURL.path)")
            return
        }

        // Evaluate the entire file ONCE. This parses + compiles + executes
        // the top-level code, which defines the Script object.
        context.evaluateScript(code)

        // Extract the Script object. It contains .start and .update methods.
        scriptObject = context.objectForKeyedSubscript("Script" as NSString)

        if scriptObject?.isUndefined == true {
            print("ScriptBehavior: \(scriptName) does not define a 'Script' object.")
            scriptObject = nil
        }
    }

    /// Reloads the script from disk. Called when the user edits the file.
    func reload() {
        scriptObject = nil
        elapsedTime = 0
        hasStarted = false
        loadScript()
    }

    // MARK: - Lifecycle

    /// Called once by the behavior system. Invokes Script.start(node).
    override func start() {
        guard let owner = owner, let script = scriptObject else { return }

        context.setObject(owner, forKeyedSubscript: "node" as NSString)
        script.invokeMethod("start", withArguments: [owner])
    }

    /// Called every frame. Invokes Script.update(node, dt, time).
    override func update(deltaTime: CFTimeInterval, input: InputManager) {
        guard let owner = owner, let script = scriptObject else { return }

        let dt = Float(deltaTime)
        elapsedTime += dt

        script.invokeMethod("update", withArguments: [owner, dt, elapsedTime])
    }
}

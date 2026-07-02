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

import simd

class CameraNode: Node {

    /// Zoom factor. 1.0 = default. 2.0 = 2x magnification (see less of
    /// the world). 0.5 = zoom out (see more of the world).
    var zoom: Float = 1.0

    override init() {
        super.init()
        name = "Camera"
    }

    /// JS-accessible zoom property (overrides the no-op base).
    override var jsZoom: Float {
        get { zoom }
        set { zoom = newValue }
    }
}

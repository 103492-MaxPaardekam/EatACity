//
//  GameScene.swift
//  EatACity
//
//  Created by Max Paardekam on 3/26/26.
//

import SceneKit
import AVFoundation
#if os(iOS) || os(tvOS)
import UIKit
private typealias PlatformColor = UIColor
#else
import AppKit
private typealias PlatformColor = NSColor

// NSColor lacks the UIColor-style init(red:green:blue:alpha:) convenience init.
// This extension bridges the gap so all PlatformColor(red:green:blue:alpha:) calls
// in this file compile on macOS without any conditional code at each call site.
private extension NSColor {
    convenience init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.init(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}
#endif

// MARK: - Physics Categories

private enum Physics {
    static let ground:   Int = 1 << 0
    static let building: Int = 1 << 1
}

// MARK: - Object Tier
//
//  Objects have tiers based on size. The hole must grow to a minimum
//  radius before tier 3 and tier 4 objects can be eaten. Locked objects
//  glow orange/red to signal they are not yet eatable; they pulse green
//  when the hole finally grows large enough to reach their tier.

private enum ObjectTier {
    case small   // always eatable (props, bollards)
    case medium  // eatable from start (normal buildings)
    case large   // unlocks at holeRadius ≥ 5.0
    case giant   // unlocks at holeRadius ≥ 9.0

    var unlockRadius: Float {
        switch self {
        case .small, .medium: return 0
        case .large:          return 5.0
        case .giant:          return 9.0
        }
    }

    /// Emissive tint applied to locked tier 3 / 4 objects at spawn time.
    var lockedEmissive: PlatformColor? {
        switch self {
        case .small, .medium: return nil
        case .large: return PlatformColor(red: 1.0, green: 0.55, blue: 0.0, alpha: 1)
        case .giant: return PlatformColor(red: 0.9,  green: 0.1,  blue: 0.1, alpha: 1)
        }
    }
}

private struct CityObjectInfo {
    let node: SCNNode
    let objectRadius: Float
    let tier: ObjectTier
}

// MARK: - Game Scene

final class GameScene: SCNScene {

    // MARK: - Public

    var cameraNode: SCNNode!
    var holeNode: SCNNode!
    var onScoreUpdate: ((Int, Float) -> Void)?
    var onTimerUpdate: ((Int) -> Void)?
    var onGameOver: (() -> Void)?

    // MARK: - Private

    private var holeRadius: Float = 1.5
    private var score: Int = 0
    private var cityObjectInfos: [CityObjectInfo] = []
    private var particleNode: SCNNode!
    private var gameTimer: Timer?
    private var timeRemaining: Int = 120
    private var isGameActive: Bool = true

    // Tier unlock tracking
    private var tier3Unlocked = false
    private var tier4Unlocked = false
    private var tier3Nodes: [SCNNode] = []
    private var tier4Nodes: [SCNNode] = []

    // Audio
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var audioReady = false

    // MARK: - Init

    override init() {
        super.init()
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        gameTimer?.invalidate()
        if audioEngine.isRunning { audioEngine.stop() }
    }

    // MARK: - Scene Setup

    private func setup() {
        physicsWorld.gravity = SCNVector3(0, -9.8, 0)
        setupLighting()
        setupGround()
        setupHole()
        setupCamera()
        spawnCity()
        setupAudio()
        startTimer()
    }

    private func setupLighting() {
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 500
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        rootNode.addChildNode(ambientNode)

        let sun = SCNLight()
        sun.type = .directional
        sun.intensity = 1200
        sun.color = PlatformColor(red: 1.0, green: 0.97, blue: 0.92, alpha: 1.0)
        sun.castsShadow = true
        sun.shadowRadius = 4
        sun.shadowColor = PlatformColor(white: 0, alpha: 0.25)
        let sunNode = SCNNode()
        sunNode.light = sun
        sunNode.eulerAngles = SCNVector3(-Float.pi / 3.5, Float.pi / 4, 0)
        rootNode.addChildNode(sunNode)
    }

    private func setupGround() {
        let groundGeo = SCNBox(width: 200, height: 0.5, length: 200, chamferRadius: 0)
        groundGeo.firstMaterial?.diffuse.contents = PlatformColor(red: 0.22, green: 0.52, blue: 0.18, alpha: 1)
        let groundNode = SCNNode(geometry: groundGeo)
        groundNode.position = SCNVector3(0, -0.25, 0)
        let groundBody = SCNPhysicsBody(type: .static, shape: nil)
        groundBody.categoryBitMask = Physics.ground
        groundBody.collisionBitMask = Physics.building
        groundNode.physicsBody = groundBody
        rootNode.addChildNode(groundNode)

        let roadMat = SCNMaterial()
        roadMat.diffuse.contents = PlatformColor(red: 0.28, green: 0.28, blue: 0.28, alpha: 1)
        for iz in stride(from: -40, through: 40, by: 10) {
            let geo = SCNBox(width: 200, height: 0.05, length: 2.5, chamferRadius: 0)
            geo.materials = [roadMat]
            let node = SCNNode(geometry: geo)
            node.position = SCNVector3(0, 0.01, Float(iz))
            rootNode.addChildNode(node)
        }
        for ix in stride(from: -40, through: 40, by: 10) {
            let geo = SCNBox(width: 2.5, height: 0.05, length: 200, chamferRadius: 0)
            geo.materials = [roadMat]
            let node = SCNNode(geometry: geo)
            node.position = SCNVector3(Float(ix), 0.01, 0)
            rootNode.addChildNode(node)
        }
    }

    private func setupHole() {
        holeNode = SCNNode()
        holeNode.name = "hole"
        holeNode.position = SCNVector3(0, 0.02, 0)

        particleNode = SCNNode()
        holeNode.addChildNode(particleNode)

        buildHoleVisual()
        rootNode.addChildNode(holeNode)
    }

    private func buildHoleVisual() {
        holeNode.enumerateChildNodes { child, _ in
            if child !== particleNode { child.removeFromParentNode() }
        }

        let r = CGFloat(holeRadius)

        let pit = SCNCylinder(radius: r, height: 0.08)
        pit.firstMaterial?.diffuse.contents = PlatformColor(white: 0.04, alpha: 1)
        holeNode.addChildNode(SCNNode(geometry: pit))

        let rim = SCNTorus(ringRadius: r, pipeRadius: 0.15)
        rim.firstMaterial?.diffuse.contents = PlatformColor.black
        let rimNode = SCNNode(geometry: rim)
        rimNode.position.y = 0.04
        holeNode.addChildNode(rimNode)
    }

    private func setupCamera() {
        cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.zFar = 300
        cameraNode.position = SCNVector3(0, 25, 18)

        let lookAt = SCNLookAtConstraint(target: holeNode)
        lookAt.isGimbalLockEnabled = true
        cameraNode.constraints = [lookAt]

        rootNode.addChildNode(cameraNode)
    }

    // MARK: - Audio

    private func setupAudio() {
        audioEngine.attach(playerNode)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)
        do {
            try audioEngine.start()
            audioReady = true
        } catch {
            // Game continues without audio.
        }
    }

    /// Plays a procedurally synthesised eat sound.
    /// Pitch and duration scale with the size of the eaten object.
    /// Haptic feedback fires regardless of audio availability.
    private func playEatSound(radius: Float) {
        #if os(iOS) || os(tvOS)
        let style: UIImpactFeedbackGenerator.FeedbackStyle =
            radius > 3.5 ? .heavy : (radius > 1.0 ? .medium : .light)
        UIImpactFeedbackGenerator(style: style).impactOccurred()
        #endif

        guard audioReady else { return }

        let sampleRate: Double = 44100
        let duration: Double  = radius > 3.5 ? 0.5 : 0.2
        let baseFreq: Double  = radius > 6.0 ? 55 : (radius > 3.5 ? 85 : (radius > 1.0 ? 140 : 210))
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount

        if let ch = buffer.floatChannelData?[0] {
            for i in 0..<Int(frameCount) {
                let t   = Double(i) / sampleRate
                let env = pow(Swift.max(0.0, 1.0 - t / duration), 1.5)
                ch[i]   = Float(sin(2 * .pi * baseFreq * t) * env * 0.45)
            }
        }

        playerNode.scheduleBuffer(buffer, completionHandler: nil)
        if !playerNode.isPlaying { playerNode.play() }
    }

    // MARK: - Timer

    private func startTimer() {
        gameTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.timeRemaining -= 1
            self.onTimerUpdate?(self.timeRemaining)
            if self.timeRemaining <= 0 {
                self.gameTimer?.invalidate()
                self.gameTimer = nil
                self.isGameActive = false
                self.onGameOver?()
            }
        }
    }

    // MARK: - City Spawning

    private static let buildingColors: [PlatformColor] = [
        PlatformColor(red: 0.78, green: 0.78, blue: 0.82, alpha: 1),
        PlatformColor(red: 0.65, green: 0.72, blue: 0.78, alpha: 1),
        PlatformColor(red: 0.82, green: 0.68, blue: 0.58, alpha: 1),
        PlatformColor(red: 0.58, green: 0.68, blue: 0.80, alpha: 1),
        PlatformColor(red: 0.72, green: 0.80, blue: 0.65, alpha: 1),
        PlatformColor(red: 0.90, green: 0.85, blue: 0.70, alpha: 1),
    ]

    private static let skyscraperColors: [PlatformColor] = [
        PlatformColor(red: 0.20, green: 0.30, blue: 0.50, alpha: 1),
        PlatformColor(red: 0.30, green: 0.20, blue: 0.45, alpha: 1),
        PlatformColor(red: 0.15, green: 0.35, blue: 0.40, alpha: 1),
    ]

    private func spawnCity() {
        let step: Float = 10
        for gx in stride(from: -30.0 as Float, through: 30.0, by: step) {
            for gz in stride(from: -30.0 as Float, through: 30.0, by: step) {
                if abs(gx) < 5 && abs(gz) < 5 { continue }
                for _ in 0..<Int.random(in: 2...4) {
                    spawnBuilding(
                        x: gx + Float.random(in: -3.5...3.5),
                        z: gz + Float.random(in: -3.5...3.5)
                    )
                }
            }
        }
        // Landmarks every 20 units — large set pieces
        for gx in stride(from: -30.0 as Float, through: 30.0, by: 20.0) {
            for gz in stride(from: -30.0 as Float, through: 30.0, by: 20.0) {
                if abs(gx) < 10 && abs(gz) < 10 { continue }
                spawnLandmark(
                    x: gx + Float.random(in: -4...4),
                    z: gz + Float.random(in: -4...4)
                )
            }
        }
        // Street props
        for _ in 0..<130 {
            spawnProp(
                x: Float.random(in: -38...38),
                z: Float.random(in: -38...38)
            )
        }
    }

    // Normal buildings — tier small / medium
    private func spawnBuilding(x: Float, z: Float) {
        let w = Float.random(in: 1.0...3.2)
        let h = Float.random(in: 2.5...8.5)
        let d = Float.random(in: 1.0...3.2)
        let r = max(w, d) / 2

        let geo = SCNBox(width: CGFloat(w), height: CGFloat(h), length: CGFloat(d), chamferRadius: 0.08)
        let mat = SCNMaterial()
        mat.diffuse.contents = GameScene.buildingColors.randomElement()!
        geo.materials = [mat]

        let node = SCNNode(geometry: geo)
        node.name = "cityObject"
        node.position = SCNVector3(x, h / 2, z)
        let body = SCNPhysicsBody(type: .static, shape: nil)
        body.categoryBitMask = Physics.building
        body.collisionBitMask = Physics.ground | Physics.building
        node.physicsBody = body

        register(node: node, radius: r, tier: r < 1.5 ? .small : .medium)
    }

    // Large set pieces — tier large / giant
    private func spawnLandmark(x: Float, z: Float) {
        let choice = Int.random(in: 0...3)
        let node: SCNNode
        let objRadius: Float
        let tier: ObjectTier

        switch choice {

        case 0: // Tall skyscraper
            let w = Float.random(in: 4.0...6.5)
            let h = Float.random(in: 18.0...30.0)
            let d = Float.random(in: 4.0...6.5)
            objRadius = max(w, d) / 2
            tier = objRadius >= 4.5 ? .giant : .large

            let geo = SCNBox(width: CGFloat(w), height: CGFloat(h), length: CGFloat(d), chamferRadius: 0.15)
            let mat = SCNMaterial()
            mat.diffuse.contents = GameScene.skyscraperColors.randomElement()!
            if let e = tier.lockedEmissive { mat.emission.contents = e.withAlphaComponent(0.35) }
            geo.materials = [mat]
            node = SCNNode(geometry: geo)
            node.position = SCNVector3(x, h / 2, z)

        case 1: // Wide hotel / mall
            let w = Float.random(in: 6.0...9.0)
            let h = Float.random(in: 5.0...9.0)
            let d = Float.random(in: 5.0...8.0)
            objRadius = max(w, d) / 2
            tier = objRadius >= 4.5 ? .giant : .large

            let geo = SCNBox(width: CGFloat(w), height: CGFloat(h), length: CGFloat(d), chamferRadius: 0.2)
            let mat = SCNMaterial()
            mat.diffuse.contents = PlatformColor(red: 0.82, green: 0.75, blue: 0.65, alpha: 1)
            if let e = tier.lockedEmissive { mat.emission.contents = e.withAlphaComponent(0.35) }
            geo.materials = [mat]
            node = SCNNode(geometry: geo)
            node.position = SCNVector3(x, h / 2, z)

        case 2: // Water tower
            objRadius = 1.8
            tier = .large
            node = SCNNode()

            for i in 0..<4 {
                let angle = Float(i) * .pi / 2
                let legGeo = SCNCylinder(radius: 0.15, height: 4)
                legGeo.firstMaterial?.diffuse.contents = PlatformColor(red: 0.55, green: 0.42, blue: 0.28, alpha: 1)
                let legNode = SCNNode(geometry: legGeo)
                legNode.position = SCNVector3(cos(angle) * 1.2, 2, sin(angle) * 1.2)
                node.addChildNode(legNode)
            }

            let tankGeo = SCNCylinder(radius: 1.5, height: 2.5)
            let tankMat = SCNMaterial()
            tankMat.diffuse.contents = PlatformColor(red: 0.55, green: 0.42, blue: 0.28, alpha: 1)
            if let e = tier.lockedEmissive { tankMat.emission.contents = e.withAlphaComponent(0.35) }
            tankGeo.materials = [tankMat]
            let tankNode = SCNNode(geometry: tankGeo)
            tankNode.position.y = 5.25
            node.addChildNode(tankNode)

            let roofGeo = SCNCone(topRadius: 0, bottomRadius: 1.6, height: 1.2)
            roofGeo.firstMaterial?.diffuse.contents = PlatformColor(red: 0.38, green: 0.28, blue: 0.18, alpha: 1)
            let roofNode = SCNNode(geometry: roofGeo)
            roofNode.position.y = 7.1
            node.addChildNode(roofNode)
            node.position = SCNVector3(x, 0, z)

        default: // Church with bell tower
            objRadius = 2.2
            tier = .large
            node = SCNNode()

            let bodyGeo = SCNBox(width: 4, height: 6, length: 5, chamferRadius: 0.1)
            bodyGeo.firstMaterial?.diffuse.contents = PlatformColor(red: 0.88, green: 0.86, blue: 0.82, alpha: 1)
            let bodyNode = SCNNode(geometry: bodyGeo)
            bodyNode.position.y = 3
            node.addChildNode(bodyNode)

            let towerGeo = SCNBox(width: 1.8, height: 10, length: 1.8, chamferRadius: 0.1)
            let towerMat = SCNMaterial()
            towerMat.diffuse.contents = PlatformColor(red: 0.85, green: 0.83, blue: 0.78, alpha: 1)
            if let e = tier.lockedEmissive { towerMat.emission.contents = e.withAlphaComponent(0.35) }
            towerGeo.materials = [towerMat]
            let towerNode = SCNNode(geometry: towerGeo)
            towerNode.position = SCNVector3(0, 5, -1.5)
            node.addChildNode(towerNode)

            let spireGeo = SCNCone(topRadius: 0, bottomRadius: 0.9, height: 3)
            spireGeo.firstMaterial?.diffuse.contents = PlatformColor(red: 0.25, green: 0.50, blue: 0.25, alpha: 1)
            let spireNode = SCNNode(geometry: spireGeo)
            spireNode.position = SCNVector3(0, 11.5, -1.5)
            node.addChildNode(spireNode)
            node.position = SCNVector3(x, 0, z)
        }

        node.name = "cityObject"
        let body = SCNPhysicsBody(type: .static, shape: nil)
        body.categoryBitMask = Physics.building
        body.collisionBitMask = Physics.ground
        node.physicsBody = body

        register(node: node, radius: objRadius, tier: tier)
    }

    // Small props — 8 types: tree, car, bench, lamp post, mailbox,
    // fire hydrant, dumpster, bollard
    private func spawnProp(x: Float, z: Float) {
        let type = Int.random(in: 0...7)
        let node: SCNNode
        let objRadius: Float

        switch type {

        case 0: // Tree
            let h = Float.random(in: 0.9...1.8)
            let trunkGeo = SCNCylinder(radius: 0.1, height: CGFloat(h * 0.5))
            trunkGeo.firstMaterial?.diffuse.contents =
                PlatformColor(red: 0.38, green: 0.24, blue: 0.10, alpha: 1)
            let trunk = SCNNode(geometry: trunkGeo)
            trunk.position.y = h * 0.25

            let canopyGeo = SCNSphere(radius: CGFloat(h * 0.45))
            canopyGeo.firstMaterial?.diffuse.contents = PlatformColor(
                red: CGFloat.random(in: 0.12...0.22),
                green: CGFloat.random(in: 0.45...0.62),
                blue: CGFloat.random(in: 0.10...0.20),
                alpha: 1
            )
            let canopy = SCNNode(geometry: canopyGeo)
            canopy.position.y = h * 0.80

            node = SCNNode()
            node.addChildNode(trunk)
            node.addChildNode(canopy)
            node.position = SCNVector3(x, 0, z)
            objRadius = h * 0.35

        case 1: // Car
            let carColors: [PlatformColor] = [
                .systemRed, .systemBlue, .yellow, .white,
                .systemOrange, .systemGreen, .systemTeal
            ]
            let geo = SCNBox(width: 1.2, height: 0.5, length: 0.65, chamferRadius: 0.1)
            geo.firstMaterial?.diffuse.contents = carColors.randomElement()!
            node = SCNNode(geometry: geo)
            node.position = SCNVector3(x, 0.25, z)
            node.eulerAngles.y = Float.random(in: 0...(.pi * 2))
            objRadius = 0.6

        case 2: // Park bench
            node = SCNNode()
            let seatGeo = SCNBox(width: 1.0, height: 0.1, length: 0.4, chamferRadius: 0.02)
            seatGeo.firstMaterial?.diffuse.contents =
                PlatformColor(red: 0.48, green: 0.34, blue: 0.22, alpha: 1)
            let seat = SCNNode(geometry: seatGeo)
            seat.position.y = 0.4
            node.addChildNode(seat)
            for lx: Float in [-0.4, 0.4] {
                let legGeo = SCNCylinder(radius: 0.04, height: 0.4)
                legGeo.firstMaterial?.diffuse.contents = PlatformColor.darkGray
                let leg = SCNNode(geometry: legGeo)
                leg.position = SCNVector3(lx, 0.2, 0)
                node.addChildNode(leg)
            }
            node.position = SCNVector3(x, 0, z)
            node.eulerAngles.y = Float.random(in: 0...(.pi * 2))
            objRadius = 0.5

        case 3: // Lamp post
            node = SCNNode()
            let poleGeo = SCNCylinder(radius: 0.06, height: 2.5)
            poleGeo.firstMaterial?.diffuse.contents = PlatformColor.darkGray
            let pole = SCNNode(geometry: poleGeo)
            pole.position.y = 1.25
            node.addChildNode(pole)
            let lampGeo = SCNSphere(radius: 0.18)
            lampGeo.firstMaterial?.diffuse.contents = PlatformColor.white
            lampGeo.firstMaterial?.emission.contents =
                PlatformColor(red: 1.0, green: 0.95, blue: 0.7, alpha: 1)
            let lamp = SCNNode(geometry: lampGeo)
            lamp.position.y = 2.6
            node.addChildNode(lamp)
            node.position = SCNVector3(x, 0, z)
            objRadius = 0.2

        case 4: // Mailbox
            node = SCNNode()
            let postGeo = SCNCylinder(radius: 0.05, height: 0.9)
            postGeo.firstMaterial?.diffuse.contents = PlatformColor.darkGray
            let post = SCNNode(geometry: postGeo)
            post.position.y = 0.45
            node.addChildNode(post)
            let boxGeo = SCNBox(width: 0.4, height: 0.3, length: 0.25, chamferRadius: 0.05)
            boxGeo.firstMaterial?.diffuse.contents =
                PlatformColor(red: 0.2, green: 0.35, blue: 0.7, alpha: 1)
            let mailbox = SCNNode(geometry: boxGeo)
            mailbox.position.y = 1.05
            node.addChildNode(mailbox)
            node.position = SCNVector3(x, 0, z)
            node.eulerAngles.y = Float.random(in: 0...(.pi * 2))
            objRadius = 0.25

        case 5: // Fire hydrant
            let geo = SCNCylinder(radius: 0.18, height: 0.5)
            geo.firstMaterial?.diffuse.contents = PlatformColor(red: 0.85, green: 0.15, blue: 0.10, alpha: 1)
            node = SCNNode(geometry: geo)
            node.position = SCNVector3(x, 0.25, z)
            objRadius = 0.2

        case 6: // Dumpster
            let geo = SCNBox(width: 1.2, height: 0.85, length: 0.7, chamferRadius: 0.05)
            geo.firstMaterial?.diffuse.contents =
                PlatformColor(red: 0.15, green: 0.45, blue: 0.20, alpha: 1)
            node = SCNNode(geometry: geo)
            node.position = SCNVector3(x, 0.425, z)
            node.eulerAngles.y = Float.random(in: 0...(.pi * 2))
            objRadius = 0.65

        default: // Bollard
            let geo = SCNCylinder(radius: 0.12, height: 0.6)
            geo.firstMaterial?.diffuse.contents =
                PlatformColor(red: 0.72, green: 0.70, blue: 0.68, alpha: 1)
            node = SCNNode(geometry: geo)
            node.position = SCNVector3(x, 0.3, z)
            objRadius = 0.15
        }

        node.name = "cityObject"
        let body = SCNPhysicsBody(type: .static, shape: nil)
        body.categoryBitMask = Physics.building
        body.collisionBitMask = Physics.ground
        node.physicsBody = body

        register(node: node, radius: objRadius, tier: .small)
    }

    private func register(node: SCNNode, radius: Float, tier: ObjectTier) {
        cityObjectInfos.append(CityObjectInfo(node: node, objectRadius: radius, tier: tier))
        rootNode.addChildNode(node)
        if tier == .large { tier3Nodes.append(node) }
        if tier == .giant { tier4Nodes.append(node) }
    }

    // MARK: - Hole Movement

    func moveHole(dx: Float, dz: Float) {
        guard isGameActive else { return }

        let speed: Float = 0.035
        let bound: Float = 40
        holeNode.position.x = max(-bound, min(bound, holeNode.position.x + dx * speed))
        holeNode.position.z = max(-bound, min(bound, holeNode.position.z + dz * speed))

        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.1
        cameraNode.position = SCNVector3(holeNode.position.x, 25, holeNode.position.z + 18)
        SCNTransaction.commit()

        checkEating()
    }

    // MARK: - Eating Detection

    private func checkEating() {
        let hx = holeNode.position.x
        let hz = holeNode.position.z
        var toEat: [CityObjectInfo] = []

        for info in cityObjectInfos {
            guard info.node.parent != nil else { continue }
            guard info.objectRadius < holeRadius else { continue }
            let dx = info.node.position.x - hx
            let dz = info.node.position.z - hz
            if (dx * dx + dz * dz) < (holeRadius * holeRadius) {
                toEat.append(info)
            }
        }

        toEat.forEach { eat($0) }
    }

    private func eat(_ info: CityObjectInfo) {
        cityObjectInfos.removeAll { $0.node === info.node }
        info.node.physicsBody = nil

        let sink = SCNAction.group([
            SCNAction.move(
                to: SCNVector3(holeNode.position.x, -5, holeNode.position.z),
                duration: 0.35
            ),
            SCNAction.scale(to: 0.05, duration: 0.35)
        ])
        info.node.runAction(SCNAction.sequence([sink, .removeFromParentNode()]))

        spawnEatParticles()
        playEatSound(radius: info.objectRadius)

        score += 1
        let growth: Float = info.objectRadius > 3.5 ? 0.3 : (info.objectRadius > 1.0 ? 0.15 : 0.08)
        holeRadius = min(holeRadius + growth, 12.0)
        buildHoleVisual()
        checkTierUnlocks()
        onScoreUpdate?(score, holeRadius)
    }

    // MARK: - Tier Unlocking

    private func checkTierUnlocks() {
        if !tier3Unlocked && holeRadius >= ObjectTier.large.unlockRadius {
            tier3Unlocked = true
            flashUnlockEffect(on: tier3Nodes)
        }
        if !tier4Unlocked && holeRadius >= ObjectTier.giant.unlockRadius {
            tier4Unlocked = true
            flashUnlockEffect(on: tier4Nodes)
        }
    }

    /// Pulses a bright green emissive on the newly unlocked nodes to tell
    /// the player they can now eat these objects.
    private func flashUnlockEffect(on nodes: [SCNNode]) {
        let pulse = SCNAction.sequence([
            SCNAction.customAction(duration: 0.25) { targetNode, elapsed in
                guard targetNode.parent != nil else { return }
                let t = min(1.0, Float(elapsed) / 0.25)
                targetNode.enumerateHierarchy { child, _ in
                    child.geometry?.materials.forEach { mat in
                        mat.emission.contents =
                            PlatformColor(red: 0.1, green: 1.0, blue: 0.3, alpha: CGFloat(t))
                    }
                }
            },
            SCNAction.customAction(duration: 0.25) { targetNode, elapsed in
                guard targetNode.parent != nil else { return }
                let t = min(1.0, Float(elapsed) / 0.25)
                targetNode.enumerateHierarchy { child, _ in
                    child.geometry?.materials.forEach { mat in
                        mat.emission.contents =
                            PlatformColor(red: 0.1, green: 1.0, blue: 0.3, alpha: CGFloat(1.0 - t))
                    }
                }
            }
        ])
        nodes.forEach { node in
            guard node.parent != nil else { return }
            node.runAction(SCNAction.repeat(pulse, count: 3))
        }
    }

    // MARK: - Particle Effects

    /// Fires a one-shot burst of purple sparkles from the hole rim.
    private func spawnEatParticles() {
        for ps in particleNode.particleSystems ?? [] {
            particleNode.removeParticleSystem(ps)
        }

        let ps = SCNParticleSystem()
        ps.birthRate = 450
        ps.emissionDuration = 0.12
        ps.loops = false
        ps.particleLifeSpan = 0.70
        ps.particleLifeSpanVariation = 0.25
        ps.particleVelocity = 3.5
        ps.particleVelocityVariation = 2.0
        ps.particleSize = 0.18
        ps.particleSizeVariation = 0.08
        ps.particleColor = PlatformColor(red: 0.55, green: 0.0, blue: 1.0, alpha: 1)
        ps.particleColorVariation = SCNVector4(0.4, 0.2, 0.2, 0)
        ps.spreadingAngle = 160
        ps.isLightingEnabled = false
        ps.isAffectedByGravity = true
        ps.emitterShape = SCNCylinder(radius: CGFloat(holeRadius * 0.75), height: 0.1)

        particleNode.addParticleSystem(ps)
    }
}



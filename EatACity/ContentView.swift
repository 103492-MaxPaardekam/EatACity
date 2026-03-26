//
//  ContentView.swift
//  EatACity
//
//  Created by Max Paardekam on 3/26/26.
//

import SwiftUI
import SceneKit
import Combine

// MARK: - Game State

final class GameState: ObservableObject {
    @Published var score: Int = 0
    @Published var holeSize: Float = 1.5
    @Published var timeRemaining: Int = 120
    @Published var gameOver: Bool = false
    @Published var restartToken: UUID = UUID()

    static let minHoleSize: Float = 1.5
    static let maxHoleSize: Float = 12.0

    var holeProgress: Float {
        (holeSize - GameState.minHoleSize) / (GameState.maxHoleSize - GameState.minHoleSize)
    }

    var timeString: String {
        String(format: "%d:%02d", timeRemaining / 60, timeRemaining % 60)
    }
}

// MARK: - Content View

struct ContentView: View {
    @StateObject private var gameState = GameState()

    var body: some View {
        ZStack {
            GameView(gameState: gameState)
                .ignoresSafeArea()
                .id(gameState.restartToken)

            if gameState.gameOver {
                gameOverOverlay
            } else {
                hud
            }
        }
    }

    // MARK: - HUD

    private var hud: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                scorePanel
                Spacer()
                timerPanel
                Spacer()
                sizePanel
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Spacer()

            VStack(spacing: 6) {
                progressBar
                Text("Drag to move the hole")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.65))
            }
            .padding(.bottom, 28)
            .padding(.horizontal, 20)
        }
    }

    private var scorePanel: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("SCORE")
                .font(.caption.bold())
                .foregroundColor(.white.opacity(0.75))
            Text("\(gameState.score)")
                .font(.system(size: 34, weight: .black, design: .rounded))
                .foregroundColor(.white)
        }
        .padding(12)
        .background(.black.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var timerPanel: some View {
        VStack(spacing: 2) {
            Text("TIME")
                .font(.caption.bold())
                .foregroundColor(.white.opacity(0.75))
            Text(gameState.timeString)
                .font(.system(size: 30, weight: .bold, design: .monospaced))
                .foregroundColor(gameState.timeRemaining <= 10 ? .red : .white)
        }
        .padding(12)
        .background(.black.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var sizePanel: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("HOLE")
                .font(.caption.bold())
                .foregroundColor(.white.opacity(0.75))
            Text(String(format: "%.1f", gameState.holeSize))
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(.white)
        }
        .padding(12)
        .background(.black.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // Progress bar: shows hole growth from min→max, with tier unlock markers.
    private var progressBar: some View {
        VStack(spacing: 4) {
            HStack {
                Text("SMALL")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white.opacity(0.6))
                Spacer()
                Text("GIANT")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white.opacity(0.6))
            }
            GeometryReader { geo in
                let w = geo.size.width
                // Tier unlock markers at hole sizes 5.0 and 9.0
                let t3 = CGFloat((5.0 - 1.5) / (12.0 - 1.5))
                let t4 = CGFloat((9.0 - 1.5) / (12.0 - 1.5))
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.2))
                        .frame(height: 12)
                    Capsule()
                        .fill(LinearGradient(
                            colors: [.purple, .indigo, .blue, .cyan],
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .frame(
                            width: w * CGFloat(max(0.02, gameState.holeProgress)),
                            height: 12
                        )
                        .animation(.spring(duration: 0.4), value: gameState.holeProgress)
                    // Tier 3 marker
                    Rectangle()
                        .fill(Color.white.opacity(0.75))
                        .frame(width: 2, height: 16)
                        .offset(x: w * t3 - 1, y: -2)
                    // Tier 4 marker
                    Rectangle()
                        .fill(Color.white.opacity(0.75))
                        .frame(width: 2, height: 16)
                        .offset(x: w * t4 - 1, y: -2)
                }
            }
            .frame(height: 16)
        }
        .padding(.horizontal, 4)
        .padding(10)
        .background(.black.opacity(0.40))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Game Over Overlay

    private var gameOverOverlay: some View {
        ZStack {
            Color.black.opacity(0.72)
                .ignoresSafeArea()

            VStack(spacing: 28) {
                Text("TIME'S UP!")
                    .font(.system(size: 44, weight: .black, design: .rounded))
                    .foregroundColor(.white)

                VStack(spacing: 6) {
                    Text("FINAL SCORE")
                        .font(.caption.bold())
                        .foregroundColor(.white.opacity(0.7))
                    Text("\(gameState.score)")
                        .font(.system(size: 80, weight: .black, design: .rounded))
                        .foregroundColor(.yellow)
                }

                Button {
                    gameState.score = 0
                    gameState.holeSize = GameState.minHoleSize
                    gameState.timeRemaining = 120
                    gameState.gameOver = false
                    gameState.restartToken = UUID()
                } label: {
                    Text("PLAY AGAIN")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundColor(.black)
                        .padding(.horizontal, 44)
                        .padding(.vertical, 16)
                        .background(Color.yellow)
                        .clipShape(Capsule())
                }
            }
            .padding(36)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 28))
            .padding(24)
        }
    }
}

// MARK: - SceneKit Game View (cross-platform)

// Shared coordinator handles pan gesture on both iOS and macOS.
final class GameViewCoordinator: NSObject {
    var gameScene: GameScene?
    weak var scnView: SCNView?
    var lastTranslation: CGPoint = .zero
}

// Shared SCNView factory — called by both platform variants.
private func configureScnView(
    _ scnView: SCNView,
    gameState: GameState,
    coordinator: GameViewCoordinator
) {
    let scene = GameScene()

    scene.onScoreUpdate = { score, size in
        DispatchQueue.main.async {
            gameState.score = score
            gameState.holeSize = size
        }
    }
    scene.onTimerUpdate = { time in
        DispatchQueue.main.async {
            gameState.timeRemaining = time
        }
    }
    scene.onGameOver = {
        DispatchQueue.main.async {
            gameState.gameOver = true
        }
    }

    scnView.scene = scene
    scnView.pointOfView = scene.cameraNode
    scnView.allowsCameraControl = false
    scnView.antialiasingMode = .multisampling4X

    coordinator.gameScene = scene
    coordinator.scnView = scnView
}

// MARK: iOS / tvOS

#if os(iOS) || os(tvOS)
struct GameView: UIViewRepresentable {
    @ObservedObject var gameState: GameState

    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView()
        configureScnView(scnView, gameState: gameState, coordinator: context.coordinator)
        scnView.backgroundColor = UIColor(red: 0.53, green: 0.81, blue: 0.98, alpha: 1.0)
        let pan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(GameViewCoordinator.handlePan(_:))
        )
        scnView.addGestureRecognizer(pan)
        return scnView
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}
    func makeCoordinator() -> GameViewCoordinator { GameViewCoordinator() }
}

extension GameViewCoordinator {
    @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let scene = gameScene, let view = scnView else { return }
        let t = gesture.translation(in: view)
        if gesture.state == .began {
            lastTranslation = t
        } else if gesture.state == .changed {
            scene.moveHole(dx: Float(t.x - lastTranslation.x),
                           dz: Float(t.y - lastTranslation.y))
            lastTranslation = t
        }
    }
}

// MARK: macOS

#elseif os(macOS)
struct GameView: NSViewRepresentable {
    @ObservedObject var gameState: GameState

    func makeNSView(context: Context) -> SCNView {
        let scnView = SCNView()
        configureScnView(scnView, gameState: gameState, coordinator: context.coordinator)
        scnView.backgroundColor = NSColor(calibratedRed: 0.53, green: 0.81, blue: 0.98, alpha: 1.0)
        let pan = NSPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(GameViewCoordinator.handlePanMac(_:))
        )
        scnView.addGestureRecognizer(pan)
        return scnView
    }

    func updateNSView(_ nsView: SCNView, context: Context) {}
    func makeCoordinator() -> GameViewCoordinator { GameViewCoordinator() }
}

extension GameViewCoordinator {
    @objc func handlePanMac(_ gesture: NSPanGestureRecognizer) {
        guard let scene = gameScene, let view = scnView else { return }
        let t = gesture.translation(in: view)
        if gesture.state == .began {
            lastTranslation = t
        } else if gesture.state == .changed {
            scene.moveHole(dx: Float(t.x - lastTranslation.x),
                           dz: Float(t.y - lastTranslation.y))
            lastTranslation = t
        }
    }
}
#endif

#Preview {
    ContentView()
}



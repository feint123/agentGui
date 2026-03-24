import AppKit
import SpriteKit

final class AgentCharacterNode: SKNode {
	private enum Constants {
		static let animationKey = "agentStudio.character.animation"
		static let idleMotionKey = "agentStudio.character.idleMotion"
	}

	private let shadowNode = SKSpriteNode(color: NSColor.black.withAlphaComponent(0.14), size: CGSize(width: 24, height: 8))
	private let spriteNode = SKSpriteNode()
	private let nameLabelNode = SKLabelNode(fontNamed: "Menlo")
	private let speechBubbleNode = SpeechBubbleNode()

	private(set) var renderedAnimationState: CharacterAnimationState = .idle
	private(set) var renderedToolName: String?

	override init() {
		super.init()

		shadowNode.position = CGPoint(x: 0, y: -18)
		shadowNode.zPosition = 0
		shadowNode.alpha = 0.7
		addChild(shadowNode)

		spriteNode.zPosition = 2
		spriteNode.setScale(2)
		addChild(spriteNode)

		nameLabelNode.fontSize = 7
		nameLabelNode.fontColor = NSColor(calibratedWhite: 0.18, alpha: 1)
		nameLabelNode.verticalAlignmentMode = .center
		nameLabelNode.horizontalAlignmentMode = .center
		nameLabelNode.position = CGPoint(x: 0, y: -28)
		nameLabelNode.zPosition = 3
		addChild(nameLabelNode)

		speechBubbleNode.zPosition = 4
		addChild(speechBubbleNode)
	}

	required init?(coder aDecoder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	func apply(_ character: AgentCharacterState) {
		renderedToolName = character.currentToolName
		nameLabelNode.text = character.displayName
		speechBubbleNode.apply(character.speechBubble)

		if renderedAnimationState != character.animationState || spriteNode.texture == nil {
			applyAnimation(skin: character.characterSkin, state: character.animationState)
		}

		renderedAnimationState = character.animationState
		applyMotion(for: character.animationState)
	}

	static func atlasName(for skin: CharacterSkin, state: CharacterAnimationState) -> String {
		"\(skin.rawValue)_\(state.rawValue)"
	}

	private func applyAnimation(skin: CharacterSkin, state: CharacterAnimationState) {
		let textures = Self.textures(for: skin, state: state)
		spriteNode.removeAction(forKey: Constants.animationKey)
		spriteNode.texture = textures.first
		spriteNode.size = textures.first?.size() ?? CGSize(width: 16, height: 16)
		spriteNode.texture?.filteringMode = .nearest

		guard textures.count > 1 else {
			return
		}

		let action = SKAction.repeatForever(
			SKAction.animate(with: textures, timePerFrame: Self.frameDuration(for: state), resize: false, restore: true)
		)
		spriteNode.run(action, withKey: Constants.animationKey)
	}

	private func applyMotion(for state: CharacterAnimationState) {
		removeAction(forKey: Constants.idleMotionKey)
		zRotation = 0
		yScale = 1

		let motion: SKAction?
		switch state {
		case .typing:
			motion = SKAction.repeatForever(
				SKAction.sequence([
					SKAction.moveBy(x: 0, y: 1.5, duration: 0.18),
					SKAction.moveBy(x: 0, y: -1.5, duration: 0.18)
				])
			)
		case .thinking, .reading:
			motion = SKAction.repeatForever(
				SKAction.sequence([
					SKAction.moveBy(x: 0, y: 1.5, duration: 0.6),
					SKAction.moveBy(x: 0, y: -1.5, duration: 0.6)
				])
			)
		case .celebrating:
			motion = SKAction.repeatForever(
				SKAction.sequence([
					SKAction.rotate(byAngle: 0.08, duration: 0.14),
					SKAction.rotate(byAngle: -0.16, duration: 0.14),
					SKAction.rotate(byAngle: 0.08, duration: 0.14)
				])
			)
		case .sleeping:
			motion = SKAction.repeatForever(
				SKAction.sequence([
					SKAction.scaleY(to: 0.94, duration: 0.8),
					SKAction.scaleY(to: 1, duration: 0.8)
				])
			)
		case .walking:
			motion = SKAction.repeatForever(
				SKAction.sequence([
					SKAction.moveBy(x: 0.8, y: 0, duration: 0.12),
					SKAction.moveBy(x: -0.8, y: 0, duration: 0.12)
				])
			)
		case .error:
			motion = SKAction.repeatForever(
				SKAction.sequence([
					SKAction.moveBy(x: 1.5, y: 0, duration: 0.06),
					SKAction.moveBy(x: -3, y: 0, duration: 0.06),
					SKAction.moveBy(x: 1.5, y: 0, duration: 0.06),
					SKAction.wait(forDuration: 0.4)
				])
			)
		case .idle:
			motion = SKAction.repeatForever(
				SKAction.sequence([
					SKAction.wait(forDuration: 0.8),
					SKAction.moveBy(x: 0, y: 1, duration: 0.5),
					SKAction.moveBy(x: 0, y: -1, duration: 0.5)
				])
			)
		}

		if let motion {
			run(motion, withKey: Constants.idleMotionKey)
		}
	}

	private static func textures(for skin: CharacterSkin, state: CharacterAnimationState) -> [SKTexture] {
		let atlas = SKTextureAtlas(named: atlasName(for: skin, state: state))
		let names = atlas.textureNames.sorted()

		if !names.isEmpty {
			return names.map {
				let texture = atlas.textureNamed($0)
				texture.filteringMode = .nearest
				return texture
			}
		}

		return [StudioSpriteTextureFactory.placeholderTexture(size: CGSize(width: 16, height: 16), color: .systemBlue)]
	}

	private static func frameDuration(for state: CharacterAnimationState) -> TimeInterval {
		switch state {
		case .typing, .walking:
			return 0.1
		case .celebrating, .error:
			return 0.12
		case .thinking, .reading:
			return 0.18
		case .sleeping:
			return 0.28
		case .idle:
			return 0.22
		}
	}
}

enum StudioSpriteTextureFactory {
	private final class BundleToken {}

	static func officeTexture(named name: String) -> SKTexture {
		if let url = resourceURL(named: name, ext: "png", subdirectory: "office_sprite"),
		   let image = NSImage(contentsOf: url) {
			let texture = SKTexture(image: image)
			texture.filteringMode = .nearest
			return texture
		}

		return placeholderTexture(size: CGSize(width: 16, height: 16), color: .systemGray)
	}

	static func placeholderTexture(size: CGSize, color: NSColor) -> SKTexture {
		let image = NSImage(size: size, flipped: false) { rect in
			color.setFill()
			rect.fill()
			return true
		}
		let texture = SKTexture(image: image)
		texture.filteringMode = .nearest
		return texture
	}

	private static func resourceURL(named name: String, ext: String, subdirectory: String? = nil) -> URL? {
		let bundles = [Bundle.main, Bundle(for: BundleToken.self)] + Bundle.allBundles + Bundle.allFrameworks
		for bundle in bundles {
			if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: subdirectory) {
				return url
			}

			if let url = bundle.url(forResource: name, withExtension: ext) {
				return url
			}
		}

		return nil
	}
}

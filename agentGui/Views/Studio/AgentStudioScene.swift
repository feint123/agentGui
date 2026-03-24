import AppKit
import SpriteKit

final class AgentStudioScene: SKScene {
	static let officeAssetNames = [
		"desk",
		"desk_2",
		"chair",
		"chair_2",
		"bookshelf",
		"tall_bookshelf",
		"wall_clock",
		"big_plant",
		"printer",
		"filing_cabinet_tall",
		"water_dispenser",
		"board",
		"papers"
	]

	private let backgroundLayer = SKNode()
	private let furnitureLayer = SKNode()
	private let characterLayer = SKNode()

	private var hasBuiltOffice = false
	private var characterNodes: [String: AgentCharacterNode] = [:]

	override init(size: CGSize = CGSize(width: 360, height: 220)) {
		super.init(size: size)

		scaleMode = .aspectFit
		anchorPoint = .zero
		backgroundColor = .clear

		backgroundLayer.name = "backgroundLayer"
		furnitureLayer.name = "furnitureLayer"
		characterLayer.name = "characterLayer"

		addChild(backgroundLayer)
		addChild(furnitureLayer)
		addChild(characterLayer)
	}

	required init?(coder aDecoder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	func applyProjection(_ projection: AgentStudioProjection) {
		buildOfficeIfNeeded()
		syncCharacters(with: projection.characters)
	}

	func setRenderingPaused(_ paused: Bool) {
		isPaused = paused
	}

	var renderedCharacterIDs: [String] {
		characterNodes.keys.sorted()
	}

	func characterNode(for id: String) -> AgentCharacterNode? {
		characterNodes[id]
	}

	private func buildOfficeIfNeeded() {
		guard !hasBuiltOffice else {
			return
		}

		hasBuiltOffice = true
		buildBackdrop()
		buildWorkspaceFurniture()
		buildDecorations()
	}

	private func buildBackdrop() {
		let wall = SKShapeNode(rect: CGRect(x: 0, y: 72, width: size.width, height: size.height - 72))
		wall.fillColor = NSColor(calibratedRed: 0.95, green: 0.94, blue: 0.88, alpha: 1)
		wall.strokeColor = NSColor(calibratedWhite: 0.7, alpha: 1)
		wall.lineWidth = 1
		wall.isAntialiased = false
		backgroundLayer.addChild(wall)

		let floor = SKShapeNode(rect: CGRect(x: 0, y: 0, width: size.width, height: 76))
		floor.fillColor = NSColor(calibratedRed: 0.84, green: 0.81, blue: 0.72, alpha: 1)
		floor.strokeColor = NSColor(calibratedWhite: 0.58, alpha: 1)
		floor.lineWidth = 1
		floor.isAntialiased = false
		backgroundLayer.addChild(floor)

		let divider = SKShapeNode(rect: CGRect(x: 0, y: 72, width: size.width, height: 4))
		divider.fillColor = NSColor(calibratedRed: 0.72, green: 0.68, blue: 0.58, alpha: 1)
		divider.strokeColor = divider.fillColor
		divider.isAntialiased = false
		backgroundLayer.addChild(divider)
	}

	private func buildWorkspaceFurniture() {
		for slot in WorkstationSlot.allCases {
			let base = slot.scenePosition
			let deskName = slot.rawValue.isMultiple(of: 2) ? "desk" : "desk_2"
			let chairName = slot.rawValue.isMultiple(of: 2) ? "chair" : "chair_2"

			addFurniture(named: deskName, position: offset(base, dx: 0, dy: 20), scale: 2.0)
			addFurniture(named: chairName, position: offset(base, dx: 0, dy: -2), scale: 2.0)

			if slot.rawValue.isMultiple(of: 3) {
				addFurniture(named: "papers", position: offset(base, dx: 12, dy: 24), scale: 2.0)
			}
		}
	}

	private func buildDecorations() {
		addFurniture(named: "bookshelf", position: CGPoint(x: 24, y: 170), scale: 2.4)
		addFurniture(named: "tall_bookshelf", position: CGPoint(x: 50, y: 170), scale: 2.2)
		addFurniture(named: "big_plant", position: CGPoint(x: 320, y: 160), scale: 2.0)
		addFurniture(named: "printer", position: CGPoint(x: 318, y: 122), scale: 2.0)
		addFurniture(named: "filing_cabinet_tall", position: CGPoint(x: 286, y: 170), scale: 2.0)
		addFurniture(named: "water_dispenser", position: CGPoint(x: 320, y: 84), scale: 2.0)
		addFurniture(named: "board", position: CGPoint(x: 174, y: 186), scale: 2.0)
		addFurniture(named: "wall_clock", position: CGPoint(x: 286, y: 188), scale: 2.0)
	}

	private func addFurniture(named name: String, position: CGPoint, scale: CGFloat) {
		let texture = StudioSpriteTextureFactory.officeTexture(named: name)
		let node = SKSpriteNode(texture: texture)
		node.name = "furniture.\(name).\(UUID().uuidString)"
		node.position = position
		node.size = CGSize(width: texture.size().width * scale, height: texture.size().height * scale)
		node.texture?.filteringMode = .nearest
		node.zPosition = 1000 - position.y
		furnitureLayer.addChild(node)
	}

	private func syncCharacters(with characters: [AgentCharacterState]) {
		let incomingIDs = Set(characters.map(\.id))

		for staleID in characterNodes.keys.filter({ !incomingIDs.contains($0) }) {
			characterNodes[staleID]?.removeFromParent()
			characterNodes.removeValue(forKey: staleID)
		}

		for character in characters {
			let node = characterNodes[character.id] ?? makeCharacterNode(id: character.id)
			node.position = offset(character.workstation.scenePosition, dx: 0, dy: 2)
			node.zPosition = 1200 - character.workstation.scenePosition.y
			node.apply(character)
		}
	}

	private func makeCharacterNode(id: String) -> AgentCharacterNode {
		let node = AgentCharacterNode()
		node.name = "character.\(id)"
		characterNodes[id] = node
		characterLayer.addChild(node)
		return node
	}

	private func offset(_ point: CGPoint, dx: CGFloat, dy: CGFloat) -> CGPoint {
		CGPoint(x: point.x + dx, y: point.y + dy)
	}
}

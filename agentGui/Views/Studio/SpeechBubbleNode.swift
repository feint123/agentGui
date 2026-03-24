import AppKit
import SpriteKit

final class SpeechBubbleNode: SKNode {
    private let backgroundNode = SKShapeNode()
    private let labelNode = SKLabelNode(fontNamed: "Menlo")

    override init() {
        super.init()

        backgroundNode.lineWidth = 1
        backgroundNode.zPosition = 1
        backgroundNode.isAntialiased = false

        labelNode.fontSize = 8
        labelNode.verticalAlignmentMode = .center
        labelNode.horizontalAlignmentMode = .center
        labelNode.zPosition = 2
        labelNode.fontColor = .black

        addChild(backgroundNode)
        addChild(labelNode)

        position = CGPoint(x: 0, y: 36)
        isHidden = true
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ bubble: SpeechBubblePresentation?) {
        guard let bubble, !bubble.text.isEmpty else {
            isHidden = true
            return
        }

        isHidden = false
        labelNode.text = bubble.text

        let width = max(48, min(120, bubble.text.count * 7 + 16))
        let rect = CGRect(x: -width / 2, y: -10, width: width, height: 20)
        backgroundNode.path = CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil)

        switch bubble.kind {
        case .thought:
            backgroundNode.fillColor = NSColor(calibratedWhite: 0.96, alpha: 0.94)
            backgroundNode.strokeColor = NSColor(calibratedWhite: 0.7, alpha: 1)
        case .speech:
            backgroundNode.fillColor = NSColor(calibratedRed: 0.88, green: 0.97, blue: 0.9, alpha: 0.94)
            backgroundNode.strokeColor = NSColor(calibratedRed: 0.2, green: 0.65, blue: 0.28, alpha: 1)
        case .action:
            backgroundNode.fillColor = NSColor(calibratedRed: 0.9, green: 0.94, blue: 1, alpha: 0.95)
            backgroundNode.strokeColor = NSColor(calibratedRed: 0.2, green: 0.4, blue: 0.85, alpha: 1)
        }
    }
}
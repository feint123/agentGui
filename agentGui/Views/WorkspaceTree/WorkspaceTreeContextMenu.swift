import AppKit

enum WorkspaceTreeContextMenuAction: String {
    case previewDiff
    case revealInFinder
    case copyRelativePath
    case newFile
    case newFolder
    case rename
    case delete
}

enum WorkspaceTreeContextMenuFactory {
    static func makeMenu(gitChange: GitFileChange?, target: AnyObject, action: Selector) -> NSMenu {
        let menu = NSMenu()

        if gitChange != nil {
            menu.addItem(item(title: "查看 Diff", action: .previewDiff, target: target, selector: action))
            menu.addItem(.separator())
        }

        menu.addItem(item(title: "在访达中打开", action: .revealInFinder, target: target, selector: action))
        menu.addItem(item(title: "复制相对路径", action: .copyRelativePath, target: target, selector: action))
        menu.addItem(.separator())
        menu.addItem(item(title: "新建文件", action: .newFile, target: target, selector: action))
        menu.addItem(item(title: "新建文件夹", action: .newFolder, target: target, selector: action))
        menu.addItem(item(title: "重命名", action: .rename, target: target, selector: action))
        menu.addItem(item(title: "删除", action: .delete, target: target, selector: action))

        return menu
    }

    private static func item(title: String, action: WorkspaceTreeContextMenuAction, target: AnyObject, selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = target
        item.representedObject = action.rawValue as NSString
        return item
    }
}
import Testing
@testable import agentGui

@Suite("CodeEditorIndentGuideScanner Tests")
struct CodeEditorIndentGuideTests {

    // MARK: - indentLevel (spaces)

    @Test("spaces: 无缩进")
    func spacesLevel0() {
        #expect(CodeEditorIndentGuideScanner.indentLevel(forLinePrefix: "func foo()", indentWidth: 4, useTabs: false) == 0)
    }

    @Test("spaces: 4 空格 = level 1")
    func spacesLevel1() {
        #expect(CodeEditorIndentGuideScanner.indentLevel(forLinePrefix: "    let x = 1", indentWidth: 4, useTabs: false) == 1)
    }

    @Test("spaces: 8 空格 = level 2")
    func spacesLevel2() {
        #expect(CodeEditorIndentGuideScanner.indentLevel(forLinePrefix: "        return x", indentWidth: 4, useTabs: false) == 2)
    }

    @Test("spaces: 2 空格 indentWidth=2")
    func spacesWidth2Level1() {
        #expect(CodeEditorIndentGuideScanner.indentLevel(forLinePrefix: "  let x", indentWidth: 2, useTabs: false) == 1)
    }

    @Test("spaces: 奇数空格向下取整")
    func spacesFloor() {
        // 6 spaces / 4 = 1（不是 1.5）
        #expect(CodeEditorIndentGuideScanner.indentLevel(forLinePrefix: "      x", indentWidth: 4, useTabs: false) == 1)
    }

    // MARK: - indentLevel (tabs)

    @Test("tabs: 无缩进")
    func tabsLevel0() {
        #expect(CodeEditorIndentGuideScanner.indentLevel(forLinePrefix: "func foo()", indentWidth: 4, useTabs: true) == 0)
    }

    @Test("tabs: 1 tab = level 1")
    func tabsLevel1() {
        #expect(CodeEditorIndentGuideScanner.indentLevel(forLinePrefix: "\tlet x = 1", indentWidth: 4, useTabs: true) == 1)
    }

    @Test("tabs: 2 tabs = level 2")
    func tabsLevel2() {
        #expect(CodeEditorIndentGuideScanner.indentLevel(forLinePrefix: "\t\treturn x", indentWidth: 4, useTabs: true) == 2)
    }

    @Test("tabs: indentWidth 不影响 tab 的层级计算")
    func tabsIgnoresIndentWidth() {
        // tab 模式 indentWidth 不影响层级（每个 tab = 1 级）
        #expect(CodeEditorIndentGuideScanner.indentLevel(forLinePrefix: "\tlet x", indentWidth: 2, useTabs: true) == 1)
    }

    // MARK: - isBlankLine

    @Test("纯空行")
    func pureBlank() {
        #expect(CodeEditorIndentGuideScanner.isBlankLine("") == true)
    }

    @Test("只有空格")
    func spacesOnlyBlank() {
        #expect(CodeEditorIndentGuideScanner.isBlankLine("    ") == true)
    }

    @Test("只有 tab")
    func tabsOnlyBlank() {
        #expect(CodeEditorIndentGuideScanner.isBlankLine("\t\t") == true)
    }

    @Test("有内容的行不是空行")
    func notBlankWithContent() {
        #expect(CodeEditorIndentGuideScanner.isBlankLine("  x") == false)
    }

    // MARK: - computeLevels 空行填充

    @Test("空行填充：取前后最小值")
    func blankLineFill() {
        let lines = [
            "    x",     // level 1
            "        y", // level 2
            "",          // blank -> min(2, 0) = 0（下面 level 0）
            "z",         // level 0
        ]
        let result = CodeEditorIndentGuideScanner.computeLevels(forLines: lines, indentWidth: 4, useTabs: false)
        #expect(result[0].level == 1)
        #expect(result[1].level == 2)
        #expect(result[2].isBlankLine == true)
        #expect(result[2].level == 0) // min(2, 0) = 0
        #expect(result[3].level == 0)
    }

    @Test("空行填充：前后都有缩进取较小值")
    func blankLineFillMinOfBoth() {
        let lines = [
            "    x",     // level 1
            "",          // blank -> min(1, 2) = 1
            "        y", // level 2
        ]
        let result = CodeEditorIndentGuideScanner.computeLevels(forLines: lines, indentWidth: 4, useTabs: false)
        #expect(result[1].isBlankLine == true)
        #expect(result[1].level == 1) // min(1, 2) = 1
    }

    @Test("连续空行：所有空行填充同一值")
    func consecutiveBlanks() {
        let lines = [
            "    x",  // level 1
            "",
            "",
            "    y",  // level 1
        ]
        let result = CodeEditorIndentGuideScanner.computeLevels(forLines: lines, indentWidth: 4, useTabs: false)
        #expect(result[1].level == 1)
        #expect(result[2].level == 1)
    }

    @Test("首行就是空行：无前驱，取后驱")
    func leadingBlank() {
        let lines = [
            "",       // blank, no prev -> min(0, 1) = 0
            "    x",  // level 1
        ]
        let result = CodeEditorIndentGuideScanner.computeLevels(forLines: lines, indentWidth: 4, useTabs: false)
        #expect(result[0].level == 0)
    }

    @Test("仅空行数组")
    func allBlankLines() {
        let lines = ["", "  ", "\t"]
        let result = CodeEditorIndentGuideScanner.computeLevels(forLines: lines, indentWidth: 4, useTabs: false)
        result.forEach { #expect($0.level == 0) }
    }

    // MARK: - 混合缩进（容错）

    @Test("混合缩进：tab 后跟空格，按 useTabs 判断")
    func mixedIndent() {
        // useTabs=true 时只数前缀 tab 数
        #expect(CodeEditorIndentGuideScanner.indentLevel(forLinePrefix: "\t   x", indentWidth: 4, useTabs: true) == 1)
        // useTabs=false 时只数前缀空格数（首字符是 tab 不是空格，所以 level=0）
        #expect(CodeEditorIndentGuideScanner.indentLevel(forLinePrefix: "\t   x", indentWidth: 4, useTabs: false) == 0)
    }

    @Test("单字符 indentWidth=1")
    func indentWidth1() {
        #expect(CodeEditorIndentGuideScanner.indentLevel(forLinePrefix: "  x", indentWidth: 1, useTabs: false) == 2)
    }

    @Test("整行为空格")
    func lineAllSpaces() {
        // 与 isBlankLine 一致
        #expect(CodeEditorIndentGuideScanner.isBlankLine("    ") == true)
        // computeLevels 空行处理
        let result = CodeEditorIndentGuideScanner.computeLevels(forLines: ["    "], indentWidth: 4, useTabs: false)
        #expect(result[0].isBlankLine == true)
        #expect(result[0].level == 0)
    }
}

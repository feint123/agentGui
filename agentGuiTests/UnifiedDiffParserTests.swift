import Testing
@testable import agentGui

struct UnifiedDiffParserTests {

    @Test func emptyDiff_returnsEmptyMap() {
        let result = UnifiedDiffParser.parse("")
        #expect(result.isEmpty)
    }

    @Test func pureAddition_marksAddedLines() {
        // @@ -0,0 +1,3 @@ → 新行 1,2,3 为 added
        let diff = """
        --- a/file.swift
        +++ b/file.swift
        @@ -0,0 +1,3 @@
        +line1
        +line2
        +line3
        """
        let result = UnifiedDiffParser.parse(diff)
        #expect(result[1] == .added)
        #expect(result[2] == .added)
        #expect(result[3] == .added)
        #expect(result.count == 3)
    }

    @Test func pureDeletion_marksDeletionAtInsertionPoint() {
        // @@ -2,3 +2,0 @@ → 纯删除，newStart=2, newCount=0 → 标记行 2 为 .deleted
        let diff = """
        --- a/file.swift
        +++ b/file.swift
        @@ -2,3 +2,0 @@
        -removed1
        -removed2
        -removed3
        """
        let result = UnifiedDiffParser.parse(diff)
        #expect(result[2] == .deleted)
        #expect(result.count == 1)
    }

    @Test func modification_marksModifiedLines() {
        // @@ -3,2 +3,2 @@ → newStart=3, newCount=2 → 行 3,4 为 .modified
        let diff = """
        --- a/file.swift
        +++ b/file.swift
        @@ -3,2 +3,2 @@
        -old1
        -old2
        +new1
        +new2
        """
        let result = UnifiedDiffParser.parse(diff)
        #expect(result[3] == .modified)
        #expect(result[4] == .modified)
        #expect(result.count == 2)
    }

    @Test func multiplHunks_mergesCorrectly() {
        let diff = """
        --- a/file.swift
        +++ b/file.swift
        @@ -1 +1,2 @@
        -old
        +new1
        +new2
        @@ -10,0 +11,1 @@
        +inserted
        """
        let result = UnifiedDiffParser.parse(diff)
        // 第一个 hunk: 1行 old → 2行 new → modified (行1), added (行2)
        #expect(result[1] == .modified)
        #expect(result[2] == .added)
        // 第二个 hunk: 纯添加行 11
        #expect(result[11] == .added)
    }

    @Test func deletionAtFileHead_marksLine1() {
        // @@ -1,2 +0,0 @@ → newStart=0, newCount=0 → 删除点为行 1
        let diff = """
        --- a/file.swift
        +++ b/file.swift
        @@ -1,2 +0,0 @@
        -removed1
        -removed2
        """
        let result = UnifiedDiffParser.parse(diff)
        #expect(result[1] == .deleted)
    }

    @Test func hunkWithImplicitCount1_parsesCorrectly() {
        // @@ -5 +5 @@ → oldCount=1, newCount=1 → line 5 is modified
        let diff = """
        --- a/file.swift
        +++ b/file.swift
        @@ -5 +5 @@
        -old
        +new
        """
        let result = UnifiedDiffParser.parse(diff)
        #expect(result[5] == .modified)
    }

    @Test func mixedHunk_addModifyDelete() {
        // 第一个 hunk: 2 added → lines 2,3
        // 第二个 hunk: pure delete at line 7
        let diff = """
        --- a/file.swift
        +++ b/file.swift
        @@ -1,0 +2,2 @@
        +add1
        +add2
        @@ -8,1 +7,0 @@
        -deleted
        """
        let result = UnifiedDiffParser.parse(diff)
        #expect(result[2] == .added)
        #expect(result[3] == .added)
        #expect(result[7] == .deleted)
    }
}

import Foundation

enum WorkbenchDetailSelection: Equatable {
    case none
    case file(URL)
    case gitDiff(title: String, diffText: String)
    case changeProposal(proposalID: UUID, filePath: String?)
}
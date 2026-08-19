import Foundation
import HeatKit

/// The order the sidebar is in, in one place.
///
/// The list sorts the tree to draw it, and the keyboard steps through the same
/// tree to move between conversations. Written twice they would drift, and a
/// shortcut that moves in a different order from the one on screen reads as a
/// bug in the shortcut rather than as two orders disagreeing.
enum FileOrder {

    /// Which way through the list a step moves.
    enum Step {
        case next, previous
    }

    /// Where a step from `current` lands, or nil if there's nowhere to go.
    ///
    /// Wraps, so the list is a loop rather than something with ends to fall
    /// off — which is what ⌃⇥ does everywhere else it appears. A `current` that
    /// isn't in the list at all (a document is open, or nothing is) comes in
    /// from whichever end the direction is travelling from.
    static func step(_ step: Step, from current: String?, in ids: [String]) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else {
            return step == .next ? ids.first : ids.last
        }
        let offset = step == .next ? 1 : -1
        return ids[(index + offset + ids.count) % ids.count]
    }

    /// The tree in the chosen order, folders sorted the same way inside.
    static func sorted(_ trees: [FileTree], files: [File], by order: FileSortOrder) -> [FileTree] {
        sorted(trees, filesByID: index(files), by: order)
    }

    /// Every file the list is drawing, top to bottom.
    ///
    /// Visible is the operative word: a folder contributes its contents only
    /// when it's open, so stepping through this can never land the selection on
    /// a row that isn't on screen. Matches `FileRow`, which recurses on
    /// `isExpanded` alone and draws nothing for a tree entry with no file
    /// behind it.
    static func visibleIDs(in trees: [FileTree], files: [File]) -> [String] {
        visibleIDs(in: trees, filesByID: index(files))
    }

    // MARK: - Implementation

    private static func index(_ files: [File]) -> [String: File] {
        Dictionary(files.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private static func sorted(_ trees: [FileTree], filesByID: [String: File], by order: FileSortOrder) -> [FileTree] {
        trees
            .map { tree in
                var tree = tree
                if let children = tree.children {
                    tree.children = sorted(children, filesByID: filesByID, by: order)
                }
                return tree
            }
            .sorted { isOrderedBefore($0, $1, filesByID: filesByID, by: order) }
    }

    private static func visibleIDs(in trees: [FileTree], filesByID: [String: File]) -> [String] {
        var ids: [String] = []
        for tree in trees {
            guard let file = filesByID[tree.id] else { continue }
            ids.append(tree.id)
            if file.isExpanded, let children = tree.children {
                ids.append(contentsOf: visibleIDs(in: children, filesByID: filesByID))
            }
        }
        return ids
    }

    private static func isOrderedBefore(
        _ lhs: FileTree,
        _ rhs: FileTree,
        filesByID: [String: File],
        by order: FileSortOrder
    ) -> Bool {
        // A row with no file behind it can't be ordered meaningfully, and
        // FileRow won't draw it either, so let it settle at the end.
        guard let left = filesByID[lhs.id] else { return false }
        guard let right = filesByID[rhs.id] else { return true }

        switch order {
        case .recentActivity:
            return left.modified > right.modified
        case .dateCreated:
            return left.created > right.created
        case .name:
            // Matches what the row displays, and compares the way a person
            // reads names — case-insensitive, with numbers in numeric order.
            return displayName(left).localizedStandardCompare(displayName(right)) == .orderedAscending
        }
    }

    private static func displayName(_ file: File) -> String {
        file.name ?? file.path
    }
}

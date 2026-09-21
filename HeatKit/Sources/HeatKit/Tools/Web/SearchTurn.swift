import Foundation

/// What a turn's searches have done so far: the links they've returned, and
/// how many of them came back with nothing.
///
/// The links, because a model working through a question searches again
/// and again and the same pages come back — the same regional round-up, the
/// same Yelp list — three and four times in one turn. Each copy went into
/// the context in full and was re-read on every round after. A link seen
/// before is returned by title alone, marked as such, so the model knows
/// it's there and can still open it, without the snippet it has already read.
///
/// The count, because a model that gets nothing back tends to try the same
/// shape of query again, more precisely — more quotes, more ORs — when the
/// shape is the problem. Knowing this is the third empty search lets the
/// tool say so, in stronger terms than the first time.
///
/// An actor because a round's searches run at once and both may return the
/// same link; whichever asks first gets the snippet. One per turn: the view
/// model makes a fresh one when a turn starts, so nothing carries over.
public actor SearchTurn {
    private var urls: Set<URL> = []
    private var emptySearches = 0

    public init() {}

    /// Records the links and says which of them were already known.
    public func mark(_ links: [URL]) -> Set<URL> {
        let seen = Set(links).intersection(urls)
        urls.formUnion(links)
        return seen
    }

    /// Records a search that found nothing, and says how many that makes.
    public func noteEmpty() -> Int {
        emptySearches += 1
        return emptySearches
    }
}

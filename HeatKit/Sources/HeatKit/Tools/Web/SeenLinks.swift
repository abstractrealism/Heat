import Foundation

/// The links a turn's searches have already returned.
///
/// A model working through a question searches again and again, and the
/// same pages come back — the same regional round-up, the same Yelp list —
/// three and four times in one turn. Each copy went into the context in full
/// and was re-read on every round after. A link seen before is now returned
/// by title alone, marked as such, so the model knows it's there and can
/// still open it, without the snippet it has already read.
///
/// An actor because a round's searches run at once and both may return the
/// same link; whichever asks first gets the snippet. One per turn: the view
/// model makes a fresh one when a turn starts, so nothing carries over.
public actor SeenLinks {
    private var urls: Set<URL> = []

    public init() {}

    /// Records the links and says which of them were already known.
    public func mark(_ links: [URL]) -> Set<URL> {
        let seen = Set(links).intersection(urls)
        urls.formUnion(links)
        return seen
    }
}

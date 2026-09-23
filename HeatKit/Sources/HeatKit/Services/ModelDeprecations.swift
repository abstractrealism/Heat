import Foundation
import GenKit

/// Models a service is known to have withdrawn while still listing them.
///
/// This used to read OpenAI's deprecations page, because nothing in the API
/// said which of its 130-odd models were dead. The API says now: a model
/// carries a `shutdown_date`, 58 of OpenAI's 136 have one, and seventeen of
/// those dates had already passed while the models went on being offered. A
/// date is read off the model itself and needs nothing kept here.
///
/// The page was then compared against the API and found to add nothing: of
/// the model ids it names that carry no `shutdown_date`, none are still in
/// `/v1/models` — and a model the service doesn't list can't be offered. So
/// the fetching and the parsing are gone, and with them the failure modes of
/// depending on the shape of a documentation page.
public struct ModelDeprecations {

    /// The one case neither a date nor a refusal catches on a fresh install:
    /// an alias whose whole family has been withdrawn.
    ///
    /// `gpt-4o-search-preview` is still listed, carries no shutdown date,
    /// and refuses every request. Its dated snapshot *is* dated — but that
    /// date can't be transferred to the alias, because an alias points at
    /// whichever snapshot the service has promoted, so a dead snapshot says
    /// nothing about it. Measured against the real list rather than assumed:
    /// `gpt-audio-mini-2025-10-06` is already shut down while
    /// `gpt-audio-mini` runs to 2027, and the looser form of that rule would
    /// condemn `gpt-4o`, `gpt-5`, `gpt-5-mini`, `gpt-5-nano`, `gpt-5-pro`
    /// and `o3`, every one of them current.
    ///
    /// So: a list of names, and a list is all it can be. Without it such a
    /// model is offered, marked suggested, and fails the first message sent
    /// to it — after which the refusal hides it, but only on the install
    /// that sent it. This will fall behind; the refusal covers that.
    public static func alreadyKnown(for kind: Service.Kind) -> Set<String> {
        switch kind {
        case .openAI:
            ["gpt-4o-search-preview", "gpt-4o-mini-search-preview"]
        default:
            []
        }
    }
}

import Foundation
import Testing

@testable import HeatKit

/// Reads a saved copy of OpenAI's deprecations page and checks what the parser
/// makes of it.
///
/// The date is pinned. Which rows count as past is a function of when you ask,
/// so a test that asked *now* would quietly change its own expectations as
/// shutdown dates went by — and would have been green on the day it was
/// written and puzzling a year later.
///
/// What this can and can't do is worth being clear about: it catches the
/// parser breaking, not the page changing. The fixture is frozen, so a
/// restructured page leaves these passing while nothing is found in practice.
/// That case is covered elsewhere, by the request itself being refused.
struct ModelDeprecationsTests {

    /// The day the fixture was taken.
    private static let asOf: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 10
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)!
    }()

    private static let withdrawn: Set<String> = {
        guard
            let url = Bundle.module.url(
                forResource: "openai-deprecations",
                withExtension: "md",
                subdirectory: "Fixtures"
            ),
            let markdown = try? String(contentsOf: url, encoding: .utf8)
        else {
            return []
        }
        return ModelDeprecations.withdrawnModelIDs(in: markdown, asOf: asOf)
    }()

    @Test("The fixture is found and yields something")
    func fixtureLoads() {
        #expect(!Self.withdrawn.isEmpty, "the fixture didn't load, so nothing below means anything")
    }

    /// Named outright on the page, so an exact match catches them. These are
    /// the whole reason for reading it: every one looks like a usable chat
    /// model from its name alone.
    @Test(
        "Models listed as already shut down are withdrawn",
        arguments: [
            "gpt-4o-search-preview-2025-03-11",
            "gpt-4o-mini-search-preview-2025-03-11",
            "gpt-5.1-chat-latest",
            "gpt-5-chat-latest",
            "gpt-5.1-codex",
            "chatgpt-4o-latest",
            "gpt-4-32k",
            "computer-use-preview",
            "computer-use-preview-2025-03-11",
        ]
    )
    func withdrawnModels(id: String) {
        #expect(Self.withdrawn.contains(id))
    }

    /// The failure that would matter. Hiding a live model is worse than
    /// showing a dead one, and `gpt-4o` is one date-strip away from
    /// `gpt-4o-2024-05-13`, which the page does list as shut down.
    @Test(
        "Live models are left alone",
        arguments: [
            "gpt-4o", "gpt-4o-mini", "gpt-4", "gpt-4-turbo", "gpt-3.5-turbo",
            "gpt-5", "gpt-5-mini", "gpt-4.1", "o1", "o3", "o3-mini", "o4-mini",
        ]
    )
    func liveModels(id: String) {
        #expect(!Self.withdrawn.contains(id))
    }

    /// A shutdown still to come means the model is running, whatever an older
    /// table says. Both of these are listed twice — once with a past date for
    /// fine-tuning, once with a future one for the model itself.
    @Test("A shutdown still to come wins", arguments: ["babbage-002", "davinci-002"])
    func scheduledButNotYetShutDown(id: String) {
        #expect(!Self.withdrawn.contains(id))
    }

    @Test("Future-dated rows are ignored", arguments: ["whisper-1", "gpt-4o-transcribe", "gpt-4o-mini-transcribe"])
    func futureShutdowns(id: String) {
        #expect(!Self.withdrawn.contains(id))
    }

    /// The regression this file exists for. `split(separator:)` drops empty
    /// pieces by default, which put a lone name at an even index and made an
    /// odd/even alternation skip it — the parse found 3 names instead of 70
    /// and read as a thin page rather than a broken parser.
    @Test("A cell holding exactly one name is read")
    func singleNameCell() {
        // `gpt-5.1-codex-mini` sits alone in its cell, unlike the rows that
        // carry a snapshot and an alias together.
        #expect(Self.withdrawn.contains("gpt-5.1-codex-mini"))
    }

    /// Two names for one thing, separated by an escaped pipe that must not be
    /// read as a column break.
    @Test("Both names in a shared cell are read")
    func escapedPipeCell() {
        #expect(Self.withdrawn.contains("o3-deep-research"))
        #expect(Self.withdrawn.contains("o3-deep-research-2025-06-26"))
    }

    /// The model column is the second one, whether the table has three columns
    /// or four — the four-column ones carry a price.
    @Test("A four-column table is read from the right column")
    func fourColumnTable() {
        #expect(Self.withdrawn.contains("gpt-4-vision-preview"))
        // The replacement column must never be harvested, or the thing being
        // recommended gets hidden.
        #expect(!Self.withdrawn.contains("gpt-5.6-terra"))
        #expect(!Self.withdrawn.contains("gpt-5.6-sol"))
    }

    @Test("Endpoints share the tables and are not models")
    func endpointsIgnored() {
        #expect(!Self.withdrawn.contains { $0.contains("/") })
    }

    /// A page that has moved, been rewritten, or come back as an error has to
    /// yield nothing rather than nonsense — nothing hidden is where things
    /// stood before any of this.
    @Test("Unrecognisable input yields nothing", arguments: [
        "",
        "# Deprecations\n\nThis page has moved.\n",
        "<html><body>404</body></html>",
        "| a | b |\n| - | - |\n| not a date | `gpt-4o` |\n",
    ])
    func unparseableInput(markdown: String) {
        #expect(ModelDeprecations.withdrawnModelIDs(in: markdown, asOf: Self.asOf).isEmpty)
    }

    /// Asked on an earlier day, a row whose shutdown hadn't happened yet must
    /// be left alone — the same fixture, a different answer.
    @Test("The date decides")
    func dateDecides() {
        var components = DateComponents()
        components.year = 2025
        components.month = 1
        components.day = 1
        components.timeZone = TimeZone(identifier: "UTC")
        let earlier = Calendar(identifier: .gregorian).date(from: components)!

        guard
            let url = Bundle.module.url(
                forResource: "openai-deprecations",
                withExtension: "md",
                subdirectory: "Fixtures"
            ),
            let markdown = try? String(contentsOf: url, encoding: .utf8)
        else {
            Issue.record("fixture missing")
            return
        }

        let then = ModelDeprecations.withdrawnModelIDs(in: markdown, asOf: earlier)
        // Shut down 2025-06-06, so still running at the start of that year.
        #expect(!then.contains("gpt-4-32k"))
        #expect(Self.withdrawn.contains("gpt-4-32k"))
        #expect(then.count < Self.withdrawn.count)
    }
}

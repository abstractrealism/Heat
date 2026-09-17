import SwiftUI
import GenKit
import HeatKit

/// The strip of controls beneath the message input: which model answers, and
/// whether it reasons first.
///
/// Below the input rather than beside it. These sit on their own row so a long
/// model name doesn't compete with the typing area for width — inline, the
/// input already shares its row with the send button, and a name like
/// `qwen3.6:27b` would have to truncate on a narrow window.
struct MessageFieldControls: View {
    @Environment(AppState.self) var state
    @Environment(ConversationViewModel.self) var conversationViewModel

    /// Lines the row up under the + button above it.
    ///
    /// The + glyph is centred in a square button, so its left edge sits at the
    /// field's own padding plus half the leftover width — not at the button's
    /// edge. Matching that by eye would drift the moment either size changed,
    /// so it's derived from the same numbers MessageField uses.
    private var leadingInset: CGFloat {
        #if os(macOS)
        let buttonWidth: CGFloat = 34
        #else
        let buttonWidth: CGFloat = 44
        #endif
        let fieldPadding: CGFloat = 4
        let glyphWidth: CGFloat = 13
        return fieldPadding + (buttonWidth - glyphWidth) / 2
    }

    var body: some View {
        HStack(spacing: 11) {
            modelPicker
            thinkingToggle
            toolsMenu
            contextGauge
            Spacer(minLength: 0)
        }
        .padding(.leading, leadingInset)
    }

    // MARK: - Shared look

    /// The look shared by Thinking and Tools.
    ///
    /// One definition rather than two matching ones, because they didn't match:
    /// the same requested font came out a size apart, one being a Button's
    /// label and the other a Menu's. Anything either of them needs — font,
    /// symbol scale, padding, tinting — belongs here, so the only difference
    /// left is the word and the glyph.
    /// How a pill shows that it's on.
    ///
    /// Thinking is on or off, and filling it says so plainly. Tools is a set
    /// that happens to be non-empty, which is a weaker claim — an outline reads
    /// as available rather than engaged, and keeps two adjacent blue pills from
    /// looking like the same kind of state.
    private enum PillEmphasis {
        case filled
        case outlined
    }

    @ViewBuilder
    private func pill<Content: View>(
        isOn: Bool,
        emphasis: PillEmphasis = .filled,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .font(.footnote)
            // Pinned explicitly: a symbol otherwise takes its size from the
            // surrounding control, and `wrench.and.screwdriver` carries more
            // ink than `brain` at the same point size.
            .imageScale(.small)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(pillForeground(isOn: isOn, emphasis: emphasis))
            .background {
                switch (isOn, emphasis) {
                case (true, .filled):
                    Capsule().fill(.tint)
                case (true, .outlined):
                    Capsule().strokeBorder(.tint, lineWidth: 1)
                case (false, _):
                    Capsule().fill(.quaternary)
                }
            }
    }

    private func pillForeground(isOn: Bool, emphasis: PillEmphasis) -> AnyShapeStyle {
        guard isOn else { return AnyShapeStyle(.secondary) }
        return emphasis == .filled ? AnyShapeStyle(Color.white) : AnyShapeStyle(.tint)
    }

    // MARK: - Tools

    private var activeToolIDs: Set<String> {
        conversationViewModel.conversation.toolIDs
    }

    /// Whether the chosen model can call a tool at all. Unknown counts as yes,
    /// as with reasoning — only Ollama reports this.
    private var modelCanUseTools: Bool {
        conversationViewModel.selectedModel?.supports(.tools) ?? true
    }

    /// Tool ids on this conversation that no tool answers to — hand-edited, or
    /// left over from a build that had more of them. Listed so they can be seen
    /// and switched off rather than sitting there invisibly.
    private var unrecognizedToolIDs: [String] {
        activeToolIDs.filter { Toolbox(name: $0) == nil }.sorted()
    }

    private func binding(for toolID: String) -> Binding<Bool> {
        Binding(
            get: { activeToolIDs.contains(toolID) },
            set: { conversationViewModel.setTool(toolID, enabled: $0) }
        )
    }

    /// A count rather than a label, because the interesting question is whether
    /// anything is armed. Which ones is a menu away; that something is, has to
    /// be readable without opening anything — the same reason Thinking left the
    /// + menu.
    @ViewBuilder
    private var toolsMenu: some View {
        let count = activeToolIDs.count
        // A model that searches the web on its own lights the pill as though
        // Search had been switched on — it is on, just not here — and counts
        // as one more, so the number on the pill is the number of ticks in
        // the menu. (With Heat's own search on too that's the same ability
        // twice, and it's counted twice: matching the menu matters more.)
        // Otherwise the note explaining it sits in a menu nobody has a
        // reason to open.
        let searchesItself = conversationViewModel.modelSearchesTheWebItself
        let shown = count + (searchesItself ? 1 : 0)
        let isArmed = shown > 0 && modelCanUseTools
        Menu {
            // Toggles rather than buttons: a menu Toggle draws the platform's
            // own checkmark, which is what says a tool is on. A Button with a
            // checkmark image beside its title has to be read to be understood.
            ForEach(Toolbox.allCases, id: \.name) { tool in
                Toggle(tool.label, isOn: binding(for: tool.name))
            }
            if !unrecognizedToolIDs.isEmpty {
                Divider()
                Section("Unrecognized") {
                    ForEach(unrecognizedToolIDs, id: \.self) { toolID in
                        Toggle(toolID, isOn: binding(for: toolID))
                    }
                }
            }
            if count > 0 {
                Divider()
                Button("Turn All Off") {
                    for toolID in activeToolIDs {
                        conversationViewModel.setTool(toolID, enabled: false)
                    }
                }
            }
            // Said here rather than in the model picker: this is the menu
            // whose switches it makes a liar of. Heat's search is a tool it
            // runs itself, so turning it off stops it — and a model that
            // searches on its own carries on regardless.
            // A tick that can't be cleared, beside the switches that can: the
            // model's own searching is on and stays on, and drawing it the
            // same way as the rest is what makes the pill's count add up.
            if searchesItself {
                Divider()
                Toggle("\(conversationViewModel.selectedModelName) always searches the web", isOn: .constant(true))
                    .disabled(true)
            }
        } label: {
            pill(isOn: isArmed, emphasis: .outlined) {
                HStack(spacing: 4) {
                    Label("Tools", systemImage: "wrench.and.screwdriver")
                        .labelStyle(.titleAndIcon)
                    // Always laid out, hidden when there's nothing to count, so
                    // the pill keeps its width and the row doesn't shift as
                    // tools are switched on and off.
                    Text("\(max(shown, 1))")
                        .monospacedDigit()
                        .opacity(shown > 0 ? 1 : 0)
                        .accessibilityHidden(shown == 0)
                }
            }
        }
        // Drawn as a button rather than a borderless menu. The borderless style
        // doesn't render the label it's given: AppKit takes an image and a
        // title out of it and draws its own control, which silently discarded
        // the count, the capsule, and every font and scale modifier — the
        // reason the wrench stayed a size too large whatever it was asked for.
        // As a button the label is drawn by SwiftUI, the same as Thinking.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!modelCanUseTools)
        .opacity(modelCanUseTools ? 1 : 0.5)
        .help(toolsHelp)
    }

    private var toolsHelp: String {
        guard modelCanUseTools else {
            return "\(conversationViewModel.selectedModelName) can't call tools, so none are offered to it. Pick a model that supports them to use this."
        }
        // Appended rather than replacing what's here: the tools still work as
        // described, and the model's own searching is a fact about that model
        // sitting alongside them.
        let searchesItself = conversationViewModel.modelSearchesTheWebItself
            ? " \(conversationViewModel.selectedModelName) also searches the web itself, which nothing here governs."
            : ""
        if activeToolIDs.isEmpty {
            return "Abilities the assistant may use in this conversation, such as searching the web. None are on. Changing this affects this conversation only — Settings › Instructions › Assistant sets the default for new ones." + searchesItself
        }
        return "Abilities the assistant may use in this conversation. It decides when to reach for one. Changing this affects this conversation only — Settings › Instructions › Assistant sets the default for new ones." + searchesItself
    }

    // MARK: - Context

    /// How full the model's context is, as a bar and a percentage.
    ///
    /// Absent rather than empty when there's nothing to report — before the
    /// first reply, or against a service that doesn't publish a context
    /// length. An empty bar would read as "plenty of room", which is a claim,
    /// not the absence of one.
    @ViewBuilder
    private var contextGauge: some View {
        if let usage = conversationViewModel.contextUsage {
            let fraction = min(1, Double(usage.used) / Double(usage.limit))
            HStack(spacing: 5) {
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                    GeometryReader { proxy in
                        Capsule()
                            .fill(gaugeColor(fraction))
                            .frame(width: max(2, proxy.size.width * fraction))
                    }
                }
                .frame(width: 44, height: 4)

                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(fraction >= 0.9 ? AnyShapeStyle(gaugeColor(fraction)) : AnyShapeStyle(.secondary))
            }
            .help("""
                Context used: \(usage.used.formatted(.number.grouping(.automatic))) of \
                \(usage.limit.formatted(.number.grouping(.automatic))) tokens.

                Measured from the last reply's own reported prompt size, so it \
                covers the conversation up to that point, not what you're \
                typing now. When it fills, the oldest messages stop reaching \
                the model.

                The limit is read when a service is opened in Settings — from \
                what the model was loaded with if it was running at the time, \
                and from the maximum it advertises otherwise, which can be \
                several times larger than it will actually be given.
                """)
        }
    }

    /// Neutral while there's room, and only insistent once it's nearly gone —
    /// a gauge that shouts at 60% teaches you to stop reading it.
    private func gaugeColor(_ fraction: Double) -> Color {
        switch fraction {
        case ..<0.75: .secondary
        case ..<0.9: .orange
        default: .red
        }
    }

    // MARK: - Model

    /// Services worth listing: switched on in Settings, with models loaded,
    /// and with at least one of them set to be offered — a service whose
    /// models have all been turned off would otherwise be a heading with
    /// nothing underneath it.
    private var services: [Service] {
        state.config.selectableServices.filter { !state.config.enabledModels(in: $0).isEmpty }
    }

    /// Choosing a model, as something that can be ticked.
    ///
    /// Only turning one on means anything. Unticking the current model would
    /// leave the conversation with none, and there is already a way to say
    /// "whatever Settings says" — the Use Default item below the list.
    private func binding(for model: Model, in service: Service) -> Binding<Bool> {
        Binding(
            get: { isSelected(service: service, model: model) },
            set: { isOn in
                guard isOn else { return }
                conversationViewModel.selectModel(serviceID: service.id, modelID: model.id)
            }
        )
    }

    @ViewBuilder
    private var modelPicker: some View {
        Menu {
            if services.isEmpty {
                // Not an empty menu: with no services configured there is
                // nothing to pick, and saying so beats a blank sheet.
                Text("No models available — add a service in Settings")
            }
            // A submenu per service once the flat list would be too tall to
            // open on screen.
            //
            // A menu is a pull-down: it opens below the button and, when it
            // can't fit, extends off the bottom and scrolls — which is where
            // 39 models put it. SwiftUI gives no say over placement, so the
            // only lever is height, and one row per service is a menu that
            // always fits. Kept flat while it does fit, since a submenu for
            // five local models is a click that buys nothing.
            if isModelListLong {
                ForEach(services) { service in
                    Menu(service.name) {
                        modelItems(for: service)
                    }
                }
            } else {
                ForEach(services) { service in
                    Section(service.name) {
                        modelItems(for: service)
                    }
                }
            }
            if conversationViewModel.hasSelectedModel {
                Divider()
                Button("Use Default") {
                    conversationViewModel.clearSelectedModel()
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(conversationViewModel.selectedModelName)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        // As with the tools menu: the borderless style hands the label to
        // AppKit, which draws the chevron below as an icon on the left and adds
        // an indicator of its own on the right — two of them, neither where the
        // code puts one. Drawn as a button, the label appears as written.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(modelHelp)
    }

    /// Where a flat list stops fitting. Rough on purpose — the point is
    /// whether the menu opens whole, not an exact row count.
    private var isModelListLong: Bool {
        services.reduce(0) { $0 + state.config.enabledModels(in: $1).count } > 12
    }

    @ViewBuilder
    private func modelItems(for service: Service) -> some View {
        // Only what this service is set to offer. See `Config.isModelEnabled`
        // — OpenAI alone lists around 130, most of them not for conversation.
        ForEach(state.config.enabledModels(in: service)) { model in
            // A Toggle rather than a Button carrying a checkmark image, for
            // the reason the tools menu found: AppKit takes a menu item's
            // label apart and draws its own, so the image was discarded and
            // the selected model looked no different from the rest. A Toggle
            // asks for the platform's own checkmark instead of drawing one.
            //
            // A checkmark rather than a highlighted row because this lists
            // every model across every service, and the same name can appear
            // under two of them.
            Toggle(model.name ?? model.id, isOn: binding(for: model, in: service))
        }
    }

    private var modelHelp: String {
        if conversationViewModel.hasSelectedModel {
            return "The model answering in this conversation. It stays put if you change the default in Settings. Titles and suggestions are unaffected — they follow the Summarization default."
        }
        return "The model answering in this conversation. Taken from the default in Settings, and fixed here once the first message is sent."
    }

    private func isSelected(service: Service, model: Model) -> Bool {
        conversationViewModel.conversation.serviceID == service.id
            && conversationViewModel.conversation.modelID == model.id
    }

    // MARK: - Thinking

    /// Whether the chosen model can reason at all.
    ///
    /// Unknown counts as yes: only Ollama reports this, so gating on a missing
    /// answer would grey the button out for every hosted service.
    private var modelCanThink: Bool {
        conversationViewModel.selectedModel?.supports(.thinking) ?? true
    }

    /// Filled and tinted when reasoning is on, plain when off, and labelled
    /// with the effort — the state has to be readable without opening
    /// anything, which is the whole reason it moved out of the + menu.
    ///
    /// A menu rather than a cycle now there are three states: cycling hides
    /// what the options are, and getting back to one you overshot means going
    /// round again.
    @ViewBuilder
    private var thinkingToggle: some View {
        // What the model will actually do, not what was asked for — those
        // differ on a model that can't stop reasoning, and the control should
        // show the truth.
        let effort = conversationViewModel.effectiveThinkingEffort
        let isOn = effort.isThinking && modelCanThink

        Menu {
            Picker("Thinking", selection: Binding(
                get: { conversationViewModel.effectiveThinkingEffort },
                set: { conversationViewModel.setThinkingEffort($0) }
            )) {
                ForEach(conversationViewModel.availableThinkingEfforts) { option in
                    Text(menuLabel(for: option)).tag(option)
                }
            }
            .pickerStyle(.inline)

            if conversationViewModel.modelAlwaysReasons {
                Divider()
                Text("\(conversationViewModel.selectedModelName) always reasons")
            }
        } label: {
            pill(isOn: isOn) {
                Label(thinkingLabel(for: effort), systemImage: "brain")
                    .labelStyle(.titleAndIcon)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(!modelCanThink)
        // Shown greyed and unclickable rather than hidden: a control that
        // vanishes reads as a bug, while one that's visibly unavailable
        // explains itself — and it comes back when the model changes.
        .opacity(modelCanThink ? 1 : 0.5)
        .help(thinkingHelp)
    }

    /// Struck through where asking for it won't be honoured.
    ///
    /// Left in the menu rather than removed: choosing it still does the
    /// nearest thing the model allows, and a list that changes length between
    /// models is harder to use than one where an item is visibly unavailable.
    /// Only a known refusal is marked — an unrecognised model says nothing,
    /// since the request degrades on its own if the guess was wrong.
    private func menuLabel(for effort: ThinkingEffort) -> AttributedString {
        var label = AttributedString(effort.label)
        if effort == .off, conversationViewModel.thinkingCannotBeTurnedOff {
            label.strikethroughStyle = .single
        }
        return label
    }

    /// "Thinking" on its own while the effort is whatever it always was, so
    /// the row doesn't grow a qualifier nobody asked for; named only once it
    /// says something.
    private func thinkingLabel(for effort: ThinkingEffort) -> String {
        switch effort {
        // Off says it by not being lit; Full and High are each their
        // service's "as much as it would do anyway", which is the state the
        // control was already in.
        case .off, .full, .high: "Thinking"
        default: "Thinking · \(effort.label)"
        }
    }

    private var thinkingHelp: String {
        guard modelCanThink else {
            let name = conversationViewModel.selectedModelName
            return "\(name) can't reason, so there's nothing to turn on. Pick a model that supports thinking to use this."
        }
        let name = conversationViewModel.selectedModelName
        switch conversationViewModel.effectiveThinkingEffort {
        case .off:
            // Said here as well as struck through in the menu, since a menu
            // item's styling doesn't always survive the trip to AppKit.
            if conversationViewModel.thinkingCannotBeTurnedOff {
                return "\(name) reasons whatever it's asked, so this asks it for the least it will do instead."
            }
            return "Reasoning is off for this conversation. The model answers directly."
        case .brief:
            if conversationViewModel.isStandingInForOff {
                return "\(name) reasons whatever it's asked, so Off isn't available — this is as little as it will do."
            }
            return "The model reasons briefly here, asked in the prompt to keep it short. How well that lands varies by model."
        case .full:
            return "The model reasons as much as it wants to here."
        case .low, .medium, .high, .xhigh, .max:
            // Services with a real effort control, where the level is a
            // request parameter rather than something asked for in the prompt.
            let effort = conversationViewModel.effectiveThinkingEffort
            if conversationViewModel.isStandingInForOff {
                return "\(name) reasons whatever it's asked, so Off isn't available — this is as little as it will do."
            }
            return "\(effort.detail). This is sent with the request, so the model is trained to honour it rather than being asked in the prompt."
        }
    }
}

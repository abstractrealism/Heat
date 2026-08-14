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

    @AppStorage(ChatPreference.thinkingEnabled) private var thinkingEnabled = true

    var body: some View {
        HStack(spacing: 6) {
            modelPicker
            thinkingToggle
            Spacer(minLength: 0)
        }
    }

    // MARK: - Model

    /// Services worth listing: switched on in Settings, and with models loaded.
    private var services: [Service] {
        state.config.selectableServices
    }

    @ViewBuilder
    private var modelPicker: some View {
        Menu {
            if services.isEmpty {
                // Not an empty menu: with no services configured there is
                // nothing to pick, and saying so beats a blank sheet.
                Text("No models available — add a service in Settings")
            }
            ForEach(services) { service in
                Section(service.name) {
                    ForEach(service.models) { model in
                        Button {
                            conversationViewModel.selectModel(serviceID: service.id, modelID: model.id)
                        } label: {
                            // A checkmark rather than a highlighted row: this is
                            // a menu of every model across every service, and
                            // the same name can appear under two of them.
                            if isSelected(service: service, model: model) {
                                Label(model.name ?? model.id, systemImage: "checkmark")
                            } else {
                                Text(model.name ?? model.id)
                            }
                        }
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
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(modelHelp)
    }

    private var modelHelp: String {
        if conversationViewModel.hasSelectedModel {
            return "The model answering in this conversation. Chosen here, so it stays put if you change the default in Settings. Titles and suggestions are unaffected — they follow the Summarization default."
        }
        return "The model answering in this conversation. Following the default in Settings until you pick one."
    }

    private func isSelected(service: Service, model: Model) -> Bool {
        conversationViewModel.conversation.serviceID == service.id
            && conversationViewModel.conversation.modelID == model.id
    }

    // MARK: - Thinking

    /// Filled and tinted when on, plain when off — the state has to be
    /// readable without opening anything, which is the whole reason it moved
    /// out of the + menu.
    @ViewBuilder
    private var thinkingToggle: some View {
        Button {
            thinkingEnabled.toggle()
        } label: {
            Label("Thinking", systemImage: "brain")
                .font(.footnote)
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .foregroundStyle(thinkingEnabled ? Color.white : Color.secondary)
                .background(
                    thinkingEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                    in: .capsule
                )
        }
        .buttonStyle(.plain)
        .help(thinkingEnabled
              ? "Reasoning is on. Models that can't reason are unaffected."
              : "Reasoning is off. Models that can't reason are unaffected.")
    }
}

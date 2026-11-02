import SwiftUI

struct AnimePromptReview: View {
    let suggestion: AnimePromptSuggestion
    let canGenerate: Bool
    var apply: (String, Bool) -> Void
    @State private var draft: String
    @Environment(\.dismiss) private var dismiss
    init(suggestion: AnimePromptSuggestion, canGenerate: Bool, apply: @escaping (String, Bool) -> Void) {
        self.suggestion = suggestion; self.canGenerate = canGenerate; self.apply = apply
        _draft = State(initialValue: suggestion.prompt)
    }
    private var valid: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.count <= 4096 }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(L("Provider"), value: suggestion.provider)
                    LabeledContent(L("Model"), value: suggestion.model)
                    if !suggestion.character.isEmpty { Text(suggestion.character).font(.headline) }
                }
                if !suggestion.original.isEmpty {
                    Section {
                        DisclosureGroup(L("Original prompt")) { Text(suggestion.original).textSelection(.enabled) }
                    }
                }
                Section {
                    TextEditor(text: $draft).frame(minHeight: 240).accessibilityLabel(L("Suggested prompt"))
                } header: { Text(L("Suggested prompt")) } footer: {
                    Text(L("The suggestion is in English for Anima. Check names, appearance and clothing before applying it. Your original prompt stays unchanged until you choose Use prompt."))
                }
                Section {
                    Button(L("Use prompt")) { apply(draft.trimmingCharacters(in: .whitespacesAndNewlines), false) }.disabled(!valid)
                    Button(L("Use and generate"), systemImage: "sparkles") { apply(draft.trimmingCharacters(in: .whitespacesAndNewlines), true) }
                        .disabled(!valid || !canGenerate)
                    if !canGenerate { Text(L("Download Anima models on a supported device before generating images.")).font(.caption).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle(L("Review the suggested prompt"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { dismiss() } } }
        }
        .presentationSizing(.page)
    }
}

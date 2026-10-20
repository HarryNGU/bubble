// The Dictate tab: start button, setup, last dictation, snippet library, clean-up options.

import AppKit
import SwiftUI

/// Record | Dictate, at the top of the window.
struct ModeSwitcher: View {
    @Binding var tab: String
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 4) {
            item("record", "Record", "record.circle")
            item("dictate", "Dictate", "waveform")
        }
        .padding(4)
        .background(Capsule().fill(Theme.card))
        .overlay(Capsule().stroke(Theme.stroke))
    }

    private func item(_ id: String, _ title: String, _ icon: String) -> some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { tab = id }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                Text(title).font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(tab == id ? Color.white : Color.primary.opacity(0.75))
            .frame(maxWidth: .infinity).frame(height: 32)
            .background {
                if tab == id { Capsule().fill(Theme.brand).matchedGeometryEffect(id: "pill", in: pill) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct DictateView: View {
    @ObservedObject var model: UIModel
    @ObservedObject var dictation: DictationModel
    @ObservedObject private var store = SnippetStore.shared
    @State private var newTrigger = ""
    @State private var newText = ""
    @State private var search = ""
    @State private var editing: Snippet?
    @State private var apiKey = ""

    var body: some View {
        VStack(spacing: 14) {
            if !dictation.accessibility { setupBanner }
            DictateButton(listening: dictation.phase == .listening) { model.onDictate?() }
            lastCard
            snippetsCard
            cleanupCard
            if dictation.history.count > 1 { historySection }
        }
    }

    // MARK: Setup

    private var setupBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.raised.fill").foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 6) {
                Text("One more permission").font(.system(size: 12.5, weight: .semibold))
                Text("Allow Accessibility so Bubble can notice ⌥⌥ in other apps and type for you. Until then, dictations are copied for you to paste.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Allow Accessibility…") { model.onAllowAccessibility?() }.controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.accent.opacity(0.1)))
    }

    // MARK: Last dictation

    private var lastCard: some View {
        Card(icon: "text.quote", title: "Last dictation", isOn: nil) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $dictation.last)
                        .font(.system(size: 12.5))
                        .scrollContentBackground(.hidden)
                        .frame(height: 84)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                    if dictation.last.isEmpty {
                        Text("Anything you dictate outside a text box lands here, ready to paste.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).padding(12).allowsHitTesting(false)
                    }
                }
                HStack {
                    Button { copy(dictation.last) } label: { Label("Copy", systemImage: "doc.on.doc") }
                        .disabled(dictation.last.isEmpty)
                    Button("Clear") { dictation.last = "" }.disabled(dictation.last.isEmpty)
                    Spacer()
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: Snippets

    private var filtered: [Snippet] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? store.snippets : store.snippets.filter { $0.trigger.lowercased().contains(q) || $0.text.lowercased().contains(q) }
    }

    private var snippetsCard: some View {
        Card(icon: "text.badge.plus", title: "Snippets (\(store.snippets.count))", isOn: nil) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Say the phrase on the left and Bubble types the text on the right. Saved only on this Mac.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    TextField("When I say…", text: $newTrigger).textFieldStyle(.roundedBorder)
                    TextField("type this", text: $newText).textFieldStyle(.roundedBorder)
                    Button {
                        store.add(trigger: newTrigger, text: newText)
                        newTrigger = ""; newText = ""
                    } label: { Image(systemName: "plus") }
                    .disabled(newTrigger.trimmingCharacters(in: .whitespaces).isEmpty || newText.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Add snippet")
                }
                .controlSize(.small)
                if store.snippets.count > 5 {
                    TextField("Search snippets", text: $search).textFieldStyle(.roundedBorder).controlSize(.small)
                }
                VStack(spacing: 2) {
                    ForEach(filtered) { s in
                        if editing?.id == s.id { editRow } else { SnippetRow(snippet: s, onEdit: { editing = s }, onDelete: { store.delete(s) }) }
                    }
                }
            }
        }
    }

    @ViewBuilder private var editRow: some View {
        if let e = editing {
            HStack(spacing: 6) {
                TextField("Phrase", text: Binding(get: { editing?.trigger ?? "" }, set: { editing?.trigger = $0 })).textFieldStyle(.roundedBorder)
                TextField("Text", text: Binding(get: { editing?.text ?? "" }, set: { editing?.text = $0 })).textFieldStyle(.roundedBorder)
                Button("Save") { if let s = editing { store.update(s) }; editing = nil }
                Button("Cancel") { editing = nil }
            }
            .controlSize(.small)
            .id(e.id)
        }
    }

    // MARK: Clean-up

    private var cleanupCard: some View {
        Card(icon: "wand.and.stars", title: "Clean-up", isOn: nil) {
            VStack(spacing: 10) {
                ToggleRow(title: "Remove filler words", subtitle: "um, uh, ah, \"you know,\"", isOn: $dictation.removeFillers)
                ToggleRow(title: "Fix self-corrections", subtitle: "\"at 5, no wait, 6\" → \"at 6\"; \"scratch that\"", isOn: $dictation.fixCorrections)
                Divider().opacity(0.5)
                ToggleRow(title: "AI polish (optional)", subtitle: "Smarter rewrites with your own Claude API key. Sends the text only, never audio or snippets.",
                          isOn: $dictation.aiPolish)
                if dictation.aiPolish {
                    if dictation.hasAPIKey {
                        HStack {
                            Label("API key saved in your Keychain", systemImage: "key.fill").font(.system(size: 11.5)).foregroundStyle(.secondary)
                            Spacer()
                            Button("Remove") { Keychain.setAPIKey(nil); dictation.hasAPIKey = false }.controlSize(.small)
                        }
                    } else {
                        HStack(spacing: 6) {
                            SecureField("Anthropic API key", text: $apiKey).textFieldStyle(.roundedBorder)
                            Button("Save") {
                                Keychain.setAPIKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
                                apiKey = ""
                                dictation.hasAPIKey = Keychain.apiKey != nil
                            }
                            .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: History

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Earlier today").font(.system(size: 13, weight: .semibold))
            ForEach(Array(dictation.history.dropFirst().enumerated()), id: \.offset) { _, text in
                Button { copy(text) } label: {
                    HStack {
                        Text(text).font(.system(size: 12)).lineLimit(2).multilineTextAlignment(.leading)
                        Spacer()
                        Image(systemName: "doc.on.doc").foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                }
                .buttonStyle(.plain)
                .help("Copy")
            }
        }
        .padding(.top, 4)
    }

    private func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

struct SnippetRow: View {
    let snippet: Snippet
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Text(snippet.trigger).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            Text(snippet.text).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if hover {
                Button(action: onEdit) { Image(systemName: "pencil") }.buttonStyle(.plain).help("Edit")
                Button(action: onDelete) { Image(systemName: "trash") }.buttonStyle(.plain).help("Delete")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(hover ? Theme.card : .clear))
        .onHover { hover = $0 }
    }
}

struct DictateButton: View {
    let listening: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(.white.opacity(0.25)).frame(width: 40, height: 40)
                    Image(systemName: listening ? "stop.fill" : "mic.fill").font(.system(size: 16, weight: .bold))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(listening ? "Listening… click to finish" : "Start dictating").font(.system(size: 16, weight: .bold, design: .rounded))
                    Text("Or double-tap ⌥ anywhere").font(.system(size: 11.5)).opacity(0.85)
                }
                Spacer()
                Text("⌥⌥")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.22)))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.brand))
            .shadow(color: Theme.accent.opacity(hover ? 0.45 : 0.25), radius: hover ? 14 : 8, y: 4)
            .scaleEffect(hover ? 1.012 : 1)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
}

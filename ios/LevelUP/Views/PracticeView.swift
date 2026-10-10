import SwiftUI

/// Flash cards: the question sits on top; tapping it flips the answer card below.
/// "Got it" marks a card known; "Again" keeps it in rotation. Swipe sideways to move between cards.
struct PracticeView: View {
    @EnvironmentObject var store: Store
    @AppStorage("practice.deck") private var deckID = "all"
    @AppStorage("practice.hideKnown") private var hideKnown = false
    @AppStorage("practice.known") private var knownData = Data()
    @State private var order: [Card] = []
    @State private var index = 0
    @State private var revealed = false
    @State private var adding = false
    @State private var drag: CGFloat = 0

    private var known: Set<String> { (try? JSONDecoder().decode(Set<String>.self, from: knownData)) ?? [] }
    private func setKnown(_ s: Set<String>) { knownData = (try? JSONEncoder().encode(s)) ?? Data() }

    private var decks: [Deck] { store.practiceDecks }
    private var deck: Deck? { decks.first { $0.id == deckID } }
    private var pool: [Card] { deck?.cards ?? decks.flatMap(\.cards) }
    private var card: Card? { order.indices.contains(index) ? order[index] : nil }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                header
                if let card {
                    GeometryReader { geo in
                        VStack(spacing: 12) {
                            questionCard(card).frame(height: geo.size.height * 0.38)
                            answerCard(card)
                        }
                        .offset(x: drag)
                        .gesture(swipe)
                    }
                    controls(card)
                } else {
                    ContentUnavailableView(hideKnown && !pool.isEmpty ? "You know every card here" : "No cards yet",
                                           systemImage: "rectangle.on.rectangle.angled",
                                           description: Text(hideKnown && !pool.isEmpty ? "Show known cards, or pick another deck." : "Pull new content from Settings, or add your own card."))
                    if hideKnown && !pool.isEmpty { Button("Show known cards") { hideKnown = false; reshuffle(shuffle: false) } }
                    Spacer()
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
            .navigationTitle("Practice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { deckMenu }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { reshuffle(shuffle: true) } label: { Image(systemName: "shuffle") }.accessibilityLabel("Shuffle")
                    Menu {
                        Toggle("Hide cards I know", isOn: $hideKnown)
                        Button { adding = true } label: { Label("Add a card", systemImage: "plus") }
                        if let card, card.id.hasPrefix("my-") {
                            Button(role: .destructive) { store.deleteCard(card.id); reshuffle(shuffle: false) } label: { Label("Delete this card", systemImage: "trash") }
                        }
                        Button(role: .destructive) { setKnown(known.subtracting(pool.map(\.id))); reshuffle(shuffle: false) } label: { Label("Reset progress for this deck", systemImage: "arrow.counterclockwise") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .sheet(isPresented: $adding) { AddCardView { q, a in store.addCard(question: q, answer: a); deckID = "d-mine"; reshuffle(shuffle: false) } }
            .onAppear { if order.isEmpty { reshuffle(shuffle: false) } }
            .onChange(of: deckID) { _, _ in reshuffle(shuffle: false) }
            .onChange(of: hideKnown) { _, _ in reshuffle(shuffle: false) }
            .onChange(of: store.library?.builtAt) { _, _ in reshuffle(shuffle: false) }
        }
    }

    // MARK: Pieces

    private var header: some View {
        let ids = Set(pool.map(\.id))
        let knownCount = known.intersection(ids).count
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(deck?.title ?? "All decks").font(.headline)
                Spacer()
                Text(order.isEmpty ? "" : "\(index + 1) of \(order.count)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            ProgressView(value: Double(knownCount), total: Double(max(1, ids.count)))
                .tint(.green)
            Text("\(knownCount) of \(ids.count) known").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.top, 6)
    }

    private var deckMenu: some View {
        Menu {
            Picker("Deck", selection: $deckID) {
                Text("All decks").tag("all")
                ForEach(decks) { d in Text("\(d.title) (\(d.cards.count))").tag(d.id) }
            }
        } label: { Label("Decks", systemImage: "square.stack.3d.up") }
    }

    private func questionCard(_ card: Card) -> some View {
        Button { withAnimation(.spring(duration: 0.5)) { revealed.toggle() } } label: {
            VStack(alignment: .leading, spacing: 10) {
                Text(deckTitle(for: card).uppercased()).font(.caption2.weight(.semibold)).tracking(0.6).foregroundStyle(.white.opacity(0.75))
                Spacer(minLength: 0)
                Text(card.q)
                    .font(.system(.title2, design: .serif, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                    .minimumScaleFactor(0.6)
                Spacer(minLength: 0)
                HStack {
                    if known.contains(card.id) { Label("Known", systemImage: "checkmark.seal.fill").font(.caption.weight(.semibold)) }
                    Spacer()
                    Label(revealed ? "Hide answer" : "Tap to reveal", systemImage: revealed ? "eye.slash" : "hand.tap").font(.caption)
                }
                .foregroundStyle(.white.opacity(0.85))
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [Color.levelUp, Color.levelUp.opacity(0.78)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint(revealed ? "Hides the answer" : "Shows the answer")
    }

    private func answerCard(_ card: Card) -> some View {
        ZStack {
            // Back of the card, shown until the question is tapped.
            VStack(spacing: 10) {
                Image(systemName: "questionmark.bubble").font(.system(size: 34)).foregroundStyle(Color.levelUp.opacity(0.6))
                Text("Say your answer out loud, then tap the question.").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .opacity(revealed ? 0 : 1)

            // Face with the answer, pre-rotated so it reads correctly once flipped.
            ScrollView {
                Text(answer(card.md))
                    .font(.system(.body, design: .serif))
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.levelUp.opacity(0.35), lineWidth: 1))
            .rotation3DEffect(.degrees(180), axis: (x: 1, y: 0, z: 0))
            .opacity(revealed ? 1 : 0)
        }
        .rotation3DEffect(.degrees(revealed ? 180 : 0), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
        .onTapGesture { withAnimation(.spring(duration: 0.5)) { revealed.toggle() } }
    }

    private func controls(_ card: Card) -> some View {
        HStack(spacing: 12) {
            Button { step(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                .disabled(index == 0).accessibilityLabel("Previous card")
            Button {
                var k = known; k.remove(card.id); setKnown(k); step(1)
            } label: { Label("Again", systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity, minHeight: 44) }
                .buttonStyle(.bordered).tint(.orange)
            Button {
                var k = known; k.insert(card.id); setKnown(k); step(1)
            } label: { Label("Got it", systemImage: "checkmark").frame(maxWidth: .infinity, minHeight: 44) }
                .buttonStyle(.borderedProminent).tint(.green)
            Button { step(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                .disabled(index >= order.count - 1).accessibilityLabel("Next card")
        }
        .font(.headline)
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { v in if abs(v.translation.width) > abs(v.translation.height) { drag = v.translation.width * 0.6 } }
            .onEnded { v in
                let dx = v.translation.width
                withAnimation(.spring(duration: 0.3)) { drag = 0 }
                if dx < -80 { step(1) } else if dx > 80 { step(-1) }
            }
    }

    // MARK: Logic

    private func step(_ by: Int) {
        let next = index + by
        guard order.indices.contains(next) else { return }
        revealed = false
        withAnimation(.easeInOut(duration: 0.2)) { index = next }
    }

    private func reshuffle(shuffle: Bool) {
        var cards = pool
        if hideKnown { let k = known; cards.removeAll { k.contains($0.id) } }
        order = shuffle ? cards.shuffled() : cards
        index = 0
        revealed = false
    }

    private func deckTitle(for card: Card) -> String {
        deck?.title ?? decks.first(where: { d in d.cards.contains(where: { c in c.id == card.id }) })?.title ?? "Practice"
    }

    private func answer(_ md: String) -> AttributedString {
        // Keep line breaks and list dashes; render **bold** and `code` inline.
        let text = md.replacingOccurrences(of: "\n- ", with: "\n• ").replacingOccurrences(of: "\n* ", with: "\n• ")
        return (try? AttributedString(markdown: text.hasPrefix("- ") ? "• " + String(text.dropFirst(2)) : text,
                                      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(md)
    }
}

/// Write your own card. Later this is where "Add to Practice" from a selected paragraph will land.
struct AddCardView: View {
    var onSave: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var answer = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Question") { TextField("What is…?", text: $question, axis: .vertical).lineLimit(2...5) }
                Section("Short answer") { TextField("Two or three sentences", text: $answer, axis: .vertical).lineLimit(4...12) }
            }
            .navigationTitle("New card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(question.trimmingCharacters(in: .whitespacesAndNewlines), answer.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                    .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || answer.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

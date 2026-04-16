import SwiftUI

// MARK: - ScanResultView
// Displayed after the user confirms a scan. Shows all parsed tire info
// in an editable form so the user can correct any OCR mistakes.
// Later, this will have a "Push to Shopify" button.

struct ScanResultView: View {
    @State var spec: TireSpec
    let onDismiss: () -> Void

    // Editable fields
    @State private var largeur: String
    @State private var hauteur: String
    @State private var rayon: String
    @State private var indiceCharge: String
    @State private var indiceVitesse: String
    @State private var marque: String
    @State private var modele: String
    @State private var saison: String
    @State private var saved = false

    let saisons = ["Été", "Hiver", "4 Saisons"]

    init(spec: TireSpec, onDismiss: @escaping () -> Void) {
        self._spec = State(initialValue: spec)
        self.onDismiss = onDismiss
        self._largeur = State(initialValue: spec.largeur)
        self._hauteur = State(initialValue: spec.hauteur)
        self._rayon = State(initialValue: spec.rayon)
        self._indiceCharge = State(initialValue: spec.indiceCharge)
        self._indiceVitesse = State(initialValue: spec.indiceVitesse)
        self._marque = State(initialValue: spec.marque)
        self._modele = State(initialValue: spec.modele)
        self._saison = State(initialValue: spec.saison.isEmpty ? "Été" : spec.saison)
    }

    var body: some View {
        NavigationStack {
            Form {
                // MARK: Tire Size Section
                Section("Dimensions") {
                    HStack {
                        FormField(label: "Largeur", value: $largeur, placeholder: "225")
                            .keyboardType(.numberPad)
                        Text("/")
                            .font(.title2)
                            .foregroundColor(.secondary)
                        FormField(label: "Hauteur", value: $hauteur, placeholder: "45")
                            .keyboardType(.numberPad)
                        Text("R")
                            .font(.title2)
                            .foregroundColor(.secondary)
                        FormField(label: "Rayon", value: $rayon, placeholder: "17")
                            .keyboardType(.numberPad)
                    }

                    HStack {
                        FormField(label: "Indice de charge", value: $indiceCharge, placeholder: "91")
                            .keyboardType(.numberPad)
                        FormField(label: "Indice de vitesse", value: $indiceVitesse, placeholder: "W")
                    }
                }

                // MARK: Brand Section
                Section("Marque & Modèle") {
                    FormField(label: "Marque", value: $marque, placeholder: "Michelin")
                    FormField(label: "Modèle", value: $modele, placeholder: "Pilot Sport 4")
                }

                // MARK: Season
                Section("Saison") {
                    Picker("Saison", selection: $saison) {
                        ForEach(saisons, id: \.self) { s in
                            Text(s).tag(s)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                // MARK: Formatted Preview
                Section("Aperçu") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(formattedTitle)
                            .font(.headline)
                        Text(formattedSubtitle)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                // MARK: Raw OCR Text (for debugging)
                Section("Texte OCR brut") {
                    Text(spec.rawText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // MARK: Actions
                Section {
                    // Save locally (Phase 1)
                    Button(action: saveLocally) {
                        HStack {
                            Image(systemName: saved ? "checkmark.circle.fill" : "square.and.arrow.down")
                            Text(saved ? "Sauvegardé!" : "Sauvegarder")
                        }
                    }
                    .foregroundColor(saved ? .green : .blue)

                    // Placeholder for future Shopify push
                    Button(action: {}) {
                        HStack {
                            Image(systemName: "cart.badge.plus")
                            Text("Publier sur Shopify")
                        }
                    }
                    .foregroundColor(.gray)
                    .disabled(true)
                }
            }
            .navigationTitle("Résultat du scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Fermer") { onDismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Nouveau scan") { onDismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: - Computed

    private var formattedTitle: String {
        "\(largeur)/\(hauteur)R\(rayon) \(indiceCharge)\(indiceVitesse)"
    }

    private var formattedSubtitle: String {
        [marque, modele, saison].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: - Save

    private func saveLocally() {
        // For Phase 1: save to UserDefaults as JSON
        // Phase 2+ will push to your Flask API / Shopify
        var updatedSpec = spec
        updatedSpec.largeur = largeur
        updatedSpec.hauteur = hauteur
        updatedSpec.rayon = rayon
        updatedSpec.indiceCharge = indiceCharge
        updatedSpec.indiceVitesse = indiceVitesse
        updatedSpec.marque = marque
        updatedSpec.modele = modele
        updatedSpec.saison = saison

        // Load existing scans
        var scans = loadSavedScans()
        scans.append(updatedSpec)

        // Save back
        if let data = try? JSONEncoder().encode(scans) {
            UserDefaults.standard.set(data, forKey: "savedScans")
        }

        saved = true
    }

    private func loadSavedScans() -> [TireSpec] {
        guard let data = UserDefaults.standard.data(forKey: "savedScans"),
              let scans = try? JSONDecoder().decode([TireSpec].self, from: data)
        else { return [] }
        return scans
    }
}

// MARK: - FormField

struct FormField: View {
    let label: String
    @Binding var value: String
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            TextField(placeholder, text: $value)
                .textFieldStyle(.roundedBorder)
        }
    }
}

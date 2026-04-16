import SwiftUI

// MARK: - ScanHistoryView
// Shows a list of all previously saved scans.
// Useful for reviewing what you've scanned before pushing to Shopify.

struct ScanHistoryView: View {
    @State private var scans: [TireSpec] = []

    var body: some View {
        NavigationStack {
            Group {
                if scans.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "tray")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("Aucun scan sauvegardé")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("Scannez un pneu pour commencer")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                } else {
                    List {
                        ForEach(scans) { scan in
                            ScanRow(spec: scan)
                        }
                        .onDelete(perform: deleteScan)
                    }
                }
            }
            .navigationTitle("Historique")
            .onAppear(perform: loadScans)
            .toolbar {
                if !scans.isEmpty {
                    EditButton()
                }
            }
        }
    }

    private func loadScans() {
        guard let data = UserDefaults.standard.data(forKey: "savedScans"),
              let saved = try? JSONDecoder().decode([TireSpec].self, from: data)
        else { return }
        scans = saved.reversed() // Most recent first
    }

    private func deleteScan(at offsets: IndexSet) {
        scans.remove(atOffsets: offsets)
        if let data = try? JSONEncoder().encode(scans.reversed()) {
            UserDefaults.standard.set(data, forKey: "savedScans")
        }
    }
}

// MARK: - ScanRow

struct ScanRow: View {
    let spec: TireSpec

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Size + brand
            HStack {
                Text(spec.formattedSize)
                    .font(.headline)
                    .foregroundColor(.orange)
                if !spec.marque.isEmpty {
                    Text("·")
                        .foregroundColor(.secondary)
                    Text(spec.marque)
                        .font(.subheadline)
                }
            }

            // Details
            HStack(spacing: 12) {
                if !spec.saison.isEmpty {
                    Label(spec.saison, systemImage: seasonIcon(spec.saison))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Text(spec.dateScanned, style: .date)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func seasonIcon(_ saison: String) -> String {
        switch saison {
        case "Été": return "sun.max"
        case "Hiver": return "snowflake"
        case "4 Saisons": return "cloud.sun"
        default: return "questionmark"
        }
    }
}

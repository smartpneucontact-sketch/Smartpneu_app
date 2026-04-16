import Foundation

// MARK: - TireSpec
// This is the data model that holds all parsed tire information.
// It mirrors the fields you already use in your Shopify metafields.

struct TireSpec: Identifiable, Codable {
    let id: UUID
    var largeur: String      // e.g., "225"
    var hauteur: String      // e.g., "45"  (also called "aspect ratio" or "profil")
    var rayon: String        // e.g., "17"  (rim diameter in inches)
    var indiceCharge: String // e.g., "91"  (load index)
    var indiceVitesse: String // e.g., "W"  (speed rating)
    var marque: String       // e.g., "Michelin"
    var modele: String       // e.g., "Pilot Sport 4"
    var saison: String       // e.g., "Été", "Hiver", "4 Saisons"
    var rawText: String      // The full OCR text captured
    var dateScanned: Date

    // The formatted tire size string, e.g. "225/45R17 91W"
    var formattedSize: String {
        var size = "\(largeur)/\(hauteur)R\(rayon)"
        if !indiceCharge.isEmpty {
            size += " \(indiceCharge)"
        }
        if !indiceVitesse.isEmpty {
            size += indiceVitesse
        }
        return size
    }

    init(
        largeur: String = "",
        hauteur: String = "",
        rayon: String = "",
        indiceCharge: String = "",
        indiceVitesse: String = "",
        marque: String = "",
        modele: String = "",
        saison: String = "",
        rawText: String = ""
    ) {
        self.id = UUID()
        self.largeur = largeur
        self.hauteur = hauteur
        self.rayon = rayon
        self.indiceCharge = indiceCharge
        self.indiceVitesse = indiceVitesse
        self.marque = marque
        self.modele = modele
        self.saison = saison
        self.rawText = rawText
        self.dateScanned = Date()
    }
}

// MARK: - ScanState
// Tracks what the scanner is currently doing

enum ScanState: Equatable {
    case scanning        // Camera is live, looking for text
    case detected        // Tire size pattern found, showing preview
    case captured        // User confirmed the scan
    case error(String)   // Something went wrong
}

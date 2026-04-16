import Foundation

// MARK: - TireTextParser
// Parses raw OCR text to extract tire specifications.
//
// Tire sidewalls contain text like: "225/45R17 91W" or "P225/45ZR17 91W"
// This parser uses regex to find these patterns and break them into components.
//
// It also tries to match brand names from the known brands list.

class TireTextParser {

    // MARK: - Tire Size Parsing

    /// Main parsing function. Takes all OCR text and returns a TireSpec if a valid size is found.
    func parse(_ rawText: String) -> TireSpec? {
        let text = rawText.uppercased()

        // Try to extract tire dimensions
        guard let dimensions = extractDimensions(from: text) else {
            return nil
        }

        // Try to extract brand
        let brand = extractBrand(from: text)

        // Try to extract season indicators
        let season = extractSeason(from: text)

        return TireSpec(
            largeur: dimensions.largeur,
            hauteur: dimensions.hauteur,
            rayon: dimensions.rayon,
            indiceCharge: dimensions.indiceCharge,
            indiceVitesse: dimensions.indiceVitesse,
            marque: brand ?? "",
            modele: "",  // Model extraction requires the brand/model database
            saison: season ?? "",
            rawText: rawText
        )
    }

    // MARK: - Dimension Extraction

    private struct Dimensions {
        let largeur: String
        let hauteur: String
        let rayon: String
        let indiceCharge: String
        let indiceVitesse: String
    }

    private func extractDimensions(from text: String) -> Dimensions? {
        // Main tire size pattern: 225/45R17 91W
        // Breakdown:
        //   P?        - Optional "P" prefix (P-metric)
        //   (\d{3})   - Width (largeur): 3 digits, e.g. 225
        //   /         - Separator
        //   (\d{2})   - Aspect ratio (hauteur): 2 digits, e.g. 45
        //   Z?R       - Optional Z before R (speed rated)
        //   (\d{2})   - Rim diameter (rayon): 2 digits, e.g. 17
        //   \s*       - Optional space
        //   (\d{2,3})? - Optional load index: 2-3 digits, e.g. 91
        //   \s*       - Optional space
        //   ([A-Z])?  - Optional speed rating: single letter, e.g. W

        let pattern = #"P?\s*(\d{3})\s*/\s*(\d{2})\s*Z?\s*R\s*(\d{2})\s*(\d{2,3})?\s*([A-Z])?"#

        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else {
            return nil
        }

        func extractGroup(_ index: Int) -> String {
            guard index < match.numberOfRanges,
                  let range = Range(match.range(at: index), in: text)
            else { return "" }
            return String(text[range])
        }

        let largeur = extractGroup(1)
        let hauteur = extractGroup(2)
        let rayon = extractGroup(3)
        let indiceCharge = extractGroup(4)
        let indiceVitesse = extractGroup(5)

        // Validate basic ranges
        guard let width = Int(largeur), width >= 125 && width <= 355 else { return nil }
        guard let ratio = Int(hauteur), ratio >= 20 && ratio <= 80 else { return nil }
        guard let diameter = Int(rayon), diameter >= 13 && diameter <= 24 else { return nil }

        return Dimensions(
            largeur: largeur,
            hauteur: hauteur,
            rayon: rayon,
            indiceCharge: indiceCharge,
            indiceVitesse: indiceVitesse
        )
    }

    // MARK: - Brand Extraction

    /// Known tire brands — matches against OCR text.
    /// You can expand this list. Later, this will load from your JSON database.
    private let knownBrands: [String] = [
        // Premium
        "MICHELIN", "BRIDGESTONE", "GOODYEAR", "CONTINENTAL", "PIRELLI",
        "DUNLOP", "HANKOOK", "YOKOHAMA", "TOYO", "FIRESTONE",
        "FALKEN", "KUMHO", "NEXEN", "COOPER", "GENERAL",
        "UNIROYAL", "BF GOODRICH", "BFGOODRICH",
        // Budget / Chinese
        "SAILUN", "WESTLAKE", "TRIANGLE", "LINGLONG", "ZEETEX",
        "NANKANG", "FEDERAL", "ACHILLES", "MAXXIS", "VREDESTEIN",
        "NOKIAN", "GISLAVED", "BARUM", "SEMPERIT", "PETLAS",
        "LAUFENN", "MARSHAL", "ROADSTONE", "MINERVA", "DAVANTI",
        "ACCELERA", "HIFLY", "TORQUE", "WINDFORCE", "APTANY",
        "GOODRIDE", "APLUS", "RADAR", "LANDSAIL", "INFINITY",
        // Add more as needed
    ]

    private func extractBrand(from text: String) -> String? {
        for brand in knownBrands {
            if text.contains(brand) {
                // Return with proper capitalization
                return brand.capitalized
            }
        }
        return nil
    }

    // MARK: - Season Extraction

    /// Look for season indicators in the text or common symbols
    private func extractSeason(from text: String) -> String? {
        // M+S or M&S marking = all-season or winter
        if text.contains("M+S") || text.contains("M&S") || text.contains("MUD") {
            return "4 Saisons"
        }

        // 3PMSF (Three Peak Mountain Snowflake) = winter
        // The actual symbol won't OCR, but sometimes the text appears
        if text.contains("3PMSF") || text.contains("WINTER") || text.contains("SNOW") {
            return "Hiver"
        }

        // Summer keywords
        if text.contains("SUMMER") || text.contains("SPORT") {
            return "Été"
        }

        return nil
    }
}

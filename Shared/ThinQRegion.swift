import Foundation

/// ThinQ Connect is served from three regional hosts. The country lists are
/// copied from LG's official SDK (thinq-connect/pythinqconnect, country.py).
enum ThinQRegion: String, Sendable {
    case americas = "aic"
    case europe = "eic"
    case asiaPacific = "kic"

    static func forCountry(_ code: String) -> ThinQRegion? {
        let code = code.uppercased()
        if americasCountries.contains(code) { return .americas }
        if europeCountries.contains(code) { return .europe }
        if asiaPacificCountries.contains(code) { return .asiaPacific }
        return nil
    }

    var baseURL: URL { URL(string: "https://api-\(rawValue).lgthinq.com")! }

    private static let americasCountries: Set<String> = [
        "AG", "AR", "AW", "BB", "BO", "BR", "BS", "BZ", "CA", "CL", "CO", "CR", "CU", "DM", "DO", "EC",
        "GD", "GT", "GY", "HN", "HT", "JM", "KN", "LC", "MX", "NI", "PA", "PE", "PR", "PY", "SR", "SV",
        "TT", "US", "UY", "VC", "VE",
    ]

    private static let europeCountries: Set<String> = [
        "AE", "AF", "AL", "AM", "AO", "AT", "AZ", "BA", "BE", "BF", "BG", "BH", "BJ", "BY", "CD", "CF",
        "CG", "CH", "CI", "CM", "CV", "CY", "CZ", "DE", "DJ", "DK", "DZ", "EE", "EG", "ES", "ET", "FI",
        "FR", "GA", "GB", "GE", "GH", "GM", "GN", "GQ", "GR", "HR", "HU", "IE", "IL", "IQ", "IR", "IS",
        "IT", "JO", "KE", "KG", "KW", "KZ", "LB", "LR", "LT", "LU", "LV", "LY", "MA", "MD", "ME", "MK",
        "ML", "MR", "MT", "MU", "MW", "NE", "NG", "NL", "NO", "OM", "PK", "PL", "PS", "PT", "QA", "RO",
        "RS", "RU", "RW", "SA", "SD", "SE", "SI", "SK", "SL", "SN", "SO", "ST", "SY", "TD", "TG", "TN",
        "TR", "TZ", "UA", "UG", "UZ", "XK", "YE", "ZA", "ZM",
    ]

    private static let asiaPacificCountries: Set<String> = [
        "AU", "BD", "CN", "HK", "ID", "IN", "JP", "KH", "KR", "LA", "LK", "MM", "MY", "NP", "NZ", "PH",
        "SG", "TH", "TW", "VN",
    ]
}

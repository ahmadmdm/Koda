import Foundation

/// When a video went up, from YouTube's relative text ("3 hours ago", "Streamed 2 days ago",
/// "قبل ٣ ساعات", "منذ يومين"). The account's feeds carry only that text; RSS has exact dates.
nonisolated enum PublishedDate {
    private static let english: [(word: String, unit: Calendar.Component, factor: Int)] = [
        ("second", .second, 1), ("minute", .minute, 1), ("hour", .hour, 1), ("day", .day, 1),
        ("week", .day, 7), ("month", .month, 1), ("year", .year, 1),
    ]

    /// Arabic stems, singular, dual and plural, as YouTube writes them.
    private static let arabic: [(stems: [String], unit: Calendar.Component, factor: Int)] = [
        (["ثانية", "ثانيت", "ثوان", "ثواني"], .second, 1),
        (["دقيقة", "دقيقت", "دقائق"], .minute, 1),
        (["ساعة", "ساعت", "ساعات"], .hour, 1),
        (["يوم", "أيام", "ايام"], .day, 1),
        (["أسبوع", "اسبوع", "أسابيع", "اسابيع"], .day, 7),
        (["شهر", "أشهر", "اشهر", "شهور"], .month, 1),
        (["سنة", "سنت", "سنوات", "سنين", "عام", "أعوام", "اعوام"], .year, 1),
    ]

    static func parse(_ text: String?, now: Date = .now, calendar: Calendar = .current) -> Date? {
        guard let raw = text, !raw.isEmpty else { return nil }
        let t = asciiDigits(raw.lowercased())
        let number = Int(String(t.drop { !$0.isASCII || !$0.isNumber }.prefix { $0.isASCII && $0.isNumber }))

        if t.contains("yesterday") { return calendar.date(byAdding: .day, value: -1, to: now) }
        if t.contains("just now") || t.contains("الآن") { return now }
        if t.contains("ago") {
            for (word, unit, factor) in english where t.contains(word) {
                return calendar.date(byAdding: unit, value: -(number ?? 1) * factor, to: now)
            }
            return nil
        }
        if t.contains("قبل") || t.contains("منذ") {
            if t.contains("أمس") || t.contains("امس") { return calendar.date(byAdding: .day, value: -1, to: now) }
            let words = t.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            for (stems, unit, factor) in arabic {
                guard let word = words.first(where: { w in stems.contains { w.contains($0) } }) else { continue }
                // The dual (ساعتين، يومان) means two without a number.
                let dual = (word.hasSuffix("ين") && !word.hasSuffix("سنين")) || (word.hasSuffix("ان") && !word.hasSuffix("ثوان"))
                let count = number ?? (dual ? 2 : 1)
                return calendar.date(byAdding: unit, value: -count * factor, to: now)
            }
        }
        return nil
    }

    /// Arabic-Indic (٠١٢) and Persian (۰۱۲) digits as ASCII ones, without Arabic diacritics
    /// ("يومًا" is "يوما"), which would otherwise join the letter before them into another character.
    private static func asciiDigits(_ s: String) -> String {
        var scalars = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            switch u.value {
            case 0x0660...0x0669: scalars.append(Unicode.Scalar(UInt8(u.value - 0x0660 + 48)))
            case 0x06F0...0x06F9: scalars.append(Unicode.Scalar(UInt8(u.value - 0x06F0 + 48)))
            case 0x064B...0x065F, 0x0670: continue
            default: scalars.append(u)
            }
        }
        return String(scalars)
    }
}

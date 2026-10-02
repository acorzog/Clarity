import Foundation
import SwiftData
import WidgetKit

/// The pieces of an expense spoken in a short, natural phrase such as
/// "20 euros on taxi" or "5 euros en Mercadona". This is deliberately a
/// small, offline parser: speech recognition turns audio into text and this
/// type makes the common logging phrases useful without an API key.
struct ParsedVoiceExpense: Equatable {
    let amount: Decimal
    let note: String
    /// The day explicitly mentioned in the phrase, or today when none is
    /// spoken. Keeping this in the parsed result makes every voice entry point
    /// (Home and New Transaction) behave consistently.
    let date: Date
    /// A semantic category family, not a made-up user category name.
    let categoryHint: VoiceExpenseCategoryHint?
    /// Detected from a spoken verb ("gasté"/"recibí"/etc.) — see
    /// `VoiceExpenseParser.strippingEntryTypeVerb(from:)`. Defaults to `.expense`, the same as
    /// before this field existed, whenever no recognized verb is present. Never `.transfer` —
    /// this parser only ever recognizes expense/income phrasing.
    let entryType: EntryType
}

enum VoiceExpenseCategoryHint: String, Equatable {
    case groceries
    case transport
}

enum VoiceExpenseParser {
    /// Extracts one or more expense/income clauses from a single utterance. For
    /// example, "15 en taxi y 25 en supermercado" produces two independent
    /// entries. Splits on "y"/"and"/"," rather than reusing the amount pattern to find clause
    /// boundaries, so a clause is free to say its amount before *or* after its note (see
    /// `parse`) — each clause is simply handed to `parse` on its own.
    ///
    /// A date mentioned inside a clause always belongs to that clause alone, so "15 en taxi el
    /// lunes y 25 en supermercado ayer" gives each entry its own day. A date said once, outside
    /// any individual clause (e.g. trailing the whole phrase, as in "15 taxi y 25 supermercado,
    /// 20 de septiembre"), still applies to every clause that didn't name its own day.
    /// `referenceDate` anchors relative expressions ("today"/"yesterday"/"el lunes") — always
    /// `.now` in production; overridable so tests can pin it for month/year-boundary cases.
    static func parseAll(_ text: String, referenceDate: Date = .now) -> [ParsedVoiceExpense] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let segments = splitIntoClauses(trimmed)
        guard segments.count > 1 else {
            return parseClause(trimmed, fallbackDate: nil, referenceDate: referenceDate).map { [$0] } ?? []
        }

        let sharedDate = extractTemporalDate(from: trimmed, referenceDate: referenceDate)?.date
        return segments.compactMap { parseClause($0, fallbackDate: sharedDate, referenceDate: referenceDate) }
    }

    private static func splitIntoClauses(_ text: String) -> [String] {
        let pattern = #"\s*,\s*|\s+(?:y|and)\s+"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [text] }

        let range = NSRange(text.startIndex..., in: text)
        var pieces: [String] = []
        var lastEnd = text.startIndex
        for match in expression.matches(in: text, range: range) {
            guard let matchRange = Range(match.range, in: text) else { continue }
            pieces.append(String(text[lastEnd..<matchRange.lowerBound]))
            lastEnd = matchRange.upperBound
        }
        pieces.append(String(text[lastEnd...]))
        return pieces.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Parses a single spoken expense or income clause. Amounts may use either a comma or dot
    /// decimal separator (Spanish speech recognition output), and may come before or after the
    /// note — "20 euros en taxi" and "taxi 20 euros" both work. A leading verb such as "gasté",
    /// "recibí" or "cobré" is recognized and stripped; it also decides `entryType`, so "recibí
    /// 1500 euros de nómina" comes back as income while a plain "20 euros en taxi" keeps
    /// defaulting to an expense exactly as before this verb detection existed.
    /// `referenceDate` anchors relative expressions ("today"/"el lunes") — see `parseAll`.
    static func parse(_ text: String, referenceDate: Date = .now) -> ParsedVoiceExpense? {
        parseClause(text, fallbackDate: nil, referenceDate: referenceDate)
    }

    private static func parseClause(_ text: String, fallbackDate: Date?, referenceDate: Date) -> ParsedVoiceExpense? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Date extraction runs *before* the verb is looked for — a leading date phrase ("Ayer
        // pagué…", "Hoy gasté…") would otherwise permanently block the verb from ever being
        // recognized, since `strippingEntryTypeVerb` only strips a verb found at the literal
        // start of the string. Extracting the date first means the verb ends up at the start
        // once the date word is gone, exactly like it would without the date phrase at all.
        //
        // This also still removes a clause that's nothing but a trailing date (e.g. the "20 de
        // septiembre" left over once "15 en taxi y 25 en supermercado, 20 de septiembre" is split
        // on its commas) before the amount is searched for, so that day number is never mistaken
        // for an amount. A date named inside this clause always wins over one shared with the
        // rest of the phrase (`fallbackDate`) — see `parseAll`'s doc comment. Neither is
        // required: with nothing spoken and no fallback, this keeps defaulting to `referenceDate`
        // (`.now` in production) exactly as before any date detection existed.
        let temporal = extractTemporalDate(from: trimmed, referenceDate: referenceDate)
        let date = temporal?.date ?? fallbackDate ?? referenceDate
        let dateStripped = temporal?.textWithoutDate ?? trimmed

        let (verbStripped, entryType) = strippingEntryTypeVerb(from: dateStripped)

        let amountPattern = #"(\d+(?:[,.]\d{1,2})?)\s*(?:€|euros?|eur|dollars?|\$)?"#
        guard
            let expression = try? NSRegularExpression(pattern: amountPattern, options: [.caseInsensitive]),
            let match = expression.firstMatch(in: verbStripped, range: NSRange(verbStripped.startIndex..., in: verbStripped)),
            let matchRange = Range(match.range, in: verbStripped),
            let amountRange = Range(match.range(at: 1), in: verbStripped),
            let amount = Decimal(string: String(verbStripped[amountRange]).replacingOccurrences(of: ",", with: ".")),
            amount > 0
        else { return nil }

        var rawNote = verbStripped
        rawNote.removeSubrange(matchRange)
        let cleanedNote = cleanNote(rawNote)
        let note = cleanedNote.isEmpty ? (entryType == .income ? "Income" : "Expense") : cleanedNote

        return ParsedVoiceExpense(amount: amount, note: note, date: date, categoryHint: categoryHint(for: note), entryType: entryType)
    }

    /// Recognizes a small, fixed set of Spanish/English verbs that name the transaction's
    /// direction ("gasté"/"pagué"/"spent"/"paid" for an expense, "recibí"/"cobré"/"me
    /// ingresaron"/"received"/"earned" for income) at the very start of the clause, and strips
    /// it so it never ends up in the note. Text with no recognized verb is returned unchanged
    /// with `.expense` — the same default `parse` always used before this existed.
    private static func strippingEntryTypeVerb(from text: String) -> (String, EntryType) {
        let incomeVerbs = [
            "me ingresaron", "me pagaron", "ingresaron", "recibi", "recibí",
            "cobre", "cobré", "gane", "gané", "received", "earned", "got paid"
        ]
        let expenseVerbs = [
            "gaste", "gasté", "pague", "pagué", "compre", "compré", "costo", "costó", "spent", "paid"
        ]

        for verb in incomeVerbs {
            if let stripped = strippingLeadingPhrase(verb, from: text) {
                return (stripped, .income)
            }
        }
        for verb in expenseVerbs {
            if let stripped = strippingLeadingPhrase(verb, from: text) {
                return (stripped, .expense)
            }
        }
        return (text, .expense)
    }

    private static func strippingLeadingPhrase(_ phrase: String, from text: String) -> String? {
        let pattern = "^\\s*" + NSRegularExpression.escapedPattern(for: phrase) + "\\b\\s*"
        guard
            let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
            let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let matchRange = Range(match.range, in: text)
        else { return nil }
        return String(text[matchRange.upperBound...])
    }

    /// Finds the user's own matching category for a known merchant/type. The
    /// app never creates categories from voice input; a user can always adjust
    /// the suggestion in the normal transaction form before saving.
    ///
    /// Deliberately omits generic single words like "food"/"car"/"travel" — a category named
    /// "Fast Food" or "Car Insurance" genuinely contains those as whole words, so no matching
    /// strategy alone can tell that apart from an actual groceries/transport category; only a
    /// specific-enough candidate list can. See `matches(candidate:categoryName:)` for the
    /// word-boundary rule this still applies on top (e.g. so "train" never matches "Training").
    static func categoryMatch(for hint: VoiceExpenseCategoryHint?, in categories: [Category]) -> Category? {
        guard let hint else { return nil }
        let names: [String]
        switch hint {
        case .groceries:
            names = ["groceries", "grocery", "supermarket", "alimentacion", "alimentación", "comida"]
        case .transport:
            names = ["transport", "transportation", "taxi", "coche", "transporte", "viajes"]
        }
        for candidateName in names {
            if let match = categories.first(where: { matches(candidate: candidateName, categoryName: $0.name) }) {
                return match
            }
        }
        return nil
    }

    /// Maps familiar merchants and spending words — including some everyday phrases, not just
    /// exact keywords ("cenar fuera", "compré comida en Mercadona") — to *existing* categories.
    /// Unlike the AI fallback this is local, immediate and transparent: every candidate below is
    /// only a preference for one of the user's own rows, tried most-specific-name first
    /// ("Taxi") and falling back to a broader one ("Transportation") only when the specific one
    /// doesn't exist. A bare, generic word (e.g. "travel"/"viajes" alone, with no "vuelo"/
    /// "flight") is deliberately absent from every rule below — it's left for `localCategoryMatch`
    /// to resolve directly against a category actually named that, rather than this table
    /// guessing a more specific subcategory the person never mentioned.
    ///
    /// If the note's words plausibly match more than one *different* existing category across
    /// the rules below (e.g. "cenar en el aeropuerto antes del vuelo" naming both a Restaurants
    /// and a Flights category), this deliberately returns nil rather than silently guessing one —
    /// the person resolves it themselves in the review step.
    static func categoryMatch(for note: String, in categories: [Category]) -> Category? {
        guard !categories.isEmpty else { return nil }
        if let directMatch = CategorizationService.localCategoryMatch(for: note, in: categories) {
            return directMatch
        }

        let normalized = normalizedWords(in: note)
        let rules: [(words: Set<String>, categoryNames: [String])] = [
            (["taxi", "uber", "cabify", "cab", "bolt", "lyft"], ["taxi", "transportation", "transport"]),
            (["bus", "metro", "tram", "subway", "autobus", "fgv"], ["public transit", "local transportation", "transportation"]),
            (["train", "tren", "renfe"], ["train", "public transit", "transportation"]),
            (["flight", "flights", "vuelo", "vuelos", "avion", "avión", "aerolinea", "aerolínea", "boarding"], ["flights", "flight", "travelling", "travel", "viajes"]),
            (["hotel", "hostal", "alojamiento", "airbnb"], ["hotels", "hotel", "accommodation", "travelling", "travel"]),
            (["fuel", "gas", "gasoline", "petrol", "diesel", "gasolina"], ["fuel"]),
            (["parking", "parquing", "aparcamiento"], ["parking"]),
            (["mercadona", "lidl", "aldi", "carrefour", "consum", "supermarket", "supermercado", "grocery", "groceries", "bread", "pan", "bakery", "panaderia"], ["groceries"]),
            (["restaurant", "restaurante", "lunch", "dinner", "comida", "cena", "cenar", "comimos", "cenamos"], ["restaurants"]),
            (["coffee", "cafe", "snack", "breakfast", "desayuno"], ["coffee & snacks"]),
            (["pharmacy", "farmacia", "medicine", "medicina"], ["pharmacy"]),
            (["doctor", "medico", "médico"], ["doctor"]),
            (["dentist", "dentista"], ["dentist"]),
            (["gym", "gimnasio"], ["gym"]),
            (["rent", "alquiler", "mortgage", "hipoteca"], ["rent & mortgage"]),
            (["electricity", "electricidad", "water", "agua", "utility", "utilities"], ["utilities", "water"]),
            (["netflix", "spotify", "streaming"], ["streaming"]),
            (["cinema", "movie", "film", "cine"], ["cinema"]),
            (["clothes", "clothing", "ropa"], ["clothing"]),
            (["nomina", "salario", "salary", "payroll", "paycheck", "sueldo"], ["salary", "payroll", "income"])
        ]

        // A handful of words above are specific enough on their own — brand/merchant names and
        // unambiguous activity words — to trust over a merely generic one from another rule that
        // happens to also be present (e.g. "comida" alone could describe almost anything, but
        // "mercadona" can't). When at least one matching category was reached through one of
        // these, any category reached *only* through a generic word is dropped before checking
        // for a genuine conflict below.
        let strongWords: Set<String> = [
            "uber", "cabify", "bolt", "lyft", "renfe",
            "mercadona", "lidl", "aldi", "carrefour", "consum",
            "fgv",
            "netflix", "spotify",
            "vuelo", "vuelos", "avion", "avión", "flight", "flights", "aerolinea", "aerolínea", "boarding",
            "hotel", "hostal", "airbnb",
            "farmacia", "pharmacy", "gimnasio", "dentista", "dentist",
            "nomina", "salario", "salary", "payroll", "sueldo"
        ]

        var strongMatches: [ObjectIdentifier: Category] = [:]
        var weakMatches: [ObjectIdentifier: Category] = [:]
        for rule in rules {
            let intersection = normalized.intersection(rule.words)
            guard !intersection.isEmpty, let match = category(namedLike: rule.categoryNames, in: categories) else { continue }
            let id = ObjectIdentifier(match)
            if intersection.isDisjoint(with: strongWords) {
                weakMatches[id] = match
            } else {
                strongMatches[id] = match
            }
        }

        // Never silently guess between two genuinely different plausible categories — leave the
        // note unresolved so the person can pick in the review step instead.
        let candidates = strongMatches.isEmpty ? weakMatches : strongMatches
        if candidates.count == 1 {
            return candidates.values.first
        }
        if candidates.count > 1 {
            return nil
        }
        return categoryMatch(for: categoryHint(for: note), in: categories)
    }

    /// Cleans the text left over once the date, verb and amount have all been removed. The
    /// leading-connector strip handles a note that's left starting with a dangling preposition —
    /// e.g. removing "20 euros" from "20 euros on taxi" leaves " on taxi", and removing it from
    /// "recibí 1500 euros de nómina" (after the verb itself is already gone) leaves " de nómina".
    /// The trailing-connector strip is the mirror image, for when the amount trailed the note
    /// with a connector in between — "Mercadona por 32 euros" leaves "Mercadona por" once "32
    /// euros" is gone.
    private static func cleanNote(_ rawNote: String) -> String {
        rawNote
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"^(?:on|for|at|in|en|para|por|a|de)\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\b(?:and|y|then)\b\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s+(?:on|for|at|in|en|para|por|a|de)$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    private static func categoryHint(for note: String) -> VoiceExpenseCategoryHint? {
        let words = normalizedWords(in: note)
        if !words.isDisjoint(with: ["mercadona", "supermercado", "supermarket", "grocery", "groceries", "lidl", "aldi", "carrefour", "dia", "bread", "pan", "bakery", "panaderia"]) {
            return .groceries
        }
        if !words.isDisjoint(with: ["taxi", "uber", "cab", "bolt", "metro", "bus", "tren", "train"]) {
            return .transport
        }
        return nil
    }

    private static func category(namedLike candidates: [String], in categories: [Category]) -> Category? {
        for candidate in candidates {
            if let match = categories.first(where: { matches(candidate: candidate, categoryName: $0.name) }) {
                return match
            }
        }
        return nil
    }

    /// Whether `candidate` names `categoryName` closely enough to auto-select it — either an
    /// exact (folded/case-insensitive) match, or, for a single-word candidate, one of
    /// `categoryName`'s own whole words. Deliberately never a raw substring check: a category
    /// named "Training" must not match the transit candidate "train" just because one contains
    /// the other's characters, and a multi-word candidate like "public transit" must match the
    /// category's full name rather than partially overlapping an unrelated one.
    private static func matches(candidate: String, categoryName: String) -> Bool {
        let normalizedCandidate = normalizedName(candidate)
        guard normalizedName(categoryName) != normalizedCandidate else { return true }
        guard !normalizedCandidate.contains(" ") else { return false }
        return normalizedWords(in: categoryName).contains(normalizedCandidate)
    }

    private static func normalizedWords(in text: String) -> Set<String> {
        Set(normalizedName(text).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
    }

    private static func normalizedName(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
    }

    // MARK: - Spoken dates

    /// Finds the first recognized date reference in `text` — an absolute day+month, a relative
    /// day word ("today"/"hoy", "yesterday"/"ayer", "tomorrow"/"mañana"), or a weekday name
    /// (optionally qualified with "last"/"next"/"pasado"/"próximo") — and returns both its
    /// resolved `Date` and the text with that reference removed. Tries the most specific/
    /// unambiguous form first (a spoken day+month can't be confused with anything else) down to
    /// the least specific (a bare weekday name). Returns nil when nothing is recognized, which
    /// keeps the existing safe behavior: no reference spoken, no date invented — the caller falls
    /// back to a shared date or `referenceDate`.
    private static func extractTemporalDate(
        from text: String, calendar: Calendar = .current, referenceDate: Date
    ) -> (date: Date, textWithoutDate: String)? {
        if let (date, range) = absoluteDayMonthDate(in: text, calendar: calendar, referenceDate: referenceDate) {
            var stripped = text
            stripped.removeSubrange(range)
            return (date, stripped)
        }
        if let (date, range) = relativeDayDate(in: text, calendar: calendar, referenceDate: referenceDate) {
            var stripped = text
            stripped.removeSubrange(range)
            return (date, stripped)
        }
        if let (date, range) = weekdayDate(in: text, calendar: calendar, referenceDate: referenceDate) {
            var stripped = text
            stripped.removeSubrange(range)
            return (date, stripped)
        }
        return nil
    }

    /// Supports natural English and Spanish day/month phrasing, for example
    /// "20 of September" and "20 de septiembre". An omitted year intentionally
    /// means `referenceDate`'s calendar year rather than guessing a future year.
    private static func absoluteDayMonthDate(
        in text: String, calendar: Calendar, referenceDate: Date
    ) -> (Date, Range<String.Index>)? {
        let pattern = #"\b(?:on\s+|el\s+)?(\d{1,2})(?:st|nd|rd|th)?\s*(?:of\s+|de\s+)?(january|february|march|april|may|june|july|august|september|october|november|december|enero|febrero|marzo|abril|mayo|junio|julio|agosto|septiembre|octubre|noviembre|diciembre)\b"#
        guard
            let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
            let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let fullRange = Range(match.range, in: text),
            let dayRange = Range(match.range(at: 1), in: text),
            let monthRange = Range(match.range(at: 2), in: text),
            let day = Int(text[dayRange]),
            let month = monthNumber(for: String(text[monthRange]))
        else { return nil }

        var components = DateComponents()
        components.calendar = calendar
        components.year = calendar.component(.year, from: referenceDate)
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else { return nil }
        return (date, fullRange)
    }

    /// "today"/"hoy", "yesterday"/"ayer", "tomorrow"/"mañana" — resolved as whole days relative
    /// to `referenceDate`, so a reference right at a month or year boundary naturally rolls over
    /// via `Calendar.date(byAdding:to:)` rather than any manual month/year arithmetic here.
    private static func relativeDayDate(
        in text: String, calendar: Calendar, referenceDate: Date
    ) -> (Date, Range<String.Index>)? {
        let terms: [(words: [String], offset: Int)] = [
            (["today", "hoy"], 0),
            (["yesterday", "ayer"], -1),
            (["tomorrow", "mañana", "manana"], 1)
        ]
        let today = calendar.startOfDay(for: referenceDate)
        for term in terms {
            let alternation = term.words.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
            guard
                let expression = try? NSRegularExpression(pattern: "\\b(?:\(alternation))\\b", options: [.caseInsensitive]),
                let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                let matchRange = Range(match.range, in: text),
                let date = calendar.date(byAdding: .day, value: term.offset, to: today)
            else { continue }
            return (date, matchRange)
        }
        return nil
    }

    /// A weekday name, optionally qualified with "last"/"pasado" (the most recent occurrence
    /// strictly before today) or "next"/"próximo" (the next occurrence strictly after today). An
    /// unqualified weekday ("el lunes", "on Friday") resolves to the nearest occurrence on or
    /// before today — the natural reading when logging a transaction that already happened.
    private static func weekdayDate(
        in text: String, calendar: Calendar, referenceDate: Date
    ) -> (Date, Range<String.Index>)? {
        let weekdayNumbers: [String: Int] = [
            "sunday": 1, "domingo": 1, "monday": 2, "lunes": 2,
            "tuesday": 3, "martes": 3, "wednesday": 4, "miercoles": 4, "miércoles": 4,
            "thursday": 5, "jueves": 5, "friday": 6, "viernes": 6,
            "saturday": 7, "sabado": 7, "sábado": 7
        ]
        let namesAlternation = weekdayNumbers.keys.joined(separator: "|")
        let pattern = #"\b(last|next|pasad[oa]|próxim[oa]|proxim[oa])?\s*(?:el\s+|la\s+|on\s+)?(\#(namesAlternation))\b"#
        guard
            let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
            let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let fullRange = Range(match.range, in: text),
            let nameRange = Range(match.range(at: 2), in: text),
            let targetWeekday = weekdayNumbers[normalizedName(String(text[nameRange]))]
        else { return nil }

        let qualifier = Range(match.range(at: 1), in: text).map { normalizedName(String(text[$0])) }
        let today = calendar.startOfDay(for: referenceDate)
        let todayWeekday = calendar.component(.weekday, from: today)
        let daysForward = (targetWeekday - todayWeekday + 7) % 7

        let dayOffset: Int
        if let qualifier, qualifier.hasPrefix("last") || qualifier.hasPrefix("pasad") {
            dayOffset = -(daysForward == 0 ? 7 : 7 - daysForward)
        } else if let qualifier, qualifier.hasPrefix("next") || qualifier.hasPrefix("proxim") {
            dayOffset = daysForward == 0 ? 7 : daysForward
        } else {
            dayOffset = -(daysForward == 0 ? 0 : 7 - daysForward)
        }
        guard let date = calendar.date(byAdding: .day, value: dayOffset, to: today) else { return nil }
        return (date, fullRange)
    }

    private static func monthNumber(for rawMonth: String) -> Int? {
        let months = [
            "january": 1, "enero": 1, "february": 2, "febrero": 2,
            "march": 3, "marzo": 3, "april": 4, "abril": 4,
            "may": 5, "mayo": 5, "june": 6, "junio": 6,
            "july": 7, "julio": 7, "august": 8, "agosto": 8,
            "september": 9, "septiembre": 9, "october": 10, "octubre": 10,
            "november": 11, "noviembre": 11, "december": 12, "diciembre": 12
        ]
        return months[normalizedName(rawMonth)]
    }
}

/// Saves one or more spoken expenses immediately — no review step. Both voice entry points
/// (Home's floating mic and `AddTransactionView`'s inline mic) use this instead of opening a form
/// or a batch-review sheet, so a multi-clause phrase like "20 en taxi y 35 en gasolina" saves both
/// entries in one go rather than only ever handling the first. Category is looked up per expense
/// exactly as the old review screens did — a note that doesn't match any existing category still
/// saves, simply uncategorized, rather than inventing one or blocking the save; it stays easy to
/// spot and fix from Entries afterward.
enum VoiceQuickSave {
    /// Returns the saved entries, or `nil` if there was nothing to save (`expenses` empty), no
    /// wallet to save into, or the save itself failed.
    @discardableResult
    static func save(
        _ expenses: [ParsedVoiceExpense], wallet: Wallet?, categories: [Category], modelContext: ModelContext
    ) -> [Entry]? {
        guard let wallet, !expenses.isEmpty else { return nil }

        let entries = expenses.map { expense -> Entry in
            let matchingCategories = categories.filter { !$0.isArchived && $0.isIncome == (expense.entryType == .income) }
            let category = VoiceExpenseParser.categoryMatch(for: expense.note, in: matchingCategories)
            return TransactionSaving.createEntry(
                amount: expense.amount, date: expense.date, note: expense.note, type: expense.entryType,
                category: category, wallet: wallet, modelContext: modelContext
            )
        }

        do {
            try modelContext.save()
        } catch {
            return nil
        }
        WidgetCenter.shared.reloadAllTimelines()
        return entries
    }
}

/// Suggests a Category for a transaction note/merchant string — first with a deterministic,
/// offline name match against the user's real categories (`localCategoryMatch`), falling back to
/// asking the Claude API to pick the best match only when that finds nothing. Best-effort UX
/// only — every failure path (missing key, offline, malformed response) returns nil rather than
/// throwing or crashing, and neither path ever invents a category name outside the user's own.
enum CategorizationService {
    /// Set once at launch from FinanceTrackerApp.init() — see `SeedData.seedIfNeeded` call site.
    static var modelContext: ModelContext?

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let model = "claude-opus-5"

    static func suggestCategory(for note: String, isIncome: Bool = false) async -> Category? {
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNote.isEmpty else { return nil }
        guard let modelContext else { return nil }

        guard
            let headCategories = try? modelContext.fetch(
                FetchDescriptor<HeadCategory>(sortBy: [SortDescriptor(\.sortOrder)])
            )
        else { return nil }

        var promptLines: [String] = []
        var allCategories: [Category] = []
        for head in headCategories {
            let activeCategories = head.categories
                .filter { !$0.isArchived && $0.isIncome == isIncome }
                .sorted { $0.name < $1.name }
            guard !activeCategories.isEmpty else { continue }
            promptLines.append("\(head.name): \(activeCategories.map(\.name).joined(separator: ", "))")
            allCategories.append(contentsOf: activeCategories)
        }
        guard !allCategories.isEmpty else { return nil }

        // Deterministic, offline pass first — see `localCategoryMatch`. Only falls through to
        // the AI suggestion below when nothing in the user's own category names obviously
        // matches, so the common "the merchant/description already names a category" case
        // (e.g. "Rent", "Gym membership") resolves instantly, with no network call and no API
        // key required — important for a Shortcuts Automation that may run unattended.
        if let voiceMatch = VoiceExpenseParser.categoryMatch(for: trimmedNote, in: allCategories) {
            return voiceMatch
        }

        guard let apiKey else { return nil }

        let prompt = """
        You categorize personal finance transactions. Given a transaction note or merchant \
        name, pick the single best matching category from the list below.

        Categories, grouped by head category:
        \(promptLines.joined(separator: "\n"))

        Transaction note: "\(trimmedNote)"

        Reply with ONLY the exact category name from the list above that best matches — \
        nothing else, no punctuation, no explanation. If nothing fits reasonably well, reply \
        with exactly: None
        """

        guard let suggestionText = await requestSuggestion(prompt: prompt, apiKey: apiKey) else {
            return nil
        }

        if let matched = matchCategory(named: suggestionText, in: allCategories) {
            return matched
        }
        return allCategories.first { $0.name.caseInsensitiveCompare("Miscellaneous") == .orderedSame }
    }

    // MARK: - Transaction extraction (from forwarded bank/wallet text)

    /// Sends a forwarded bank/wallet notification (SMS, push body, etc.) to Claude in a single
    /// call and asks it to extract amount, merchant/note, and best-matching category as JSON.
    /// Best-effort like `suggestCategory` — returns nil on any failure rather than throwing.
    static func extractTransaction(from rawText: String) async -> ExtractedTransaction? {
        let trimmedText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return nil }
        guard let apiKey else { return nil }

        var categoryNames: [String] = []
        if let modelContext,
           let headCategories = try? modelContext.fetch(
               FetchDescriptor<HeadCategory>(sortBy: [SortDescriptor(\.sortOrder)])
           ) {
            for head in headCategories {
                categoryNames.append(
                    contentsOf: head.categories
                        .filter { !$0.isArchived && !$0.isIncome }
                        .map(\.name)
                )
            }
        }
        let categoryList = categoryNames.isEmpty ? "(none available)" : categoryNames.joined(separator: ", ")

        let prompt = """
        Extract transaction details from this forwarded bank or wallet notification text \
        (SMS, push notification, email snippet, etc.). Reply with ONLY a single-line JSON \
        object, no markdown formatting, no explanation, in exactly this shape:
        {"amount": <number>, "note": "<merchant or short description>", "category": "<name or null>"}

        Rules:
        - "amount" must be a plain positive number (no currency symbol, no thousands separator).
        - "note" should be a short merchant name or description suitable as a transaction note.
        - "category" must be exactly one of these names if one clearly fits, otherwise null: \(categoryList)

        Text:
        \"\"\"
        \(trimmedText)
        \"\"\"
        """

        guard let responseText = await requestSuggestion(prompt: prompt, apiKey: apiKey, maxTokens: 200) else {
            return nil
        }
        return parseExtraction(responseText)
    }

    /// Exposed (rather than private) so tests can exercise malformed-JSON handling directly.
    static func parseExtraction(_ text: String) -> ExtractedTransaction? {
        guard
            let jsonStart = text.firstIndex(of: "{"),
            let jsonEnd = text.lastIndex(of: "}"),
            let data = text[jsonStart...jsonEnd].data(using: .utf8),
            let raw = try? JSONDecoder().decode(RawExtraction.self, from: data),
            raw.amount > 0
        else { return nil }

        return ExtractedTransaction(
            amount: Decimal(raw.amount),
            note: raw.note.trimmingCharacters(in: .whitespacesAndNewlines),
            categoryName: raw.category?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    // MARK: - Networking

    private static func requestSuggestion(prompt: String, apiKey: String, maxTokens: Int = 20) async -> String? {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body = MessagesRequest(
            model: model,
            maxTokens: maxTokens,
            messages: [.init(role: "user", content: prompt)],
            outputConfig: .init(effort: "low")
        )

        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            return nil
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                return nil
            }
            let decoded = try JSONDecoder().decode(MessagesResponse.self, from: data)
            guard let text = decoded.content.first(where: { $0.type == "text" })?.text else {
                return nil
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            // Network failure, decoding failure, cancellation — all treated as "no suggestion".
            return nil
        }
    }

    // MARK: - Matching

    /// Deterministic, offline category match: does an active category's own name appear as a
    /// case-insensitive substring of `note` (or vice versa — covers a short note like "Gym"
    /// matching a longer category name like "Gym Membership")? Reuses the caller's real
    /// `Category` rows exactly as `matchCategory(named:in:)` does — never invents a name, only
    /// ever returns one of `categories`. Internal (not `private`) so it's directly unit-testable
    /// without a `ModelContext`.
    ///
    /// When more than one category matches, the longest matching category name wins, so a more
    /// specific category (e.g. "Fast Food") is preferred over a shorter, coincidentally-matching
    /// one (e.g. "Food"). Exposed as its own function (rather than folded into `suggestCategory`)
    /// so it stays testable as a pure function and so `suggestCategory` can try it before ever
    /// requiring an API key.
    static func localCategoryMatch(for note: String, in categories: [Category]) -> Category? {
        let normalizedNote = note.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedNote.isEmpty else { return nil }

        let matches = categories.compactMap { category -> (Category, Int)? in
            let normalizedName = category.name.lowercased()
            guard !normalizedName.isEmpty else { return nil }
            guard normalizedNote.contains(normalizedName) || normalizedName.contains(normalizedNote) else { return nil }
            return (category, normalizedName.count)
        }

        return matches.max { $0.1 < $1.1 }?.0
    }

    private static func matchCategory(named suggestion: String, in categories: [Category]) -> Category? {
        let normalized = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.caseInsensitiveCompare("None") != .orderedSame else {
            return nil
        }
        return categories.first { $0.name.caseInsensitiveCompare(normalized) == .orderedSame }
    }

    // MARK: - API key

    /// Reads ANTHROPIC_API_KEY from Secrets.plist (gitignored). Returns nil if the file is
    /// missing, malformed, empty, or still holds the placeholder value.
    private static var apiKey: String? {
        guard
            let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
            let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
            let key = plist["ANTHROPIC_API_KEY"] as? String
        else { return nil }

        return sanitizedAPIKey(from: key)
    }

    /// nil for an empty/whitespace-only key or the still-unfilled placeholder; the trimmed key otherwise.
    /// Exposed (rather than private) so tests can cover the placeholder case without a Secrets.plist.
    static func sanitizedAPIKey(from raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "INSERT_YOUR_ANTHROPIC_API_KEY_HERE" else { return nil }
        return trimmed
    }
}

/// Result of `CategorizationService.extractTransaction(from:)`.
struct ExtractedTransaction {
    let amount: Decimal
    let note: String
    /// Name of the best-matching existing category, or nil if none fit well.
    let categoryName: String?
}

private struct RawExtraction: Decodable {
    let amount: Double
    let note: String
    let category: String?
}

// MARK: - Request/response models

private struct MessagesRequest: Encodable {
    let model: String
    let maxTokens: Int
    let messages: [Message]
    let outputConfig: OutputConfig

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case messages
        case outputConfig = "output_config"
    }

    struct Message: Encodable {
        let role: String
        let content: String
    }

    struct OutputConfig: Encodable {
        let effort: String
    }
}

private struct MessagesResponse: Decodable {
    let content: [ContentBlock]

    struct ContentBlock: Decodable {
        let type: String
        let text: String?
    }
}

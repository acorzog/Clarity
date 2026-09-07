import Foundation

enum IconGroupID: String, CaseIterable, Identifiable {
    case money = "Money & Finance"
    case home = "Home & Utilities"
    case food = "Food & Drink"
    case shopping = "Shopping"
    case transport = "Transport"
    case health = "Health"
    case travel = "Travel"
    case entertainment = "Entertainment"
    case sports = "Sports & Fitness"
    case nature = "Nature & Weather"
    case work = "Work & Business"
    case family = "Family & Pets"
    case subscriptions = "Subscriptions & Software"
    case symbols = "Symbols & Flags"
    case general = "General"

    var id: String { rawValue }
}

/// One pickable icon: an SF Symbol paired with a human name and search keywords, so a search
/// field can resolve something like "coffee" straight to `cup.and.saucer.fill` instead of
/// requiring the user to browse groups or know the raw SF Symbol name.
struct IconDefinition: Identifiable, Hashable {
    let id: String
    let symbolName: String
    let displayName: String
    let group: IconGroupID
    let keywords: [String]
}

/// A named bucket of icons for the "browse by group" tab UI — derived from `IconCatalog.all`.
struct IconGroup {
    let title: String
    let icons: [String]
}

enum IconCatalog {
    private static func defs(
        _ group: IconGroupID,
        _ raw: [(slug: String, symbol: String, name: String, keywords: [String])]
    ) -> [IconDefinition] {
        raw.map {
            IconDefinition(id: "\(group).\($0.slug)", symbolName: $0.symbol, displayName: $0.name, group: group, keywords: $0.keywords)
        }
    }

    static let all: [IconDefinition] =
        defs(.money, [
            ("cash", "banknote.fill", "Cash", ["cash", "money", "banknote", "bill"]),
            ("dollar", "dollarsign.circle.fill", "Dollar", ["dollar", "usd", "currency", "money"]),
            ("euro", "eurosign.circle.fill", "Euro", ["euro", "eur", "currency", "money"]),
            ("card", "creditcard.fill", "Card", ["card", "credit", "debit", "payment"]),
            ("investing", "chart.line.uptrend.xyaxis", "Investing", ["invest", "stocks", "growth", "portfolio"]),
            ("chart", "chart.bar.fill", "Chart", ["chart", "stats", "analytics", "report"]),
            ("budget", "chart.pie.fill", "Budget", ["budget", "pie", "breakdown", "split"]),
            ("bank", "building.columns.fill", "Bank", ["bank", "savings", "institution", "finance"]),
            ("wallet", "wallet.pass.fill", "Wallet", ["wallet", "pass", "purse"]),
            ("tax", "percent", "Tax", ["tax", "percent", "vat", "rate"]),
            ("incomeIn", "arrow.down.circle.fill", "Income In", ["income", "deposit", "received", "in", "bizum in"]),
            ("moneyOut", "arrow.up.circle.fill", "Money Out", ["withdrawal", "sent", "out", "payment", "bizum out"]),
            ("refund", "arrow.uturn.backward.circle.fill", "Refund", ["refund", "reimburse", "return", "back"]),
            ("transfer", "arrow.left.arrow.right", "Transfer", ["transfer", "exchange", "swap", "move"]),
            ("salary", "briefcase.fill", "Salary", ["salary", "job", "work", "freelance", "income"])
        ]) +
        defs(.home, [
            ("house", "house.fill", "House", ["house", "home", "rent", "mortgage"]),
            ("keys", "key.fill", "Keys", ["key", "lock", "access", "rent"]),
            ("electricity", "bolt.fill", "Electricity", ["electricity", "power", "energy", "utility"]),
            ("internet", "wifi", "Internet", ["internet", "wifi", "broadband"]),
            ("phoneBill", "iphone", "Phone Bill", ["phone", "mobile", "cell"]),
            ("water", "drop.fill", "Water", ["water", "utility", "bill"]),
            ("gas", "flame.fill", "Gas", ["gas", "heating", "utility"]),
            ("lighting", "lightbulb.fill", "Lighting", ["light", "bulb", "electricity"]),
            ("maintenance", "wrench.and.screwdriver.fill", "Maintenance", ["maintenance", "repair", "fix"]),
            ("renovation", "hammer.fill", "Renovation", ["renovation", "build", "diy"]),
            ("painting", "paintbrush.fill", "Painting", ["paint", "decorate", "diy"]),
            ("waste", "trash.fill", "Waste", ["trash", "garbage", "waste"]),
            ("cleaning", "sparkles", "Cleaning", ["cleaning", "clean", "tidy"]),
            ("furniture", "bed.double.fill", "Furniture", ["bed", "furniture", "bedroom"]),
            ("apartment", "building.2.fill", "Apartment", ["apartment", "building", "condo"]),
            ("insurance", "shield.fill", "Insurance", ["insurance", "protection", "coverage"]),
            ("security", "lock.fill", "Security", ["security", "lock", "safety"]),
            ("cable", "network", "Cable", ["cable", "network", "provider"])
        ]) +
        defs(.food, [
            ("restaurant", "fork.knife", "Restaurant", ["restaurant", "dining", "eat"]),
            ("coffee", "cup.and.saucer.fill", "Coffee", ["coffee", "cafe", "tea"]),
            ("drinks", "wineglass.fill", "Drinks", ["wine", "drinks", "alcohol", "bar"]),
            ("bakery", "birthday.cake.fill", "Bakery", ["cake", "bakery", "dessert"]),
            ("takeout", "takeoutbag.and.cup.and.straw.fill", "Takeout", ["takeout", "delivery", "fast food"]),
            ("tea", "mug.fill", "Tea", ["tea", "mug", "drink"]),
            ("groceries", "basket.fill", "Groceries", ["groceries", "supermarket", "shopping"]),
            ("produce", "carrot.fill", "Produce", ["produce", "vegetables", "fresh"]),
            ("organic", "leaf.fill", "Organic", ["organic", "healthy", "vegan"])
        ]) +
        defs(.shopping, [
            ("cart", "cart.fill", "Cart", ["cart", "shopping", "purchase"]),
            ("bag", "bag.fill", "Bag", ["bag", "shopping", "retail"]),
            ("sale", "tag.fill", "Sale", ["sale", "tag", "discount", "price"]),
            ("gift", "gift.fill", "Gift", ["gift", "present", "donation"]),
            ("package", "shippingbox.fill", "Package", ["package", "delivery", "shipping", "order"]),
            ("clothing", "tshirt.fill", "Clothing", ["clothes", "clothing", "apparel", "fashion"]),
            ("store", "storefront.fill", "Store", ["store", "shop", "retail"])
        ]) +
        defs(.transport, [
            ("car", "car.fill", "Car", ["car", "drive", "vehicle", "taxi"]),
            ("carRental", "car.2.fill", "Car Rental", ["rental", "carshare", "rent a car"]),
            ("bus", "bus.fill", "Bus", ["bus", "transit", "public transport"]),
            ("train", "tram.fill", "Train", ["train", "tram", "metro", "subway"]),
            ("bike", "bicycle", "Bike", ["bike", "bicycle", "cycling"]),
            ("fuel", "fuelpump.fill", "Fuel", ["fuel", "gas", "petrol", "gasoline"]),
            ("parking", "parkingsign.circle.fill", "Parking", ["parking", "garage"]),
            ("flight", "airplane", "Flight", ["flight", "plane", "airplane", "airport"])
        ]) +
        defs(.health, [
            ("healthcare", "cross.case.fill", "Healthcare", ["healthcare", "medical", "doctor", "hospital"]),
            ("medical", "cross.fill", "Medical", ["medical", "health", "first aid"]),
            ("wellness", "heart.fill", "Wellness", ["heart", "wellness", "love", "health"]),
            ("pharmacy", "pills.fill", "Pharmacy", ["pharmacy", "medicine", "pills"]),
            ("supplements", "pill.fill", "Supplements", ["supplements", "vitamins", "pill"]),
            ("activity", "figure.walk", "Activity", ["walk", "activity", "exercise"]),
            ("firstAid", "bandage.fill", "First Aid", ["bandage", "first aid", "injury"]),
            ("checkup", "waveform.path.ecg", "Checkup", ["checkup", "ecg", "heartbeat", "exam"]),
            ("doctor", "stethoscope", "Doctor", ["doctor", "physician", "checkup", "dentist"]),
            ("optician", "eyeglasses", "Optician", ["glasses", "lenses", "optician", "eyes"]),
            ("gym", "figure.strengthtraining.traditional", "Gym", ["gym", "fitness", "workout", "strength"]),
            ("mentalHealth", "brain.head.profile", "Mental Health", ["mental health", "therapy", "psychology"]),
            ("therapy", "figure.mind.and.body", "Therapy", ["therapy", "mindfulness", "wellness"]),
            ("fitness", "figure.run", "Fitness", ["run", "fitness", "cardio", "jog"])
        ]) +
        defs(.travel, [
            ("flight", "airplane", "Flight", ["flight", "trip", "vacation", "airport"]),
            ("luggage", "suitcase.fill", "Luggage", ["luggage", "suitcase", "packing"]),
            ("map", "map.fill", "Map", ["map", "navigation", "route"]),
            ("abroad", "globe", "Abroad", ["abroad", "international", "world"]),
            ("beach", "beach.umbrella.fill", "Beach", ["beach", "vacation", "umbrella"]),
            ("photography", "camera.fill", "Photography", ["photo", "camera", "memories"]),
            ("sightseeing", "binoculars.fill", "Sightseeing", ["sightseeing", "tour", "explore", "attraction"]),
            ("hotel", "bed.double.fill", "Hotel", ["hotel", "stay", "accommodation"]),
            ("ticket", "ticket.fill", "Ticket", ["ticket", "admission", "pass"]),
            ("museum", "building.columns.fill", "Museum", ["museum", "landmark", "attraction"])
        ]) +
        defs(.entertainment, [
            ("games", "gamecontroller.fill", "Games", ["games", "gaming", "videogame"]),
            ("movies", "film.fill", "Movies", ["movie", "cinema", "film"]),
            ("music", "music.note", "Music", ["music", "concert", "song"]),
            ("event", "ticket.fill", "Event", ["event", "show", "concert"]),
            ("streaming", "tv.fill", "Streaming", ["tv", "streaming", "show"]),
            ("podcasts", "headphones", "Podcasts", ["podcast", "audio", "headphones"]),
            ("books", "book.fill", "Books", ["book", "reading", "education"]),
            ("art", "paintpalette.fill", "Art", ["art", "hobby", "craft"]),
            ("nightlife", "moon.stars.fill", "Nightlife", ["nightlife", "night out", "party"]),
            ("haircut", "scissors", "Haircut", ["haircut", "hair", "salon", "barber", "peluqueria"]),
            ("theater", "theatermasks.fill", "Theater", ["theater", "drama", "show"])
        ]) +
        defs(.sports, [
            ("running", "figure.run", "Running", ["running", "jog", "cardio"]),
            ("walking", "figure.walk", "Walking", ["walking", "steps", "stroll"]),
            ("hiking", "figure.hiking", "Hiking", ["hiking", "trail", "outdoors"]),
            ("swimming", "figure.pool.swim", "Swimming", ["swim", "pool", "swimming"]),
            ("yoga", "figure.yoga", "Yoga", ["yoga", "stretch", "mindfulness"]),
            ("strength", "figure.strengthtraining.traditional", "Strength Training", ["strength", "weights", "training"]),
            ("courtSports", "sportscourt.fill", "Court Sports", ["court", "tennis", "basketball"]),
            ("competition", "trophy.fill", "Competition", ["trophy", "win", "competition", "award"]),
            ("medal", "medal.fill", "Medal", ["medal", "award", "achievement"]),
            ("weights", "dumbbell.fill", "Weights", ["weights", "dumbbell", "strength"]),
            ("soccer", "soccerball", "Soccer", ["soccer", "football", "futbol"]),
            ("basketball", "basketball.fill", "Basketball", ["basketball", "hoops"]),
            ("tennis", "tennis.racket", "Tennis", ["tennis", "racket"])
        ]) +
        defs(.nature, [
            ("sunny", "sun.max.fill", "Sunny", ["sun", "sunny", "weather"]),
            ("cloudy", "cloud.fill", "Cloudy", ["cloud", "cloudy", "weather"]),
            ("rain", "cloud.rain.fill", "Rain", ["rain", "weather", "storm"]),
            ("snow", "snowflake", "Snow", ["snow", "winter", "cold"]),
            ("night", "moon.fill", "Night", ["night", "moon", "evening"]),
            ("wind", "wind", "Wind", ["wind", "breeze", "weather"]),
            ("umbrella", "umbrella.fill", "Umbrella", ["umbrella", "rain", "protection"]),
            ("leaf", "leaf.fill", "Nature", ["nature", "leaf", "plant", "eco"])
        ]) +
        defs(.work, [
            ("briefcase", "briefcase.fill", "Business", ["work", "business", "job", "office"]),
            ("office", "building.2.fill", "Office", ["office", "building", "company"]),
            ("laptop", "laptopcomputer", "Laptop", ["laptop", "computer", "equipment"]),
            ("desktop", "desktopcomputer", "Desktop", ["desktop", "computer", "equipment"]),
            ("printer", "printer.fill", "Printer", ["printer", "print", "office supplies"]),
            ("tools", "keyboard", "Software Tools", ["keyboard", "typing", "tools"]),
            ("invoice", "doc.text.fill", "Invoice", ["invoice", "document", "receipt", "paperwork", "iva"]),
            ("tax", "percent", "Tax & VAT", ["tax", "vat", "accounting", "irpf"]),
            ("accountant", "person.crop.circle.fill", "Accountant", ["accountant", "advisor", "professional", "gestor"]),
            ("chart", "chart.bar.fill", "Business Report", ["business", "chart", "report"]),
            ("government", "building.columns.fill", "Government", ["government", "social security", "institution"])
        ]) +
        defs(.family, [
            ("pet", "pawprint.fill", "Pet", ["pet", "paw", "animal"]),
            ("couple", "person.2.fill", "Couple", ["couple", "two people", "partner"]),
            ("group", "person.3.fill", "Group", ["group", "family", "friends"]),
            ("kids", "figure.and.child.holdinghands", "Kids", ["kids", "children", "family"]),
            ("dog", "dog.fill", "Dog", ["dog", "pet", "animal"]),
            ("cat", "cat.fill", "Cat", ["cat", "pet", "animal"]),
            ("fish", "fish.fill", "Fish", ["fish", "pet", "aquarium"]),
            ("turtle", "tortoise.fill", "Turtle", ["turtle", "tortoise", "pet"]),
            ("familyHome", "house.fill", "Family Home", ["family", "home", "household"]),
            ("familyGift", "gift.fill", "Gift", ["gift", "present", "birthday"])
        ]) +
        defs(.subscriptions, [
            ("streaming", "play.rectangle.fill", "Video Streaming", ["streaming", "video", "subscription"]),
            ("musicStreaming", "music.note", "Music Streaming", ["music streaming", "spotify", "subscription"]),
            ("cloudStorage", "icloud.fill", "Cloud Storage", ["cloud", "storage", "backup"]),
            ("app", "square.grid.2x2.fill", "App", ["app", "software", "tool"]),
            ("ai", "sparkles", "AI Tools", ["ai", "chatgpt", "claude", "assistant"]),
            ("news", "newspaper.fill", "News", ["news", "magazine", "subscription"]),
            ("vpn", "lock.shield.fill", "VPN", ["vpn", "security", "privacy"]),
            ("renewal", "arrow.clockwise.circle.fill", "Renewal", ["renewal", "recurring", "subscription", "membership"]),
            ("gaming", "gamecontroller.fill", "Gaming Subscription", ["gaming subscription", "game pass"]),
            ("mobilePlan", "antenna.radiowaves.left.and.right", "Mobile Plan", ["signal", "broadcast", "mobile plan"]),
            ("fitnessApp", "figure.run", "Fitness App", ["fitness app", "workout subscription"])
        ]) +
        defs(.symbols, [
            ("flag", "flag.fill", "Flag", ["flag", "marker", "milestone"]),
            ("race", "flag.2.crossed.fill", "Race", ["race", "competition", "finish"]),
            ("finish", "flag.checkered", "Finish", ["finish", "checkered", "race"]),
            ("favorite", "star.fill", "Favorite", ["favorite", "star", "rating"]),
            ("featured", "star.circle.fill", "Featured", ["featured", "highlight", "star"]),
            ("verified", "checkmark.seal.fill", "Verified", ["verified", "approved", "seal"]),
            ("number", "number", "Number", ["number", "hashtag", "id"]),
            ("world", "globe", "World", ["world", "global", "international"])
        ]) +
        defs(.general, [
            ("unknown", "questionmark.circle.fill", "Unknown", ["unknown", "unclear", "other"]),
            ("other", "ellipsis.circle.fill", "Other", ["other", "misc", "more"]),
            ("warning", "exclamationmark.triangle.fill", "Warning", ["warning", "alert", "important", "fine"]),
            ("flag", "flag.fill", "Flag", ["flag", "marker", "country"]),
            ("world", "globe", "World", ["world", "global", "international"]),
            ("package", "shippingbox.fill", "Package", ["package", "box", "misc"]),
            ("love", "heart.fill", "Love", ["love", "favorite", "care"]),
            ("charity", "hands.sparkles.fill", "Charity", ["charity", "donation", "help"]),
            ("cash", "banknote.fill", "Cash", ["cash", "money", "misc"]),
            ("transfer", "arrow.left.arrow.right", "Transfer", ["transfer", "exchange", "move"])
        ])

    /// Icons grouped for the "browse by category" tab UI.
    static var groups: [IconGroup] {
        IconGroupID.allCases.compactMap { group in
            let icons = all.filter { $0.group == group }.map(\.symbolName)
            guard !icons.isEmpty else { return nil }
            return IconGroup(title: group.rawValue, icons: icons)
        }
    }

    /// Matches a free-text query against display names and keywords — e.g. "coffee" resolves
    /// straight to `cup.and.saucer.fill` without the user browsing groups or knowing SF Symbol names.
    ///
    /// The same SF Symbol intentionally appears under multiple concepts (e.g. `airplane` is both
    /// "Flight" under Transport and under Travel), so a query can match more than one definition
    /// for the same symbol. Since picking is ultimately just choosing a symbol name, showing that
    /// symbol twice — and having both tiles light up together, since they'd share `selectedIcon`
    /// — is a bug, not a legitimate second option. Keep only the first match per symbol.
    static func search(_ query: String) -> [IconDefinition] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        var seenSymbols = Set<String>()
        var results: [IconDefinition] = []
        for def in all where def.displayName.lowercased().contains(q) || def.keywords.contains(where: { $0.contains(q) }) {
            guard seenSymbols.insert(def.symbolName).inserted else { continue }
            results.append(def)
        }
        return results
    }
}

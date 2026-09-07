import Foundation

enum EmojiGroupID: String, CaseIterable, Identifiable {
    case money = "Money"
    case home = "Home"
    case food = "Food & Drink"
    case shopping = "Shopping"
    case transport = "Transport"
    case health = "Health"
    case travel = "Travel"
    case entertainment = "Entertainment"
    case sports = "Sports"
    case family = "Family & Pets"
    case flags = "Flags"
    case symbols = "Symbols"

    var id: String { rawValue }
}

/// One pickable emoji: the character itself paired with a human name and search keywords,
/// mirroring `IconDefinition` so the emoji grid can be searched the same way the SF Symbol
/// grid is — e.g. "party" resolves straight to 🎉 without browsing every group.
struct EmojiDefinition: Identifiable, Hashable {
    let id: String
    let emoji: String
    let displayName: String
    let group: EmojiGroupID
    let keywords: [String]
}

/// A named bucket of emoji for the "browse by group" tab UI — derived from `EmojiCatalog.all`.
struct EmojiGroup {
    let title: String
    let emoji: [String]
}

enum EmojiCatalog {
    private static func defs(
        _ group: EmojiGroupID,
        _ raw: [(slug: String, emoji: String, name: String, keywords: [String])]
    ) -> [EmojiDefinition] {
        raw.map {
            EmojiDefinition(id: "\(group).\($0.slug)", emoji: $0.emoji, displayName: $0.name, group: group, keywords: $0.keywords)
        }
    }

    static let all: [EmojiDefinition] =
        defs(.money, [
            ("moneyBag", "💰", "Money Bag", ["money", "cash", "savings", "rich"]),
            ("dollarBill", "💵", "Dollar Bill", ["dollar", "cash", "money", "bill", "usd"]),
            ("yenBill", "💴", "Yen Bill", ["yen", "money", "japan", "currency"]),
            ("euroBill", "💶", "Euro Bill", ["euro", "money", "europe", "currency"]),
            ("poundBill", "💷", "Pound Bill", ["pound", "money", "uk", "sterling", "currency"]),
            ("creditCard", "💳", "Credit Card", ["card", "credit", "debit", "payment"]),
            ("bank", "🏦", "Bank", ["bank", "savings", "institution"]),
            ("chartUp", "📈", "Chart Up", ["chart", "investing", "growth", "stocks", "profit"]),
            ("chartDown", "📉", "Chart Down", ["chart", "loss", "decline", "stocks"]),
            ("coin", "🪙", "Coin", ["coin", "money", "currency", "crypto"]),
            ("moneyWings", "💸", "Money Flying", ["spending", "expense", "money", "flying", "outcome"]),
            ("receipt", "🧾", "Receipt", ["receipt", "invoice", "bill"]),
            ("dollarSign", "💲", "Dollar Sign", ["dollar", "currency", "sign"]),
            ("moneyFace", "🤑", "Money Face", ["rich", "money", "greedy"])
        ]) +
        defs(.home, [
            ("house", "🏠", "House", ["house", "home"]),
            ("houseGarden", "🏡", "House with Garden", ["home", "garden", "house"]),
            ("key", "🔑", "Key", ["key", "lock", "access", "rent"]),
            ("lightbulb", "💡", "Light Bulb", ["light", "electricity", "idea"]),
            ("shower", "🚿", "Shower", ["shower", "water", "bathroom"]),
            ("couch", "🛋️", "Couch", ["sofa", "furniture", "living room"]),
            ("broom", "🧹", "Broom", ["cleaning", "sweep", "chores"]),
            ("wrench", "🔧", "Wrench", ["repair", "tools", "fix"]),
            ("tools", "🛠️", "Tools", ["tools", "repair", "maintenance"]),
            ("window", "🪟", "Window", ["window", "home"]),
            ("bed", "🛏️", "Bed", ["bed", "bedroom", "furniture"]),
            ("laundryBasket", "🧺", "Laundry Basket", ["laundry", "chores", "basket"]),
            ("plant", "🪴", "Plant", ["plant", "garden", "decoration"]),
            ("fire", "🔥", "Fire", ["gas", "heating", "fire"])
        ]) +
        defs(.food, [
            ("burger", "🍔", "Burger", ["burger", "fast food"]),
            ("pizza", "🍕", "Pizza", ["pizza", "fast food"]),
            ("fries", "🍟", "Fries", ["fries", "fast food"]),
            ("taco", "🌮", "Taco", ["taco", "mexican"]),
            ("sushi", "🍣", "Sushi", ["sushi", "japanese"]),
            ("noodles", "🍜", "Noodles", ["ramen", "noodles", "soup"]),
            ("cake", "🍰", "Cake", ["cake", "dessert", "bakery"]),
            ("donut", "🍩", "Donut", ["donut", "dessert", "bakery"]),
            ("coffee", "☕", "Coffee", ["coffee", "cafe", "tea"]),
            ("beer", "🍺", "Beer", ["beer", "drinks", "alcohol"]),
            ("wine", "🍷", "Wine", ["wine", "drinks", "alcohol"]),
            ("salad", "🥗", "Salad", ["salad", "healthy", "vegetables"]),
            ("apple", "🍎", "Apple", ["apple", "fruit", "produce"]),
            ("cart", "🛒", "Groceries", ["groceries", "shopping", "cart"]),
            ("iceCream", "🍦", "Ice Cream", ["ice cream", "dessert"]),
            ("croissant", "🥐", "Croissant", ["bakery", "breakfast"]),
            ("eggs", "🍳", "Eggs", ["breakfast", "eggs", "cooking"]),
            ("chocolate", "🍫", "Chocolate", ["chocolate", "candy", "snack"])
        ]) +
        defs(.shopping, [
            ("shoppingBags", "🛍️", "Shopping Bags", ["shopping", "bags", "retail"]),
            ("dress", "👗", "Dress", ["clothes", "dress", "fashion"]),
            ("heels", "👠", "Heels", ["shoes", "fashion"]),
            ("handbag", "👜", "Handbag", ["bag", "purse", "fashion"]),
            ("gift", "🎁", "Gift", ["gift", "present"]),
            ("lipstick", "💄", "Lipstick", ["makeup", "beauty", "cosmetics"]),
            ("tie", "👔", "Tie", ["clothes", "formal", "work"]),
            ("sunglasses", "🕶️", "Sunglasses", ["accessories", "sunglasses"]),
            ("sneaker", "👟", "Sneaker", ["shoes", "sneakers"]),
            ("ring", "💍", "Ring", ["jewelry", "ring"])
        ]) +
        defs(.transport, [
            ("car", "🚗", "Car", ["car", "drive"]),
            ("taxi", "🚕", "Taxi", ["taxi", "cab"]),
            ("bus", "🚌", "Bus", ["bus", "transit"]),
            ("train", "🚆", "Train", ["train", "rail"]),
            ("plane", "✈️", "Plane", ["flight", "airplane"]),
            ("bike", "🚲", "Bike", ["bicycle", "cycling"]),
            ("fuel", "⛽", "Fuel", ["gas", "fuel", "petrol"]),
            ("parking", "🅿️", "Parking", ["parking"]),
            ("scooter", "🛵", "Scooter", ["scooter", "moped"]),
            ("rocket", "🚀", "Rocket", ["rocket", "launch"]),
            ("ship", "🚢", "Ship", ["boat", "ship", "cruise"]),
            ("kickScooter", "🛴", "Kick Scooter", ["scooter", "kick"])
        ]) +
        defs(.health, [
            ("pill", "💊", "Pill", ["medicine", "pharmacy"]),
            ("stethoscope", "🩺", "Stethoscope", ["doctor", "checkup"]),
            ("hospital", "🏥", "Hospital", ["hospital", "medical"]),
            ("tooth", "🦷", "Tooth", ["dentist", "teeth"]),
            ("syringe", "💉", "Syringe", ["injection", "vaccine"]),
            ("brain", "🧠", "Brain", ["mental health", "brain"]),
            ("mask", "😷", "Mask", ["sick", "mask", "covid"]),
            ("bandage", "🩹", "Bandage", ["bandage", "first aid"]),
            ("lotion", "🧴", "Lotion", ["skincare", "lotion"]),
            ("bone", "🦴", "Bone", ["bone", "orthopedic"])
        ]) +
        defs(.travel, [
            ("flight", "✈️", "Flight", ["flight", "airplane", "trip"]),
            ("luggage", "🧳", "Luggage", ["luggage", "suitcase", "packing"]),
            ("map", "🗺️", "Map", ["map", "navigation"]),
            ("beach", "🏖️", "Beach", ["beach", "vacation"]),
            ("hotel", "🏨", "Hotel", ["hotel", "stay"]),
            ("landmark", "🗽", "Landmark", ["landmark", "statue", "monument"]),
            ("camping", "⛺", "Camping", ["camp", "tent", "outdoors"]),
            ("palmTree", "🌴", "Palm Tree", ["tropical", "vacation", "beach"]),
            ("backpack", "🎒", "Backpack", ["backpack", "travel", "hiking"]),
            ("passport", "🛂", "Passport", ["passport", "customs", "immigration"])
        ]) +
        defs(.entertainment, [
            ("gaming", "🎮", "Gaming", ["games", "gaming"]),
            ("movie", "🎬", "Movie", ["movie", "cinema", "film"]),
            ("music", "🎵", "Music", ["music", "song"]),
            ("guitar", "🎸", "Guitar", ["music", "guitar", "instrument"]),
            ("books", "📚", "Books", ["books", "reading"]),
            ("theater", "🎭", "Theater", ["theater", "drama"]),
            ("art", "🎨", "Art", ["art", "painting", "hobby"]),
            ("ticket", "🎟️", "Ticket", ["ticket", "event"]),
            ("popcorn", "🍿", "Popcorn", ["movie", "popcorn", "snack"]),
            ("haircut", "💇", "Haircut", ["haircut", "salon", "peluqueria"]),
            ("scissors", "✂️", "Scissors", ["haircut", "cut"]),
            ("party", "🎉", "Party", ["party", "celebration"]),
            ("circus", "🎪", "Circus", ["circus", "event"]),
            ("tv", "📺", "TV", ["tv", "streaming"])
        ]) +
        defs(.sports, [
            ("soccer", "⚽", "Soccer", ["soccer", "football"]),
            ("basketball", "🏀", "Basketball", ["basketball"]),
            ("americanFootball", "🏈", "American Football", ["football", "nfl"]),
            ("tennis", "🎾", "Tennis", ["tennis"]),
            ("weightlifting", "🏋️", "Weightlifting", ["gym", "weights"]),
            ("running", "🏃", "Running", ["running", "jog"]),
            ("cycling", "🚴", "Cycling", ["cycling", "bike"]),
            ("swimming", "🏊", "Swimming", ["swim", "pool"]),
            ("boxing", "🥊", "Boxing", ["boxing", "fight"]),
            ("trophy", "🏆", "Trophy", ["trophy", "win"]),
            ("medal", "🥇", "Medal", ["medal", "gold", "award"]),
            ("golf", "⛳", "Golf", ["golf"]),
            ("volleyball", "🏐", "Volleyball", ["volleyball"]),
            ("tableTennis", "🏓", "Table Tennis", ["ping pong", "table tennis"])
        ]) +
        defs(.family, [
            ("family", "👨‍👩‍👧‍👦", "Family", ["family"]),
            ("baby", "👶", "Baby", ["baby", "child"]),
            ("dog", "🐶", "Dog", ["dog", "pet"]),
            ("cat", "🐱", "Cat", ["cat", "pet"]),
            ("pawPrint", "🐾", "Paw Print", ["pet", "paw"]),
            ("fish", "🐟", "Fish", ["fish", "pet", "aquarium"]),
            ("turtle", "🐢", "Turtle", ["turtle", "pet"]),
            ("heart", "❤️", "Heart", ["love", "family", "care"]),
            ("bird", "🐦", "Bird", ["bird", "pet"]),
            ("hamster", "🐹", "Hamster", ["hamster", "pet"])
        ]) +
        defs(.flags, [
            ("spain", "🇪🇸", "Spain", ["spain", "espana", "flag"]),
            ("colombia", "🇨🇴", "Colombia", ["colombia", "flag"]),
            ("unitedStates", "🇺🇸", "United States", ["usa", "united states", "flag"]),
            ("unitedKingdom", "🇬🇧", "United Kingdom", ["uk", "britain", "flag"]),
            ("france", "🇫🇷", "France", ["france", "flag"]),
            ("germany", "🇩🇪", "Germany", ["germany", "flag"]),
            ("italy", "🇮🇹", "Italy", ["italy", "flag"]),
            ("portugal", "🇵🇹", "Portugal", ["portugal", "flag"]),
            ("mexico", "🇲🇽", "Mexico", ["mexico", "flag"]),
            ("canada", "🇨🇦", "Canada", ["canada", "flag"]),
            ("brazil", "🇧🇷", "Brazil", ["brazil", "flag"]),
            ("argentina", "🇦🇷", "Argentina", ["argentina", "flag"]),
            ("japan", "🇯🇵", "Japan", ["japan", "flag"]),
            ("china", "🇨🇳", "China", ["china", "flag"]),
            ("netherlands", "🇳🇱", "Netherlands", ["netherlands", "holland", "flag"]),
            ("switzerland", "🇨🇭", "Switzerland", ["switzerland", "flag"]),
            ("sweden", "🇸🇪", "Sweden", ["sweden", "flag"]),
            ("india", "🇮🇳", "India", ["india", "flag"]),
            ("australia", "🇦🇺", "Australia", ["australia", "flag"]),
            ("southKorea", "🇰🇷", "South Korea", ["korea", "flag"]),
            ("world", "🌍", "World", ["world", "global", "earth"])
        ]) +
        defs(.symbols, [
            ("question", "❓", "Question", ["unknown", "question"]),
            ("star", "⭐", "Star", ["favorite", "star"]),
            ("bell", "🔔", "Bell", ["notification", "reminder", "bell"]),
            ("pin", "📌", "Pin", ["pin", "save", "marker"]),
            ("target", "🎯", "Target", ["goal", "target"]),
            ("hundred", "💯", "Hundred", ["perfect", "100"]),
            ("checkmark", "✅", "Checkmark", ["done", "complete", "check"]),
            ("exclamation", "❗", "Exclamation", ["important", "alert"]),
            ("fireSymbol", "🔥", "Fire", ["hot", "trending", "fire"]),
            ("sparkles", "✨", "Sparkles", ["new", "magic", "sparkle"]),
            ("warning", "⚠️", "Warning", ["warning", "caution"]),
            ("lock", "🔒", "Lock", ["security", "lock", "private"])
        ])

    /// Emoji grouped for the "browse by category" tab UI.
    static var groups: [EmojiGroup] {
        EmojiGroupID.allCases.compactMap { group in
            let emoji = all.filter { $0.group == group }.map(\.emoji)
            guard !emoji.isEmpty else { return nil }
            return EmojiGroup(title: group.rawValue, emoji: emoji)
        }
    }

    /// Matches a free-text query against display names and keywords — e.g. "party" resolves
    /// straight to 🎉 without the user browsing groups.
    ///
    /// The same emoji can appear under more than one concept (e.g. 🔥 is both "Fire" under Home
    /// and under Symbols), so dedupe by the emoji itself — otherwise a query matching both would
    /// show the same emoji twice, with both tiles lighting up together since they'd share
    /// `emojiText`.
    static func search(_ query: String) -> [EmojiDefinition] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        var seenEmoji = Set<String>()
        var results: [EmojiDefinition] = []
        for def in all where def.displayName.lowercased().contains(q) || def.keywords.contains(where: { $0.contains(q) }) {
            guard seenEmoji.insert(def.emoji).inserted else { continue }
            results.append(def)
        }
        return results
    }
}

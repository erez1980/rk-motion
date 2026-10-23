import Foundation

// The Hebrew words a search is read by. They are matched, never shown,
// so they stay out of the string catalog (see scripts/check-ios-store.py).
extension FrameSearch {
    /// Hebrew words and the Vision label words they mean.
    static let hebrew: [String: [String]] = [
        "ים": ["sea", "ocean", "beach", "shore", "coast", "wave"], "חוף": ["beach", "shore", "coast", "sand"],
        "בריכה": ["pool", "swimming"], "מים": ["water", "sea", "lake", "pool", "river"], "גלים": ["wave", "surfing"],
        "כלב": ["dog", "puppy", "canine"], "חתול": ["cat", "kitten", "feline"], "חיה": ["animal", "pet", "dog", "cat"],
        "ציפור": ["bird", "parrot"], "סוס": ["horse", "pony"], "דג": ["fish", "aquarium"],
        "ילד": ["child", "kid", "children", "toddler"], "ילדה": ["child", "kid", "children", "toddler"], "ילדים": ["child", "kid", "children", "toddler"],
        "תינוק": ["baby", "infant", "toddler"], "תינוקת": ["baby", "infant", "toddler"],
        "אנשים": ["people", "crowd", "adult"], "קהל": ["crowd", "audience", "people"],
        "עוגה": ["cake", "dessert"], "יומולדת": ["birthday", "cake", "balloon"], "בלונים": ["balloon"], "בלון": ["balloon"],
        "זיקוקים": ["fireworks"], "נרות": ["candle"], "מסיבה": ["party", "celebration", "dance", "concert"],
        "ריקוד": ["dance", "dancing"], "רוקדים": ["dance", "dancing"], "הופעה": ["concert", "stage", "performance"], "במה": ["stage", "concert"],
        "חתונה": ["wedding", "bride", "groom"], "כלה": ["bride", "wedding"], "חתן": ["groom", "wedding"],
        "שקיעה": ["sunset", "dusk"], "זריחה": ["sunrise", "dawn"], "שמיים": ["sky", "cloud"], "שמים": ["sky", "cloud"], "ענן": ["cloud"], "עננים": ["cloud"],
        "לילה": ["night", "dark"], "שמש": ["sun", "sunny"], "גשם": ["rain"], "שלג": ["snow", "ski", "skiing", "snowboard"],
        "הר": ["mountain", "hill", "cliff"], "הרים": ["mountain", "hill"], "יער": ["forest", "tree", "woods"], "עץ": ["tree"], "עצים": ["tree", "forest"],
        "פרח": ["flower"], "פרחים": ["flower"], "דשא": ["grass", "lawn"], "גן": ["garden", "park"], "פארק": ["park"],
        "מדבר": ["desert", "sand", "dune"], "חול": ["sand", "beach", "desert"], "נהר": ["river", "stream"], "אגם": ["lake"], "מפל": ["waterfall"],
        "עיר": ["city", "cityscape", "skyline", "street"], "רחוב": ["street", "road"], "כביש": ["road", "street", "highway"], "גשר": ["bridge"],
        "אוכל": ["food", "meal", "dish"], "ארוחה": ["meal", "food", "dinner", "lunch"], "פיצה": ["pizza"], "סושי": ["sushi"], "המבורגר": ["burger", "hamburger"],
        "קפה": ["coffee", "cafe"], "יין": ["wine"], "בירה": ["beer"], "גלידה": ["ice", "cream", "dessert"], "שולחן": ["table"], "מסעדה": ["restaurant"],
        "מכונית": ["car", "vehicle"], "אוטו": ["car", "vehicle"], "רכב": ["car", "vehicle", "jeep"], "ג'יפ": ["jeep", "vehicle"],
        "אופניים": ["bicycle", "bike", "cycling"], "אופנוע": ["motorcycle", "motorbike"], "סירה": ["boat", "sailboat", "kayak"], "מטוס": ["airplane", "aircraft"],
        "כדור": ["ball", "soccer", "football", "basketball"], "כדורגל": ["soccer", "football"], "כדורסל": ["basketball"], "טניס": ["tennis"],
        "שחייה": ["swimming", "pool"], "סקי": ["ski", "skiing", "snow"], "גלישה": ["surfing", "surfboard"], "טיפוס": ["climbing"],
        "מגלשה": ["slide", "playground"], "נדנדה": ["swing", "playground"], "גן שעשועים": ["playground"], "צעצוע": ["toy"],
        "מוזיאון": ["museum"], "טירה": ["castle"], "מקדש": ["temple"], "כנסייה": ["church"], "אוהל": ["tent", "camping"], "מדורה": ["campfire", "fire"],
    ]
    /// The letters Hebrew joins to the front of a word: "the", "and", "in", "to", "from", "that".
    static let prefixes: Set<Character> = ["ה", "ו", "ב", "ל", "מ", "ש", "כ"]
    /// Words that only carry the request ("find the moments with…").
    static let fillers: Set<String> = ["את", "עם", "של", "על", "כל", "רגעים", "קטעים", "רגע", "קטע", "תמצא", "מצא", "חפש", "תחפש", "תוסיף", "הוסף", "איפה", "יש", "בהם", "שבהם", "ש", "the", "with", "find", "show", "a", "an", "of", "moments", "clips"]
}

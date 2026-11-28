/// The three check words of one stop's unlock code (Menu bar v5, "Matching
/// words"): the code's three bytes, each spelled as a word from a fixed
/// list of 256, so `a7c835` reads `orchid · rocket · crane` in the
/// terminal (`rv wait`) and on the menu bar's approval sheet alike.
///
/// The words let the person check that the sheet they are about to approve
/// with Touch ID is the stop they are looking at in their terminal. They
/// are a spelling of the code, not a secret and never authority: rvd
/// decides what an approval covers from what it issued, whatever words a
/// screen shows.
public enum CheckWords {
    /// Separator the terminal and the sheet both use.
    public static let separator = " · "

    /// One word per byte of `code`, first byte first. Always three words.
    public static func words(for code: AllowOnceUnlockCode) -> [String] {
        let scalars = Array(code.rawValue.unicodeScalars)
        return stride(from: 0, to: scalars.count, by: 2).map { start in
            list[byte(scalars[start], scalars[start + 1])]
        }
    }

    /// `orchid · rocket · crane`.
    public static func line(for code: AllowOnceUnlockCode) -> String {
        words(for: code).joined(separator: separator)
    }

    /// Two lowercase hex digits as a byte. `AllowOnceUnlockCode` admits only
    /// `0-9a-f`, so every pair is in range.
    private static func byte(_ high: Unicode.Scalar, _ low: Unicode.Scalar) -> Int {
        nibble(high) << 4 | nibble(low)
    }

    private static func nibble(_ scalar: Unicode.Scalar) -> Int {
        let value = Int(scalar.value)
        return value >= 0x61 ? value - 0x61 + 10 : value - 0x30
    }

    /// The word for each byte value. Order is the contract: changing it
    /// changes every stop's words. Short, plain, distinct nouns.
    public static let list: [String] = [
        "acorn", "agate", "alder", "amber", "anchor", "apple", "apron", "arrow", "aspen", "atlas",
        "autumn", "badger", "bagel", "bamboo", "banjo", "barley", "basil", "beacon", "beaver", "birch",
        "bison", "blossom", "bonnet", "bramble", "bridge", "bronze", "brook", "bubble", "bucket", "button",
        "cabin", "cactus", "camel", "canal", "candle", "canoe", "canyon", "carrot", "castle", "cedar",
        "cellar", "cherry", "chimney", "cider", "cinder", "citrus", "clover", "cobalt", "comet", "copper",
        "coral", "cotton", "coyote", "crane", "crater", "cricket", "crystal", "cypress", "daisy", "dawn",
        "delta", "denim", "desert", "dingo", "dolphin", "donkey", "dragon", "drum", "dune", "eagle",
        "easel", "echo", "eclipse", "elbow", "elder", "ember", "emerald", "falcon", "fennel", "fern",
        "ferry", "fiddle", "fig", "finch", "fjord", "flute", "forest", "fossil", "fox", "garden", "garlic",
        "gecko", "geyser", "ginger", "glacier", "globe", "goose", "granite", "grape", "gravel", "gull",
        "hammer", "harbor", "harp", "hazel", "heron", "hickory", "honey", "hornet", "husky", "iceberg",
        "igloo", "indigo", "iris", "island", "ivory", "jade", "jaguar", "jasmine", "jelly", "juniper",
        "kayak", "kelp", "kettle", "kiwi", "koala", "ladder", "lagoon", "lantern", "larch", "lark",
        "laurel", "lemon", "lentil", "lilac", "lily", "linen", "lizard", "llama", "lobster", "lotus",
        "lynx", "magnet", "mango", "maple", "marble", "meadow", "melon", "mint", "mitten", "mole", "moose",
        "mosaic", "moss", "muffin", "mural", "nectar", "nickel", "nutmeg", "oak", "oasis", "oatmeal",
        "ocean", "olive", "onyx", "opal", "orbit", "orchid", "otter", "owl", "oyster", "paddle", "panda",
        "papaya", "parrot", "pasta", "peach", "pebble", "pecan", "pelican", "pepper", "pigeon", "pillow",
        "pine", "plum", "pony", "poppy", "prairie", "puffin", "pumpkin", "quail", "quartz", "quill",
        "rabbit", "radish", "raven", "reef", "ribbon", "river", "robin", "rocket", "rose", "ruby",
        "saddle", "saffron", "salmon", "sandal", "satin", "scarf", "seal", "sequoia", "shell", "sierra",
        "silver", "sketch", "sloth", "snail", "sorrel", "sparrow", "spider", "spruce", "squid", "stork",
        "summit", "swan", "tango", "teapot", "thistle", "thunder", "tiger", "timber", "toast", "tomato",
        "topaz", "tulip", "tundra", "turnip", "turtle", "valley", "velvet", "violet", "walnut", "walrus",
        "willow", "wren", "yarrow", "yak", "zebra", "zinnia", "nine", "cobra", "kite", "bell", "cliff",
        "wave", "lime"
    ]
}

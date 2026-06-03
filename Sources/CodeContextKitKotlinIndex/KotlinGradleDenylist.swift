public enum GradleDenylist {
    public static let defaultExcludedPathFragments = [
        ".gradle/",
        ".idea/",
        ".kotlin/",
        "captures/",
        ".cxx/"
    ]

    public static let generatedPathFragments = [
        "build/",
        "build/generated/",
        "generated/ksp/",
        "generated/source/",
        "generated/sources/",
        "build/tmp/"
    ]
}

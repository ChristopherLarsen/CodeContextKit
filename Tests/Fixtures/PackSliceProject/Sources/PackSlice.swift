import Foundation

/// Deliberately large fixture used to verify surgical pack emits symbol
/// slices instead of whole-file dumps.
public enum PackSliceTarget {
    public static func targetFunction(input: String) -> String {
        return "target:" + input
    }
}

public enum PackSliceNoise {
    public static let uniqueMarker = "UNIQUE_MARKER_NOISE_XYZ_DO_NOT_PACK"

    public static func unrelatedNoiseFunction() -> String {
        var parts: [String] = []
        parts.append(uniqueMarker)
        parts.append("noise-line-01")
        parts.append("noise-line-02")
        parts.append("noise-line-03")
        parts.append("noise-line-04")
        parts.append("noise-line-05")
        parts.append("noise-line-06")
        parts.append("noise-line-07")
        parts.append("noise-line-08")
        parts.append("noise-line-09")
        parts.append("noise-line-10")
        parts.append("noise-line-11")
        parts.append("noise-line-12")
        parts.append("noise-line-13")
        parts.append("noise-line-14")
        parts.append("noise-line-15")
        parts.append("noise-line-16")
        parts.append("noise-line-17")
        parts.append("noise-line-18")
        parts.append("noise-line-19")
        parts.append("noise-line-20")
        parts.append("noise-line-21")
        parts.append("noise-line-22")
        parts.append("noise-line-23")
        parts.append("noise-line-24")
        parts.append("noise-line-25")
        parts.append("noise-line-26")
        parts.append("noise-line-27")
        parts.append("noise-line-28")
        parts.append("noise-line-29")
        parts.append("noise-line-30")
        parts.append("noise-line-31")
        parts.append("noise-line-32")
        parts.append("noise-line-33")
        parts.append("noise-line-34")
        parts.append("noise-line-35")
        parts.append("noise-line-36")
        parts.append("noise-line-37")
        parts.append("noise-line-38")
        parts.append("noise-line-39")
        parts.append("noise-line-40")
        parts.append("noise-line-41")
        parts.append("noise-line-42")
        parts.append("noise-line-43")
        parts.append("noise-line-44")
        parts.append("noise-line-45")
        parts.append("noise-line-46")
        parts.append("noise-line-47")
        parts.append("noise-line-48")
        parts.append("noise-line-49")
        parts.append("noise-line-50")
        return parts.joined(separator: "\n")
    }

    public static func moreUnrelatedNoise() -> String {
        return [
            "extra-noise-01",
            "extra-noise-02",
            "extra-noise-03",
            "extra-noise-04",
            "extra-noise-05",
            "extra-noise-06",
            "extra-noise-07",
            "extra-noise-08",
            "extra-noise-09",
            "extra-noise-10",
            "extra-noise-11",
            "extra-noise-12",
            "extra-noise-13",
            "extra-noise-14",
            "extra-noise-15",
            "extra-noise-16",
            "extra-noise-17",
            "extra-noise-18",
            "extra-noise-19",
            "extra-noise-20",
            "extra-noise-21",
            "extra-noise-22",
            "extra-noise-23",
            "extra-noise-24",
            "extra-noise-25",
            "extra-noise-26",
            "extra-noise-27",
            "extra-noise-28",
            "extra-noise-29",
            "extra-noise-30",
            "extra-noise-31",
            "extra-noise-32",
            "extra-noise-33",
            "extra-noise-34",
            "extra-noise-35",
            "extra-noise-36",
            "extra-noise-37",
            "extra-noise-38",
            "extra-noise-39",
            "extra-noise-40",
        ].joined(separator: "\n")
    }

    public static func evenMoreNoise() -> String {
        (1...40).map { "pad-noise-\($0)" }.joined(separator: "\n")
    }
}

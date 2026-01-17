import Foundation

enum ModelIdentifier: Equatable, Hashable, Codable, CustomStringConvertible {
    case gaussianSplat(URL)
    case animatedSplat(URL) // Directory containing PLY frames
    case singleFrameSplat(URL) // Directory containing PLY frames, load only first frame
    case sampleBox

    var description: String {
        switch self {
        case .gaussianSplat(let url):
            "Gaussian Splat: \(url.path)"
        case .animatedSplat(let url):
            "Animated Splat: \(url.path)"
        case .singleFrameSplat(let url):
            "Single Frame Splat: \(url.path)"
        case .sampleBox:
            "Sample Box"
        }
    }
}

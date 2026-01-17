import Foundation

enum ModelIdentifier: Equatable, Hashable, Codable, CustomStringConvertible {
    case gaussianSplat(URL)
    case animatedSplat(URL) // Directory containing PLY frames
    case sampleBox

    var description: String {
        switch self {
        case .gaussianSplat(let url):
            "Gaussian Splat: \(url.path)"
        case .animatedSplat(let url):
            "Animated Splat: \(url.path)"
        case .sampleBox:
            "Sample Box"
        }
    }
}

#if os(visionOS)
import Foundation

/// Request to dismiss and reopen immersive space with a specific frame
struct DismissReopenRequest: Equatable {
    let dismiss: Bool
    let frameIndex: Int
    let directoryURL: URL
    
    static func == (lhs: DismissReopenRequest, rhs: DismissReopenRequest) -> Bool {
        lhs.dismiss == rhs.dismiss &&
        lhs.frameIndex == rhs.frameIndex &&
        lhs.directoryURL == rhs.directoryURL
    }
}

/// Global storage for frame index that persists across immersive space cycles
final class FrameIndexStorage: @unchecked Sendable {
    static let shared = FrameIndexStorage()
    private var _frameIndex: Int = 0
    private let queue = DispatchQueue(label: "com.metalsplatter.frameIndex")
    
    private init() {}
    
    var frameIndex: Int {
        get {
            queue.sync { _frameIndex }
        }
        set {
            queue.sync {
                _frameIndex = newValue
                print("FrameIndexStorage: Set frameIndex to \(newValue)")
            }
        }
    }
}

/// Shared state manager for frame navigation in single frame splat mode
@MainActor
class FrameNavigationManager: ObservableObject {
    static let shared = FrameNavigationManager()
    
    @Published private(set) var animatedSplatRenderer: AnimatedSplatRenderer?
    @Published private(set) var isSingleFrameMode: Bool = false
    @Published var shouldDismissAndReopen: DismissReopenRequest?
    
    private var directoryURL: URL?
    
    var targetFrameIndex: Int {
        get {
            FrameIndexStorage.shared.frameIndex
        }
        set {
            FrameIndexStorage.shared.frameIndex = newValue
        }
    }
    
    private init() {}
    
    func registerRenderer(_ renderer: AnimatedSplatRenderer?, isSingleFrame: Bool, directoryURL: URL? = nil) {
        animatedSplatRenderer = renderer
        isSingleFrameMode = isSingleFrame
        if let url = directoryURL {
            self.directoryURL = url
        }
        // Update ContentView's frame index to match what was actually loaded
        if let renderer = renderer, isSingleFrame {
            let loadedIndex = renderer.currentFrame
            FrameIndexStorage.shared.frameIndex = loadedIndex
            print("FrameNavigationManager: Registered renderer with currentFrame = \(loadedIndex)")
        }
    }
    
    func getNextFrameInfo() -> (frameIndex: Int, directoryURL: URL)? {
        guard isSingleFrameMode, let renderer = animatedSplatRenderer, let url = directoryURL else { return nil }
        let currentIndex = renderer.currentFrame
        let frameCount = renderer.frameCount
        let nextIndex = (currentIndex + 1) % frameCount
        return (nextIndex, url)
    }
    
    func getPreviousFrameInfo() -> (frameIndex: Int, directoryURL: URL)? {
        guard isSingleFrameMode, let renderer = animatedSplatRenderer, let url = directoryURL else { return nil }
        let currentIndex = renderer.currentFrame
        let frameCount = renderer.frameCount
        let prevIndex = (currentIndex - 1 + frameCount) % frameCount
        return (prevIndex, url)
    }
    
    func requestNextFrame() {
        guard let info = getNextFrameInfo() else { return }
        targetFrameIndex = info.frameIndex
        shouldDismissAndReopen = DismissReopenRequest(dismiss: true, frameIndex: info.frameIndex, directoryURL: info.directoryURL)
    }
    
    func requestPreviousFrame() {
        guard let info = getPreviousFrameInfo() else { return }
        targetFrameIndex = info.frameIndex
        shouldDismissAndReopen = DismissReopenRequest(dismiss: true, frameIndex: info.frameIndex, directoryURL: info.directoryURL)
    }
    
    func clearDismissRequest() {
        shouldDismissAndReopen = nil
    }
}
#endif // os(visionOS)


#if os(visionOS)
import Foundation

/// Shared state manager for frame navigation in single frame splat mode
@MainActor
class FrameNavigationManager: ObservableObject {
    static let shared = FrameNavigationManager()
    
    @Published private(set) var animatedSplatRenderer: AnimatedSplatRenderer?
    @Published private(set) var isSingleFrameMode: Bool = false
    
    private init() {}
    
    func registerRenderer(_ renderer: AnimatedSplatRenderer?, isSingleFrame: Bool) {
        animatedSplatRenderer = renderer
        isSingleFrameMode = isSingleFrame
    }
    
    func nextFrame() async {
        guard let renderer = animatedSplatRenderer, isSingleFrameMode else { return }
        await renderer.nextFrame()
    }
    
    func previousFrame() async {
        guard let renderer = animatedSplatRenderer, isSingleFrameMode else { return }
        await renderer.previousFrame()
    }
}
#endif // os(visionOS)


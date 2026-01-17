import Foundation
import Metal
import MetalSplatter
import SplatIO
import PLYIO

/// A filtered PLY reader that only processes vertex elements, skipping other element types
/// This works around SplatPLYSceneReader's limitation with multi-element PLY files
class FilteredVertexPLYReader: SplatSceneReader {
    private let url: URL
    
    init(url: URL) {
        self.url = url
    }
    
    func read() async throws -> AsyncThrowingStream<[SplatScenePoint], Swift.Error> {
        let plyReader = try PLYReader(url)
        let (header, elementStream) = try await plyReader.read()
        
        // Find vertex element index
        guard let vertexElementIndex = header.elements.firstIndex(where: { $0.name.lowercased() == "vertex" }) else {
            throw NSError(domain: "FilteredVertexPLYReader", code: 1, 
                         userInfo: [NSLocalizedDescriptionKey: "No vertex element found in PLY file"])
        }
        
        // Get element mapping for vertex elements
        // Use the same approach as SplatPLYSceneReader but with public APIs
        let vertexElement = header.elements[vertexElementIndex]
        
        // Helper function to get float32 property index
        func getFloat32PropertyIndex(_ names: [String]) throws -> Int {
            for name in names {
                if let idx = vertexElement.index(forPropertyNamed: name),
                   case .primitive(.float32) = vertexElement.properties[idx].type {
                    return idx
                }
            }
            throw NSError(domain: "FilteredVertexPLYReader", code: 2,
                         userInfo: [NSLocalizedDescriptionKey: "Property not found: \(names.first ?? "unknown")"])
        }
        
        // Helper function to get optional float32 property index
        func getOptionalFloat32PropertyIndex(_ names: [String]) -> Int? {
            for name in names {
                if let idx = vertexElement.index(forPropertyNamed: name),
                   case .primitive(.float32) = vertexElement.properties[idx].type {
                    return idx
                }
            }
            return nil
        }
        
        // Create mapping for vertex properties (using same property names as SplatPLYConstants)
        let positionXIdx = try getFloat32PropertyIndex(["x"])
        let positionYIdx = try getFloat32PropertyIndex(["y"])
        let positionZIdx = try getFloat32PropertyIndex(["z"])
        let scaleXIdx = try getFloat32PropertyIndex(["scale_0"])
        let scaleYIdx = try getFloat32PropertyIndex(["scale_1"])
        let scaleZIdx = try getFloat32PropertyIndex(["scale_2"])
        let opacityIdx = try getFloat32PropertyIndex(["opacity"])
        let rot0Idx = try getFloat32PropertyIndex(["rot_0"])
        let rot1Idx = try getFloat32PropertyIndex(["rot_1"])
        let rot2Idx = try getFloat32PropertyIndex(["rot_2"])
        let rot3Idx = try getFloat32PropertyIndex(["rot_3"])
        
        // Check for color format (spherical harmonics f_dc_0, f_dc_1, f_dc_2) - optional
        let sh0_rIdx = getOptionalFloat32PropertyIndex(["f_dc_0"])
        let sh0_gIdx = getOptionalFloat32PropertyIndex(["f_dc_1"])
        let sh0_bIdx = getOptionalFloat32PropertyIndex(["f_dc_2"])
        
        return AsyncThrowingStream { continuation in
            Task {
                var points: [SplatScenePoint] = []
                
                // Filter stream to only process vertex elements
                for try await elementSeries in elementStream {
                    // Skip non-vertex elements
                    guard elementSeries.typeIndex == vertexElementIndex else {
                        continue
                    }
                    
                    // Process vertex elements
                    for element in elementSeries.elements {
                        var point = SplatScenePoint(position: .zero,
                                                    color: .linearUInt8(.zero),
                                                    opacity: .linearFloat(.zero),
                                                    scale: .exponent(.zero),
                                                    rotation: .init(vector: .zero))
                        
                        // Extract position
                        point.position = SIMD3(
                            x: try element.float32Value(forPropertyIndex: positionXIdx),
                            y: try element.float32Value(forPropertyIndex: positionYIdx),
                            z: try element.float32Value(forPropertyIndex: positionZIdx)
                        )
                        
                        // Extract color (spherical harmonics f_dc_0, f_dc_1, f_dc_2)
                        if let sh0_r = sh0_rIdx, let sh0_g = sh0_gIdx, let sh0_b = sh0_bIdx {
                            let r = try element.float32Value(forPropertyIndex: sh0_r)
                            let g = try element.float32Value(forPropertyIndex: sh0_g)
                            let b = try element.float32Value(forPropertyIndex: sh0_b)
                            point.color = .sphericalHarmonic([SIMD3(r, g, b)])
                        } else {
                            // Fallback to default color if spherical harmonics not found
                            point.color = .linearUInt8(.zero)
                        }
                        
                        // Extract scale
                        point.scale = .exponent(SIMD3(
                            x: try element.float32Value(forPropertyIndex: scaleXIdx),
                            y: try element.float32Value(forPropertyIndex: scaleYIdx),
                            z: try element.float32Value(forPropertyIndex: scaleZIdx)
                        ))
                        
                        // Extract opacity - PLY files store opacity in logit space, not linear
                        point.opacity = .logitFloat(try element.float32Value(forPropertyIndex: opacityIdx))
                        
                        // Extract rotation (quaternion)
                        // PLY format stores rotation as: rot_0 (real/w), rot_1 (imag.x), rot_2 (imag.y), rot_3 (imag.z)
                        // This matches how SplatPLYSceneReader does it
                        point.rotation.real = try element.float32Value(forPropertyIndex: rot0Idx)
                        point.rotation.imag.x = try element.float32Value(forPropertyIndex: rot1Idx)
                        point.rotation.imag.y = try element.float32Value(forPropertyIndex: rot2Idx)
                        point.rotation.imag.z = try element.float32Value(forPropertyIndex: rot3Idx)
                        
                        points.append(point)
                    }
                    
                    // Yield points in batches
                    if points.count >= 10000 {
                        continuation.yield(points)
                        points.removeAll(keepingCapacity: true)
                    }
                }
                
                // Yield remaining points
                if !points.isEmpty {
                    continuation.yield(points)
                }
                
                continuation.finish()
            }
        }
    }
}

// Helper extension to access PLYElement float32 values
private extension PLYElement {
    func float32Value(forPropertyIndex propertyIndex: Int) throws -> Float {
        guard propertyIndex < properties.count else {
            throw NSError(domain: "FilteredVertexPLYReader", code: 2,
                         userInfo: [NSLocalizedDescriptionKey: "Property index out of bounds"])
        }
        switch properties[propertyIndex] {
        case .float32(let value):
            return value
        case .float64(let value):
            return Float(value)
        case .int8(let value):
            return Float(value)
        case .uint8(let value):
            return Float(value)
        case .int16(let value):
            return Float(value)
        case .uint16(let value):
            return Float(value)
        case .int32(let value):
            return Float(value)
        case .uint32(let value):
            return Float(value)
        default:
            throw NSError(domain: "FilteredVertexPLYReader", code: 3,
                         userInfo: [NSLocalizedDescriptionKey: "Property at index \(propertyIndex) is not a numeric type"])
        }
    }
}

/// An animated splat renderer that cycles through multiple PLY files
/// It's marked @unchecked Sendable because it manages thread safety manually
final class AnimatedSplatRenderer: @unchecked Sendable, ModelRenderer {
    private let device: MTLDevice
    private let colorFormat: MTLPixelFormat
    private let depthFormat: MTLPixelFormat
    private let sampleCount: Int
    private let maxViewCount: Int
    private let maxSimultaneousRenders: Int
    
    // Double buffering: two renderers, one visible while the other updates
    private var rendererA: SplatRenderer?
    private var rendererB: SplatRenderer?
    private var activeRendererIndex: Int = 0 // 0 = rendererA, 1 = rendererB
    private var frameData: [SplatMemoryBuffer] = []
    private var frameURLs: [URL] = []
    private let frameIndexQueue = DispatchQueue(label: "com.metalsplatter.animated.frameIndex")
    private var currentFrameIndex: Int = 0
    private var renderedFrameIndex: Int = -1
    private var lastFrameUpdateTime: Date?
    private let fps: Double = 10.0 // Can increase FPS now with double buffering
    private var isPaused: Bool = false
    private var isUpdatingFrame: Bool = false // Prevent concurrent frame updates
    private var lastFrameUpdateCompletionTime: Date? // Track when last update completed
    
    init(device: MTLDevice,
         colorFormat: MTLPixelFormat,
         depthFormat: MTLPixelFormat,
         sampleCount: Int,
         maxViewCount: Int,
         maxSimultaneousRenders: Int) throws {
        self.device = device
        self.colorFormat = colorFormat
        self.depthFormat = depthFormat
        self.sampleCount = sampleCount
        self.maxViewCount = maxViewCount
        self.maxSimultaneousRenders = maxSimultaneousRenders
    }
    
    /// Load all PLY files from a directory
    @MainActor
    func loadFrames(from directory: URL) async throws {
        let fileManager = FileManager.default
        
        // Check if directory exists
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NSError(domain: "AnimatedSplatRenderer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Directory does not exist: \(directory.path)"])
        }
        
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            throw NSError(domain: "AnimatedSplatRenderer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot read directory: \(directory.path)"])
        }
        
        // Filter and sort PLY files
        let plyFiles = files.filter { $0.pathExtension.lowercased() == "ply" }
            .sorted { url1, url2 in
                // Sort by frame number if files are named like frame_000001.ply
                let name1 = url1.deletingPathExtension().lastPathComponent
                let name2 = url2.deletingPathExtension().lastPathComponent
                if name1.hasPrefix("frame_") && name2.hasPrefix("frame_") {
                    let num1 = Int(name1.dropFirst(6)) ?? 0
                    let num2 = Int(name2.dropFirst(6)) ?? 0
                    return num1 < num2
                }
                return name1 < name2
            }
        
        guard !plyFiles.isEmpty else {
            throw NSError(domain: "AnimatedSplatRenderer", code: 2, userInfo: [NSLocalizedDescriptionKey: "No PLY files found in directory"])
        }
        
        frameURLs = plyFiles
        frameData = []
        
        // Load all frames
        for url in plyFiles {
            // Use filtered reader that only processes vertex elements
            // This works around SplatPLYSceneReader's limitation with multi-element PLY files
            let reader = FilteredVertexPLYReader(url: url)
            var buffer = SplatMemoryBuffer()
            try await buffer.read(from: reader)
            frameData.append(buffer)
        }
        
        // Initialize both renderers with first frame (double buffering)
        if let firstFrame = frameData.first {
            rendererA = try SplatRenderer(device: device,
                                           colorFormat: colorFormat,
                                           depthFormat: depthFormat,
                                           sampleCount: sampleCount,
                                           maxViewCount: maxViewCount,
                                           maxSimultaneousRenders: maxSimultaneousRenders)
            try await rendererA?.add(firstFrame.points)
            
            // Initialize rendererB with first frame too (will be updated before use)
            rendererB = try SplatRenderer(device: device,
                                           colorFormat: colorFormat,
                                           depthFormat: depthFormat,
                                           sampleCount: sampleCount,
                                           maxViewCount: maxViewCount,
                                           maxSimultaneousRenders: maxSimultaneousRenders)
            try await rendererB?.add(firstFrame.points)
        }
        
        frameIndexQueue.sync {
            currentFrameIndex = 0
            renderedFrameIndex = 0
            activeRendererIndex = 0 // Start with rendererA
        }
        lastFrameUpdateTime = Date()
    }
    
    /// Update animation frame based on elapsed time
    private func updateAnimation() {
        guard !frameData.isEmpty, !isPaused else { return }
        
        let now = Date()
        guard let lastUpdate = lastFrameUpdateTime else {
            lastFrameUpdateTime = now
            return
        }
        
        let elapsed = now.timeIntervalSince(lastUpdate)
        let frameDuration = 1.0 / fps
        
        if elapsed >= frameDuration {
            let frameToRender = frameIndexQueue.sync { () -> Int in
                let framesToAdvance = Int(elapsed / frameDuration)
                currentFrameIndex = (currentFrameIndex + framesToAdvance) % frameData.count
                return currentFrameIndex
            }
            
            lastFrameUpdateTime = now
            
            // Update renderer with new frame if it changed
            // With double buffering, we can update more frequently
            let needsUpdate = frameIndexQueue.sync { () -> Bool in
                return frameToRender != renderedFrameIndex
            }
            
            if needsUpdate {
                frameIndexQueue.sync {
                    isUpdatingFrame = true
                }
                Task {
                    await updateRendererFrame(frameIndex: frameToRender)
                    frameIndexQueue.sync {
                        isUpdatingFrame = false
                    }
                }
            }
        }
    }
    
    private func updateRendererFrame(frameIndex: Int) async {
        guard frameIndex < frameData.count else { return }
        
        let frame = frameData[frameIndex]
        
        // Determine which renderer to update (the inactive one)
        let inactiveRendererIndex = frameIndexQueue.sync { () -> Int in
            // Get the inactive renderer (the one not currently visible)
            return activeRendererIndex == 0 ? 1 : 0
        }
        
        guard let inactiveRenderer = inactiveRendererIndex == 0 ? rendererA : rendererB else {
            print("Error: Inactive renderer not available")
            return
        }
        
        do {
            // Update the inactive renderer with the new frame
            // No need for delays since we're updating the inactive renderer
            await inactiveRenderer.reset()
            try await inactiveRenderer.add(frame.points)
            
            // Switch to the updated renderer
            frameIndexQueue.sync {
                activeRendererIndex = inactiveRendererIndex
                renderedFrameIndex = frameIndex
            }
            
            // Track when update completed
            lastFrameUpdateCompletionTime = Date()
        } catch {
            print("Error updating frame: \(error)")
        }
    }
    
    func setPaused(_ paused: Bool) {
        isPaused = paused
    }
    
    var frameCount: Int {
        frameData.count
    }
    
    var currentFrame: Int {
        frameIndexQueue.sync {
            currentFrameIndex
        }
    }
    
    // MARK: - ModelRenderer
    
    @discardableResult
    func render(viewports: [ModelRendererViewportDescriptor],
                colorTexture: MTLTexture,
                colorStoreAction: MTLStoreAction,
                depthTexture: MTLTexture?,
                rasterizationRateMap: MTLRasterizationRateMap?,
                renderTargetArrayLength: Int,
                to commandBuffer: MTLCommandBuffer) throws -> Bool {
        updateAnimation()
        
        // Get the active renderer (the one currently visible)
        let activeRenderer = frameIndexQueue.sync { () -> SplatRenderer? in
            return activeRendererIndex == 0 ? rendererA : rendererB
        }
        
        guard let renderer = activeRenderer else { return false }
        
        let remappedViewports = viewports.map { viewport -> SplatRenderer.ViewportDescriptor in
            SplatRenderer.ViewportDescriptor(viewport: viewport.viewport,
                                            projectionMatrix: viewport.projectionMatrix,
                                            viewMatrix: viewport.viewMatrix,
                                            screenSize: viewport.screenSize)
        }
        
        return try renderer.render(viewports: remappedViewports,
                                  colorTexture: colorTexture,
                                  colorStoreAction: colorStoreAction,
                                  depthTexture: depthTexture,
                                  rasterizationRateMap: rasterizationRateMap,
                                  renderTargetArrayLength: renderTargetArrayLength,
                                  to: commandBuffer)
    }
}


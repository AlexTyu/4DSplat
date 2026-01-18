import Foundation
import Metal
import MetalSplatter
import SplatIO
import PLYIO

/// A filtered PLY reader that only processes vertex elements, skipping other element types
/// This works around SplatPLYSceneReader's limitation with multi-element PLY files
private class FilteredVertexPLYReader: SplatSceneReader {
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
    
    private var splatRenderer: SplatRenderer?
    private var frameData: [SplatMemoryBuffer] = []
    private var frameURLs: [URL] = []
    private let frameIndexQueue = DispatchQueue(label: "com.metalsplatter.animated.frameIndex")
    private let navigationQueue = DispatchQueue(label: "com.metalsplatter.animated.navigation", qos: .userInitiated)
    private var currentFrameIndex: Int = 0
    private var renderedFrameIndex: Int = -1
    private var lastFrameUpdateTime: Date?
    private let fps: Double = 30.0
    private var isPaused: Bool = false
    private var navigationTask: Task<Void, Never>?
    
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
    func loadFrames(from directory: URL, paused: Bool = false, initialFrameIndex: Int = 0) async throws {
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
        
        if paused {
            // Load specific frame (single frame mode)
            print("AnimatedSplatRenderer.loadFrames: paused=true, initialFrameIndex=\(initialFrameIndex), plyFiles.count=\(plyFiles.count)")
            let frameIndex = max(0, min(initialFrameIndex, plyFiles.count - 1))
            print("AnimatedSplatRenderer.loadFrames: Calculated frameIndex=\(frameIndex)")
            guard frameIndex < plyFiles.count else {
                throw NSError(domain: "AnimatedSplatRenderer", code: 4,
                             userInfo: [NSLocalizedDescriptionKey: "Frame index out of range"])
            }
            
            let targetFile = plyFiles[frameIndex]
            print("AnimatedSplatRenderer.loadFrames: Loading file: \(targetFile.lastPathComponent)")
            
            let reader = FilteredVertexPLYReader(url: targetFile)
            var buffer = SplatMemoryBuffer()
            try await buffer.read(from: reader)
            
            guard !buffer.points.isEmpty else {
                throw NSError(domain: "AnimatedSplatRenderer", code: 7,
                             userInfo: [NSLocalizedDescriptionKey: "No points loaded from \(targetFile.lastPathComponent)"])
            }
            
            print("Loaded frame \(frameIndex): \(buffer.points.count) points from \(targetFile.lastPathComponent)")
            frameData.append(buffer)
            
            // Set paused state
            isPaused = true
            
            // Initialize renderer with the loaded frame
            splatRenderer = try SplatRenderer(device: device,
                                              colorFormat: colorFormat,
                                              depthFormat: depthFormat,
                                              sampleCount: sampleCount,
                                              maxViewCount: maxViewCount,
                                              maxSimultaneousRenders: maxSimultaneousRenders)
            try await splatRenderer?.add(buffer.points)
            
            // Set initial frame index
            frameIndexQueue.sync {
                currentFrameIndex = frameIndex
                renderedFrameIndex = frameIndex
            }
            lastFrameUpdateTime = Date()
        } else {
            // Load all frames for animation
            for url in plyFiles {
                // Use filtered reader that only processes vertex elements
                // This works around SplatPLYSceneReader's limitation with multi-element PLY files
                let reader = FilteredVertexPLYReader(url: url)
                var buffer = SplatMemoryBuffer()
                try await buffer.read(from: reader)
                frameData.append(buffer)
            }
            
            // Initialize renderer with first frame
            guard let firstFrame = frameData.first else {
                throw NSError(domain: "AnimatedSplatRenderer", code: 5,
                             userInfo: [NSLocalizedDescriptionKey: "No frame data loaded"])
            }
            
            guard !firstFrame.points.isEmpty else {
                throw NSError(domain: "AnimatedSplatRenderer", code: 6,
                             userInfo: [NSLocalizedDescriptionKey: "Frame contains no points"])
            }
            
            splatRenderer = try SplatRenderer(device: device,
                                              colorFormat: colorFormat,
                                              depthFormat: depthFormat,
                                              sampleCount: sampleCount,
                                              maxViewCount: maxViewCount,
                                              maxSimultaneousRenders: maxSimultaneousRenders)
            try await splatRenderer?.add(firstFrame.points)
            
            frameIndexQueue.sync {
                currentFrameIndex = 0
                renderedFrameIndex = 0
            }
            lastFrameUpdateTime = Date()
        }
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
            let (needsUpdate, frame) = frameIndexQueue.sync { () -> (Bool, SplatMemoryBuffer?) in
                let needsUpdate = frameToRender != renderedFrameIndex
                guard needsUpdate && frameToRender < frameData.count else {
                    return (false, nil)
                }
                return (true, frameData[frameToRender])
            }
            
            if needsUpdate, let frame = frame {
                Task {
                    await updateRendererFrame(frameIndex: frameToRender, frame: frame)
                }
            }
        }
    }
    
    private func updateRendererFrame(frameIndex: Int, frame: SplatMemoryBuffer) async {
        guard let renderer = splatRenderer else { return }
        
        // Check if task was cancelled
        if Task.isCancelled {
            return
        }
        
        // Ensure frame has points before rendering
        guard !frame.points.isEmpty else {
            print("Error: Frame \(frameIndex) has no points")
            return
        }
        
        // Verify this is still the frame we want to render (check if navigation changed)
        let shouldContinue = frameIndexQueue.sync { () -> Bool in
            // Only proceed if this is still the current frame index
            frameIndex == currentFrameIndex
        }
        
        guard shouldContinue else {
            print("Frame navigation changed, skipping update for frame \(frameIndex)")
            return
        }
        
        do {
            // Reset renderer first to free Metal buffer memory from previous frame
            await renderer.reset()
            
            // Check again after reset (in case cancelled during reset)
            if Task.isCancelled {
                return
            }
            
            // Double-check frame index is still valid
            let stillValid = frameIndexQueue.sync { () -> Bool in
                frameIndex == currentFrameIndex
            }
            
            guard stillValid else {
                print("Frame navigation changed during reset, aborting")
                return
            }
            
            // Add points to renderer
            try await renderer.add(frame.points)
            
            // Only update rendered index if successful and still valid
            frameIndexQueue.sync {
                if frameIndex == currentFrameIndex {
                    renderedFrameIndex = frameIndex
                }
            }
            
            print("Successfully updated renderer to frame \(frameIndex) with \(frame.points.count) points")
        } catch {
            print("Error updating frame \(frameIndex): \(error)")
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
    
    /// Navigate to next frame (for single frame mode)
    func nextFrame() async {
        await withCheckedContinuation { continuation in
            navigationQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume()
                    return
                }
                
                // Cancel any pending navigation
                self.navigationTask?.cancel()
                
                guard !self.frameURLs.isEmpty else {
                    continuation.resume()
                    return
                }
                
                let nextIndex = self.frameIndexQueue.sync { () -> Int in
                    let newIndex = (self.currentFrameIndex + 1) % self.frameURLs.count
                    self.currentFrameIndex = newIndex
                    return newIndex
                }
                
                self.navigationTask = Task { [weak self] in
                    guard let self = self else {
                        continuation.resume()
                        return
                    }
                    await self.loadFrame(at: nextIndex)
                    continuation.resume()
                }
            }
        }
    }
    
    /// Navigate to previous frame (for single frame mode)
    func previousFrame() async {
        await withCheckedContinuation { continuation in
            navigationQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume()
                    return
                }
                
                // Cancel any pending navigation
                self.navigationTask?.cancel()
                
                guard !self.frameURLs.isEmpty else {
                    continuation.resume()
                    return
                }
                
                let prevIndex = self.frameIndexQueue.sync { () -> Int in
                    let newIndex = (self.currentFrameIndex - 1 + self.frameURLs.count) % self.frameURLs.count
                    self.currentFrameIndex = newIndex
                    return newIndex
                }
                
                self.navigationTask = Task { [weak self] in
                    guard let self = self else {
                        continuation.resume()
                        return
                    }
                    await self.loadFrame(at: prevIndex)
                    continuation.resume()
                }
            }
        }
    }
    
    /// Load a specific frame by index (for single frame mode)
    private func loadFrame(at index: Int) async {
        guard index >= 0 && index < frameURLs.count else { return }
        
        // For single frame mode, clear all previous frames to free memory
        // Only keep the current frame being loaded
        frameIndexQueue.sync {
            // Clear all frames except the one we're about to load (if it exists)
            for i in 0..<frameData.count {
                if i != index {
                    frameData[i] = SplatMemoryBuffer() // Clear points array to free memory
                }
            }
        }
        
        // Check if frame needs to be loaded (synchronized check)
        let (needsLoad, existingFrame) = frameIndexQueue.sync { () -> (Bool, SplatMemoryBuffer?) in
            let needsLoad = index >= frameData.count || frameData[index].points.isEmpty
            let existingFrame = (index < frameData.count && !frameData[index].points.isEmpty) ? frameData[index] : nil
            return (needsLoad, existingFrame)
        }
        
        // If frame is already loaded, use it directly
        if let frame = existingFrame {
            // Update index and render
            frameIndexQueue.sync {
                currentFrameIndex = index
            }
            await updateRendererFrame(frameIndex: index, frame: frame)
            return
        }
        
        // If frame is not loaded, load it on demand
        guard index < frameURLs.count else { return }
        let url = frameURLs[index]
        
        let loadedFrame: SplatMemoryBuffer
        do {
            let reader = FilteredVertexPLYReader(url: url)
            var buffer = SplatMemoryBuffer()
            try await buffer.read(from: reader)
            
            guard !buffer.points.isEmpty else {
                print("Warning: Frame \(index) contains no points")
                return
            }
            
            loadedFrame = buffer
            
            // Store frame data (synchronized) - only keep current frame
            frameIndexQueue.sync {
                // Ensure array is large enough
                while frameData.count <= index {
                    frameData.append(SplatMemoryBuffer())
                }
                // Store the current frame
                frameData[index] = buffer
                // Clear any other frames to free memory
                for i in 0..<frameData.count where i != index {
                    frameData[i] = SplatMemoryBuffer()
                }
            }
            print("Loaded frame \(index) on demand: \(buffer.points.count) points")
        } catch {
            print("Error loading frame \(index): \(error)")
            return
        }
        
        // Check if task was cancelled before updating renderer
        if Task.isCancelled {
            // Clear the frame we just loaded since we're not using it
            frameIndexQueue.sync {
                if index < frameData.count {
                    frameData[index] = SplatMemoryBuffer()
                }
            }
            return
        }
        
        // Update index (synchronized)
        frameIndexQueue.sync {
            currentFrameIndex = index
        }
        
        // Now update renderer with the fully loaded frame
        await updateRendererFrame(frameIndex: index, frame: loadedFrame)
        
        // After renderer is updated, we can clear the frame from frameData
        // since the renderer now has its own copy in Metal buffers
        // This helps free Swift array memory (Metal buffers are separate)
        frameIndexQueue.sync {
            // Keep only the current frame in frameData for potential reuse
            // Clear others to free memory
            for i in 0..<frameData.count where i != index {
                frameData[i] = SplatMemoryBuffer()
            }
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
        guard let renderer = splatRenderer else { return false }
        
        updateAnimation()
        
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


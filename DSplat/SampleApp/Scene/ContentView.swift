import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var isPickingFile = false
    @ObservedObject private var frameNavigationManager = FrameNavigationManager.shared
    @State private var currentSingleFrameIndex: Int = 0
    @State private var singleFrameDirectoryURL: URL?
    @State private var plyFileNames: [String] = []
    @State private var showGallery = false

#if os(macOS)
    @Environment(\.openWindow) private var openWindow
#elseif os(iOS)
    @State private var navigationPath = NavigationPath()

    private func openWindow(value: ModelIdentifier) {
        navigationPath.append(value)
    }
#elseif os(visionOS)
    @Environment(\.openImmersiveSpace) var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) var dismissImmersiveSpace

    @State var immersiveSpaceIsShown = false

    private func openWindow(value: ModelIdentifier) {
        Task {
            switch await openImmersiveSpace(value: value) {
            case .opened:
                immersiveSpaceIsShown = true
            case .error, .userCancelled:
                break
            @unknown default:
                break
            }
        }
    }
#endif

    var body: some View {
#if os(macOS) || os(visionOS)
        NavigationStack {
            mainView
                .sheet(isPresented: $showGallery) {
                    NavigationStack {
                        // Use the same directory detection as "Load Frame"
                        let directoryURL: URL? = {
                            if let existing = singleFrameDirectoryURL {
                                return existing
                            }
                            // Try multiple possible locations (same as "Load Frame")
                            let possiblePaths: [URL?] = [
                                Bundle.main.resourceURL?.appendingPathComponent("ply_frames"),
                                Bundle.main.resourceURL?.appendingPathComponent("Resources/ply_frames"),
                                Bundle.main.bundleURL.appendingPathComponent("ply_frames"),
                                Bundle.main.bundleURL.appendingPathComponent("Resources/ply_frames"),
                                Bundle.main.bundleURL.appendingPathComponent("App/ply_frames"),
                            ]
                            
                            for pathOption in possiblePaths {
                                if let path = pathOption, FileManager.default.fileExists(atPath: path.path) {
                                    // Verify it has PLY files
                                    if let files = try? FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil),
                                       files.contains(where: { $0.pathExtension.lowercased() == "ply" }) {
                                        return path
                                    }
                                }
                            }
                            
                            // If not found, try to find any .ply files in the bundle
                            if let resourceURL = Bundle.main.resourceURL {
                                let fileManager = FileManager.default
                                if let files = try? fileManager.contentsOfDirectory(at: resourceURL, includingPropertiesForKeys: nil),
                                   let plyFile = files.first(where: { $0.pathExtension.lowercased() == "ply" }) {
                                    return plyFile.deletingLastPathComponent()
                                }
                            }
                            
                            return nil
                        }()
                        
                        if let directoryURL = directoryURL {
                            FramesGalleryView(
                                immersiveSpaceIsShown: $immersiveSpaceIsShown,
                                plyDirectoryURL: directoryURL
                            )
                        } else {
                            VStack {
                                Text("No PLY directory found")
                                    .foregroundColor(.secondary)
                                Button("Close") {
                                    showGallery = false
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .navigationTitle("Frames Gallery")
                        }
                    }
                }
                .onChange(of: showGallery) {
                    print("ContentView: showGallery changed to: \(showGallery)")
                }
        }
#elseif os(iOS)
        NavigationStack(path: $navigationPath) {
            mainView
                .navigationDestination(for: ModelIdentifier.self) { modelIdentifier in
                    MetalKitSceneView(modelIdentifier: modelIdentifier)
                        .navigationTitle(modelIdentifier.description)
                }
        }
#endif // os(iOS)
    }
    
    private func findPLYDirectory() -> URL? {
        let fileManager = FileManager.default
        let possiblePaths: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent("ply_frames"),
            Bundle.main.resourceURL?.appendingPathComponent("Resources/ply_frames"),
            Bundle.main.bundleURL.appendingPathComponent("ply_frames"),
            Bundle.main.bundleURL.appendingPathComponent("Resources/ply_frames"),
            Bundle.main.bundleURL.appendingPathComponent("App/ply_frames"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/ply_frames"),
        ]
        
        for pathOption in possiblePaths {
            if let path = pathOption {
                let pathString = path.path
                if fileManager.fileExists(atPath: pathString) {
                    // Verify it has PLY files
                    if let files = try? fileManager.contentsOfDirectory(at: path, includingPropertiesForKeys: nil),
                       files.contains(where: { $0.pathExtension.lowercased() == "ply" }) {
                        print("ContentView: Found PLY directory at: \(pathString)")
                        return path
                    }
                }
            }
        }
        
        print("ContentView: Could not find PLY directory")
        return nil
    }

    @ViewBuilder
    var mainView: some View {
        VStack(spacing: 12) {
#if os(visionOS)
            Button("Close splat") {
                Task {
                    await dismissImmersiveSpace()
                    immersiveSpaceIsShown = false
                }
            }
            .disabled(!immersiveSpaceIsShown)
            .buttonStyle(.borderedProminent)

#endif

            Button("Read Scene File") {
                isPickingFile = true
            }
            .buttonStyle(.borderedProminent)
            .disabled(isPickingFile)
#if os(visionOS)
            .disabled(immersiveSpaceIsShown)
#endif
            .fileImporter(isPresented: $isPickingFile,
                          allowedContentTypes: [
                            UTType(filenameExtension: "ply")!,
                            UTType(filenameExtension: "splat")!,
                          ]) { result in
                // Close file picker immediately
                isPickingFile = false
                
                switch result {
                case .success(let url):
                    Task { @MainActor in
                        // Reset frame index for new load
                        currentSingleFrameIndex = 0
                        FrameIndexStorage.shared.frameIndex = 0
                        
                        // Start accessing security-scoped resource for the file
                        guard url.startAccessingSecurityScopedResource() else {
                            print("Error: Failed to access security-scoped resource for file")
                            return
                        }
                        
                        // Get the directory containing the selected file
                        let sourceDirectoryURL = url.deletingLastPathComponent()
                        
                        // Also access security-scoped resource for the directory
                        let directoryAccessGranted = sourceDirectoryURL.startAccessingSecurityScopedResource()
                        
                        defer {
                            url.stopAccessingSecurityScopedResource()
                            if directoryAccessGranted {
                                sourceDirectoryURL.stopAccessingSecurityScopedResource()
                            }
                        }
                        
                        // Copy directory to temporary location
                        let fileManager = FileManager.default
                        let tempDir = fileManager.temporaryDirectory
                        let tempDirectoryURL = tempDir.appendingPathComponent(UUID().uuidString)
                        
                        do {
                            // Create temp directory
                            try fileManager.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
                            
                            // Copy all PLY files from source directory to temp directory
                            if let files = try? fileManager.contentsOfDirectory(at: sourceDirectoryURL, includingPropertiesForKeys: nil) {
                                let plyFiles = files.filter { $0.pathExtension.lowercased() == "ply" }
                                print("Found \(plyFiles.count) PLY files to copy")
                                for plyFile in plyFiles {
                                    let destinationURL = tempDirectoryURL.appendingPathComponent(plyFile.lastPathComponent)
                                    try fileManager.copyItem(at: plyFile, to: destinationURL)
                                    print("Copied: \(plyFile.lastPathComponent)")
                                }
                            } else {
                                print("Error: Could not read directory contents")
                            }
                            
                            // Stop accessing security-scoped resources before opening window
                            url.stopAccessingSecurityScopedResource()
                            if directoryAccessGranted {
                                sourceDirectoryURL.stopAccessingSecurityScopedResource()
                            }
                            
                            // Verify directory exists and has files (same check as "Load Frame")
                            if FileManager.default.fileExists(atPath: tempDirectoryURL.path) {
                                if let files = try? fileManager.contentsOfDirectory(at: tempDirectoryURL, includingPropertiesForKeys: nil),
                                   !files.isEmpty {
                                    singleFrameDirectoryURL = tempDirectoryURL
                                    // Load list of PLY files
                                    loadPLYFileList(from: tempDirectoryURL)
                                    print("Opening window with temp directory: \(tempDirectoryURL.path)")
                                    // Load as single frame splat (same as "Load Frame")
                                    openWindow(value: ModelIdentifier.singleFrameSplat(tempDirectoryURL))
                                } else {
                                    print("Error: Temp directory is empty")
                                }
                            } else {
                                print("Error: Temp directory does not exist: \(tempDirectoryURL.path)")
                            }
                        } catch {
                            print("Error copying files: \(error.localizedDescription)")
                        }
                    }
                case .failure:
                    break
                }
            }

            Button("Load Animated Splat", action: {
                // Try multiple possible locations for the PLY files
                let possiblePaths: [URL?] = [
                    Bundle.main.resourceURL?.appendingPathComponent("ply_frames"),
                    Bundle.main.resourceURL?.appendingPathComponent("Resources/ply_frames"),
                    Bundle.main.bundleURL.appendingPathComponent("ply_frames"),
                    Bundle.main.bundleURL.appendingPathComponent("Resources/ply_frames"),
                ]
                
                for pathOption in possiblePaths {
                    if let path = pathOption, FileManager.default.fileExists(atPath: path.path) {
                        openWindow(value: ModelIdentifier.animatedSplat(path))
                        return
                    }
                }
                
                // If not found, try to find any .ply files in the bundle
                if let resourceURL = Bundle.main.resourceURL {
                    let fileManager = FileManager.default
                    if let files = try? fileManager.contentsOfDirectory(at: resourceURL, includingPropertiesForKeys: nil),
                       let plyFile = files.first(where: { $0.pathExtension.lowercased() == "ply" }) {
                        // Use the directory containing the first PLY file
                        openWindow(value: ModelIdentifier.animatedSplat(plyFile.deletingLastPathComponent()))
                    }
                }
                
                print("Error: Could not find ply_frames directory in bundle")
            })
            .buttonStyle(.borderedProminent)
#if os(visionOS)
            .disabled(immersiveSpaceIsShown)
#endif

            Button("Load Frame", action: {
                // Reset frame index for new load
                currentSingleFrameIndex = 0
                FrameIndexStorage.shared.frameIndex = 0
                
                // Try multiple possible locations for the PLY files
                let possiblePaths: [URL?] = [
                    Bundle.main.resourceURL?.appendingPathComponent("ply_frames"),
                    Bundle.main.resourceURL?.appendingPathComponent("Resources/ply_frames"),
                    Bundle.main.bundleURL.appendingPathComponent("ply_frames"),
                    Bundle.main.bundleURL.appendingPathComponent("Resources/ply_frames"),
                ]
                
                for pathOption in possiblePaths {
                    if let path = pathOption, FileManager.default.fileExists(atPath: path.path) {
                        singleFrameDirectoryURL = path
                        // Load list of PLY files
                        loadPLYFileList(from: path)
                        openWindow(value: ModelIdentifier.singleFrameSplat(path))
                        return
                    }
                }
                
                // If not found, try to find any .ply files in the bundle
                if let resourceURL = Bundle.main.resourceURL {
                    let fileManager = FileManager.default
                    if let files = try? fileManager.contentsOfDirectory(at: resourceURL, includingPropertiesForKeys: nil),
                       let plyFile = files.first(where: { $0.pathExtension.lowercased() == "ply" }) {
                        // Use the directory containing the first PLY file
                        let dir = plyFile.deletingLastPathComponent()
                        singleFrameDirectoryURL = dir
                        loadPLYFileList(from: dir)
                        openWindow(value: ModelIdentifier.singleFrameSplat(dir))
                    }
                }
                
                print("Error: Could not find ply_frames directory in bundle")
            })
            .buttonStyle(.borderedProminent)
#if os(visionOS)
            .disabled(immersiveSpaceIsShown)
#endif

#if os(visionOS)
            Button("Frames Gallery", action: {
                print("ContentView: Frames Gallery button clicked")
                print("ContentView: immersiveSpaceIsShown = \(immersiveSpaceIsShown)")
                print("ContentView: showGallery = \(showGallery)")
                
                // Ensure we have a directory URL first (but don't block if not found)
                if singleFrameDirectoryURL == nil {
                    print("ContentView: singleFrameDirectoryURL is nil, searching for PLY directory...")
                    if let dir = findPLYDirectory() {
                        print("ContentView: Found PLY directory: \(dir.path)")
                        singleFrameDirectoryURL = dir
                        loadPLYFileList(from: dir)
                    } else {
                        print("ContentView: WARNING - Could not find PLY directory, will show error in gallery")
                    }
                } else {
                    print("ContentView: Using existing singleFrameDirectoryURL: \(singleFrameDirectoryURL?.path ?? "nil")")
                }
                
                // Dismiss immersive space if shown before opening gallery
                if immersiveSpaceIsShown {
                    print("ContentView: Dismissing immersive space before opening gallery")
                    Task { @MainActor in
                        await dismissImmersiveSpace()
                        immersiveSpaceIsShown = false
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        print("ContentView: Setting showGallery = true")
                        showGallery = true
                    }
                } else {
                    print("ContentView: No immersive space shown, opening gallery directly")
                    showGallery = true
                    print("ContentView: showGallery set to: \(showGallery)")
                }
            })
            .buttonStyle(.borderedProminent)
#endif

#if os(visionOS)
            // Frame navigation buttons (only shown for single frame splat)
            if frameNavigationManager.isSingleFrameMode, let directoryURL = singleFrameDirectoryURL {
                let frameCount = plyFileNames.count
                let nextIndex = frameCount > 0 ? (currentSingleFrameIndex + 1) % frameCount : 0
                let prevIndex = frameCount > 0 ? (currentSingleFrameIndex - 1 + frameCount) % frameCount : 0
                let nextFileName = nextIndex < plyFileNames.count ? plyFileNames[nextIndex] : "?"
                let prevFileName = prevIndex < plyFileNames.count ? plyFileNames[prevIndex] : "?"
                
                HStack(spacing: 20) {
                    Button("Previous Frame\n(\(prevFileName))") {
                        guard frameCount > 0 else { return }
                        currentSingleFrameIndex = prevIndex
                        
                        // Dismiss and reopen with previous frame
                        Task {
                            FrameIndexStorage.shared.frameIndex = currentSingleFrameIndex
                            print("ContentView: Previous Frame - Setting frameIndex to \(currentSingleFrameIndex), file: \(prevFileName)")
                            await dismissImmersiveSpace()
                            immersiveSpaceIsShown = false
                            try? await Task.sleep(nanoseconds: 200_000_000)
                            
                            let modelIdentifier = ModelIdentifier.singleFrameSplat(directoryURL)
                            switch await openImmersiveSpace(value: modelIdentifier) {
                            case .opened:
                                immersiveSpaceIsShown = true
                            default:
                                break
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!immersiveSpaceIsShown)
                    
                    Button("Next Frame\n(\(nextFileName))") {
                        guard frameCount > 0 else { return }
                        currentSingleFrameIndex = nextIndex
                        
                        // Dismiss and reopen with next frame
                        Task {
                            FrameIndexStorage.shared.frameIndex = currentSingleFrameIndex
                            print("ContentView: Next Frame - Setting frameIndex to \(currentSingleFrameIndex), file: \(nextFileName)")
                            await dismissImmersiveSpace()
                            immersiveSpaceIsShown = false
                            try? await Task.sleep(nanoseconds: 200_000_000)
                            
                            let modelIdentifier = ModelIdentifier.singleFrameSplat(directoryURL)
                            switch await openImmersiveSpace(value: modelIdentifier) {
                            case .opened:
                                immersiveSpaceIsShown = true
                            default:
                                break
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!immersiveSpaceIsShown)
                }
                .padding()
                .onChange(of: frameNavigationManager.isSingleFrameMode) {
                    // Sync currentSingleFrameIndex with what's actually loaded when single frame mode is enabled
                    if frameNavigationManager.isSingleFrameMode,
                       let renderer = frameNavigationManager.animatedSplatRenderer {
                        let actualIndex = renderer.currentFrame
                        if currentSingleFrameIndex != actualIndex {
                            currentSingleFrameIndex = actualIndex
                        }
                    }
                }
            }
#endif // os(visionOS)
        }
        .padding(8)
    }
    
    private func loadPLYFileList(from directory: URL) {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            plyFileNames = []
            return
        }
        
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
            .map { $0.lastPathComponent }
        
        plyFileNames = plyFiles
        print("ContentView: Loaded \(plyFiles.count) PLY files: \(plyFiles.prefix(5).joined(separator: ", "))...")
    }
}

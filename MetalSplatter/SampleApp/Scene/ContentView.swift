import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var isPickingFile = false
    @ObservedObject private var frameNavigationManager = FrameNavigationManager.shared
    @State private var currentSingleFrameIndex: Int = 0
    @State private var singleFrameDirectoryURL: URL?
    @State private var plyFileNames: [String] = []

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
        mainView
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

    @ViewBuilder
    var mainView: some View {
        VStack {
            Spacer()

            Text("MetalSplatter SampleApp")

            Spacer()

            Button("Read Scene File") {
                isPickingFile = true
            }
            .padding()
            .buttonStyle(.borderedProminent)
            .disabled(isPickingFile)
#if os(visionOS)
            .disabled(immersiveSpaceIsShown)
#endif
            .fileImporter(isPresented: $isPickingFile,
                          allowedContentTypes: [
                            UTType(filenameExtension: "ply")!,
                            UTType(filenameExtension: "splat")!,
                          ]) {
                isPickingFile = false
                switch $0 {
                case .success(let url):
                    _ = url.startAccessingSecurityScopedResource()
                    Task {
                        // This is a sample app. In a real app, this should be more tightly scoped, not using a silly timer.
                        try await Task.sleep(for: .seconds(10))
                        url.stopAccessingSecurityScopedResource()
                    }
                    openWindow(value: ModelIdentifier.gaussianSplat(url))
                case .failure:
                    break
                }
            }

            Spacer()

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
            .padding()
            .buttonStyle(.borderedProminent)
#if os(visionOS)
            .disabled(immersiveSpaceIsShown)
#endif

            Spacer()

            Button("Load Single Frame", action: {
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
            .padding()
            .buttonStyle(.borderedProminent)
#if os(visionOS)
            .disabled(immersiveSpaceIsShown)
#endif

            Spacer()

            Button("Show Sample Box") {
                openWindow(value: ModelIdentifier.sampleBox)
            }
            .padding()
            .buttonStyle(.borderedProminent)
#if os(visionOS)
            .disabled(immersiveSpaceIsShown)
#endif

            Spacer()

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
                .onChange(of: frameNavigationManager.isSingleFrameMode) { _ in
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
            
            Button("Dismiss Immersive Space") {
                Task {
                    await dismissImmersiveSpace()
                    immersiveSpaceIsShown = false
                }
            }
            .disabled(!immersiveSpaceIsShown)

            Spacer()
#endif // os(visionOS)
        }
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

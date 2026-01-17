import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var isPickingFile = false

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

            Button("Load Animated Splat") {
                // Try multiple possible locations for the PLY files
                let possiblePaths = [
                    Bundle.main.resourceURL?.appendingPathComponent("ply_frames"),
                    Bundle.main.resourceURL?.appendingPathComponent("Resources/ply_frames"),
                    Bundle.main.bundleURL.appendingPathComponent("ply_frames"),
                    Bundle.main.bundleURL.appendingPathComponent("Resources/ply_frames"),
                ]
                
                for path in possiblePaths {
                    if let path = path, FileManager.default.fileExists(atPath: path.path) {
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
                        return
                    }
                }
                
                print("Error: Could not find ply_frames directory in bundle")
            }
            .padding()
            .buttonStyle(.borderedProminent)
#if os(visionOS)
            .disabled(immersiveSpaceIsShown)
#endif

            Spacer()

            Button("Load Last Frame (Static)") {
                // Find the last frame from ply_frames directory
                let possiblePaths = [
                    Bundle.main.resourceURL?.appendingPathComponent("ply_frames"),
                    Bundle.main.resourceURL?.appendingPathComponent("Resources/ply_frames"),
                    Bundle.main.bundleURL.appendingPathComponent("ply_frames"),
                    Bundle.main.bundleURL.appendingPathComponent("Resources/ply_frames"),
                ]
                
                var plyDirectory: URL?
                for path in possiblePaths {
                    if let path = path, FileManager.default.fileExists(atPath: path.path) {
                        plyDirectory = path
                        break
                    }
                }
                
                guard let directory = plyDirectory else {
                    print("Error: Could not find ply_frames directory in bundle")
                    return
                }
                
                // Find all PLY files and get the last one
                let fileManager = FileManager.default
                guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
                    print("Error: Cannot read directory")
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
                
                if let lastFrame = plyFiles.last {
                    openWindow(value: ModelIdentifier.gaussianSplat(lastFrame))
                } else {
                    print("Error: No PLY files found in directory")
                }
            }
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
}

import SwiftUI

struct FramesGalleryView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.openImmersiveSpace) var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) var dismissImmersiveSpace
    
    @Binding var immersiveSpaceIsShown: Bool
    @State private var thumbnailURLs: [(url: URL?, plyName: String)] = []
    @State private var isLoading = true
    
    let plyDirectoryURL: URL
    
    init(immersiveSpaceIsShown: Binding<Bool>, plyDirectoryURL: URL) {
        self._immersiveSpaceIsShown = immersiveSpaceIsShown
        self.plyDirectoryURL = plyDirectoryURL
        print("FramesGalleryView: Initialized with directory: \(plyDirectoryURL.path)")
    }
    
    private let columns = [
        GridItem(.adaptive(minimum: 150), spacing: 16)
    ]
    
    var body: some View {
        VStack {
            if isLoading {
                ProgressView("Loading thumbnails...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if thumbnailURLs.isEmpty {
                VStack(spacing: 16) {
                    Text("No PLY files found")
                        .foregroundColor(.secondary)
                    Button("Close") {
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(thumbnailURLs.indices, id: \.self) { index in
                            let item = thumbnailURLs[index]
                            ThumbnailView(
                                thumbnailURL: item.url,
                                plyName: item.plyName,
                                onTap: {
                                    loadFrame(at: index)
                                }
                            )
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Frames Gallery")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Close") {
                    dismiss()
                }
            }
        }
        .onAppear {
            loadThumbnails()
        }
    }
    
    private func loadThumbnails() {
        isLoading = true
        
        Task {
            let fileManager = FileManager.default
            let thumbnailsDir = plyDirectoryURL.appendingPathComponent("thumbnails")
            
            // Get all PLY files - use same approach as AnimatedSplatRenderer
            print("FramesGalleryView: Reading directory: \(plyDirectoryURL.path)")
            
            // Check if directory exists (same check as AnimatedSplatRenderer)
            var isDirectory: ObjCBool = false
            let directoryExists = fileManager.fileExists(atPath: plyDirectoryURL.path, isDirectory: &isDirectory)
            print("FramesGalleryView: Directory exists: \(directoryExists), isDirectory: \(isDirectory.boolValue)")
            
            guard directoryExists && isDirectory.boolValue else {
                print("FramesGalleryView: ERROR - Directory does not exist or is not a directory")
                await MainActor.run {
                    isLoading = false
                }
                return
            }
            
            guard let plyFiles = try? fileManager.contentsOfDirectory(at: plyDirectoryURL, includingPropertiesForKeys: nil) else {
                print("FramesGalleryView: ERROR - Failed to read directory contents")
                await MainActor.run {
                    isLoading = false
                }
                return
            }
            
            print("FramesGalleryView: Found \(plyFiles.count) total files in directory")
            
            let sortedPLYFiles = plyFiles
                .filter { $0.pathExtension.lowercased() == "ply" }
                .sorted { url1, url2 in
                    let name1 = url1.deletingPathExtension().lastPathComponent
                    let name2 = url2.deletingPathExtension().lastPathComponent
                    if name1.hasPrefix("frame_") && name2.hasPrefix("frame_") {
                        let num1 = Int(name1.dropFirst(6)) ?? 0
                        let num2 = Int(name2.dropFirst(6)) ?? 0
                        return num1 < num2
                    }
                    return name1 < name2
                }
            
            print("FramesGalleryView: Found \(sortedPLYFiles.count) PLY files")
            
            // Build thumbnail map if thumbnails directory exists
            var thumbnailMap: [String: URL] = [:]
            let thumbnailsPath = thumbnailsDir.path
            print("FramesGalleryView: Looking for thumbnails at: \(thumbnailsPath)")
            print("FramesGalleryView: PLY directory: \(plyDirectoryURL.path)")
            
            if fileManager.fileExists(atPath: thumbnailsPath) {
                print("FramesGalleryView: Thumbnails directory exists")
                if let thumbnailFiles = try? fileManager.contentsOfDirectory(at: thumbnailsDir, includingPropertiesForKeys: nil) {
                    print("FramesGalleryView: Found \(thumbnailFiles.count) files in thumbnails directory")
                    // Map by base name (without extension) to support both .jpg and .png
                    for thumbnailFile in thumbnailFiles {
                        let ext = thumbnailFile.pathExtension.lowercased()
                        let fileName = thumbnailFile.lastPathComponent
                        if ext == "jpg" || ext == "jpeg" || ext == "png" {
                            let baseName = (fileName as NSString).deletingPathExtension
                            
                            // Try to get bundle URL if this is a bundle resource
                            var finalURL = thumbnailFile
                            if let bundleURL = Bundle.main.url(forResource: baseName, withExtension: ext, subdirectory: "ply_frames/thumbnails") {
                                print("FramesGalleryView: Found bundle URL for \(baseName).\(ext)")
                                finalURL = bundleURL
                            } else if let bundleURL = Bundle.main.url(forResource: baseName, withExtension: ext, subdirectory: "App/ply_frames/thumbnails") {
                                print("FramesGalleryView: Found bundle URL in App/ply_frames/thumbnails for \(baseName).\(ext)")
                                finalURL = bundleURL
                            }
                            
                            thumbnailMap[baseName] = finalURL
                            print("FramesGalleryView: Mapped thumbnail \(baseName) -> \(finalURL.path)")
                        } else {
                            print("FramesGalleryView: Skipping non-image file: \(fileName)")
                        }
                    }
                    print("FramesGalleryView: Created thumbnail map with \(thumbnailMap.count) entries")
                } else {
                    print("FramesGalleryView: Failed to read thumbnails directory contents")
                }
            } else {
                print("FramesGalleryView: Thumbnails directory does not exist at: \(thumbnailsPath)")
                // Try to find thumbnails via bundle
                print("FramesGalleryView: Attempting to find thumbnails via Bundle.main...")
                if let resourcePath = Bundle.main.resourcePath {
                    let bundleThumbnailsPath = (resourcePath as NSString).appendingPathComponent("ply_frames/thumbnails")
                    if fileManager.fileExists(atPath: bundleThumbnailsPath) {
                        print("FramesGalleryView: Found thumbnails at bundle resource path: \(bundleThumbnailsPath)")
                    }
                }
            }
            
            // Create entries for ALL PLY files, with thumbnails if available
            var matchedThumbnails: [(url: URL?, plyName: String)] = []
            
            for plyFile in sortedPLYFiles {
                let plyName = plyFile.lastPathComponent
                let baseName = (plyName as NSString).deletingPathExtension
                
                // Try to find matching thumbnail by base name (supports .jpg, .jpeg, .png)
                let thumbnailURL = thumbnailMap[baseName]
                if let thumbnailURL = thumbnailURL {
                    print("FramesGalleryView: ✓ Found thumbnail for \(plyName) -> \(thumbnailURL.lastPathComponent)")
                } else {
                    print("FramesGalleryView: ✗ No thumbnail found for \(plyName) (baseName: \(baseName))")
                    print("FramesGalleryView:   Available thumbnail keys: \(Array(thumbnailMap.keys).sorted().prefix(5))")
                }
                matchedThumbnails.append((url: thumbnailURL, plyName: plyName))
            }
            
            let thumbnailCount = matchedThumbnails.filter { $0.url != nil }.count
            print("FramesGalleryView: Loaded \(matchedThumbnails.count) PLY files, \(thumbnailCount) with thumbnails")
            if thumbnailCount == 0 && !thumbnailMap.isEmpty {
                print("FramesGalleryView: WARNING - Thumbnail map has \(thumbnailMap.count) entries but no matches found!")
                print("FramesGalleryView: Sample PLY base names: \(sortedPLYFiles.prefix(3).map { ($0.lastPathComponent as NSString).deletingPathExtension })")
                print("FramesGalleryView: Sample thumbnail keys: \(Array(thumbnailMap.keys).sorted().prefix(3))")
            }
            
            await MainActor.run {
                thumbnailURLs = matchedThumbnails
                isLoading = false
            }
        }
    }
    
    private func loadFrame(at index: Int) {
        guard index < thumbnailURLs.count else { return }
        
        let plyName = thumbnailURLs[index].plyName
        
        // Get all PLY files sorted to find the correct index
        let fileManager = FileManager.default
        guard let plyFiles = try? fileManager.contentsOfDirectory(at: plyDirectoryURL, includingPropertiesForKeys: nil) else {
            return
        }
        
        let sortedPLYFiles = plyFiles
            .filter { $0.pathExtension.lowercased() == "ply" }
            .sorted { url1, url2 in
                let name1 = url1.deletingPathExtension().lastPathComponent
                let name2 = url2.deletingPathExtension().lastPathComponent
                if name1.hasPrefix("frame_") && name2.hasPrefix("frame_") {
                    let num1 = Int(name1.dropFirst(6)) ?? 0
                    let num2 = Int(name2.dropFirst(6)) ?? 0
                    return num1 < num2
                }
                return name1 < name2
            }
        
        // Find the index of the selected PLY file in the sorted array
        if let frameIndex = sortedPLYFiles.firstIndex(where: { $0.lastPathComponent == plyName }) {
            Task {
                // Set frame index (this is the index in the sorted array, not the frame number)
                FrameIndexStorage.shared.frameIndex = frameIndex
                
                // Dismiss current immersive space if shown
                if immersiveSpaceIsShown {
                    await dismissImmersiveSpace()
                    immersiveSpaceIsShown = false
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                
                // Open new frame
                let modelIdentifier = ModelIdentifier.singleFrameSplat(plyDirectoryURL)
                switch await openImmersiveSpace(value: modelIdentifier) {
                case .opened:
                    immersiveSpaceIsShown = true
                    dismiss()
                default:
                    break
                }
            }
        }
    }
}

struct ThumbnailView: View {
    let thumbnailURL: URL?
    let plyName: String
    let onTap: () -> Void
    
    @State private var image: UIImage?
    @State private var imageLoadFailed = false
    
    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                if let image = image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 150, height: 150)
                        .clipped()
                        .cornerRadius(8)
                } else if imageLoadFailed {
                    // Show file name when thumbnail is not available
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 150, height: 150)
                        .cornerRadius(8)
                        .overlay {
                            Text((plyName as NSString).deletingPathExtension)
                                .font(.caption)
                                .foregroundColor(.primary)
                                .multilineTextAlignment(.center)
                                .padding(4)
                        }
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 150, height: 150)
                        .cornerRadius(8)
                        .overlay {
                            ProgressView()
                        }
                }
                
                Text((plyName as NSString).deletingPathExtension)
                    .font(.caption)
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .onAppear {
            loadImage()
        }
    }
    
    private func loadImage() {
        guard let thumbnailURL = thumbnailURL else {
            // No thumbnail URL provided, show name instead
            print("ThumbnailView: No URL for \(plyName)")
            imageLoadFailed = true
            return
        }
        
        print("ThumbnailView: Loading image from: \(thumbnailURL.path)")
        print("ThumbnailView: URL scheme: \(thumbnailURL.scheme ?? "nil")")
        print("ThumbnailView: URL isFileURL: \(thumbnailURL.isFileURL)")
        
        Task {
            // Check if file exists first
            let fileManager = FileManager.default
            let filePath = thumbnailURL.path
            
            // Try to access the file with security-scoped resource if needed
            let needsSecurityAccess = thumbnailURL.startAccessingSecurityScopedResource()
            defer {
                if needsSecurityAccess {
                    thumbnailURL.stopAccessingSecurityScopedResource()
                }
            }
            
            guard fileManager.fileExists(atPath: filePath) else {
                print("ThumbnailView: File does not exist at: \(filePath)")
                // Try alternative: check if it's a bundle resource
                let fileName = thumbnailURL.lastPathComponent
                let baseName = (fileName as NSString).deletingPathExtension
                if let bundleURL = Bundle.main.url(forResource: baseName, withExtension: "jpg", subdirectory: "ply_frames/thumbnails") {
                    print("ThumbnailView: Found in bundle at: \(bundleURL.path)")
                    await loadImageFromURL(bundleURL)
                } else {
                    print("ThumbnailView: Not found in bundle either")
                    await MainActor.run {
                        imageLoadFailed = true
                    }
                }
                return
            }
            
            print("ThumbnailView: File exists, reading data...")
            await loadImageFromURL(thumbnailURL)
        }
    }
    
    private func loadImageFromURL(_ url: URL) async {
        if let data = try? Data(contentsOf: url) {
            print("ThumbnailView: Read \(data.count) bytes from \(url.lastPathComponent)")
            if let loadedImage = UIImage(data: data) {
                print("ThumbnailView: Successfully loaded image for \(plyName)")
                await MainActor.run {
                    image = loadedImage
                }
            } else {
                print("ThumbnailView: Failed to create UIImage from data (size: \(data.count) bytes)")
                await MainActor.run {
                    imageLoadFailed = true
                }
            }
        } else {
            print("ThumbnailView: Failed to read data from URL: \(url.path)")
            await MainActor.run {
                imageLoadFailed = true
            }
        }
    }
}


import Foundation

public struct FileSystemTreeNode: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let url: URL
    public let isDirectory: Bool
    public let relativePath: String
    public let depth: Int
    public var children: [FileSystemTreeNode]
    public var videoURLs: [URL]
    
    public var videoCount: Int {
        if isDirectory {
            return videoURLs.count
        } else {
            return 1
        }
    }
    
    public var isExpandable: Bool {
        return isDirectory && !children.isEmpty
    }
    
    public init(
        id: String,
        name: String,
        url: URL,
        isDirectory: Bool,
        relativePath: String,
        depth: Int,
        children: [FileSystemTreeNode] = [],
        videoURLs: [URL] = []
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.isDirectory = isDirectory
        self.relativePath = relativePath
        self.depth = depth
        self.children = children
        self.videoURLs = videoURLs
    }
}

public struct FileSystemTreeBuilder {
    
    /// Builds a hierarchical tree of nodes representing the folder and file structure.
    /// If rootURL is provided, hierarchy is relative to rootURL.
    /// Otherwise, common parent directory is used if available.
    public static func buildTree(rootURL: URL?, files: [URL]) -> [FileSystemTreeNode] {
        guard !files.isEmpty else { return [] }
        
        let baseDirectory: URL
        if let root = rootURL {
            baseDirectory = root.standardizedFileURL
        } else {
            // Find common ancestor directory among all files
            baseDirectory = commonAncestor(for: files)
        }
        
        // Tree building using an internal mutable directory node structure
        final class MutableDirNode {
            let name: String
            let url: URL
            let relativePath: String
            var subdirs: [String: MutableDirNode] = [:]
            var fileURLs: [URL] = []
            
            init(name: String, url: URL, relativePath: String) {
                self.name = name
                self.url = url
                self.relativePath = relativePath
            }
            
            func allVideos() -> [URL] {
                var list = fileURLs
                for sub in subdirs.values {
                    list.append(contentsOf: sub.allVideos())
                }
                return list
            }
        }
        
        let rootNode = MutableDirNode(name: baseDirectory.lastPathComponent, url: baseDirectory, relativePath: "")
        let basePath = baseDirectory.path
        
        for file in files {
            let stdFile = file.standardizedFileURL
            let filePath = stdFile.path
            
            var relPath = ""
            if filePath.hasPrefix(basePath) {
                relPath = String(filePath.dropFirst(basePath.count))
                if relPath.hasPrefix("/") {
                    relPath = String(relPath.dropFirst())
                }
            } else {
                relPath = stdFile.lastPathComponent
            }
            
            let components = relPath.split(separator: "/").map(String.init)
            if components.isEmpty { continue }
            
            var current = rootNode
            var cumulativeRelPath = ""
            
            if components.count > 1 {
                for i in 0..<(components.count - 1) {
                    let dirName = components[i]
                    cumulativeRelPath = cumulativeRelPath.isEmpty ? dirName : "\(cumulativeRelPath)/\(dirName)"
                    if let existing = current.subdirs[dirName] {
                        current = existing
                    } else {
                        let dirURL = current.url.appendingPathComponent(dirName)
                        let newDir = MutableDirNode(name: dirName, url: dirURL, relativePath: cumulativeRelPath)
                        current.subdirs[dirName] = newDir
                        current = newDir
                    }
                }
            }
            
            current.fileURLs.append(stdFile)
        }
        
        // Convert MutableDirNode tree into immutable FileSystemTreeNode tree
        func convert(dir: MutableDirNode, depth: Int) -> [FileSystemTreeNode] {
            var items: [FileSystemTreeNode] = []
            
            // 1. Sort subdirectories alphabetically
            let sortedSubdirs = dir.subdirs.values.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            
            for sub in sortedSubdirs {
                let subChildren = convert(dir: sub, depth: depth + 1)
                let allVids = sub.allVideos()
                let node = FileSystemTreeNode(
                    id: sub.url.path,
                    name: sub.name,
                    url: sub.url,
                    isDirectory: true,
                    relativePath: sub.relativePath,
                    depth: depth,
                    children: subChildren,
                    videoURLs: allVids
                )
                items.append(node)
            }
            
            // 2. Sort files alphabetically
            let sortedFiles = dir.fileURLs.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
            
            for file in sortedFiles {
                let fileRelPath = dir.relativePath.isEmpty ? file.lastPathComponent : "\(dir.relativePath)/\(file.lastPathComponent)"
                let node = FileSystemTreeNode(
                    id: file.path,
                    name: file.lastPathComponent,
                    url: file,
                    isDirectory: false,
                    relativePath: fileRelPath,
                    depth: depth,
                    children: [],
                    videoURLs: [file]
                )
                items.append(node)
            }
            
            return items
        }
        
        return convert(dir: rootNode, depth: 0)
    }
    
    /// Checks if any directory nodes exist in the tree.
    public static func hasSubfolders(in nodes: [FileSystemTreeNode]) -> Bool {
        return nodes.contains(where: { $0.isDirectory })
    }
    
    /// Flattens a tree into a linear list of visible nodes respecting collapsed folder IDs, hidden folder IDs, global folder visibility, and search filters.
    public static func flatten(
        nodes: [FileSystemTreeNode],
        collapsedIDs: Set<String>,
        hiddenIDs: Set<String> = [],
        hideAllFolders: Bool = false,
        filterText: String = ""
    ) -> [FileSystemTreeNode] {
        let cleanFilter = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
        // If filter is active, check if a node or any of its descendants matches
        func nodeMatches(_ node: FileSystemTreeNode) -> Bool {
            if cleanFilter.isEmpty { return true }
            if node.name.localizedCaseInsensitiveContains(cleanFilter) { return true }
            if node.isDirectory {
                return node.videoURLs.contains { $0.lastPathComponent.localizedCaseInsensitiveContains(cleanFilter) }
            }
            return false
        }
        
        var result: [FileSystemTreeNode] = []
        
        func traverse(_ list: [FileSystemTreeNode]) {
            for node in list {
                guard cleanFilter.isEmpty || nodeMatches(node) else { continue }
                
                if node.isDirectory {
                    let isBannerHidden = hideAllFolders || hiddenIDs.contains(node.id)
                    if !isBannerHidden {
                        result.append(node)
                    }
                    let isCollapsed = !isBannerHidden && cleanFilter.isEmpty && collapsedIDs.contains(node.id)
                    if !isCollapsed {
                        traverse(node.children)
                    }
                } else {
                    let adjustedNode: FileSystemTreeNode
                    if hideAllFolders {
                        adjustedNode = FileSystemTreeNode(
                            id: node.id,
                            name: node.name,
                            url: node.url,
                            isDirectory: node.isDirectory,
                            relativePath: node.relativePath,
                            depth: 0,
                            children: node.children,
                            videoURLs: node.videoURLs
                        )
                    } else {
                        adjustedNode = node
                    }
                    result.append(adjustedNode)
                }
            }
        }
        
        traverse(nodes)
        return result
    }
    
    /// Extracts all video URLs in depth-first traversal order
    public static func orderedVideoURLs(from nodes: [FileSystemTreeNode]) -> [URL] {
        var urls: [URL] = []
        func collect(_ list: [FileSystemTreeNode]) {
            for node in list {
                if !node.isDirectory {
                    urls.append(node.url)
                } else {
                    collect(node.children)
                }
            }
        }
        collect(nodes)
        return urls
    }
    
    private static func commonAncestor(for urls: [URL]) -> URL {
        guard let first = urls.first else {
            return URL(fileURLWithPath: "/")
        }
        var common = first.deletingLastPathComponent().standardizedFileURL
        for u in urls.dropFirst() {
            let parent = u.deletingLastPathComponent().standardizedFileURL
            while !parent.path.hasPrefix(common.path) && common.path != "/" {
                common = common.deletingLastPathComponent()
            }
        }
        return common
    }
}

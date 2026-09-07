import SwiftUI
import AppKit
import UniformTypeIdentifiers
import VideoQCLib

struct PropertiesModalView: View {
    @Binding var isPresented: Bool
    var asset: DeliverableAsset?
    var fileURL: URL?
    var isLoading: Bool
    var isLightMode: Bool
    
    var onCopySpecs: ((String) -> Void)?
    var onRevealInFinder: ((URL) -> Void)?
    var onLoadSlotA: ((URL) -> Void)?
    var onLoadSlotB: ((URL) -> Void)?
    
    private var palette: StudioPalette { StudioPalette(isLightMode) }
    
    private var effectiveURL: URL? {
        asset?.fileURL ?? fileURL
    }
    
    private var fileName: String {
        asset?.fileName ?? effectiveURL?.lastPathComponent ?? "UNKNOWN"
    }
    
    private var containerType: String {
        let ext = effectiveURL?.pathExtension.uppercased() ?? "FILE"
        switch ext {
        case "MOV": return "QuickTime Movie (.MOV)"
        case "MP4": return "MPEG-4 Movie (.MP4)"
        case "M4V": return "Apple MPEG-4 Video (.M4V)"
        case "MXF": return "Material Exchange Format (.MXF)"
        case "AVI": return "Audio Video Interleave (.AVI)"
        default: return "\(ext) Media File"
        }
    }
    
    var body: some View {
        ZStack {
            // Backdrop Scrim
            Color.black.opacity(isPresented ? 0.65 : 0.0)
                .edgesIgnoringSafeArea(.all)
                .allowsHitTesting(isPresented)
                .onTapGesture {
                    dismissModal()
                }
            
            // Modal Card
            VStack(spacing: 0) {
                // Header Bar
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(palette.textMain)
                    
                    Text("FILE PROPERTIES // \(fileName.uppercased())")
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .foregroundColor(palette.textMain)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
                    Spacer()
                    
                    Button(action: { dismissModal() }) {
                        Text("CLOSE (ESC)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .foregroundColor(palette.textMain)
                            .studioBox(background: palette.bgSubtle, border: palette.borderLine)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(palette.bgPanel)
                
                Rectangle().fill(palette.borderLine).frame(height: 1)
                
                // Body Content
                if isLoading {
                    VStack(spacing: 14) {
                        Spacer()
                        ProgressView()
                            .scaleEffect(1.1)
                        Text("READING FILE PROPERTIES...")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(palette.textMuted)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(palette.bgMain)
                } else if let asset = asset {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            // Top Overview Banner
                            overviewBanner(asset: asset)
                            
                            // Section 1: File Information
                            propertiesSection(title: "01 // FILE INFORMATION") {
                                propertyRow(label: "File Path", value: asset.fileURL.path, copyable: true)
                                propertyRow(label: "Type", value: containerType)
                                propertyRow(label: "File Size", value: "\(asset.formattedFileSize) (\(formattedByteString(asset.fileSizeBytes)))")
                                propertyRow(label: "Created", value: asset.formattedCreationDate)
                            }
                            
                            // Section 2: Video Stream
                            propertiesSection(title: "02 // IMAGE / VIDEO STREAM") {
                                propertyRow(label: "Image Size", value: "\(asset.width) x \(asset.height) (\(asset.aspectRatioString))")
                                propertyRow(label: "Pixel Aspect Ratio", value: "Square Pixels (1.0)")
                                propertyRow(label: "Frame Rate", value: String(format: "%.3f fps", asset.fps))
                                propertyRow(label: "Video Codec", value: asset.videoCodec)
                                propertyRow(label: "Total Duration", value: "\(asset.timecode) (\(asset.formattedDuration))")
                                propertyRow(label: "Total Frames", value: "\(asset.totalFrames) frames")
                            }
                            
                            // Section 3: Audio Stream
                            propertiesSection(title: "03 // AUDIO STREAM") {
                                if asset.hasAudio {
                                    propertyRow(label: "Audio Codec", value: asset.audioCodec)
                                    propertyRow(label: "Configuration", value: asset.audioConfig)
                                    if !asset.audioFormatDetail.isEmpty {
                                        propertyRow(label: "Format Detail", value: asset.audioFormatDetail)
                                    }
                                    if asset.audioBitrate != "--" {
                                        propertyRow(label: "Bitrate", value: asset.audioBitrate)
                                    }
                                } else {
                                    propertyRow(label: "Audio Status", value: "No Audio Streams Detected")
                                }
                            }
                            
                            // Section 4: Captions & Subtitles
                            if asset.hasSubtitles || asset.subtitlesInfo != "NONE" {
                                propertiesSection(title: "04 // CAPTIONS & SUBTITLES") {
                                    propertyRow(label: "Captions / Subs", value: asset.subtitlesInfo)
                                }
                            }
                        }
                        .padding(20)
                    }
                    .background(palette.bgMain)
                } else {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 28))
                            .foregroundColor(palette.textMuted)
                        Text("UNABLE TO LOAD PROPERTIES")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(palette.textMain)
                        if let effectiveURL = effectiveURL {
                            Text(effectiveURL.path)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(palette.textSubtle)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(palette.bgMain)
                }
                
                Rectangle().fill(palette.borderLine).frame(height: 1)
                
                // Bottom Footer Action Bar
                HStack(spacing: 10) {
                    if let asset = asset {
                        Button(action: {
                            let text = buildPremiereProSpecsText(asset: asset)
                            copyToClipboard(text)
                            onCopySpecs?(text)
                        }) {
                            HStack(spacing: 5) {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 10, weight: .bold))
                                Text("COPY SPECS")
                                    .font(.system(size: 10, weight: .black, design: .monospaced))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .foregroundColor(palette.textMain)
                            .studioBox(background: palette.bgSubtle, border: palette.borderLine)
                        }
                        .buttonStyle(.plain)
                    }
                    
                    if let effectiveURL = effectiveURL {
                        Button(action: {
                            onRevealInFinder?(effectiveURL) ?? NSWorkspace.shared.activateFileViewerSelecting([effectiveURL])
                        }) {
                            HStack(spacing: 5) {
                                Image(systemName: "folder")
                                    .font(.system(size: 10, weight: .bold))
                                Text("REVEAL IN FINDER")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .foregroundColor(palette.textMain)
                            .studioBox(background: palette.bgSubtle, border: palette.borderLine)
                        }
                        .buttonStyle(.plain)
                        
                        Spacer()
                        
                        Button(action: {
                            onLoadSlotA?(effectiveURL)
                            dismissModal()
                        }) {
                            HStack(spacing: 4) {
                                Text("+A")
                                    .font(.system(size: 9, weight: .black, design: .monospaced))
                                Text("LOAD AS MASTER")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .foregroundColor(palette.accentPositive)
                            .studioBox(background: palette.accentPositive.opacity(0.12), border: palette.accentPositive.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                        
                        Button(action: {
                            onLoadSlotB?(effectiveURL)
                            dismissModal()
                        }) {
                            HStack(spacing: 4) {
                                Text("+B")
                                    .font(.system(size: 9, weight: .black, design: .monospaced))
                                Text("LOAD AS COMPARE")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .foregroundColor(palette.accentSlotB)
                            .studioBox(background: palette.accentSlotB.opacity(0.12), border: palette.accentSlotB.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                    } else {
                        Spacer()
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(palette.bgPanel)
            }
            .frame(width: 660, height: 580)
            .studioBox(background: palette.bgPanel, border: palette.borderStrong)
            .shadow(color: Color.black.opacity(0.45), radius: 24, x: 0, y: 12)
        }
        .allowsHitTesting(isPresented)
    }
    
    // MARK: - Overview Banner
    
    private func overviewBanner(asset: DeliverableAsset) -> some View {
        HStack(spacing: 12) {
            // Container format badge
            Text(asset.container)
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .foregroundColor(palette.textMain)
                .studioBox(background: palette.bgSubtle, border: palette.borderStrong)
            
            VStack(alignment: .leading, spacing: 3) {
                Text(asset.fileName)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(palette.textMain)
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                HStack(spacing: 8) {
                    Text("\(asset.width)x\(asset.height)")
                    Text("•")
                    Text(String(format: "%.2ffps", asset.fps))
                    Text("•")
                    Text(asset.videoCodec)
                    Text("•")
                    Text(asset.formattedDuration)
                }
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(palette.textMuted)
            }
            
            Spacer()
        }
        .padding(12)
        .studioBox(background: palette.bgCardHeader, border: palette.borderLine)
    }
    
    // MARK: - Section & Row Builders
    
    private func propertiesSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .foregroundColor(palette.textMuted)
                .tracking(0.5)
            
            VStack(spacing: 1) {
                content()
            }
            .studioBox(background: palette.bgCardSubtle, border: palette.borderLine)
        }
    }
    
    private func propertyRow(label: String, value: String, copyable: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(palette.textMuted)
                .frame(width: 150, alignment: .leading)
            
            Text(value)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(palette.textMain)
                .lineLimit(label == "File Path" ? 2 : 1)
                .truncationMode(label == "File Path" ? .middle : .tail)
                .textSelection(.enabled)
            
            Spacer()
            
            if copyable {
                Button(action: {
                    copyToClipboard(value)
                }) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(palette.textSubtle)
                        .padding(4)
                }
                .buttonStyle(.plain)
                .help("Copy \(label)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(palette.bgPanel)
    }
    
    // MARK: - Premiere Pro Style Formatted Specs Text
    
    private func buildPremiereProSpecsText(asset: DeliverableAsset) -> String {
        var lines: [String] = []
        lines.append("File Path: \(asset.fileURL.path)")
        lines.append("Type: \(containerType)")
        lines.append("File Size: \(asset.formattedFileSize) (\(formattedByteString(asset.fileSizeBytes)))")
        lines.append("Image Size: \(asset.width) x \(asset.height)")
        lines.append("Frame Rate: \(String(format: "%.3f fps", asset.fps))")
        lines.append("Source Audio Format: \(asset.hasAudio ? "\(asset.audioCodec) - \(asset.audioConfig)" : "No Audio")")
        lines.append("Total Duration: \(asset.timecode) (\(asset.formattedDuration)) - \(asset.totalFrames) frames")
        lines.append("Pixel Aspect Ratio: 1.0 (Square Pixels)")
        lines.append("Aspect Ratio: \(asset.aspectRatioString)")
        lines.append("Video Codec: \(asset.videoCodec)")
        if asset.hasAudio {
            lines.append("Audio Codec: \(asset.audioCodec)")
            if !asset.audioBitrate.isEmpty && asset.audioBitrate != "--" {
                lines.append("Audio Bitrate: \(asset.audioBitrate)")
            }
            if !asset.audioFormatDetail.isEmpty {
                lines.append("Audio Format Detail: \(asset.audioFormatDetail)")
            }
        }
        if asset.hasSubtitles || asset.subtitlesInfo != "NONE" {
            lines.append("Subtitles / Captions: \(asset.subtitlesInfo)")
        }
        lines.append("Created: \(asset.formattedCreationDate)")
        return lines.joined(separator: "\n")
    }
    
    private func formattedByteString(_ bytes: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let numStr = formatter.string(from: NSNumber(value: bytes)) ?? "\(bytes)"
        return "\(numStr) bytes"
    }
    
    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    
    private func dismissModal() {
        withAnimation(.easeInOut(duration: 0.15)) {
            isPresented = false
        }
        DispatchQueue.main.async {
            if let window = NSApp.windows.first(where: { $0.canBecomeKey }) {
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(nil)
            }
        }
    }
}

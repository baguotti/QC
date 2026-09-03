import SwiftUI
import AppKit

struct FeedbackModalView: View {
    @Binding var isPresented: Bool
    @AppStorage("isLightMode") private var isLightMode: Bool = false
    
    @State private var feedbackType: FeedbackType = .issue
    @State private var userEmail: String = ""
    @State private var feedbackText: String = ""
    @State private var includeSystemSpecs: Bool = true
    @State private var copySuccessNotice: Bool = false
    
    enum FeedbackType: String, CaseIterable, Identifiable {
        case issue = "BUG / ISSUE"
        case feature = "FEATURE REQUEST"
        case feedback = "FEEDBACK"
        
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .issue: return "exclamationmark.triangle.fill"
            case .feature: return "sparkles"
            case .feedback: return "bubble.left.and.bubble.right.fill"
            }
        }
    }
    
    // Dynamic Studio Theme Palette
    private var bgMain: Color { StudioTheme.bgMain(isLightMode) }
    private var bgPanel: Color { StudioTheme.bgPanel(isLightMode) }
    private var bgSubtle: Color { StudioTheme.bgSubtle(isLightMode) }
    private var bgCardBody: Color { StudioTheme.bgCardSubtle(isLightMode) }
    private var borderLine: Color { StudioTheme.borderLine(isLightMode) }
    private var borderStrong: Color { StudioTheme.borderStrong(isLightMode) }
    private var textMain: Color { StudioTheme.textMain(isLightMode) }
    private var textMuted: Color { StudioTheme.textMuted(isLightMode) }
    private var textSubtle: Color { StudioTheme.textSubtle(isLightMode) }
    private var primaryBtnBg: Color { StudioTheme.primaryBtnBg(isLightMode) }
    private var primaryBtnFg: Color { StudioTheme.primaryBtnFg(isLightMode) }
    private var accentPositive: Color { StudioTheme.positive }
    
    private let targetEmail = "fusetti.riccardo@gmail.com"
    
    private var systemSpecsString: String {
        let osVer = ProcessInfo.processInfo.operatingSystemVersionString
        let macArch: String
        #if arch(arm64)
        macArch = "Apple Silicon (arm64)"
        #else
        macArch = "Intel (x86_64)"
        #endif
        return "App: QCpie v\(AppVersionInfo.version)\nOS: macOS \(osVer)\nArchitecture: \(macArch)"
    }
    
    private var fullEmailBody: String {
        var body = feedbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !userEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body += "\n\n---\nReply to: \(userEmail.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        if includeSystemSpecs {
            body += "\n\n---\nDiagnostics:\n\(systemSpecsString)"
        }
        return body
    }
    
    var body: some View {
        ZStack {
            // Backdrop Scrim
            Color.black.opacity(0.65)
                .edgesIgnoringSafeArea(.all)
                .onTapGesture {
                    isPresented = false
                }
            
            // Modal Card Container
            VStack(spacing: 0) {
                // Header Bar
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: "envelope.badge.fill")
                            .font(.system(size: 13))
                            .foregroundColor(textMain)
                        Text("FEEDBACK & SUPPORT // QCpie")
                            .font(.system(size: 12, weight: .black, design: .monospaced))
                            .foregroundColor(textMain)
                        
                        Text("TO: \(targetEmail)")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(textMuted)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .foregroundColor(textMuted)
                            .studioBox(background: bgSubtle, border: borderLine)
                    }
                    Spacer()
                    Button(action: { isPresented = false }) {
                        Text("CLOSE (ESC)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .foregroundColor(textMain)
                            .studioBox(background: bgSubtle, border: borderLine)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(bgPanel)
                
                Rectangle().fill(borderLine).frame(height: 1)
                
                // Form Body
                VStack(alignment: .leading, spacing: 14) {
                    // Category Picker
                    VStack(alignment: .leading, spacing: 6) {
                        Text("CATEGORY")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(textMuted)
                        
                        HStack(spacing: 8) {
                            ForEach(FeedbackType.allCases) { type in
                                Button(action: { feedbackType = type }) {
                                    HStack(spacing: 6) {
                                        Image(systemName: type.icon)
                                            .font(.system(size: 10))
                                        Text(type.rawValue)
                                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .foregroundColor(feedbackType == type ? primaryBtnFg : textMain)
                                    .studioBox(background: feedbackType == type ? primaryBtnBg : bgSubtle, border: feedbackType == type ? borderStrong : borderLine)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    
                    // Optional Reply Email
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("YOUR EMAIL (OPTIONAL)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(textMuted)
                            Spacer()
                            Text("For follow-up replies")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(textSubtle)
                        }
                        
                        TextField("your.email@example.com", text: $userEmail)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11, design: .monospaced))
                            .padding(8)
                            .foregroundColor(textMain)
                            .studioBox(background: bgSubtle, border: borderLine)
                    }
                    
                    // Message Text Area
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("MESSAGE / NOTES")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(textMuted)
                            Spacer()
                            Text("\(feedbackText.count) CHARS")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(textSubtle)
                        }
                        
                        TextEditor(text: $feedbackText)
                            .font(.system(size: 11, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .foregroundColor(textMain)
                            .studioBox(background: bgSubtle, border: borderLine)
                            .frame(minHeight: 140, maxHeight: 180)
                    }
                    
                    // Include Diagnostic Specs Toggle
                    HStack(spacing: 8) {
                        Button(action: { includeSystemSpecs.toggle() }) {
                            Image(systemName: includeSystemSpecs ? "checkmark.square.fill" : "square")
                                .font(.system(size: 13))
                                .foregroundColor(includeSystemSpecs ? textMain : textMuted)
                        }
                        .buttonStyle(.plain)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Include app version and macOS build specs")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(textMain)
                            Text("QCpie v\(AppVersionInfo.version) • macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(textMuted)
                        }
                        
                        Spacer()
                    }
                    .padding(8)
                    .studioBox(background: bgCardBody, border: borderLine)
                }
                .padding(18)
                .background(bgMain)
                
                Rectangle().fill(borderLine).frame(height: 1)
                
                // Footer Actions
                HStack(spacing: 10) {
                    if copySuccessNotice {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(accentPositive)
                            Text("COPIED TO CLIPBOARD!")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(accentPositive)
                        }
                        .transition(.opacity)
                    }
                    
                    Spacer()
                    
                    // Copy to Clipboard Fallback
                    Button(action: copyToClipboard) {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 10))
                            Text("COPY MESSAGE")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .foregroundColor(textMain)
                        .studioBox(background: bgSubtle, border: borderLine)
                    }
                    .buttonStyle(.plain)
                    .disabled(feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    
                    // Primary Send / Open Mail Button
                    Button(action: sendFeedback) {
                        HStack(spacing: 6) {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 10))
                            Text("SEND TO RICCARDO")
                                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .foregroundColor(feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? textMuted : primaryBtnFg)
                        .studioBox(background: feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? bgSubtle : primaryBtnBg, border: borderLine)
                    }
                    .buttonStyle(.plain)
                    .disabled(feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(bgPanel)
            }
            .frame(width: 580)
            .studioBox(background: bgMain, border: borderStrong)
            .shadow(color: Color.black.opacity(0.4), radius: 24, x: 0, y: 12)
        }
    }
    
    private func copyToClipboard() {
        let text = fullEmailBody
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation(.easeInOut(duration: 0.2)) {
            copySuccessNotice = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(.easeInOut(duration: 0.2)) {
                copySuccessNotice = false
            }
        }
    }
    
    private func sendFeedback() {
        let subject = "[QCpie Feedback] [\(feedbackType.rawValue)]"
        let body = fullEmailBody
        
        guard let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let mailtoURL = URL(string: "mailto:\(targetEmail)?subject=\(encodedSubject)&body=\(encodedBody)") else {
            copyToClipboard()
            return
        }
        
        NSWorkspace.shared.open(mailtoURL)
        isPresented = false
    }
}

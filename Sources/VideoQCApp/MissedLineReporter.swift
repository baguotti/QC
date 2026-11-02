import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// The Player's MISSED LINE button: uploads the frame on screen (no EV) to the notes-sync Worker and emails the details
/// plus the frame link through Web3Forms, so lines the automatic Line Check missed can be studied. Lossless PNG when it
/// fits the Worker's limit; a noisy 4K / 8K frame that doesn't is sent as high-quality JPEG instead.
enum MissedLineReporter {
    enum ReportError: LocalizedError {
        case noServer, encode, upload(String), email(String)
        var errorDescription: String? {
            switch self {
            case .noServer: return "No report server configured"
            case .encode: return "Couldn't encode the frame"
            case .upload(let reason): return "Upload failed: \(reason)"
            case .email(let reason): return "Email failed: \(reason)"
            }
        }
    }
    
    /// Uploads `image` and sends the email. `details` are "Label: value" lines shown in the email.
    static func send(image: CGImage, subject: String, details: [String]) async throws {
        guard let server = AppConfig.notesSyncServerURL else { throw ReportError.noServer }
        guard let frame = await Task.detached(priority: .userInitiated, operation: { encode(image) }).value else { throw ReportError.encode }
        
        var upload = URLRequest(url: server.appendingPathComponent("v1/frames"))
        upload.httpMethod = "POST"
        upload.setValue(frame.mimeType, forHTTPHeaderField: "Content-Type")
        upload.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.upload(for: upload, from: frame.data)
        if (response as? HTTPURLResponse)?.statusCode == 415, frame.mimeType != "image/png" {
            throw ReportError.upload("the frame is too large for PNG and the report server doesn't take JPEG yet (redeploy server/notes-sync)")
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let id = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String else {
            throw ReportError.upload(String(data: data, encoding: .utf8) ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let frameURL = server.appendingPathComponent("v1/frames/\(id)").absoluteString
        
        let message = (details + ["", "Frame (\(frame.label), \(image.width)×\(image.height), kept 90 days):", frameURL]).joined(separator: "\n")
        let payload: [String: Any] = [
            "access_key": AppConfig.web3FormsAccessKey,
            "subject": subject,
            "message": message,
            "from_name": "QCpie v\(AppVersionInfo.version)",
            "name": "QCpie Missed Line Report"
        ]
        guard let url = URL(string: "https://api.web3forms.com/submit") else { throw ReportError.email("bad URL") }
        var email = URLRequest(url: url)
        email.httpMethod = "POST"
        email.setValue("application/json", forHTTPHeaderField: "Content-Type")
        email.setValue("application/json", forHTTPHeaderField: "Accept")
        email.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (reply, _) = try await URLSession.shared.data(for: email)
        let json = try? JSONSerialization.jsonObject(with: reply) as? [String: Any]
        guard json?["success"] as? Bool == true else {
            throw ReportError.email(json?["message"] as? String ?? "no confirmation")
        }
    }
    
    /// The Worker's size limit (Cloudflare KV holds up to 25 MB per value).
    static let maxUploadBytes = 24_000_000

    /// Lossless PNG, 8-bit RGB without alpha (an alpha channel or 16-bit samples only add bytes); when that is over the
    /// limit, JPEG at the highest quality that fits (95% keeps a 1 px line's colour; below that only for extreme noise:
    /// pure 8K noise needs 50%).
    static func encode(_ image: CGImage) -> (data: Data, mimeType: String, label: String)? {
        guard let rgb = opaqueRGB8(image) else { return nil }
        if let png = encoded(rgb, type: .png, options: [:]), png.count <= maxUploadBytes {
            return (png, "image/png", "PNG")
        }
        for quality in [0.95, 0.9, 0.8, 0.65, 0.5, 0.35] {
            if let jpeg = encoded(rgb, type: .jpeg, options: [kCGImageDestinationLossyCompressionQuality: quality]),
               jpeg.count <= maxUploadBytes {
                return (jpeg, "image/jpeg", "JPEG \(Int(quality * 100))%, too large for PNG")
            }
        }
        return nil
    }

    private static func opaqueRGB8(_ image: CGImage) -> CGImage? {
        let isOpaque8 = image.bitsPerComponent == 8 && [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        if isOpaque8 { return image }
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    private static func encoded(_ image: CGImage, type: UTType, options: [CFString: Any]) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

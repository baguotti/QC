import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// The Player's MISSED LINE button: uploads the frame on screen (lossless PNG, no EV) to the notes-sync Worker and
/// emails the details plus the frame link through Web3Forms, so lines the automatic Line Check missed can be studied.
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
        guard let png = await Task.detached(priority: .userInitiated, operation: { pngData(image) }).value else { throw ReportError.encode }
        
        var upload = URLRequest(url: server.appendingPathComponent("v1/frames"))
        upload.httpMethod = "POST"
        upload.setValue("image/png", forHTTPHeaderField: "Content-Type")
        upload.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.upload(for: upload, from: png)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let id = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String else {
            throw ReportError.upload(String(data: data, encoding: .utf8) ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let frameURL = server.appendingPathComponent("v1/frames/\(id)").absoluteString
        
        let message = (details + ["", "Frame (PNG, \(image.width)×\(image.height), kept 90 days):", frameURL]).joined(separator: "\n")
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
    
    private static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

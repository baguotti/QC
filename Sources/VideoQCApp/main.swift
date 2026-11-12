import Foundation
import VideoQCLib

// A helper process for Check Subs & Graphics (`PictureTextWorkers`): no window, no Dock icon, no app state.
if CommandLine.arguments.dropFirst().first == PictureTextWorkers.flag {
    ProVideoFormats.register()   // the same decoders as the app (MXF and other pro formats)
    PictureTextWorkers.runProcess()
}
ScanWorkers.executable = Bundle.main.executableURL
QCpieApp.main()

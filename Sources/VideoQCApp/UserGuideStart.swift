import Foundation

// The guide's first chapter: a walk through QCpie for someone opening it for the first time, with the buttons to
// look for drawn as they appear in the app. Keep labels in step with the app's own (they're copied, not linked).

extension UserGuideView {
    static let gettingStarted = GuideChapter(title: "Getting Started", icon: "flag", topics: [
        GuideTopic(title: "Welcome to QCpie", body: "", blocks: [
            .text("QCpie checks video deliverables before they go to a client: it plays them frame by frame, reads their specs, scans them for faults and uploads them to Frame.io. This chapter takes you through each part in a few minutes."),
            .window(.overview),
            .steps([
                GuideStep("The tabs at the top are the four jobs QCpie does. Click one to switch.",
                          [.tab(.player), .tab(.specs), .tab(.lineFinder), .tab(.upload)]),
                GuideStep("The left panel holds your files. Every tab shares them: load a folder once and it's ready everywhere."),
                GuideStep("The middle is where the work happens: the video, the table of specs, the scan results or Frame.io."),
                GuideStep("The right drawer shows details: media info, notes, subtitles and the Delivery Plan."),
                GuideStep("The gear button opens settings, this guide and the feedback form.", [.icon("gearshape.fill", label: "Top right of the window")]),
                GuideStep("The status bar at the bottom explains whatever your pointer is over. If you're unsure what a button does, hover over it and read."),
            ]),
            .tip("Hide either side panel with ⌘⇧← and ⌘⇧→ when you want more room."),
        ]),
        GuideTopic(title: "Load Your Files", body: "", blocks: [
            .window(.leftPanel),
            .steps([
                GuideStep("At the top of the left panel, click Select… and choose a folder of deliverables (or a few files).", [.segments(["Select…", "Add", "Refresh"])]),
                GuideStep("Or drag a folder from Finder onto the box underneath.", [.dropZone("Drop a folder or media files here")]),
                GuideStep("Once files are loaded, Select… becomes Change (replace them), Add brings in more, and Refresh picks up files that were added or re-exported since.", [.segments(["Change", "Add", "Refresh"])]),
            ]),
            .tip("Checking never changes your files: what QCpie finds is shown in the app or saved as a separate report."),
        ]),
        GuideTopic(title: "Watch a Clip", body: "", blocks: [
            .steps([
                GuideStep("Click the Play tab.", [.tab(.player)]),
                GuideStep("Click a file in the queue on the left. It opens in the player."),
                GuideStep("Press Space to play and pause. The arrow keys step one frame at a time.", [.key("Space"), .key("←"), .key("→")]),
                GuideStep("J, K and L shuttle backwards, pause and forwards; press L again to go faster.", [.key("J"), .key("K"), .key("L")]),
                GuideStep("Spotted a problem? Press N to leave a note at that frame. Notes show on the timeline and in the Notes drawer.", [.key("N")]),
            ]),
            .tip("To compare two versions, ⌥-click a second file: it loads into Slot B. Then press C to switch between split, side by side and difference."),
        ]),
        GuideTopic(title: "Check the Specs", body: "", blocks: [
            .steps([
                GuideStep("Click the Inspect tab. Every loaded file gets a row: length, resolution, frame rate, codec, audio and size.", [.tab(.specs)]),
                GuideStep("A warning on a row means the file's name says one thing and the file another (a \"16x9\" file that is really 9x16, say). Hover over it to read why."),
                GuideStep("For sound levels and end frames, use the buttons in the left panel.", [.button("Check Loudness"), .button("Check End Frames")]),
                GuideStep("To share the table, copy it for Google Sheets or save it.", [.button("Sheets"), .button("Save CSV"), .button("Open HTML")]),
            ]),
        ]),
        GuideTopic(title: "Scan for Faults", body: "", blocks: [
            .steps([
                GuideStep("Click the Scan tab.", [.tab(.lineFinder)]),
                GuideStep("Pick a check and click its button. Line Check looks for thin coloured lines at the frame's edges; Frame Check looks for stutters, flash frames and Media Offline; Full Check runs both.",
                          [.button("Run Line Check", icon: "play.fill", primary: true), .button("Run Frame Check"), .button("Run Full Check")]),
                GuideStep("Each file with a finding gets a card. Click a finding to open that exact frame in the player."),
            ]),
            .tip("Scans read every frame, so long files take a while. You can keep working in the other tabs while it runs."),
        ]),
        GuideTopic(title: "Upload to Frame.io", body: "", blocks: [
            .steps([
                GuideStep("Click the Upload tab.", [.tab(.upload)]),
                GuideStep("The first time, sign in with the Adobe account you use for Frame.io.", [.button("Sign In with Adobe", primary: true)]),
                GuideStep("In the middle, open the Frame.io project and folder the files should go to."),
                GuideStep("Click Upload All. Upload & Share does the same, then copies a share link you can paste to the client.",
                          [.button("Upload All", primary: true), .button("Upload & Share")]),
            ]),
            .tip("Files already in that folder (same name and size) are skipped, and an interrupted upload carries on where it stopped."),
        ]),
        GuideTopic(title: "Follow the Delivery Plan", body: "", blocks: [
            .text("If the job has a Google Sheet listing every deliverable, QCpie can tick it off for you: it matches your files to the sheet's rows and checks each one's specs."),
            .window(.drawer),
            .steps([
                GuideStep("On the Inspect tab, open the right drawer with ⌘⇧→.", [.tab(.specs), .key("⌘"), .key("⇧"), .key("→")]),
                GuideStep("Sign in with your studio Google account.", [.button("Sign In with Google…")]),
                GuideStep("Paste the sheet's link and click Link.", [.button("Link")]),
                GuideStep("Each row shows whether its file is Missing, To QC or needs a Check. Right-click a row to set its status (QC Passed, Needs Fix…); the sheet updates for everyone."),
            ]),
        ]),
        GuideTopic(title: "Getting Help", body: "", blocks: [
            .steps([
                GuideStep("Hover over any button and read the status bar at the bottom of the window."),
                GuideStep("Press ⌘S to see the shortcuts for the tab you're on (⌘S or Esc closes the list).", [.key("⌘"), .key("S")]),
                GuideStep("Open this guide again from the gear menu.", [.menuItem(icon: "info.circle", title: "Info / Guide")]),
                GuideStep("Something wrong? Tell us from the same menu.", [.menuItem(icon: "envelope", title: "Feedback & Support")]),
                GuideStep("If QCpie misbehaves, go to User Settings → General → Logs and click Save Zip to Desktop, then send that file along.", [.button("Save Zip to Desktop")]),
            ]),
        ]),
    ])
}

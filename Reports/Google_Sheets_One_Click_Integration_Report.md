# Feasibility Report: 1-Click Google Sheets Export Integration

**Project**: QCpie (The LineFinder 5000)  
**Date**: September 2026  
**Document**: `Reports/Google_Sheets_One_Click_Integration_Report.md`  
**Status**: Feasibility & Architecture Study

---

## Executive Summary

**Yes, a 1-click solution is possible**, but because Google Sheets is a closed cloud web application, **how** it is achieved determines whether it requires cloud authentication (Google OAuth) or operates with zero setup.

Currently, clicking `[ EXPORT GOOGLE SHEETS / CSV ]` invokes a native macOS `NSSavePanel`, saving a `.csv` file to disk. The user must then open Google Drive, upload the CSV, and convert it to a Google Sheet—a tedious 4-to-5 step workflow.

Below are the **3 concrete engineering approaches** to achieve a direct 1-click (or 1.5-click) Google Sheets solution, with trade-offs, feasibility, and user experience compared.

---

## The Core Technical Constraint: How Google Sheets Works

- **No Public "URL with Data" Scheme**: Google does **not** support URLs like `https://sheets.new?data=...` or query-string injection. URLs have hard length limits (~2 KB), and Google’s web servers ignore or reject table payloads for security reasons.
- **`IMPORTDATA` cannot reach local files**: Google Sheets' `=IMPORTDATA("...")` formula is executed on Google's cloud servers, meaning it cannot access local files on your Mac (`localhost` or `file:///`).

Therefore, data must enter Google Sheets through one of three pathways:
1. **The System Clipboard** (Instant, Zero Setup, 1.5 Clicks)
2. **Google Drive REST API via OAuth 2.0** (True 1-Click, Cloud Setup Required)
3. **A Lightweight Google Apps Script Webhook** (True 1-Click, Zero User Auth, Requires Webhook Deployment)

---

## Comparative Breakdown of the 3 Solutions

| Capability | Approach 1: Smart Clipboard + `sheets.new` | Approach 2: Google Drive API (OAuth 2.0) | Approach 3: Google Apps Script Webhook |
| :--- | :--- | :--- | :--- |
| **Number of User Clicks** | **1 Click + ⌘V** ("1.5 Clicks") | **1 Click** (True 1-click after 1st login) | **1 Click** (True 1-click immediately) |
| **Setup / Configuration Required** | **None (Zero setup)** | Google Cloud Console OAuth Client ID | A 10-line Apps Script deployed once |
| **User Authentication** | Uses existing browser session | Requires user to sign in & grant Drive scope | None |
| **Offline Support** | Copies to clipboard even if offline | Fails without internet connection | Fails without internet connection |
| **Privacy & Security** | 100% local (data stays on Mac & clipboard) | Data sent directly to user's Google Drive | Data sent via Webhook endpoint |
| **Implementation Complexity** | **Very Low (~20 lines of Swift)** | **Medium (~150 lines + OAuth handler)** | **Low (~40 lines of Swift + JS script)** |

---

## Detailed Architectural Options

### Approach 1: The "Smart Clipboard + sheets.new" Pattern (Recommended First Step)
*Used by tools like Raycast, Linear, TablePlus, and Notion.*

#### How It Works:
1. The user clicks **`[ OPEN IN GOOGLE SHEETS ]`**.
2. QCpie formats the specs or report table as **Tab-Separated Values (TSV)** and immediately copies it to macOS's system clipboard (`NSPasteboard.general`).
3. QCpie automatically launches `https://sheets.new` in the user's default browser (Chrome, Safari, Brave, Edge).
4. Google Sheets opens with cell **A1** highlighted by default.
5. The user hits **`⌘V` (Paste)**. The entire table—including headers, timestamps, resolutions, and file sizes—instantly snaps into formatted spreadsheet columns.
6. QCpie displays a sleek HUD banner in the app:
   > *"Specs copied to clipboard! Press ⌘V in the new Google Sheet."*

#### Pros:
- **Zero API credentials, zero Google Cloud setup, zero approval delays.**
- Works immediately for every user on any Mac.
- 100% private: no data passes through third-party servers.

#### Cons:
- Requires the user to hit `⌘V` once the browser opens (1 click in QCpie + 1 keystroke in browser).

---

### Approach 2: Google Drive REST API (True 1-Click Cloud Upload)
*Used by cloud-native tools like Figma and Slack.*

#### How It Works:
1. QCpie implements a standard macOS OAuth 2.0 sign-in flow (`ASWebAuthenticationSession`).
2. When the user clicks **`[ OPEN IN GOOGLE SHEETS ]`**:
   - If not signed in: Prompts user to log into their Google account once.
   - If signed in: QCpie sends an HTTP `POST` multipart upload directly to:
     ```
     POST https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart
     ```
     With metadata header: `mimeType: application/vnd.google-apps.spreadsheet`.
3. Google Drive automatically converts the CSV data into a native Google Spreadsheet in the user's Google Drive root or a selected folder.
4. The API returns the spreadsheet's URL (`https://docs.google.com/spreadsheets/d/{fileId}/edit`).
5. QCpie opens that exact URL in the user's browser in <500ms.

#### Pros:
- **True 1-click**: The sheet opens completely pre-filled, titled with the project/folder name and timestamp.
- Automatically saved into the user's own Google Drive.

#### Cons:
- Requires creating a Google Cloud Project with OAuth consent screens and `drive.file` scope.
- Requires internet access and handling token refreshes.

---

### Approach 3: Google Apps Script Webhook (Serverless Bridge)

#### How It Works:
1. Deploy a tiny serverless Google Apps Script on Google Drive:
   ```javascript
   function doPost(e) {
     var csvData = Utilities.parseCsv(e.postData.contents);
     var folder = DriveApp.getRootFolder();
     var ss = SpreadsheetApp.create("QCpie_Specs_" + Utilities.formatDate(new Date(), "GMT", "yyyyMMdd_HHmmss"));
     var sheet = ss.getActiveSheet();
     sheet.getRange(1, 1, csvData.length, csvData[0].length).setValues(csvData);
     return ContentService.createTextOutput(JSON.stringify({ url: ss.getUrl() }))
                          .setMimeType(ContentService.MimeType.JSON);
   }
   ```
2. When the user clicks in QCpie, QCpie makes an `URLSession` `POST` request with the CSV text to this endpoint.
3. The response returns the Google Sheet URL, and QCpie opens it in the browser.

#### Pros:
- True 1-click with zero login screens for the end user.

#### Cons:
- The created spreadsheets reside in the Google Drive of the account that deployed the script, unless the user manually makes a copy or is invited via email.

---

## What About Apple Numbers & Microsoft Excel?

If the goal is simply **"1-click spreadsheet without picking save paths"**, macOS has native support for instant local spreadsheet launching:
- QCpie writes the CSV to a temporary cache file (`/tmp/Deliverables_Specs.csv`).
- Calls `NSWorkspace.shared.open(tempURL)`.
- If Microsoft Excel or Apple Numbers is installed, the spreadsheet opens in **under 150 ms** in a single click, completely bypassing the `NSSavePanel` dialog.

---

## Recommended Next Steps

1. **Phase 1 (Immediate UX Win - Zero Config)**:
   - Change the button action from opening `NSSavePanel` to:
     1. Copy TSV table data to clipboard.
     2. Open `https://sheets.new`.
     3. Show toast: *"Data copied! Press ⌘V in Google Sheets."*
   - Keep a secondary `[ SAVE CSV... ]` option for users who strictly need a file on disk.

2. **Phase 2 (True 1-Click via OAuth)**:
   - If pressing `⌘V` is still too friction-heavy, implement the Google Drive API upload flow with OAuth 2.0 so the sheet is directly provisioned in the user's cloud drive in 1 single click.

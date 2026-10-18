# QCpie Notes Sync (Cloudflare Worker, free plan)

Stores one encrypted blob per clip. The app derives everything from the sync password, so the server never sees file names or note text. Free plan limits (100k requests/day, D1 5 GB) are far above what a few reviewers need: one Mac polls the open clip every 10 s ≈ 8.6k requests per day while QCpie is open.

## Deploy (once)

1. Create a free account at https://dash.cloudflare.com/sign-up and install Node.js LTS (https://nodejs.org).
2. In Terminal:
   ```sh
   cd server/notes-sync
   npx wrangler login
   npx wrangler d1 create qcpie-notes
   ```
3. Copy the printed `database_id` into `wrangler.toml` (replace `PASTE_DATABASE_ID_HERE`).
4. Create the table and deploy:
   ```sh
   npx wrangler d1 execute qcpie-notes --remote --file=schema.sql
   npx wrangler deploy
   ```
   The first deploy asks you to pick a `workers.dev` subdomain, then prints the Worker URL, e.g. `https://qcpie-notes-sync.<subdomain>.workers.dev`.
5. Check it answers:
   ```sh
   curl https://qcpie-notes-sync.<subdomain>.workers.dev/v1/00000000000000000000000000000000/0000000000000000000000000000000000000000000000000000000000000000
   # {"version":0,"data":null}
   ```
6. Put the URL in `Sources/VideoQCApp/AppConfig.swift` → `notesSyncServer`, then build and ship QCpie as usual.

## Use

Settings menu → **Theme, Accents & Sync** → **06 // NOTES SYNC**:
- **CREATE PASSWORD** generates one and copies it; send it to your collaborators.
- Collaborators paste it and press **CONNECT**. Nothing else to set up.

Anyone with the password can read and change the shared notes; to revoke access, everyone switches to a new password (old notes stay on the server under the old one).

## API

- `GET /v1/<room>/<clip>[?since=<version>]` → `200 {version, data}` (`version 0` when empty) or `204` when unchanged.
- `PUT /v1/<room>/<clip>` with `{base, data}` → `200 {version}`, or `409` when another Mac wrote first (the app re-fetches, merges and retries).

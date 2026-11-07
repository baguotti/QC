# Self-hosted client review ("our own Frame.io") — research & plan

Status: **parked** (brainstormed 2026-11-03, nothing built). Prices are from memory / mid-2026 — re-check before committing.

## Goal

Send a link (internal staff or clients) → browser page with a player, frame-accurate comments, replies, resolve, later drawings/approvals. **QCpie runs the show**: it makes proxies, creates links, and pulls comments back as QC notes. Masters never leave the office.

## Decision

**Option A: self-host in the office**, on a dedicated machine. The 4.1 Gbps up / 5.9 Gbps down line removes the bandwidth objection.

- One small always-on box (Mac mini or Linux): **proxies only**, never mounts the project share, ideally its own VLAN.
- Server: one small Swift binary (Hummingbird or Vapor) + SQLite + local SSD for proxies. Swift lets it share QCpie's notes model, merge and timecode code.
- In front: **Caddy** (automatic HTTPS, port 443 only), or **Cloudflare Tunnel / Tailscale Funnel** so no router port is opened. Video still streams from the office; the tunnel only hides the IP.
- Internal / remote staff: LAN, or Tailscale (free at this size, nothing public).
- Fallback, only if uptime or exposure becomes a problem: the same binary on a rented server (Option B below), with QCpie choosing per link.

## Architecture

1. **QCpie → "Share for review"** on a queue clip:
   - Hardware H.264 1080p proxy (VideoToolbox), keyframe about every 12 frames so browser stepping and seeking stay snappy.
   - Written to the review box (SMB or upload), clip registered via the API, link copied: `https://review.<domain>/r/<token>`.
   - Encoding runs at low priority and pauses during playback, like Line Check. **Check that it doesn't hurt Player playback or scrubbing.**
2. **Server**: serves proxies with HTTP Range requests (needed for seeking), the review page, and a comments API. Share links have unguessable tokens, optional expiry and password, and an allow-download switch.
3. **Browser page**:
   - Player with frame stepping; timecode from `requestVideoFrameCallback`. Accurate enough for review notes; pixel QC stays in QCpie.
   - Timeline markers; comments with replies and resolve.
   - Viewers type their name once (cookie), no accounts.
4. **Comments ⇄ QC notes**: QCpie polls the server like the Frame.io comment import (§8j in AGENTS.md): stable note ids, echo and merge rules, a reserved note colour. QC notes can be pushed to the page.

## Effort (sessions with Claude)

| Part | Sessions |
|---|---|
| Server: files, links, comments | 1 |
| Browser player and comments | 1–2 |
| QCpie: proxy and share action | 1 |
| Comments ⇄ notes round trip | 1 |
| Security hardening (rate limits, expiry, logging, isolation checklist) | 1 |
| **MVP total** | **~5–7** (4–6 internal-only) |
| Later: versions, drawings on frames, approvals, email notifications | +1–2 each |

Frame.io parity (teams, permissions, polish) would take months, mostly UI grind.

## Office line capacity (4.1 Gbps up)

| Proxy | Per viewer | Viewers at once |
|---|---|---|
| 1080p | 8 Mbps | ~500 |
| 4K | 25 Mbps | ~160 |
| 20 people at 4K | ~0.5 Gbps total | about 12% of the line |

The real limits are elsewhere:
- Router or firewall throughput when port-forwarding with inspection on.
- The review box's network card (1 GbE ≈ 120 viewers at 1080p).
- The proxy disk: use an SSD, not the project volume.

## Remaining risks of Option A

- **Uptime**: a power cut, internet outage or reboot means dead links. Mitigate with a UPS and an auto-restarting service.
- **Exposure**: an internet-facing box in the building. Mitigate with a separate machine, proxies only, a VLAN, 443 only or a tunnel, rate limits and logs. Do a security review before the first client link.
- **Distance**: far-away clients get slower starts and seeks (no CDN). Bunny CDN in front can be added later.
- **Maintenance**: we're on call.

## Hosting alternatives considered

| Option | Monthly cost | Notes |
|---|---|---|
| A. Office server (chosen) | €0 | Line is ample; we own uptime and security |
| B. Rented server (e.g. Hetzner) | ~€5–20 | ~20 TB traffic included, EU, same binary; fallback |
| C. Bunny.net storage + CDN (+ Stream) | ~€5–20 | Fast global delivery; still needs a small backend |
| D. Backblaze B2 / Wasabi + server | ~€6–10/TB | Free download traffic has limits; more pieces |
| E. AWS S3 + CloudFront | ~$0.085/GB downloaded | Too expensive for video |
| Cloudflare R2 + Workers + D1 | ~$5–15 | Free downloads, $0.015/GB-month stored; Stream: $5 per 1,000 min stored + $1 per 1,000 min watched. Serve video from R2 or Stream (CDN terms) |

## Off-the-shelf tools considered (not chosen: no QCpie round trip)

None of these were checked for maintenance activity or security reviews.

- **Shumai**: MIT, newer. Frame-accurate drawings, timestamped comments, local or S3 storage. Closest match; try it for an afternoon (Docker) to learn which features matter, and borrow its player and drawing ideas.
- **Clapshot**: GPL, Rust + Svelte. Most established open-source option; basic interface.
- **Kitsu (CGWire)**: AGPL. Production tracking plus review playlists, clients open them from a link. Overkill for client review.
- **OpenFrame / open-frame.net**: very new.
- **iconik**: hybrid media asset manager, masters can stay on-prem. Paid and heavy.
- **SaaS** (Frame.io, Ziflow, Filestage): not ours, priced per seat.

## Open question before starting

What does the file server run (macOS, Linux, Synology/QNAP)? That decides whether the review service runs there, in Docker, or on a separate Mac mini. A separate box is preferred for isolation anyway.

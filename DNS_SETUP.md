# DNS Configuration for GitHub Pages

> **Obsolete since 2026-11-25:** the frontend moved to the Cloudflare Worker `ai-arda-tr`, which owns `ai.arda.tr` as a custom domain (see [wrangler.jsonc](wrangler.jsonc) and the README). Kept for history.

To make `ai.arda.tr` work, you need to update your DNS records at your domain registrar (where you managed `arda.tr`).

## Required Record

Add a **CNAME** record with the following details:

| Type | Name (Host) | Value (Points to) | TTL |
| :--- | :--- | :--- | :--- |
| **CNAME** | `ai` | `c0ze.github.io` | Auto / 1 Hour |

> **Note:** Replace `c0ze.github.io` with your actual GitHub username + `.github.io` if your username is different. Based on the screenshot, it seems to be `c0ze`.

## Troubleshooting
*   **Propagation:** DNS changes can take up to 24-48 hours to propagate, though it's usually much faster (minutes).
*   **Enforce HTTPS:** Once GitHub detects the correct DNS, the "Enforce HTTPS" checkbox in the settings (from your screenshot) will become available. Check it to ensure secure connections.
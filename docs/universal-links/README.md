# Rune Scribe universal links

The website administrator should follow
`RuneScribeWebsiteUniversalLinkImplementationPackage.md` for the live WordPress change,
rollback requirements, and acceptance evidence.

Cipher invitations use the existing Rune Scribe product page as their browser fallback:

`https://ravenforgesoftware.com/rune-scribe/?runescribe=import&v=3&p=...`

When Rune Scribe is installed, iOS can open the same URL in the app and present the existing import confirmation. When it is not installed, the product page remains visible and gives the recipient the App Store link.

## Website deployment

The deployable WordPress source is in
`wordpress-plugin/rune-scribe-universal-links/`. Version 1.0.0 was installed and
activated on the Raven Forge site on 2026-09-18 without modifying the active theme,
the Rune Scribe page record, or the website-management plugin.

The plugin serves `apple-app-site-association` unchanged at both of these URLs:

- `https://ravenforgesoftware.com/.well-known/apple-app-site-association`
- `https://ravenforgesoftware.com/apple-app-site-association`

The response must:

- return HTTP 200 without a redirect;
- use `Content-Type: application/json`;
- remain publicly reachable over HTTPS;
- contain no `.json` filename extension.

After deployment, validate the exact response and install a fresh signed app build. iOS caches associated-domain decisions, so an already-installed development build may need to be removed before retesting.

The plugin also adds the Rune Scribe Smart App Banner and a hidden product-page panel.
The panel is revealed in the browser only when `runescribe=import` is present with that
exact value. It links to the official Rune Scribe App Store listing and does not read,
render, or transmit the cipher payload query item.

## App configuration

The iOS target declares `applinks:ravenforgesoftware.com` in `Config/RuneScrib-iOS.entitlements`. `project.yml` is the project-generation authority and contains the same capability.

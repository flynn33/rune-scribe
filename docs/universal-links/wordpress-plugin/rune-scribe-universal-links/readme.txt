=== Rune Scribe Universal Links ===
Contributors: ravenforgesoftware
Tags: universal links, apple, rune scribe
Requires at least: 6.0
Tested up to: 7.1
Requires PHP: 7.4
Stable tag: 1.0.0
License: Proprietary

Serves the Apple App Site Association document for Rune Scribe and displays the
App Store fallback panel for cipher invitation links.

== Installation ==

1. Upload the rune-scribe-universal-links directory to wp-content/plugins.
2. Activate Rune Scribe Universal Links in WordPress.
3. Clear all page, host, and CDN caches.
4. Verify both AASA URLs return HTTP 200 with application/json.

== Behavior ==

The plugin responds only to these association paths:

* /.well-known/apple-app-site-association
* /apple-app-site-association

The missing-app panel is present only on the Rune Scribe product page and is
revealed only when the runescribe query item exactly equals import.

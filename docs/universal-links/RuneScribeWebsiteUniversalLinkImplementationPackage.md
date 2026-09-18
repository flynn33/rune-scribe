# Rune Scribe Website Universal Link Implementation Package

Version: 1.0
Date: 2026-09-18
Website: `https://ravenforgesoftware.com`
Product page: `https://ravenforgesoftware.com/rune-scribe/`

## Objective

Configure the existing Raven Forge Software WordPress website so a Rune Scribe cipher
invitation has two deterministic outcomes:

1. If Rune Scribe is installed, iOS opens the app and the app presents its existing
   cipher-import confirmation.
2. If Rune Scribe is not installed, the Rune Scribe webpage explains that the app is
   required and links directly to the official App Store listing.

This work does not add a database, API, account system, analytics, or message service.
It uses the existing WordPress/PHP host only to serve Apple's static association
document and the existing product page.

## Controlling identifiers

| Item | Required value |
| --- | --- |
| Domain | `ravenforgesoftware.com` |
| Apple team ID | `9AQ2C2838M` |
| App bundle ID | `com.runescribe.app` |
| AASA app ID | `9AQ2C2838M.com.runescribe.app` |
| Current invitation path | `/rune-scribe/` |
| Current invitation marker | `runescribe=import` |
| Legacy invitation paths | `/rune-scribe/import`, `/rune-scribe/import/` |
| App Store URL | `https://apps.apple.com/us/app/rune-scribe/id6782169761` |
| Primary AASA URL | `https://ravenforgesoftware.com/.well-known/apple-app-site-association` |
| Compatibility AASA URL | `https://ravenforgesoftware.com/apple-app-site-association` |

The repository copy at `docs/universal-links/apple-app-site-association` is the
authority for the AASA response body.

## Non-negotiable constraints

- Take a reversible snapshot before changing any live file, page, or plugin.
- Preserve unrelated website content, styling, plugins, and configuration.
- Do not update WordPress, PHP, the active theme, or unrelated plugins as part of this
  task.
- Do not add analytics, tracking pixels, cookies, accounts, or external services.
- Do not display, store, decode, transform, or reflect the `p`, `v`, or `n` parameters.
- Do not place any cipher or message payload into rendered HTML, page metadata,
  analytics events, error messages, or administrator notices.
- Do not redirect either AASA URL.
- Do not rename the AASA resource or add a `.json` extension.
- Do not change the Apple team ID, bundle ID, domain, import marker, or App Store URL.
- Do not add attribution to source, filenames, comments, page content, or completion
  records.
- Stop and restore the snapshot if the product page, WordPress administration, or any
  unrelated route fails after the change.

## Current hosting condition

The site runs on Apache/PHP and WordPress intercepts requests that are not physical
files in the document root. A previous site-specific investigation found that the
administration bridge exposes `wp-content`, not the document root. Therefore, merely
uploading a file under `wp-content/.well-known` will not create the required public
URL.

Use the isolated plugin in
`wordpress-plugin/rune-scribe-universal-links/` to serve the exact response before
template and canonical-redirect processing. The plugin is intentionally independent
of the active theme so theme changes do not remove the association response. If the
hosting control panel provides verified direct document-root access, a physical file
is also acceptable, but the live acceptance tests below remain mandatory.

## Required work

### 1. Capture a reversible snapshot

Before editing:

1. Export or copy the current Rune Scribe page record and rendered HTML.
2. Export the active theme's relevant files if they will be touched.
3. Export the current must-use plugin directory listing and any file that will be
   modified.
4. Record the current responses, status codes, content types, and redirect behavior
   for both AASA URLs and the Rune Scribe page.
5. Store the snapshot outside the live WordPress tree with a timestamp.

Do not proceed if the snapshot is incomplete or cannot be restored.

### 2. Serve the AASA document

Preferred implementation: install and activate
`wordpress-plugin/rune-scribe-universal-links/` as
`wp-content/plugins/rune-scribe-universal-links/`. The production deployment uses
this implementation.

The handler must:

- run at priority `0` on `init` or an equivalently early hook;
- match only the two exact AASA paths;
- answer `GET` and `HEAD` without authentication;
- return status `200` directly, without a redirect;
- return `Content-Type: application/json`;
- return the exact JSON below for `GET`;
- terminate request processing immediately after the response;
- have no effect on any other route.

Required semantic JSON response:

```json
{
  "applinks": {
    "details": [
      {
        "appIDs": [
          "9AQ2C2838M.com.runescribe.app"
        ],
        "components": [
          {
            "/": "/rune-scribe/",
            "?": {
              "runescribe": "import"
            },
            "comment": "Current Rune Scribe cipher invitation links"
          },
          {
            "/": "/rune-scribe/import",
            "comment": "Compatible cipher invitation links from earlier builds"
          },
          {
            "/": "/rune-scribe/import/",
            "comment": "Compatible cipher invitation links from earlier builds"
          }
        ]
      }
    ]
  }
}
```

Do not reuse the obsolete `/rune-scribe/m*` AASA configuration from earlier planning
documents. The JSON above is the current contract.

If an existing handler named for Rune Scribe AASA is present, update that handler
instead of creating a duplicate. Ensure only one handler answers these paths.

### 3. Add the missing-app panel to the Rune Scribe page

On `https://ravenforgesoftware.com/rune-scribe/`, add a panel that is hidden during an
ordinary page visit and becomes visible only when the URL contains the exact query
item `runescribe=import`.

Required visible content:

**Heading**

> Rune Scribe is required to import this cipher

**Instruction**

> Install Rune Scribe from the App Store. After installation, return to the original
> message and tap the runic tablet again.

**Primary button**

- Label: `Get Rune Scribe on the App Store`
- Destination: `https://apps.apple.com/us/app/rune-scribe/id6782169761`

**Secondary information**

> The cipher remains in the original invitation. This webpage does not import, decode,
> or store it.

Implementation requirements:

- Check only `new URLSearchParams(window.location.search).get('runescribe') ===
  'import'`, or an equivalent exact comparison.
- Never place another query value into the DOM.
- Never send query values to WordPress, analytics, logging code, or a third party.
- The panel must work on iPhone widths and with larger text.
- Use the existing Rune Scribe/Raven Forge visual system and existing page components.
- The panel and App Store button must have readable contrast and keyboard-visible focus.
- Do not automatically redirect visitors to the App Store. The recipient must retain
  the explanatory page and choose the install action.
- Do not alter the normal Rune Scribe product-page experience when the marker is absent.

Optional enhancement: add this Smart App Banner metadata to the Rune Scribe page:

```html
<meta name="apple-itunes-app" content="app-id=6782169761">
```

The Smart App Banner is supplementary. It does not replace AASA or the visible install
panel.

### 4. Clear website caches

After deploying the AASA handler and page change:

1. Clear the WordPress page cache.
2. Clear any host/CDN cache for both AASA paths and `/rune-scribe/`.
3. Confirm that no cache or security plugin adds a redirect, HTML wrapper, login page,
   challenge, or cookie gate to the AASA response.

### 5. Execute live acceptance checks

All checks are required.

#### AASA transport

For both AASA URLs, record evidence that:

- the status is `200`;
- the final URL is unchanged;
- no redirect occurred;
- the content type begins with `application/json`;
- the body parses as JSON;
- the body contains only the expected app ID and routes.

Representative commands:

```bash
curl -sS -D - -o /tmp/rune-scribe-aasa \
  https://ravenforgesoftware.com/.well-known/apple-app-site-association
python3 -m json.tool /tmp/rune-scribe-aasa

curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' \
  https://ravenforgesoftware.com/.well-known/apple-app-site-association
```

Expected redirect output:

```text
200
```

Repeat for `https://ravenforgesoftware.com/apple-app-site-association`.

#### Product-page behavior

Verify these three visits:

1. `/rune-scribe/` — normal product page; import-help panel hidden.
2. `/rune-scribe/?runescribe=import` — import-help panel visible with the exact App
   Store link.
3. `/rune-scribe/?runescribe=wrong&v=3&p=PRIVATE_TEST_SENTINEL` — panel hidden and
   `PRIVATE_TEST_SENTINEL` absent from rendered text, metadata, and client-side errors.

Also verify that `/rune-scribe/?runescribe=import&v=3&p=PRIVATE_TEST_SENTINEL` displays
the generic panel without displaying `PRIVATE_TEST_SENTINEL` anywhere in the page.

#### Regression checks

Verify:

- WordPress administration still loads.
- The site home page still loads.
- The Rune Scribe product page still loads without query parameters.
- An unrelated nonexistent route still returns the site's normal `404` behavior.
- No PHP warnings, notices, or stack traces appear in responses or site logs.

### 6. Produce a completion report

Return a concise report containing:

1. Exact live files and page records changed.
2. Snapshot location and rollback procedure.
3. Before/after status and content type for both AASA URLs.
4. The validated AASA JSON body.
5. Screenshots of the normal Rune Scribe page and the import-help state at an iPhone
   viewport.
6. Confirmation that the App Store button points exactly to
   `https://apps.apple.com/us/app/rune-scribe/id6782169761`.
7. Confirmation that test payload values were not reflected or stored by the page.
8. Confirmation that unrelated routes and WordPress administration still work.
9. Any host/CDN caching behavior that may delay Apple's retrieval.

Do not claim that Universal Links work end to end based only on the website checks.
Final qualification requires a newly installed, properly signed Rune Scribe build whose
provisioning profile grants Associated Domains, followed by a tap test on a physical
iPhone.

## Rollback

If any acceptance check fails:

1. Restore the modified page record from the snapshot.
2. Restore or remove only the Rune Scribe must-use plugin file created by this package.
3. Clear WordPress and host/CDN caches.
4. Re-run the normal product-page and unrelated-route regression checks.
5. Report the failed check and observed response without attempting unrelated repairs.

## Privacy note for the app owner

The current app build places encoded cipher material in the URL query. Even when the
WordPress page ignores it, Apache or the hosting provider may include the query in
access logs. A follow-up app change should move cipher material into the URL fragment
while retaining `runescribe=import` as the AASA query marker. Website work must not
claim that origin-level logging is impossible until that client change is shipped.

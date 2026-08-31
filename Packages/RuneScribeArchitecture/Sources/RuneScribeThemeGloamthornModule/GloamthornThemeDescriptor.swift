import Foundation
import RuneScribeContracts

public enum GloamthornThemeDescriptorFactory {
    public static let discoveryDescriptor: ThemeDescriptor = {
        do { return try make() }
        catch { preconditionFailure("Invalid frozen Gloamthorn Theme descriptor: \(error)") }
    }()

    public static func make() throws -> ThemeDescriptor {
        guard var root = try JSONSerialization.jsonObject(
            with: Data(seedJSON.utf8)
        ) as? [String: Any],
        let resources = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(try GloamthornThemeResourceCatalog.references())
        ) as? [[String: Any]]
        else {
            throw GloamthornThemeDescriptorError.invalidSeed
        }
        root["resources"] = resources
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        return try JSONDecoder().decode(ThemeDescriptor.self, from: data)
    }

    private static let seedJSON = #"""
    {
      "id": "theme.gloamthorn.production",
      "moduleID": "com.runescribe.module.theme.gloamthorn",
      "moduleRole": "runescribe.theme.gloamthorn",
      "policyClass": "policy.theme-provider",
      "criticality": "optional",
      "schemaVersion": {
        "major": 1,
        "minor": 0
      },
      "contentVersion": 1,
      "minimumUIContractVersion": {
        "major": 1,
        "minor": 0
      },
      "platformCompatibility": [
        {
          "platform": "iOS",
          "minimumMajorVersion": 17,
          "minimumMinorVersion": 0,
          "minimumPatchVersion": 0
        },
        {
          "platform": "macOS",
          "minimumMajorVersion": 15,
          "minimumMinorVersion": 0,
          "minimumPatchVersion": 0
        }
      ],
      "fallbackCodexID": "codex.norse",
      "codex": {
        "id": "codex.gloamthorn",
        "entitlementID": "unlock.codex.gloamthorn",
        "displayName": {
          "key": "codex.gloamthorn.name",
          "fallbackValue": "Gloamthorn Codex"
        },
        "shortDescription": {
          "key": "codex.gloamthorn.tagline",
          "fallbackValue": "Twilight inscriptions bound in thorn, silver, and shadow."
        },
        "longDescription": {
          "key": "codex.gloamthorn.description",
          "fallbackValue": "A shadowed Elven Codex of charcoal stone, silver briar, and amethyst light. Its script is elegant, severe, and designed to feel ceremonial rather than monstrous."
        },
        "accessibility": {
          "label": {
            "key": "codex.gloamthorn.label",
            "fallbackValue": "Gloamthorn Codex"
          },
          "hint": {
            "key": "codex.gloamthorn.hint",
            "fallbackValue": "An optional Codex that remains unavailable until earned."
          },
          "hidesRedundantGlyphs": false,
          "noColorOnlyState": true,
          "dynamicTypeSafe": true
        },
        "palette": {
          "backgroundPrimary": "#090B13",
          "backgroundSecondary": "#111321",
          "surfacePrimary": "#171A27",
          "surfaceElevated": "#202437",
          "textPrimary": "#EEE7F3",
          "textSecondary": "#B6A9C2",
          "textInverse": "#171A27",
          "accentPrimary": "#A985D3",
          "accentSecondary": "#8CB6A8",
          "success": "#68E09B",
          "warning": "#FFD166",
          "danger": "#FF8A8A",
          "information": "#8FD8FF",
          "locked": "#67636D",
          "encountered": "#8C75A3",
          "unavailable": "#555965",
          "selected": "#F2D675",
          "focus": "#8FD8FF",
          "keyboardFocus": "#FFFFFF",
          "rarityAccents": [
            {
              "rarity": "forged",
              "color": "#D6D9E0"
            },
            {
              "rarity": "inscribed",
              "color": "#8FD8FF"
            },
            {
              "rarity": "rare",
              "color": "#F2D675"
            },
            {
              "rarity": "mythic",
              "color": "#FFB4E6"
            }
          ]
        },
        "primaryScriptID": "script.gloamthorn",
        "fallbackScriptID": "script.base-runes",
        "defaultRelicID": "relic.gloamthorn.nightthorn-tablet",
        "scripts": [
          {
            "id": "script.gloamthorn",
            "displayName": {
              "key": "script.gloamthorn.name",
              "fallbackValue": "Gloamthorn Script"
            },
            "portability": "fontDependent",
            "glyphs": [
              {
                "canonicalValue": 0,
                "glyphID": "gloamthorn-glyph-00",
                "textToken": "ᚠ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 1,
                "glyphID": "gloamthorn-glyph-01",
                "textToken": "ᚡ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 2,
                "glyphID": "gloamthorn-glyph-02",
                "textToken": "ᚢ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 3,
                "glyphID": "gloamthorn-glyph-03",
                "textToken": "ᚣ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 4,
                "glyphID": "gloamthorn-glyph-04",
                "textToken": "ᚤ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 5,
                "glyphID": "gloamthorn-glyph-05",
                "textToken": "ᚥ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 6,
                "glyphID": "gloamthorn-glyph-06",
                "textToken": "ᚦ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 7,
                "glyphID": "gloamthorn-glyph-07",
                "textToken": "ᚧ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 8,
                "glyphID": "gloamthorn-glyph-08",
                "textToken": "ᚨ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 9,
                "glyphID": "gloamthorn-glyph-09",
                "textToken": "ᚩ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 10,
                "glyphID": "gloamthorn-glyph-10",
                "textToken": "ᚪ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 11,
                "glyphID": "gloamthorn-glyph-11",
                "textToken": "ᚫ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 12,
                "glyphID": "gloamthorn-glyph-12",
                "textToken": "ᚬ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 13,
                "glyphID": "gloamthorn-glyph-13",
                "textToken": "ᚭ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 14,
                "glyphID": "gloamthorn-glyph-14",
                "textToken": "ᚮ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 15,
                "glyphID": "gloamthorn-glyph-15",
                "textToken": "ᚯ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 16,
                "glyphID": "gloamthorn-glyph-16",
                "textToken": "ᚰ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 17,
                "glyphID": "gloamthorn-glyph-17",
                "textToken": "ᚱ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 18,
                "glyphID": "gloamthorn-glyph-18",
                "textToken": "ᚲ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 19,
                "glyphID": "gloamthorn-glyph-19",
                "textToken": "ᚳ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 20,
                "glyphID": "gloamthorn-glyph-20",
                "textToken": "ᚴ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 21,
                "glyphID": "gloamthorn-glyph-21",
                "textToken": "ᚵ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 22,
                "glyphID": "gloamthorn-glyph-22",
                "textToken": "ᚶ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 23,
                "glyphID": "gloamthorn-glyph-23",
                "textToken": "ᚷ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 24,
                "glyphID": "gloamthorn-glyph-24",
                "textToken": "ᚸ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 25,
                "glyphID": "gloamthorn-glyph-25",
                "textToken": "ᚹ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 26,
                "glyphID": "gloamthorn-glyph-26",
                "textToken": "ᚺ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 27,
                "glyphID": "gloamthorn-glyph-27",
                "textToken": "ᚻ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 28,
                "glyphID": "gloamthorn-glyph-28",
                "textToken": "ᚼ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 29,
                "glyphID": "gloamthorn-glyph-29",
                "textToken": "ᚽ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 30,
                "glyphID": "gloamthorn-glyph-30",
                "textToken": "ᚾ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 31,
                "glyphID": "gloamthorn-glyph-31",
                "textToken": "ᚿ",
                "vectorResourceID": null
              }
            ],
            "fontResourceID": "resource.script.gloamthorn.output.script-font",
            "fontReferenceID": "rs-gloamthorn",
            "fontVersion": 1,
            "fontPostScriptName": "RavenForgeGloamthornScript-Regular",
            "staticFallbackResourceID": "resource.script.gloamthorn.output.script-static-fallback",
            "fallbackScriptID": "script.base-runes",
            "recommendedPointSizes": {
              "minimum": 12.0,
              "maximum": 64.0
            },
            "accessibility": {
              "label": {
                "key": "resource.script.gloamthorn.accessibility.label",
                "fallbackValue": "Gloamthorn Codex script with complete static renderer fallback."
              },
              "hint": null,
              "hidesRedundantGlyphs": true,
              "noColorOnlyState": true,
              "dynamicTypeSafe": true
            },
            "rightsID": "prov.Source.Masters.Glyphs.gloamthorn.glyph.master.json"
          }
        ],
        "relics": [
          {
            "metadata": {
              "id": "relic.gloamthorn.nightthorn-tablet",
              "codexID": "codex.gloamthorn",
              "displayName": {
                "key": "relic.gloamthorn.nightthorn-tablet.name",
                "fallbackValue": "Nightthorn Tablet"
              },
              "description": {
                "key": "relic.gloamthorn.nightthorn-tablet.description",
                "fallbackValue": "A dark but highly legible default Relic that presents Gloamthorn as luxurious and ceremonial."
              },
              "facets": [
                {
                  "key": "relic.gloamthorn.nightthorn-tablet.facet.shadowbound",
                  "fallbackValue": "Shadowbound"
                },
                {
                  "key": "relic.gloamthorn.nightthorn-tablet.facet.thornscript",
                  "fallbackValue": "Thornscript"
                }
              ],
              "rarity": "forged",
              "availability": "included",
              "accessibility": {
                "label": {
                  "key": "resource.relic.gloamthorn.nightthorn-tablet.accessibility.label",
                  "fallbackValue": "A wide charcoal tablet framed in silver thorns, with a purple crescent crest and pale violet inscription."
                },
                "hint": null,
                "hidesRedundantGlyphs": true,
                "noColorOnlyState": true,
                "dynamicTypeSafe": true
              },
              "rightsID": "prov.Source.Masters.Relic.Geometry.gloamthorn.nightthorn.tablet.geometry.svg"
            },
            "isDefault": true,
            "primaryResourceID": "resource.relic.gloamthorn.nightthorn-tablet.output.relic-master",
            "thumbnailResourceID": "resource.relic.gloamthorn.nightthorn-tablet.output.relic-thumbnail",
            "staticFallbackResourceID": "resource.relic.gloamthorn.nightthorn-tablet.output.relic-static-share-fallback",
            "highContrastResourceID": "resource.relic.gloamthorn.nightthorn-tablet.output.relic-high-contrast",
            "defaultLayoutID": "layout-profile.relic.gloamthorn.nightthorn-tablet",
            "layouts": [
              {
                "id": "layout-profile.relic.gloamthorn.nightthorn-tablet",
                "aspectRatio": {
                  "width": 1600,
                  "height": 1200
                },
                "relicBounds": {
                  "x": 0.0,
                  "y": 0.0,
                  "width": 1.0,
                  "height": 1.0
                },
                "contentSafeRegion": {
                  "x": 0.14,
                  "y": 0.22,
                  "width": 0.7200000000000001,
                  "height": 0.45999999999999996
                },
                "glyphSafeRegion": {
                  "x": 0.16,
                  "y": 0.24,
                  "width": 0.68,
                  "height": 0.42
                },
                "sealAnchors": [
                  {
                    "category": "lowerRight",
                    "point": {
                      "x": 0.82,
                      "y": 0.75
                    }
                  },
                  {
                    "category": "lowerLeft",
                    "point": {
                      "x": 0.18,
                      "y": 0.75
                    }
                  }
                ],
                "maximumGlyphLines": 5,
                "catalogSpecimenRows": 3,
                "catalogSpecimenColumns": 9,
                "minimumGlyphScale": 0.72,
                "overflowBehavior": "standardAlternate",
                "attributionRegion": {
                  "x": 0.04,
                  "y": 0.94,
                  "width": 0.28,
                  "height": 0.04
                },
                "provenanceRegion": {
                  "x": 0.68,
                  "y": 0.94,
                  "width": 0.28,
                  "height": 0.04
                },
                "serialNumberRegion": null,
                "qrSafeRegion": null,
                "thumbnailCrop": {
                  "x": 0.125,
                  "y": 0.0,
                  "width": 0.75,
                  "height": 1.0
                }
              }
            ]
          },
          {
            "metadata": {
              "id": "relic.gloamthorn.umbral-plaque",
              "codexID": "codex.gloamthorn",
              "displayName": {
                "key": "relic.gloamthorn.umbral-plaque.name",
                "fallbackValue": "Umbral Plaque"
              },
              "description": {
                "key": "relic.gloamthorn.umbral-plaque.description",
                "fallbackValue": "A compact dark-court plaque with dense material detail and clear short-message presentation."
              },
              "facets": [
                {
                  "key": "relic.gloamthorn.umbral-plaque.facet.shadowleaf",
                  "fallbackValue": "Shadowleaf"
                },
                {
                  "key": "relic.gloamthorn.umbral-plaque.facet.twilightforged",
                  "fallbackValue": "Twilightforged"
                }
              ],
              "rarity": "inscribed",
              "availability": "earned",
              "accessibility": {
                "label": {
                  "key": "resource.relic.gloamthorn.umbral-plaque.accessibility.label",
                  "fallbackValue": "A compact dark metal plaque with silver corners and a shadowleaf medallion."
                },
                "hint": null,
                "hidesRedundantGlyphs": true,
                "noColorOnlyState": true,
                "dynamicTypeSafe": true
              },
              "rightsID": "prov.Source.Masters.Relic.Geometry.gloamthorn.umbral.plaque.geometry.svg"
            },
            "isDefault": false,
            "primaryResourceID": "resource.relic.gloamthorn.umbral-plaque.output.relic-master",
            "thumbnailResourceID": "resource.relic.gloamthorn.umbral-plaque.output.relic-thumbnail",
            "staticFallbackResourceID": "resource.relic.gloamthorn.umbral-plaque.output.relic-static-share-fallback",
            "highContrastResourceID": "resource.relic.gloamthorn.umbral-plaque.output.relic-high-contrast",
            "defaultLayoutID": "layout-profile.relic.gloamthorn.umbral-plaque",
            "layouts": [
              {
                "id": "layout-profile.relic.gloamthorn.umbral-plaque",
                "aspectRatio": {
                  "width": 1600,
                  "height": 1200
                },
                "relicBounds": {
                  "x": 0.0,
                  "y": 0.0,
                  "width": 1.0,
                  "height": 1.0
                },
                "contentSafeRegion": {
                  "x": 0.16,
                  "y": 0.21000000000000002,
                  "width": 0.68,
                  "height": 0.52
                },
                "glyphSafeRegion": {
                  "x": 0.18,
                  "y": 0.23,
                  "width": 0.64,
                  "height": 0.48
                },
                "sealAnchors": [
                  {
                    "category": "lowerRight",
                    "point": {
                      "x": 0.813125,
                      "y": 0.785833
                    }
                  },
                  {
                    "category": "lowerLeft",
                    "point": {
                      "x": 0.186875,
                      "y": 0.785833
                    }
                  }
                ],
                "maximumGlyphLines": 4,
                "minimumGlyphScale": 0.72,
                "overflowBehavior": "standardAlternate",
                "attributionRegion": {
                  "x": 0.04,
                  "y": 0.94,
                  "width": 0.28,
                  "height": 0.04
                },
                "provenanceRegion": {
                  "x": 0.68,
                  "y": 0.94,
                  "width": 0.28,
                  "height": 0.04
                },
                "serialNumberRegion": null,
                "qrSafeRegion": null,
                "thumbnailCrop": {
                  "x": 0.125,
                  "y": 0.0,
                  "width": 0.75,
                  "height": 1.0
                }
              }
            ]
          },
          {
            "metadata": {
              "id": "relic.gloamthorn.duskbriar-stele",
              "codexID": "codex.gloamthorn",
              "displayName": {
                "key": "relic.gloamthorn.duskbriar-stele.name",
                "fallbackValue": "Duskbriar Stele"
              },
              "description": {
                "key": "relic.gloamthorn.duskbriar-stele.description",
                "fallbackValue": "A prestige Relic for formal long inscriptions, designed to feel aristocratic rather than hostile."
              },
              "facets": [
                {
                  "key": "relic.gloamthorn.duskbriar-stele.facet.aristocratic",
                  "fallbackValue": "Aristocratic"
                },
                {
                  "key": "relic.gloamthorn.duskbriar-stele.facet.pactbound",
                  "fallbackValue": "Pactbound"
                }
              ],
              "rarity": "rare",
              "availability": "earned",
              "accessibility": {
                "label": {
                  "key": "resource.relic.gloamthorn.duskbriar-stele.accessibility.label",
                  "fallbackValue": "A tall black stone stele rising through silver briars with a small purple gem at its center."
                },
                "hint": null,
                "hidesRedundantGlyphs": true,
                "noColorOnlyState": true,
                "dynamicTypeSafe": true
              },
              "rightsID": "prov.Source.Masters.Relic.Geometry.gloamthorn.duskbriar.stele.geometry.svg"
            },
            "isDefault": false,
            "primaryResourceID": "resource.relic.gloamthorn.duskbriar-stele.output.relic-master",
            "thumbnailResourceID": "resource.relic.gloamthorn.duskbriar-stele.output.relic-thumbnail",
            "staticFallbackResourceID": "resource.relic.gloamthorn.duskbriar-stele.output.relic-static-share-fallback",
            "highContrastResourceID": "resource.relic.gloamthorn.duskbriar-stele.output.relic-high-contrast",
            "defaultLayoutID": "layout-profile.relic.gloamthorn.duskbriar-stele",
            "layouts": [
              {
                "id": "layout-profile.relic.gloamthorn.duskbriar-stele",
                "aspectRatio": {
                  "width": 1200,
                  "height": 1600
                },
                "relicBounds": {
                  "x": 0.0,
                  "y": 0.0,
                  "width": 1.0,
                  "height": 1.0
                },
                "contentSafeRegion": {
                  "x": 0.26,
                  "y": 0.18000000000000002,
                  "width": 0.48,
                  "height": 0.6000000000000001
                },
                "glyphSafeRegion": {
                  "x": 0.28,
                  "y": 0.2,
                  "width": 0.44,
                  "height": 0.56
                },
                "sealAnchors": [
                  {
                    "category": "bottomCenter",
                    "point": {
                      "x": 0.5,
                      "y": 0.82
                    }
                  }
                ],
                "maximumGlyphLines": 7,
                "minimumGlyphScale": 0.72,
                "overflowBehavior": "standardAlternate",
                "attributionRegion": {
                  "x": 0.04,
                  "y": 0.94,
                  "width": 0.28,
                  "height": 0.04
                },
                "provenanceRegion": {
                  "x": 0.68,
                  "y": 0.94,
                  "width": 0.28,
                  "height": 0.04
                },
                "serialNumberRegion": null,
                "qrSafeRegion": null,
                "thumbnailCrop": {
                  "x": 0.0,
                  "y": 0.125,
                  "width": 1.0,
                  "height": 0.75
                }
              }
            ]
          }
        ],
        "seals": [
          {
            "metadata": {
              "id": "seal.gloamthorn.thornmoon",
              "codexID": "codex.gloamthorn",
              "displayName": {
                "key": "seal.gloamthorn.thornmoon.name",
                "fallbackValue": "Thornmoon"
              },
              "description": {
                "key": "seal.gloamthorn.thornmoon.description",
                "fallbackValue": "The central Gloamthorn mark of beauty protected by restraint and consequence."
              },
              "rarity": "forged",
              "availability": "included",
              "accessibility": {
                "label": {
                  "key": "resource.seal.gloamthorn.thornmoon.accessibility.label",
                  "fallbackValue": "A silver crescent moon inside a circular thorn wreath."
                },
                "hint": null,
                "hidesRedundantGlyphs": true,
                "noColorOnlyState": true,
                "dynamicTypeSafe": true
              },
              "rightsID": "prov.Source.Masters.Seals.gloamthorn.thornmoon.svg"
            },
            "vectorResourceID": "resource.seal.gloamthorn.thornmoon.output.seal-vector-master",
            "colorResourceID": "resource.seal.gloamthorn.thornmoon.output.seal-color-master",
            "monochromeFallbackResourceID": "resource.seal.gloamthorn.thornmoon.output.seal-monochrome-fallback",
            "thumbnailResourceID": "resource.seal.gloamthorn.thornmoon.output.seal-thumbnail",
            "allowedScale": {
              "minimum": 0.12,
              "maximum": 0.24
            },
            "scaleReference": "relicShortEdge",
            "allowedAnchors": [
              "lowerLeft",
              "lowerRight",
              "bottomCenter"
            ]
          },
          {
            "metadata": {
              "id": "seal.gloamthorn.nightglass-moth",
              "codexID": "codex.gloamthorn",
              "displayName": {
                "key": "seal.gloamthorn.nightglass-moth.name",
                "fallbackValue": "Nightglass Moth"
              },
              "description": {
                "key": "seal.gloamthorn.nightglass-moth.description",
                "fallbackValue": "An elegant nocturnal emblem suited to Gloamthorn’s refined darkness."
              },
              "rarity": "forged",
              "availability": "included",
              "accessibility": {
                "label": {
                  "key": "resource.seal.gloamthorn.nightglass-moth.accessibility.label",
                  "fallbackValue": "A dark moth with translucent violet wings."
                },
                "hint": null,
                "hidesRedundantGlyphs": true,
                "noColorOnlyState": true,
                "dynamicTypeSafe": true
              },
              "rightsID": "prov.Source.Masters.Seals.gloamthorn.nightglass.moth.svg"
            },
            "vectorResourceID": "resource.seal.gloamthorn.nightglass-moth.output.seal-vector-master",
            "colorResourceID": "resource.seal.gloamthorn.nightglass-moth.output.seal-color-master",
            "monochromeFallbackResourceID": "resource.seal.gloamthorn.nightglass-moth.output.seal-monochrome-fallback",
            "thumbnailResourceID": "resource.seal.gloamthorn.nightglass-moth.output.seal-thumbnail",
            "allowedScale": {
              "minimum": 0.12,
              "maximum": 0.24
            },
            "scaleReference": "relicShortEdge",
            "allowedAnchors": [
              "lowerLeft",
              "lowerRight",
              "bottomCenter"
            ]
          },
          {
            "metadata": {
              "id": "seal.gloamthorn.eclipse-bloom",
              "codexID": "codex.gloamthorn",
              "displayName": {
                "key": "seal.gloamthorn.eclipse-bloom.name",
                "fallbackValue": "Eclipse Bloom"
              },
              "description": {
                "key": "seal.gloamthorn.eclipse-bloom.description",
                "fallbackValue": "A first-dispatch mark representing a message revealed from shadow."
              },
              "rarity": "inscribed",
              "availability": "earned",
              "accessibility": {
                "label": {
                  "key": "resource.seal.gloamthorn.eclipse-bloom.accessibility.label",
                  "fallbackValue": "A six-petal dark flower surrounding a thin eclipse ring."
                },
                "hint": null,
                "hidesRedundantGlyphs": true,
                "noColorOnlyState": true,
                "dynamicTypeSafe": true
              },
              "rightsID": "prov.Source.Masters.Seals.gloamthorn.eclipse.bloom.svg"
            },
            "vectorResourceID": "resource.seal.gloamthorn.eclipse-bloom.output.seal-vector-master",
            "colorResourceID": "resource.seal.gloamthorn.eclipse-bloom.output.seal-color-master",
            "monochromeFallbackResourceID": "resource.seal.gloamthorn.eclipse-bloom.output.seal-monochrome-fallback",
            "thumbnailResourceID": "resource.seal.gloamthorn.eclipse-bloom.output.seal-thumbnail",
            "allowedScale": {
              "minimum": 0.12,
              "maximum": 0.24
            },
            "scaleReference": "relicShortEdge",
            "allowedAnchors": [
              "lowerLeft",
              "lowerRight",
              "bottomCenter"
            ]
          },
          {
            "metadata": {
              "id": "seal.gloamthorn.veiled-serpent",
              "codexID": "codex.gloamthorn",
              "displayName": {
                "key": "seal.gloamthorn.veiled-serpent.name",
                "fallbackValue": "Veiled Serpent"
              },
              "description": {
                "key": "seal.gloamthorn.veiled-serpent.description",
                "fallbackValue": "A receiving mark for knowledge returned carefully and deliberately."
              },
              "rarity": "inscribed",
              "availability": "earned",
              "accessibility": {
                "label": {
                  "key": "resource.seal.gloamthorn.veiled-serpent.accessibility.label",
                  "fallbackValue": "A slender serpent curled around a single leaf."
                },
                "hint": null,
                "hidesRedundantGlyphs": true,
                "noColorOnlyState": true,
                "dynamicTypeSafe": true
              },
              "rightsID": "prov.Source.Masters.Seals.gloamthorn.veiled.serpent.svg"
            },
            "vectorResourceID": "resource.seal.gloamthorn.veiled-serpent.output.seal-vector-master",
            "colorResourceID": "resource.seal.gloamthorn.veiled-serpent.output.seal-color-master",
            "monochromeFallbackResourceID": "resource.seal.gloamthorn.veiled-serpent.output.seal-monochrome-fallback",
            "thumbnailResourceID": "resource.seal.gloamthorn.veiled-serpent.output.seal-thumbnail",
            "allowedScale": {
              "minimum": 0.12,
              "maximum": 0.24
            },
            "scaleReference": "relicShortEdge",
            "allowedAnchors": [
              "lowerLeft",
              "lowerRight",
              "bottomCenter"
            ]
          },
          {
            "metadata": {
              "id": "seal.gloamthorn.pact-crown",
              "codexID": "codex.gloamthorn",
              "displayName": {
                "key": "seal.gloamthorn.pact-crown.name",
                "fallbackValue": "Pact Crown"
              },
              "description": {
                "key": "seal.gloamthorn.pact-crown.description",
                "fallbackValue": "A dark-court prestige mark earned through sustained correspondence."
              },
              "rarity": "rare",
              "availability": "earned",
              "accessibility": {
                "label": {
                  "key": "resource.seal.gloamthorn.pact-crown.accessibility.label",
                  "fallbackValue": "A narrow crown made from three silver thorns above a purple gem."
                },
                "hint": null,
                "hidesRedundantGlyphs": true,
                "noColorOnlyState": true,
                "dynamicTypeSafe": true
              },
              "rightsID": "prov.Source.Masters.Seals.gloamthorn.pact.crown.svg"
            },
            "vectorResourceID": "resource.seal.gloamthorn.pact-crown.output.seal-vector-master",
            "colorResourceID": "resource.seal.gloamthorn.pact-crown.output.seal-color-master",
            "monochromeFallbackResourceID": "resource.seal.gloamthorn.pact-crown.output.seal-monochrome-fallback",
            "thumbnailResourceID": "resource.seal.gloamthorn.pact-crown.output.seal-thumbnail",
            "allowedScale": {
              "minimum": 0.12,
              "maximum": 0.24
            },
            "scaleReference": "relicShortEdge",
            "allowedAnchors": [
              "lowerLeft",
              "lowerRight",
              "bottomCenter"
            ]
          },
          {
            "metadata": {
              "id": "seal.gloamthorn.echo-wisp",
              "codexID": "codex.gloamthorn",
              "displayName": {
                "key": "seal.gloamthorn.echo-wisp.name",
                "fallbackValue": "Echo Wisp"
              },
              "description": {
                "key": "seal.gloamthorn.echo-wisp.description",
                "fallbackValue": "An encounter mark showing Gloamthorn discovered through another Scribe."
              },
              "rarity": "rare",
              "availability": "encountered",
              "accessibility": {
                "label": {
                  "key": "resource.seal.gloamthorn.echo-wisp.accessibility.label",
                  "fallbackValue": "A small violet wisp inside a broken silver ring."
                },
                "hint": null,
                "hidesRedundantGlyphs": true,
                "noColorOnlyState": true,
                "dynamicTypeSafe": true
              },
              "rightsID": "prov.Source.Masters.Seals.gloamthorn.echo.wisp.svg"
            },
            "vectorResourceID": "resource.seal.gloamthorn.echo-wisp.output.seal-vector-master",
            "colorResourceID": "resource.seal.gloamthorn.echo-wisp.output.seal-color-master",
            "monochromeFallbackResourceID": "resource.seal.gloamthorn.echo-wisp.output.seal-monochrome-fallback",
            "thumbnailResourceID": "resource.seal.gloamthorn.echo-wisp.output.seal-thumbnail",
            "allowedScale": {
              "minimum": 0.12,
              "maximum": 0.24
            },
            "scaleReference": "relicShortEdge",
            "allowedAnchors": [
              "lowerLeft",
              "lowerRight",
              "bottomCenter"
            ]
          }
        ],
        "frames": [
          {
            "metadata": {
              "id": "frame.gloamthorn.briar-court",
              "codexID": "codex.gloamthorn",
              "displayName": {
                "key": "frame.gloamthorn.briar-court.name",
                "fallbackValue": "Briar Court Frame"
              },
              "description": {
                "key": "frame.gloamthorn.briar-court.description",
                "fallbackValue": "Thin silver briars, four amethyst nodes, inward-facing thorns kept outside all content safe regions."
              },
              "rarity": "mythic",
              "availability": "mastery",
              "accessibility": {
                "label": {
                  "key": "resource.frame.gloamthorn.briar-court.accessibility.label",
                  "fallbackValue": "Thin silver briars, four amethyst nodes, inward-facing thorns kept outside all content safe regions."
                },
                "hint": null,
                "hidesRedundantGlyphs": true,
                "noColorOnlyState": true,
                "dynamicTypeSafe": true
              },
              "rightsID": "prov.Source.Masters.Frames.gloamthorn.briar.court.svg"
            },
            "vectorResourceID": "resource.frame.gloamthorn.briar-court.output.frame-vector-master",
            "staticFallbackResourceID": "resource.frame.gloamthorn.briar-court.output.frame-static-fallback",
            "compatibleRelicIDs": [
              "relic.gloamthorn.nightthorn-tablet",
              "relic.gloamthorn.umbral-plaque",
              "relic.gloamthorn.duskbriar-stele"
            ],
            "allowsStaticShare": true
          }
        ],
        "crests": [
          {
            "metadata": {
              "id": "crest.gloamthorn.gloam-sovereign",
              "codexID": "codex.gloamthorn",
              "displayName": {
                "key": "crest.gloamthorn.gloam-sovereign.name",
                "fallbackValue": "Gloam Sovereign Crest"
              },
              "description": {
                "key": "crest.gloamthorn.gloam-sovereign.description",
                "fallbackValue": "A narrow thorn crown over an eclipse ring and one central amethyst point."
              },
              "rarity": "mythic",
              "availability": "mastery",
              "accessibility": {
                "label": {
                  "key": "resource.crest.gloamthorn.gloam-sovereign.accessibility.label",
                  "fallbackValue": "A narrow thorn crown over an eclipse ring and one central amethyst point."
                },
                "hint": null,
                "hidesRedundantGlyphs": true,
                "noColorOnlyState": true,
                "dynamicTypeSafe": true
              },
              "rightsID": "prov.Source.Masters.Crests.gloamthorn.gloam.sovereign.svg"
            },
            "vectorResourceID": "resource.crest.gloamthorn.gloam-sovereign.output.crest-vector-master",
            "staticFallbackResourceID": "resource.crest.gloamthorn.gloam-sovereign.output.crest-static-fallback"
          }
        ],
        "background": {
          "id": "background.gloamthorn.twilight-briar",
          "displayName": {
            "key": "background.gloamthorn.twilight-briar.name",
            "fallbackValue": "Twilight Briar"
          },
          "staticBaseResourceID": "resource.background.gloamthorn.twilight-briar.output.background-static-base",
          "reduceMotionResourceID": "resource.background.gloamthorn.twilight-briar.output.background-reduce-motion",
          "highContrastResourceID": "resource.background.gloamthorn.twilight-briar.output.background-high-contrast",
          "optionalMotionResourceID": null,
          "rendererParametersResourceID": null,
          "motionIntensity": "none",
          "performanceClass": "standard",
          "parallaxAllowed": false,
          "accessibility": {
            "label": {
              "key": "resource.background.gloamthorn.twilight-briar.accessibility.label",
              "fallbackValue": "Deep night forest, silver thorn silhouettes, sparse amethyst glints, and a distant eclipse-like halo."
            },
            "hint": null,
            "hidesRedundantGlyphs": true,
            "noColorOnlyState": true,
            "dynamicTypeSafe": true
          },
          "rightsID": "prov.Production.Sources.gloamthorn.gloamthorn.background.recipe.json"
        },
        "vault": {
          "id": "card.gloamthorn.codex",
          "grouping": {
            "key": "vault.gloamthorn.grouping",
            "fallbackValue": "Elven Series"
          },
          "cardResourceID": "resource.vault.gloamthorn.codex.output.vault-card",
          "lockedSilhouetteResourceID": "resource.vault.gloamthorn.codex.output.vault-locked-silhouette",
          "encounteredResourceID": "resource.vault.gloamthorn.codex.output.vault-encountered",
          "selectedResourceID": "resource.vault.gloamthorn.codex.output.vault-selected",
          "accessibility": {
            "label": {
              "key": "resource.vault.gloamthorn.codex.accessibility.label",
              "fallbackValue": "Gloamthorn Codex locked, encountered, owned, and selected presentation."
            },
            "hint": null,
            "hidesRedundantGlyphs": true,
            "noColorOnlyState": true,
            "dynamicTypeSafe": true
          },
          "rightsID": "prov.Production.Sources.gloamthorn.gloamthorn.vault.recipe.json"
        },
        "rightsID": "prov.Production.Sources.gloamthorn.gloamthorn.background.recipe.json"
      },
      "resources": [],
      "localizations": [
        {
          "localeIdentifier": "en-US",
          "stringsResourceID": "resource.localization.gloamthorn.control"
        }
      ],
      "defaultLocaleIdentifier": "en-US",
      "rights": [
        {
          "id": "prov.Source.Masters.Glyphs.gloamthorn.glyph.master.json",
          "creatorTool": "macOS byte-preserving canonicalization with Python 3.9.6 hashing",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "/Users/jimdaley/Documents/RavenForge/RuneScribe/Rune-Scribe-Elven-Series-Design-Package-v1.0/Source-Masters/Glyphs/gloamthorn/glyph-master.json",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        },
        {
          "id": "prov.Production.Sources.gloamthorn.gloamthorn.background.recipe.json",
          "creatorTool": "Python 3.9.6 with Pillow 11.3.0 and fontTools 4.60.2",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "owner-approved production design and manifest direction",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        },
        {
          "id": "prov.Production.Sources.gloamthorn.accepted.source.masters.recipe.json",
          "creatorTool": "Pinned deterministic v4.3 asset builder",
          "creationDate": "2026-08-27",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "docs/verification/theme-fidelity-v4-3/inventory/recipes/Gloamthorn-Accepted-Source-Master-Recipe-v4.3.json",
          "exportSettings": "{\"deterministic\":true,\"ownerReview\":\"PENDING\",\"pipeline\":\"scripts/build-sunspire-wildwood-gloamthorn-v43-assets.py\"}",
          "licenseNotice": "Project-local proprietary production masters; owner visual review remains pending"
        },
        {
          "id": "prov.Production.Sources.gloamthorn.gloamthorn.vault.recipe.json",
          "creatorTool": "Python 3.9.6 with Pillow 11.3.0 and fontTools 4.60.2",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "owner-approved production design and manifest direction",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        },
        {
          "id": "prov.Source.Masters.Frames.gloamthorn.briar.court.svg",
          "creatorTool": "Python 3.9.6 with Pillow 11.3.0 and fontTools 4.60.2",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "/Users/jimdaley/Documents/RavenForge/RuneScribe/Rune-Scribe-Elven-Series-Design-Package-v1.0/Source-Masters/Frames/gloamthorn/briar-court.svg",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        },
        {
          "id": "prov.Source.Masters.Crests.gloamthorn.gloam.sovereign.svg",
          "creatorTool": "Python 3.9.6 with Pillow 11.3.0 and fontTools 4.60.2",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "/Users/jimdaley/Documents/RavenForge/RuneScribe/Rune-Scribe-Elven-Series-Design-Package-v1.0/Source-Masters/Crests/gloamthorn/gloam-sovereign.svg",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        },
        {
          "id": "prov.Source.Masters.Relic.Geometry.gloamthorn.nightthorn.tablet.geometry.svg",
          "creatorTool": "macOS byte-preserving canonicalization with Python 3.9.6 hashing",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "/Users/jimdaley/Documents/RavenForge/RuneScribe/Rune-Scribe-Elven-Series-Design-Package-v1.0/Source-Masters/Relic-Geometry/gloamthorn/nightthorn-tablet-geometry.svg",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        },
        {
          "id": "prov.Source.Masters.Relic.Geometry.gloamthorn.umbral.plaque.geometry.svg",
          "creatorTool": "Python 3.9.6 with Pillow 11.3.0 and fontTools 4.60.2",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "/Users/jimdaley/Documents/RavenForge/RuneScribe/Rune-Scribe-Elven-Series-Design-Package-v1.0/Source-Masters/Relic-Geometry/gloamthorn/umbral-plaque-geometry.svg",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        },
        {
          "id": "prov.Source.Masters.Relic.Geometry.gloamthorn.duskbriar.stele.geometry.svg",
          "creatorTool": "macOS byte-preserving canonicalization with Python 3.9.6 hashing",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "/Users/jimdaley/Documents/RavenForge/RuneScribe/Rune-Scribe-Elven-Series-Design-Package-v1.0/Source-Masters/Relic-Geometry/gloamthorn/duskbriar-stele-geometry.svg",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        },
        {
          "id": "prov.Source.Masters.Seals.gloamthorn.thornmoon.svg",
          "creatorTool": "macOS byte-preserving canonicalization with Python 3.9.6 hashing",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "/Users/jimdaley/Documents/RavenForge/RuneScribe/Rune-Scribe-Elven-Series-Design-Package-v1.0/Source-Masters/Seals/gloamthorn/thornmoon.svg",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        },
        {
          "id": "prov.Source.Masters.Seals.gloamthorn.nightglass.moth.svg",
          "creatorTool": "macOS byte-preserving canonicalization with Python 3.9.6 hashing",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "/Users/jimdaley/Documents/RavenForge/RuneScribe/Rune-Scribe-Elven-Series-Design-Package-v1.0/Source-Masters/Seals/gloamthorn/nightglass-moth.svg",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        },
        {
          "id": "prov.Source.Masters.Seals.gloamthorn.eclipse.bloom.svg",
          "creatorTool": "macOS byte-preserving canonicalization with Python 3.9.6 hashing",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "/Users/jimdaley/Documents/RavenForge/RuneScribe/Rune-Scribe-Elven-Series-Design-Package-v1.0/Source-Masters/Seals/gloamthorn/eclipse-bloom.svg",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        },
        {
          "id": "prov.Source.Masters.Seals.gloamthorn.veiled.serpent.svg",
          "creatorTool": "macOS byte-preserving canonicalization with Python 3.9.6 hashing",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "/Users/jimdaley/Documents/RavenForge/RuneScribe/Rune-Scribe-Elven-Series-Design-Package-v1.0/Source-Masters/Seals/gloamthorn/veiled-serpent.svg",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        },
        {
          "id": "prov.Source.Masters.Seals.gloamthorn.pact.crown.svg",
          "creatorTool": "macOS byte-preserving canonicalization with Python 3.9.6 hashing",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "/Users/jimdaley/Documents/RavenForge/RuneScribe/Rune-Scribe-Elven-Series-Design-Package-v1.0/Source-Masters/Seals/gloamthorn/pact-crown.svg",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        },
        {
          "id": "prov.Source.Masters.Seals.gloamthorn.echo.wisp.svg",
          "creatorTool": "macOS byte-preserving canonicalization with Python 3.9.6 hashing",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "/Users/jimdaley/Documents/RavenForge/RuneScribe/Rune-Scribe-Elven-Series-Design-Package-v1.0/Source-Masters/Seals/gloamthorn/echo-wisp.svg",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        }
      ]
    }
    """#
}

private enum GloamthornThemeDescriptorError: Error {
    case invalidSeed
}

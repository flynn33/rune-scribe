import Foundation
import RuneScribeContracts

public enum MoonleafThemeDescriptorFactory {
    public static let discoveryDescriptor: ThemeDescriptor = {
        do { return try make() }
        catch { preconditionFailure("Invalid frozen Moonleaf Theme descriptor: \(error)") }
    }()

    public static func make() throws -> ThemeDescriptor {
        guard var root = try JSONSerialization.jsonObject(
            with: Data(seedJSON.utf8)
        ) as? [String: Any],
        let resources = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(try MoonleafThemeResourceCatalog.references())
        ) as? [[String: Any]]
        else {
            throw MoonleafThemeDescriptorError.invalidSeed
        }
        root["resources"] = resources
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        return try JSONDecoder().decode(ThemeDescriptor.self, from: data)
    }

    private static let seedJSON = #"""
    {
      "id": "theme.moonleaf.production",
      "moduleID": "com.runescribe.module.theme.moonleaf",
      "moduleRole": "runescribe.theme.moonleaf",
      "policyClass": "policy.theme-provider",
      "criticality": "optional",
      "schemaVersion": {
        "major": 1,
        "minor": 0
      },
      "contentVersion": 2,
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
        "id": "codex.moonleaf",
        "entitlementID": "unlock.codex.moonleaf",
        "displayName": {
          "key": "codex.moonleaf.name",
          "fallbackValue": "Moonleaf Codex"
        },
        "shortDescription": {
          "key": "codex.moonleaf.tagline",
          "fallbackValue": "Moonlit inscriptions shaped in silver vine and pale stone."
        },
        "longDescription": {
          "key": "codex.moonleaf.description",
          "fallbackValue": "A serene Elven Codex of moonstone, silverwood, and living vinework. Its script carries the quiet cadence of leaves beneath a night sky."
        },
        "accessibility": {
          "label": {
            "key": "codex.moonleaf.label",
            "fallbackValue": "Moonleaf Codex"
          },
          "hint": {
            "key": "codex.moonleaf.hint",
            "fallbackValue": "An optional Codex that remains unavailable until earned."
          },
          "hidesRedundantGlyphs": false,
          "noColorOnlyState": true,
          "dynamicTypeSafe": true
        },
        "palette": {
          "backgroundPrimary": "#071A18",
          "backgroundSecondary": "#0D2925",
          "surfacePrimary": "#102B28",
          "surfaceElevated": "#173C36",
          "textPrimary": "#F4EEE4",
          "textSecondary": "#A9C1B8",
          "textInverse": "#102B28",
          "accentPrimary": "#7FD3B0",
          "accentSecondary": "#C8D6D0",
          "success": "#68E09B",
          "warning": "#FFD166",
          "danger": "#FF8A8A",
          "information": "#8FD8FF",
          "locked": "#756E64",
          "encountered": "#8BA99E",
          "unavailable": "#5E6865",
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
        "primaryScriptID": "script.moonleaf",
        "fallbackScriptID": "script.base-runes",
        "defaultRelicID": "relic.moonleaf.tablet",
        "scripts": [
          {
            "id": "script.moonleaf",
            "displayName": {
              "key": "script.moonleaf.name",
              "fallbackValue": "Moonleaf Script"
            },
            "portability": "fontDependent",
            "glyphs": [
              {
                "canonicalValue": 0,
                "glyphID": "moonleaf-glyph-00",
                "textToken": "ᚠ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 1,
                "glyphID": "moonleaf-glyph-01",
                "textToken": "ᚡ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 2,
                "glyphID": "moonleaf-glyph-02",
                "textToken": "ᚢ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 3,
                "glyphID": "moonleaf-glyph-03",
                "textToken": "ᚣ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 4,
                "glyphID": "moonleaf-glyph-04",
                "textToken": "ᚤ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 5,
                "glyphID": "moonleaf-glyph-05",
                "textToken": "ᚥ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 6,
                "glyphID": "moonleaf-glyph-06",
                "textToken": "ᚦ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 7,
                "glyphID": "moonleaf-glyph-07",
                "textToken": "ᚧ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 8,
                "glyphID": "moonleaf-glyph-08",
                "textToken": "ᚨ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 9,
                "glyphID": "moonleaf-glyph-09",
                "textToken": "ᚩ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 10,
                "glyphID": "moonleaf-glyph-10",
                "textToken": "ᚪ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 11,
                "glyphID": "moonleaf-glyph-11",
                "textToken": "ᚫ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 12,
                "glyphID": "moonleaf-glyph-12",
                "textToken": "ᚬ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 13,
                "glyphID": "moonleaf-glyph-13",
                "textToken": "ᚭ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 14,
                "glyphID": "moonleaf-glyph-14",
                "textToken": "ᚮ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 15,
                "glyphID": "moonleaf-glyph-15",
                "textToken": "ᚯ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 16,
                "glyphID": "moonleaf-glyph-16",
                "textToken": "ᚰ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 17,
                "glyphID": "moonleaf-glyph-17",
                "textToken": "ᚱ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 18,
                "glyphID": "moonleaf-glyph-18",
                "textToken": "ᚲ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 19,
                "glyphID": "moonleaf-glyph-19",
                "textToken": "ᚳ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 20,
                "glyphID": "moonleaf-glyph-20",
                "textToken": "ᚴ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 21,
                "glyphID": "moonleaf-glyph-21",
                "textToken": "ᚵ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 22,
                "glyphID": "moonleaf-glyph-22",
                "textToken": "ᚶ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 23,
                "glyphID": "moonleaf-glyph-23",
                "textToken": "ᚷ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 24,
                "glyphID": "moonleaf-glyph-24",
                "textToken": "ᚸ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 25,
                "glyphID": "moonleaf-glyph-25",
                "textToken": "ᚹ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 26,
                "glyphID": "moonleaf-glyph-26",
                "textToken": "ᚺ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 27,
                "glyphID": "moonleaf-glyph-27",
                "textToken": "ᚻ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 28,
                "glyphID": "moonleaf-glyph-28",
                "textToken": "ᚼ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 29,
                "glyphID": "moonleaf-glyph-29",
                "textToken": "ᚽ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 30,
                "glyphID": "moonleaf-glyph-30",
                "textToken": "ᚾ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 31,
                "glyphID": "moonleaf-glyph-31",
                "textToken": "ᚿ",
                "vectorResourceID": null
              }
            ],
            "fontResourceID": "resource.script.moonleaf.output.script-font",
            "fontReferenceID": "rs-moonleaf",
            "fontVersion": 1,
            "fontPostScriptName": "RavenForgeMoonleafScript-Regular",
            "staticFallbackResourceID": "resource.script.moonleaf.output.script-static-fallback",
            "standardSpecimenResourceID": "resource.script.moonleaf.output.script-specimen-standard",
            "highContrastSpecimenResourceID": "resource.script.moonleaf.output.script-specimen-high-contrast",
            "fallbackScriptID": "script.base-runes",
            "recommendedPointSizes": {
              "minimum": 12.0,
              "maximum": 96.0
            },
            "accessibility": {
              "label": {
                "key": "resource.script.moonleaf.accessibility.label",
                "fallbackValue": "Moonleaf Codex script with complete static renderer fallback."
              },
              "hint": null,
              "hidesRedundantGlyphs": true,
              "noColorOnlyState": true,
              "dynamicTypeSafe": true
            },
        "rightsID": "prov.Project.Script.Calligraphic.moonleaf.v1"
          }
        ],
        "relics": [
          {
            "metadata": {
              "id": "relic.moonleaf.tablet",
              "codexID": "codex.moonleaf",
              "displayName": {
                "key": "relic.moonleaf.tablet.name",
                "fallbackValue": "Moonleaf Tablet"
              },
              "description": {
                "key": "relic.moonleaf.tablet.description",
                "fallbackValue": "A broad, serene inscription surface designed for the widest range of message lengths."
              },
              "facets": [
                {
                  "key": "relic.moonleaf.tablet.facet.moonlit",
                  "fallbackValue": "Moonlit"
                },
                {
                  "key": "relic.moonleaf.tablet.facet.verdant",
                  "fallbackValue": "Verdant"
                },
                {
                  "key": "relic.moonleaf.tablet.facet.eternal",
                  "fallbackValue": "Eternal"
                }
              ],
              "rarity": "forged",
              "availability": "included",
              "accessibility": {
                "label": {
                  "key": "resource.relic.moonleaf.tablet.accessibility.label",
                  "fallbackValue": "A pale rectangular moonstone tablet framed by silver leaves, with a crescent crest and a blue-white gem."
                },
                "hint": null,
                "hidesRedundantGlyphs": true,
                "noColorOnlyState": true,
                "dynamicTypeSafe": true
              },
              "rightsID": "prov.Source.Masters.Relic.Geometry.moonleaf.tablet.geometry.svg"
            },
            "isDefault": true,
            "primaryResourceID": "resource.relic.moonleaf.tablet.output.relic-master",
            "thumbnailResourceID": "resource.relic.moonleaf.tablet.output.relic-thumbnail",
            "staticFallbackResourceID": "resource.relic.moonleaf.tablet.output.relic-static-share-fallback",
            "highContrastResourceID": "resource.relic.moonleaf.tablet.output.relic-high-contrast",
            "defaultLayoutID": "layout-profile.relic.moonleaf.tablet",
            "layouts": [
              {
                "id": "layout-profile.relic.moonleaf.tablet",
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
                "catalogSpecimenRows": 2,
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
              "id": "relic.moonleaf.ivybound-plaque",
              "codexID": "codex.moonleaf",
              "displayName": {
                "key": "relic.moonleaf.ivybound-plaque.name",
                "fallbackValue": "Ivybound Plaque"
              },
              "description": {
                "key": "relic.moonleaf.ivybound-plaque.description",
                "fallbackValue": "A more intimate woodland Relic whose living border frames short and medium inscriptions."
              },
              "rarity": "inscribed",
              "availability": "earned",
              "accessibility": {
                "label": {
                  "key": "resource.relic.moonleaf.ivybound-plaque.accessibility.label",
                  "fallbackValue": "A weathered square plaque ringed by living ivy and antique silver, with a quiet crescent motif."
                },
                "hint": null,
                "hidesRedundantGlyphs": true,
                "noColorOnlyState": true,
                "dynamicTypeSafe": true
              },
              "rightsID": "prov.Source.Masters.Relic.Geometry.moonleaf.ivybound.plaque.geometry.svg"
            },
            "isDefault": false,
            "primaryResourceID": "resource.relic.moonleaf.ivybound-plaque.output.relic-master",
            "thumbnailResourceID": "resource.relic.moonleaf.ivybound-plaque.output.relic-thumbnail",
            "staticFallbackResourceID": "resource.relic.moonleaf.ivybound-plaque.output.relic-static-share-fallback",
            "highContrastResourceID": "resource.relic.moonleaf.ivybound-plaque.output.relic-high-contrast",
            "defaultLayoutID": "layout-profile.relic.moonleaf.ivybound-plaque",
            "layouts": [
              {
                "id": "layout-profile.relic.moonleaf.ivybound-plaque",
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
                  "x": 0.18000000000000002,
                  "y": 0.22,
                  "width": 0.64,
                  "height": 0.52
                },
                "glyphSafeRegion": {
                  "x": 0.2,
                  "y": 0.24,
                  "width": 0.6,
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
              "id": "relic.moonleaf.whisperbark-stele",
              "codexID": "codex.moonleaf",
              "displayName": {
                "key": "relic.moonleaf.whisperbark-stele.name",
                "fallbackValue": "Whisperbark Stele"
              },
              "description": {
                "key": "relic.moonleaf.whisperbark-stele.description",
                "fallbackValue": "A prestige Relic optimized for narrow vertical inscriptions and ceremonial presentation."
              },
              "rarity": "rare",
              "availability": "earned",
              "accessibility": {
                "label": {
                  "key": "resource.relic.moonleaf.whisperbark-stele.accessibility.label",
                  "fallbackValue": "A tall carved wooden stele with glowing grain, a branch crown, and roots gathered at its base."
                },
                "hint": null,
                "hidesRedundantGlyphs": true,
                "noColorOnlyState": true,
                "dynamicTypeSafe": true
              },
              "rightsID": "prov.Source.Masters.Relic.Geometry.moonleaf.whisperbark.stele.geometry.svg"
            },
            "isDefault": false,
            "primaryResourceID": "resource.relic.moonleaf.whisperbark-stele.output.relic-master",
            "thumbnailResourceID": "resource.relic.moonleaf.whisperbark-stele.output.relic-thumbnail",
            "staticFallbackResourceID": "resource.relic.moonleaf.whisperbark-stele.output.relic-static-share-fallback",
            "highContrastResourceID": "resource.relic.moonleaf.whisperbark-stele.output.relic-high-contrast",
            "defaultLayoutID": "layout-profile.relic.moonleaf.whisperbark-stele",
            "layouts": [
              {
                "id": "layout-profile.relic.moonleaf.whisperbark-stele",
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
                  "x": 0.26999999999999996,
                  "y": 0.18000000000000002,
                  "width": 0.45999999999999996,
                  "height": 0.6000000000000001
                },
                "glyphSafeRegion": {
                  "x": 0.29,
                  "y": 0.2,
                  "width": 0.42,
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
              "id": "seal.moonleaf.crescentleaf",
              "codexID": "codex.moonleaf",
              "displayName": {
                "key": "seal.moonleaf.crescentleaf.name",
                "fallbackValue": "Crescentleaf"
              },
              "description": {
                "key": "seal.moonleaf.crescentleaf.description",
                "fallbackValue": "The Moonleaf Codex’s primary mark of calm, secrecy, and renewal."
              },
              "rarity": "forged",
              "availability": "included",
              "accessibility": {
                "label": {
                  "key": "resource.seal.moonleaf.crescentleaf.accessibility.label",
                  "fallbackValue": "A silver crescent moon wrapped around a small leafy branch."
                },
                "hint": null,
                "hidesRedundantGlyphs": true,
                "noColorOnlyState": true,
                "dynamicTypeSafe": true
              },
              "rightsID": "prov.Source.Masters.Seals.moonleaf.crescentleaf.svg"
            },
            "vectorResourceID": "resource.seal.moonleaf.crescentleaf.output.seal-vector-master",
            "colorResourceID": "resource.seal.moonleaf.crescentleaf.output.seal-color-master",
            "monochromeFallbackResourceID": "resource.seal.moonleaf.crescentleaf.output.seal-monochrome-fallback",
            "thumbnailResourceID": "resource.seal.moonleaf.crescentleaf.output.seal-thumbnail",
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
              "id": "seal.moonleaf.woodland-stag",
              "codexID": "codex.moonleaf",
              "displayName": {
                "key": "seal.moonleaf.woodland-stag.name",
                "fallbackValue": "Woodland Stag"
              },
              "description": {
                "key": "seal.moonleaf.woodland-stag.description",
                "fallbackValue": "A dignified woodland emblem representing watchfulness and ancient paths."
              },
              "rarity": "forged",
              "availability": "included",
              "accessibility": {
                "label": {
                  "key": "resource.seal.moonleaf.woodland-stag.accessibility.label",
                  "fallbackValue": "A pale stag with branching antlers inside a circular leafy seal."
                },
                "hint": null,
                "hidesRedundantGlyphs": true,
                "noColorOnlyState": true,
                "dynamicTypeSafe": true
              },
              "rightsID": "prov.Source.Masters.Seals.moonleaf.woodland.stag.svg"
            },
            "vectorResourceID": "resource.seal.moonleaf.woodland-stag.output.seal-vector-master",
            "colorResourceID": "resource.seal.moonleaf.woodland-stag.output.seal-color-master",
            "monochromeFallbackResourceID": "resource.seal.moonleaf.woodland-stag.output.seal-monochrome-fallback",
            "thumbnailResourceID": "resource.seal.moonleaf.woodland-stag.output.seal-thumbnail",
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
              "id": "seal.moonleaf.night-owl",
              "codexID": "codex.moonleaf",
              "displayName": {
                "key": "seal.moonleaf.night-owl.name",
                "fallbackValue": "Night Owl"
              },
              "description": {
                "key": "seal.moonleaf.night-owl.description",
                "fallbackValue": "A quiet watcher earned through the first Moonleaf dispatch."
              },
              "rarity": "inscribed",
              "availability": "earned",
              "accessibility": {
                "label": {
                  "key": "resource.seal.moonleaf.night-owl.accessibility.label",
                  "fallbackValue": "A silver owl beneath a small crescent moon."
                },
                "hint": null,
                "hidesRedundantGlyphs": true,
                "noColorOnlyState": true,
                "dynamicTypeSafe": true
              },
              "rightsID": "prov.Source.Masters.Seals.moonleaf.night.owl.svg"
            },
            "vectorResourceID": "resource.seal.moonleaf.night-owl.output.seal-vector-master",
            "colorResourceID": "resource.seal.moonleaf.night-owl.output.seal-color-master",
            "monochromeFallbackResourceID": "resource.seal.moonleaf.night-owl.output.seal-monochrome-fallback",
            "thumbnailResourceID": "resource.seal.moonleaf.night-owl.output.seal-thumbnail",
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
              "id": "seal.moonleaf.moonwell",
              "codexID": "codex.moonleaf",
              "displayName": {
                "key": "seal.moonleaf.moonwell.name",
                "fallbackValue": "Moonwell"
              },
              "description": {
                "key": "seal.moonleaf.moonwell.description",
                "fallbackValue": "A symbol of receiving, reflection, and messages returned."
              },
              "rarity": "inscribed",
              "availability": "earned",
              "accessibility": {
                "label": {
                  "key": "resource.seal.moonleaf.moonwell.accessibility.label",
                  "fallbackValue": "A crescent moon reflected in a round pool with three ripples."
                },
                "hint": null,
                "hidesRedundantGlyphs": true,
                "noColorOnlyState": true,
                "dynamicTypeSafe": true
              },
              "rightsID": "prov.Source.Masters.Seals.moonleaf.moonwell.svg"
            },
            "vectorResourceID": "resource.seal.moonleaf.moonwell.output.seal-vector-master",
            "colorResourceID": "resource.seal.moonleaf.moonwell.output.seal-color-master",
            "monochromeFallbackResourceID": "resource.seal.moonleaf.moonwell.output.seal-monochrome-fallback",
            "thumbnailResourceID": "resource.seal.moonleaf.moonwell.output.seal-thumbnail",
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
              "id": "seal.moonleaf.starflower",
              "codexID": "codex.moonleaf",
              "displayName": {
                "key": "seal.moonleaf.starflower.name",
                "fallbackValue": "Starflower"
              },
              "description": {
                "key": "seal.moonleaf.starflower.description",
                "fallbackValue": "A luminous bloom awarded after sustained Moonleaf correspondence."
              },
              "rarity": "rare",
              "availability": "earned",
              "accessibility": {
                "label": {
                  "key": "resource.seal.moonleaf.starflower.accessibility.label",
                  "fallbackValue": "A pale six-petal flower with a star at its center."
                },
                "hint": null,
                "hidesRedundantGlyphs": true,
                "noColorOnlyState": true,
                "dynamicTypeSafe": true
              },
              "rightsID": "prov.Source.Masters.Seals.moonleaf.starflower.svg"
            },
            "vectorResourceID": "resource.seal.moonleaf.starflower.output.seal-vector-master",
            "colorResourceID": "resource.seal.moonleaf.starflower.output.seal-color-master",
            "monochromeFallbackResourceID": "resource.seal.moonleaf.starflower.output.seal-monochrome-fallback",
            "thumbnailResourceID": "resource.seal.moonleaf.starflower.output.seal-thumbnail",
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
              "id": "seal.moonleaf.echo-firefly",
              "codexID": "codex.moonleaf",
              "displayName": {
                "key": "seal.moonleaf.echo-firefly.name",
                "fallbackValue": "Echo Firefly"
              },
              "description": {
                "key": "seal.moonleaf.echo-firefly.description",
                "fallbackValue": "An encounter mark showing that Moonleaf was discovered through another Scribe."
              },
              "rarity": "rare",
              "availability": "encountered",
              "accessibility": {
                "label": {
                  "key": "resource.seal.moonleaf.echo-firefly.accessibility.label",
                  "fallbackValue": "A small firefly surrounded by two glow rings."
                },
                "hint": null,
                "hidesRedundantGlyphs": true,
                "noColorOnlyState": true,
                "dynamicTypeSafe": true
              },
              "rightsID": "prov.Source.Masters.Seals.moonleaf.echo.firefly.svg"
            },
            "vectorResourceID": "resource.seal.moonleaf.echo-firefly.output.seal-vector-master",
            "colorResourceID": "resource.seal.moonleaf.echo-firefly.output.seal-color-master",
            "monochromeFallbackResourceID": "resource.seal.moonleaf.echo-firefly.output.seal-monochrome-fallback",
            "thumbnailResourceID": "resource.seal.moonleaf.echo-firefly.output.seal-thumbnail",
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
              "id": "frame.moonleaf.silvervine",
              "codexID": "codex.moonleaf",
              "displayName": {
                "key": "frame.moonleaf.silvervine.name",
                "fallbackValue": "Silvervine Frame"
              },
              "description": {
                "key": "frame.moonleaf.silvervine.description",
                "fallbackValue": "Thin silver vines, four leaf clusters, one moon gem, and no intrusion into the inscription safe region."
              },
              "rarity": "mythic",
              "availability": "mastery",
              "accessibility": {
                "label": {
                  "key": "resource.frame.moonleaf.silvervine.accessibility.label",
                  "fallbackValue": "Thin silver vines, four leaf clusters, one moon gem, and no intrusion into the inscription safe region."
                },
                "hint": null,
                "hidesRedundantGlyphs": true,
                "noColorOnlyState": true,
                "dynamicTypeSafe": true
              },
              "rightsID": "prov.Source.Masters.Frames.moonleaf.silvervine.svg"
            },
            "vectorResourceID": "resource.frame.moonleaf.silvervine.output.frame-vector-master",
            "staticFallbackResourceID": "resource.frame.moonleaf.silvervine.output.frame-static-fallback",
            "thumbnailResourceID": "resource.frame.moonleaf.silvervine.output.frame-thumbnail",
            "compatibleRelicIDs": [
              "relic.moonleaf.tablet",
              "relic.moonleaf.ivybound-plaque",
              "relic.moonleaf.whisperbark-stele"
            ],
            "allowsStaticShare": true
          }
        ],
        "crests": [
          {
            "metadata": {
              "id": "crest.moonleaf.moonbloom",
              "codexID": "codex.moonleaf",
              "displayName": {
                "key": "crest.moonleaf.moonbloom.name",
                "fallbackValue": "Moonbloom Crest"
              },
              "description": {
                "key": "crest.moonleaf.moonbloom.description",
                "fallbackValue": "A crescent rising behind a three-leaf bloom in a small circular silver crest."
              },
              "rarity": "mythic",
              "availability": "mastery",
              "accessibility": {
                "label": {
                  "key": "resource.crest.moonleaf.moonbloom.accessibility.label",
                  "fallbackValue": "A crescent rising behind a three-leaf bloom in a small circular silver crest."
                },
                "hint": null,
                "hidesRedundantGlyphs": true,
                "noColorOnlyState": true,
                "dynamicTypeSafe": true
              },
              "rightsID": "prov.Source.Masters.Crests.moonleaf.moonbloom.svg"
            },
            "vectorResourceID": "resource.crest.moonleaf.moonbloom.output.crest-vector-master",
            "staticFallbackResourceID": "resource.crest.moonleaf.moonbloom.output.crest-static-fallback",
            "thumbnailResourceID": "resource.crest.moonleaf.moonbloom.output.crest-thumbnail"
          }
        ],
        "background": {
          "id": "background.moonleaf.moonlit-canopy",
          "displayName": {
            "key": "background.moonleaf.moonlit-canopy.name",
            "fallbackValue": "Moonlit Canopy"
          },
          "staticBaseResourceID": "resource.background.moonleaf.moonlit-canopy.output.background-static-base",
          "reduceMotionResourceID": "resource.background.moonleaf.moonlit-canopy.output.background-reduce-motion",
          "highContrastResourceID": "resource.background.moonleaf.moonlit-canopy.output.background-high-contrast",
          "macOSWideResourceID": "resource.background.moonleaf.moonlit-canopy.output.background-macos-wide-crop",
          "optionalMotionResourceID": null,
          "rendererParametersResourceID": null,
          "motionIntensity": "none",
          "performanceClass": "standard",
          "parallaxAllowed": false,
          "accessibility": {
            "label": {
              "key": "resource.background.moonleaf.moonlit-canopy.accessibility.label",
              "fallbackValue": "Deep forest canopy, soft moonbeams, sparse fireflies, silver-green foliage, and no identifiable architecture."
            },
            "hint": null,
            "hidesRedundantGlyphs": true,
            "noColorOnlyState": true,
            "dynamicTypeSafe": true
          },
          "rightsID": "prov.Production.Sources.moonleaf.moonleaf.background.recipe.json"
        },
        "vault": {
          "id": "card.moonleaf.codex",
          "grouping": {
            "key": "vault.moonleaf.grouping",
            "fallbackValue": "Elven Series"
          },
          "cardResourceID": "resource.vault.moonleaf.codex.output.vault-card",
          "lockedSilhouetteResourceID": "resource.vault.moonleaf.codex.output.vault-locked-silhouette",
          "encounteredResourceID": "resource.vault.moonleaf.codex.output.vault-encountered",
          "selectedResourceID": "resource.vault.moonleaf.codex.output.vault-selected",
          "unavailableResourceID": "resource.vault.moonleaf.codex.output.vault-unavailable",
          "accessibility": {
            "label": {
              "key": "resource.vault.moonleaf.codex.accessibility.label",
              "fallbackValue": "Moonleaf Codex locked, encountered, owned, and selected presentation."
            },
            "hint": null,
            "hidesRedundantGlyphs": true,
            "noColorOnlyState": true,
            "dynamicTypeSafe": true
          },
          "rightsID": "prov.Production.Sources.moonleaf.moonleaf.vault.recipe.json"
        },
        "receivedPresentation": {
          "familyDisplayName": {
            "key": "codex.moonleaf.received-family.name",
            "fallbackValue": "Elven Codex"
          },
          "primarySenderAvatarResourceID": "resource.received.moonleaf.primary.sender-avatar",
          "shareSenderAvatarResourceID": "resource.received.moonleaf.share.sender-avatar",
          "shareCodexBadgeResourceID": "resource.received.moonleaf.share.codex-badge",
          "primaryMedallion": {
            "resourceID": "resource.received.moonleaf.primary.medallion",
            "anchor": {
              "x": 0.834,
              "y": 0.84
            },
            "scale": 0.205
          },
          "shareMedallion": {
            "resourceID": "resource.received.moonleaf.share.medallion",
            "anchor": {
              "x": 0.757,
              "y": 0.84
            },
            "scale": 0.161
          }
        },
        "rightsID": "prov.Production.Sources.moonleaf.moonleaf.background.recipe.json"
      },
      "resources": [],
      "localizations": [
        {
          "localeIdentifier": "en-US",
          "stringsResourceID": "resource.localization.moonleaf.control"
        }
      ],
      "defaultLocaleIdentifier": "en-US",
      "rights": [
        {
          "id": "prov.Project.Script.Calligraphic.moonleaf.v1",
          "creatorTool": "Python 3 with fontTools 4.60.2 and Pillow 11.3.0",
          "creationDate": "2026-09-15",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "scripts/make-elven-calligraphic-fonts.py",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/make-elven-calligraphic-fonts.py\",\"styleReference\":\"owner-supplied visual reference, 2026-09-15\"}",
          "licenseNotice": "Owner-supplied visual direction and proprietary project-local outlines"
        },
        {
          "id": "prov.Production.Sources.moonleaf.moonleaf.background.recipe.json",
          "creatorTool": "Python 3.9.6 with Pillow 11.3.0 and fontTools 4.60.2",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "owner-approved production design and manifest direction",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        },
        {
          "id": "prov.Production.Sources.moonleaf.accepted.source.masters.recipe.json",
          "creatorTool": "Pinned deterministic v4.3 asset builder",
          "creationDate": "2026-08-27",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "docs/verification/theme-fidelity-v4-3/inventory/recipes/Moonleaf-Accepted-Source-Master-Recipe-v4.3.json",
          "exportSettings": "{\"deterministic\":true,\"ownerReview\":\"PENDING\",\"pipeline\":\"scripts/build-moonleaf-v43-assets.py\"}",
          "licenseNotice": "Project-local proprietary production masters; owner visual review remains pending"
        },
        {
          "id": "prov.Production.Sources.moonleaf.moonleaf.vault.recipe.json",
          "creatorTool": "Python 3.9.6 with Pillow 11.3.0 and fontTools 4.60.2",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "owner-approved production design and manifest direction",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        },
        {
          "id": "prov.Source.Masters.Frames.moonleaf.silvervine.svg",
          "creatorTool": "Python 3.9.6 with Pillow 11.3.0 and fontTools 4.60.2",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "/Users/jimdaley/Documents/RavenForge/RuneScribe/Rune-Scribe-Elven-Series-Design-Package-v1.0/Source-Masters/Frames/moonleaf/silvervine.svg",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        },
        {
          "id": "prov.Source.Masters.Crests.moonleaf.moonbloom.svg",
          "creatorTool": "Python 3.9.6 with Pillow 11.3.0 and fontTools 4.60.2",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "/Users/jimdaley/Documents/RavenForge/RuneScribe/Rune-Scribe-Elven-Series-Design-Package-v1.0/Source-Masters/Crests/moonleaf/moonbloom.svg",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        },
        {
          "id": "prov.Source.Masters.Relic.Geometry.moonleaf.tablet.geometry.svg",
          "creatorTool": "macOS byte-preserving canonicalization with Python 3.9.6 hashing",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "/Users/jimdaley/Documents/RavenForge/RuneScribe/Rune-Scribe-Elven-Series-Design-Package-v1.0/Source-Masters/Relic-Geometry/moonleaf/tablet-geometry.svg",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        },
        {
          "id": "prov.Source.Masters.Relic.Geometry.moonleaf.ivybound.plaque.geometry.svg",
          "creatorTool": "Python 3.9.6 with Pillow 11.3.0 and fontTools 4.60.2",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "/Users/jimdaley/Documents/RavenForge/RuneScribe/Rune-Scribe-Elven-Series-Design-Package-v1.0/Source-Masters/Relic-Geometry/moonleaf/ivybound-plaque-geometry.svg",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        },
        {
          "id": "prov.Source.Masters.Relic.Geometry.moonleaf.whisperbark.stele.geometry.svg",
          "creatorTool": "macOS byte-preserving canonicalization with Python 3.9.6 hashing",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "/Users/jimdaley/Documents/RavenForge/RuneScribe/Rune-Scribe-Elven-Series-Design-Package-v1.0/Source-Masters/Relic-Geometry/moonleaf/whisperbark-stele-geometry.svg",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        },
        {
          "id": "prov.Source.Masters.Seals.moonleaf.crescentleaf.svg",
          "creatorTool": "macOS byte-preserving canonicalization with Python 3.9.6 hashing",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "/Users/jimdaley/Documents/RavenForge/RuneScribe/Rune-Scribe-Elven-Series-Design-Package-v1.0/Source-Masters/Seals/moonleaf/crescentleaf.svg",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        },
        {
          "id": "prov.Source.Masters.Seals.moonleaf.woodland.stag.svg",
          "creatorTool": "macOS byte-preserving canonicalization with Python 3.9.6 hashing",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "/Users/jimdaley/Documents/RavenForge/RuneScribe/Rune-Scribe-Elven-Series-Design-Package-v1.0/Source-Masters/Seals/moonleaf/woodland-stag.svg",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        },
        {
          "id": "prov.Source.Masters.Seals.moonleaf.night.owl.svg",
          "creatorTool": "Python 3.9.6 with Pillow 11.3.0 and fontTools 4.60.2",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "/Users/jimdaley/Documents/RavenForge/RuneScribe/Rune-Scribe-Elven-Series-Design-Package-v1.0/Source-Masters/Seals/moonleaf/night-owl.svg",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        },
        {
          "id": "prov.Source.Masters.Seals.moonleaf.moonwell.svg",
          "creatorTool": "macOS byte-preserving canonicalization with Python 3.9.6 hashing",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "/Users/jimdaley/Documents/RavenForge/RuneScribe/Rune-Scribe-Elven-Series-Design-Package-v1.0/Source-Masters/Seals/moonleaf/moonwell.svg",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        },
        {
          "id": "prov.Source.Masters.Seals.moonleaf.starflower.svg",
          "creatorTool": "macOS byte-preserving canonicalization with Python 3.9.6 hashing",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "/Users/jimdaley/Documents/RavenForge/RuneScribe/Rune-Scribe-Elven-Series-Design-Package-v1.0/Source-Masters/Seals/moonleaf/starflower.svg",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        },
        {
          "id": "prov.Source.Masters.Seals.moonleaf.echo.firefly.svg",
          "creatorTool": "Python 3.9.6 with Pillow 11.3.0 and fontTools 4.60.2",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "/Users/jimdaley/Documents/RavenForge/RuneScribe/Rune-Scribe-Elven-Series-Design-Package-v1.0/Source-Masters/Seals/moonleaf/echo-firefly.svg",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        },
        {
          "id": "prov.Theme.Fidelity.v4.3.Source.Masters.moonleaf.Moonleaf.Received.Identity.Extraction.v4.3.json",
          "creatorTool": "Python 3.9.6 with Pillow 11.3.0 exact source-pixel extraction",
          "creationDate": "2026-08-27",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "docs/verification/theme-fidelity-v4-3/source-masters/moonleaf/Moonleaf-Received-Identity-Extraction-v4.3.json",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/extract-moonleaf-received-identity-v43.py\",\"pipelineSHA256\":\"a0926182c694db1e3692ed63da15b721a4d897cf67ca2b81ea98427377a1b00b\",\"resampling\":\"none\",\"sourceRegionRoundTripMaximumChannelDifference\":0}",
          "licenseNotice": "Owner-supplied proprietary source and canonical v4.3 received-state authority"
        }
      ]
    }
    """#
}

private enum MoonleafThemeDescriptorError: Error {
    case invalidSeed
}

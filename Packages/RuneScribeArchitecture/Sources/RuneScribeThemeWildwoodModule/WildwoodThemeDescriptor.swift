import Foundation
import RuneScribeContracts

public enum WildwoodThemeDescriptorFactory {
    public static let discoveryDescriptor: ThemeDescriptor = {
        do { return try make() }
        catch { preconditionFailure("Invalid frozen Wildwood Theme descriptor: \(error)") }
    }()

    public static func make() throws -> ThemeDescriptor {
        guard var root = try JSONSerialization.jsonObject(
            with: Data(seedJSON.utf8)
        ) as? [String: Any],
        let resources = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(try WildwoodThemeResourceCatalog.references())
        ) as? [[String: Any]]
        else {
            throw WildwoodThemeDescriptorError.invalidSeed
        }
        root["resources"] = resources
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        return try JSONDecoder().decode(ThemeDescriptor.self, from: data)
    }

    private static let seedJSON = #"""
    {
      "id": "theme.wildwood.production",
      "moduleID": "com.runescribe.module.theme.wildwood",
      "moduleRole": "runescribe.theme.wildwood",
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
        "id": "codex.wildwood",
        "entitlementID": "unlock.codex.wildwood",
        "displayName": {
          "key": "codex.wildwood.name",
          "fallbackValue": "Wildwood Codex"
        },
        "shortDescription": {
          "key": "codex.wildwood.tagline",
          "fallbackValue": "Living inscriptions rooted in bark, moss, and ancient memory."
        },
        "longDescription": {
          "key": "codex.wildwood.description",
          "fallbackValue": "An earthy Elven Codex of elderbark, moss, roots, and patient growth. Its script feels carved by hand and shaped by the memory of the forest."
        },
        "accessibility": {
          "label": {
            "key": "codex.wildwood.label",
            "fallbackValue": "Wildwood Codex"
          },
          "hint": {
            "key": "codex.wildwood.hint",
            "fallbackValue": "An optional Codex that remains unavailable until earned."
          },
          "hidesRedundantGlyphs": false,
          "noColorOnlyState": true,
          "dynamicTypeSafe": true
        },
        "palette": {
          "backgroundPrimary": "#0D160E",
          "backgroundSecondary": "#172117",
          "surfacePrimary": "#1D2A1C",
          "surfaceElevated": "#293726",
          "textPrimary": "#E7E0CF",
          "textSecondary": "#A8B396",
          "textInverse": "#1D2A1C",
          "accentPrimary": "#9FB77B",
          "accentSecondary": "#B7A57D",
          "success": "#68E09B",
          "warning": "#FFD166",
          "danger": "#FF8A8A",
          "information": "#8FD8FF",
          "locked": "#706B5B",
          "encountered": "#8F9F73",
          "unavailable": "#5C6659",
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
        "primaryScriptID": "script.wildwood",
        "fallbackScriptID": "script.base-runes",
        "defaultRelicID": "relic.wildwood.rootsong-tablet",
        "scripts": [
          {
            "id": "script.wildwood",
            "displayName": {
              "key": "script.wildwood.name",
              "fallbackValue": "Wildwood Script"
            },
            "portability": "fontDependent",
            "glyphs": [
              {
                "canonicalValue": 0,
                "glyphID": "wildwood-glyph-00",
                "textToken": "ᚠ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 1,
                "glyphID": "wildwood-glyph-01",
                "textToken": "ᚡ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 2,
                "glyphID": "wildwood-glyph-02",
                "textToken": "ᚢ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 3,
                "glyphID": "wildwood-glyph-03",
                "textToken": "ᚣ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 4,
                "glyphID": "wildwood-glyph-04",
                "textToken": "ᚤ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 5,
                "glyphID": "wildwood-glyph-05",
                "textToken": "ᚥ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 6,
                "glyphID": "wildwood-glyph-06",
                "textToken": "ᚦ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 7,
                "glyphID": "wildwood-glyph-07",
                "textToken": "ᚧ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 8,
                "glyphID": "wildwood-glyph-08",
                "textToken": "ᚨ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 9,
                "glyphID": "wildwood-glyph-09",
                "textToken": "ᚩ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 10,
                "glyphID": "wildwood-glyph-10",
                "textToken": "ᚪ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 11,
                "glyphID": "wildwood-glyph-11",
                "textToken": "ᚫ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 12,
                "glyphID": "wildwood-glyph-12",
                "textToken": "ᚬ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 13,
                "glyphID": "wildwood-glyph-13",
                "textToken": "ᚭ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 14,
                "glyphID": "wildwood-glyph-14",
                "textToken": "ᚮ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 15,
                "glyphID": "wildwood-glyph-15",
                "textToken": "ᚯ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 16,
                "glyphID": "wildwood-glyph-16",
                "textToken": "ᚰ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 17,
                "glyphID": "wildwood-glyph-17",
                "textToken": "ᚱ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 18,
                "glyphID": "wildwood-glyph-18",
                "textToken": "ᚲ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 19,
                "glyphID": "wildwood-glyph-19",
                "textToken": "ᚳ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 20,
                "glyphID": "wildwood-glyph-20",
                "textToken": "ᚴ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 21,
                "glyphID": "wildwood-glyph-21",
                "textToken": "ᚵ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 22,
                "glyphID": "wildwood-glyph-22",
                "textToken": "ᚶ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 23,
                "glyphID": "wildwood-glyph-23",
                "textToken": "ᚷ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 24,
                "glyphID": "wildwood-glyph-24",
                "textToken": "ᚸ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 25,
                "glyphID": "wildwood-glyph-25",
                "textToken": "ᚹ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 26,
                "glyphID": "wildwood-glyph-26",
                "textToken": "ᚺ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 27,
                "glyphID": "wildwood-glyph-27",
                "textToken": "ᚻ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 28,
                "glyphID": "wildwood-glyph-28",
                "textToken": "ᚼ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 29,
                "glyphID": "wildwood-glyph-29",
                "textToken": "ᚽ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 30,
                "glyphID": "wildwood-glyph-30",
                "textToken": "ᚾ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 31,
                "glyphID": "wildwood-glyph-31",
                "textToken": "ᚿ",
                "vectorResourceID": null
              }
            ],
            "fontResourceID": "resource.script.wildwood.output.script-font",
            "fontReferenceID": "rs-wildwood",
            "fontVersion": 1,
            "fontPostScriptName": "RavenForgeWildwoodScript-Regular",
            "staticFallbackResourceID": "resource.script.wildwood.output.script-static-fallback",
            "fallbackScriptID": "script.base-runes",
            "recommendedPointSizes": {
              "minimum": 12.0,
              "maximum": 64.0
            },
            "accessibility": {
              "label": {
                "key": "resource.script.wildwood.accessibility.label",
                "fallbackValue": "Wildwood Codex script with complete static renderer fallback."
              },
              "hint": null,
              "hidesRedundantGlyphs": true,
              "noColorOnlyState": true,
              "dynamicTypeSafe": true
            },
            "rightsID": "prov.Source.Masters.Glyphs.wildwood.glyph.master.json"
          }
        ],
        "relics": [
          {
            "metadata": {
              "id": "relic.wildwood.rootsong-tablet",
              "codexID": "codex.wildwood",
              "displayName": {
                "key": "relic.wildwood.rootsong-tablet.name",
                "fallbackValue": "Rootsong Tablet"
              },
              "description": {
                "key": "relic.wildwood.rootsong-tablet.description",
                "fallbackValue": "A grounded default Relic combining broad inscription capacity with unmistakable living-forest material."
              },
              "rarity": "forged",
              "availability": "included",
              "accessibility": {
                "label": {
                  "key": "resource.relic.wildwood.rootsong-tablet.accessibility.label",
                  "fallbackValue": "A broad bark tablet wrapped in roots and moss, with a carved tree emblem above the inscription."
                },
                "hint": null,
                "hidesRedundantGlyphs": true,
                "noColorOnlyState": true,
                "dynamicTypeSafe": true
              },
              "rightsID": "prov.Source.Masters.Relic.Geometry.wildwood.rootsong.tablet.geometry.svg"
            },
            "isDefault": true,
            "primaryResourceID": "resource.relic.wildwood.rootsong-tablet.output.relic-master",
            "thumbnailResourceID": "resource.relic.wildwood.rootsong-tablet.output.relic-thumbnail",
            "staticFallbackResourceID": "resource.relic.wildwood.rootsong-tablet.output.relic-static-share-fallback",
            "highContrastResourceID": "resource.relic.wildwood.rootsong-tablet.output.relic-high-contrast",
            "defaultLayoutID": "layout-profile.relic.wildwood.rootsong-tablet",
            "layouts": [
              {
                "id": "layout-profile.relic.wildwood.rootsong-tablet",
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
                  "x": 0.15000000000000002,
                  "y": 0.23,
                  "width": 0.7000000000000001,
                  "height": 0.44
                },
                "glyphSafeRegion": {
                  "x": 0.17,
                  "y": 0.25,
                  "width": 0.66,
                  "height": 0.4
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
                "catalogSpecimenColumns": 8,
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
              "id": "relic.wildwood.mossbound-plaque",
              "codexID": "codex.wildwood",
              "displayName": {
                "key": "relic.wildwood.mossbound-plaque.name",
                "fallbackValue": "Mossbound Plaque"
              },
              "description": {
                "key": "relic.wildwood.mossbound-plaque.description",
                "fallbackValue": "A quiet, time-worn plaque optimized for short and medium inscriptions."
              },
              "rarity": "inscribed",
              "availability": "earned",
              "accessibility": {
                "label": {
                  "key": "resource.relic.wildwood.mossbound-plaque.accessibility.label",
                  "fallbackValue": "A rounded square plaque softened by moss and lichen, with a small leaf crest at the top."
                },
                "hint": null,
                "hidesRedundantGlyphs": true,
                "noColorOnlyState": true,
                "dynamicTypeSafe": true
              },
              "rightsID": "prov.Source.Masters.Relic.Geometry.wildwood.mossbound.plaque.geometry.svg"
            },
            "isDefault": false,
            "primaryResourceID": "resource.relic.wildwood.mossbound-plaque.output.relic-master",
            "thumbnailResourceID": "resource.relic.wildwood.mossbound-plaque.output.relic-thumbnail",
            "staticFallbackResourceID": "resource.relic.wildwood.mossbound-plaque.output.relic-static-share-fallback",
            "highContrastResourceID": "resource.relic.wildwood.mossbound-plaque.output.relic-high-contrast",
            "defaultLayoutID": "layout-profile.relic.wildwood.mossbound-plaque",
            "layouts": [
              {
                "id": "layout-profile.relic.wildwood.mossbound-plaque",
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
                  "height": 0.54
                },
                "glyphSafeRegion": {
                  "x": 0.18,
                  "y": 0.23,
                  "width": 0.64,
                  "height": 0.5
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
                "catalogSpecimenRows": 2,
                "catalogSpecimenColumns": 7,
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
              "id": "relic.wildwood.elderbark-stele",
              "codexID": "codex.wildwood",
              "displayName": {
                "key": "relic.wildwood.elderbark-stele.name",
                "fallbackValue": "Elderbark Stele"
              },
              "description": {
                "key": "relic.wildwood.elderbark-stele.description",
                "fallbackValue": "An ancient prestige Relic with a tall inscription field and the visual weight of an old tree."
              },
              "rarity": "rare",
              "availability": "earned",
              "accessibility": {
                "label": {
                  "key": "resource.relic.wildwood.elderbark-stele.accessibility.label",
                  "fallbackValue": "A tall dark wooden stele carved with branches and roots, standing on a rooted base."
                },
                "hint": null,
                "hidesRedundantGlyphs": true,
                "noColorOnlyState": true,
                "dynamicTypeSafe": true
              },
              "rightsID": "prov.Source.Masters.Relic.Geometry.wildwood.elderbark.stele.geometry.svg"
            },
            "isDefault": false,
            "primaryResourceID": "resource.relic.wildwood.elderbark-stele.output.relic-master",
            "thumbnailResourceID": "resource.relic.wildwood.elderbark-stele.output.relic-thumbnail",
            "staticFallbackResourceID": "resource.relic.wildwood.elderbark-stele.output.relic-static-share-fallback",
            "highContrastResourceID": "resource.relic.wildwood.elderbark-stele.output.relic-high-contrast",
            "defaultLayoutID": "layout-profile.relic.wildwood.elderbark-stele",
            "layouts": [
              {
                "id": "layout-profile.relic.wildwood.elderbark-stele",
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
                  "y": 0.19,
                  "width": 0.48,
                  "height": 0.5800000000000001
                },
                "glyphSafeRegion": {
                  "x": 0.28,
                  "y": 0.21,
                  "width": 0.44,
                  "height": 0.54
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
              "id": "seal.wildwood.rooted-tree",
              "codexID": "codex.wildwood",
              "displayName": {
                "key": "seal.wildwood.rooted-tree.name",
                "fallbackValue": "Rooted Tree"
              },
              "description": {
                "key": "seal.wildwood.rooted-tree.description",
                "fallbackValue": "The central Wildwood mark of continuity, memory, and belonging."
              },
              "rarity": "forged",
              "availability": "included",
              "accessibility": {
                "label": {
                  "key": "resource.seal.wildwood.rooted-tree.accessibility.label",
                  "fallbackValue": "A tree with spreading branches and visible roots inside a circle."
                },
                "hint": null,
                "hidesRedundantGlyphs": true,
                "noColorOnlyState": true,
                "dynamicTypeSafe": true
              },
              "rightsID": "prov.Source.Masters.Seals.wildwood.rooted.tree.svg"
            },
            "vectorResourceID": "resource.seal.wildwood.rooted-tree.output.seal-vector-master",
            "colorResourceID": "resource.seal.wildwood.rooted-tree.output.seal-color-master",
            "monochromeFallbackResourceID": "resource.seal.wildwood.rooted-tree.output.seal-monochrome-fallback",
            "thumbnailResourceID": "resource.seal.wildwood.rooted-tree.output.seal-thumbnail",
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
              "id": "seal.wildwood.lantern-moth",
              "codexID": "codex.wildwood",
              "displayName": {
                "key": "seal.wildwood.lantern-moth.name",
                "fallbackValue": "Lantern Moth"
              },
              "description": {
                "key": "seal.wildwood.lantern-moth.description",
                "fallbackValue": "A gentle nocturnal guide through old forest paths."
              },
              "rarity": "forged",
              "availability": "included",
              "accessibility": {
                "label": {
                  "key": "resource.seal.wildwood.lantern-moth.accessibility.label",
                  "fallbackValue": "A moth with wide wings and a small lantern hanging below it."
                },
                "hint": null,
                "hidesRedundantGlyphs": true,
                "noColorOnlyState": true,
                "dynamicTypeSafe": true
              },
              "rightsID": "prov.Source.Masters.Seals.wildwood.lantern.moth.svg"
            },
            "vectorResourceID": "resource.seal.wildwood.lantern-moth.output.seal-vector-master",
            "colorResourceID": "resource.seal.wildwood.lantern-moth.output.seal-color-master",
            "monochromeFallbackResourceID": "resource.seal.wildwood.lantern-moth.output.seal-monochrome-fallback",
            "thumbnailResourceID": "resource.seal.wildwood.lantern-moth.output.seal-thumbnail",
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
              "id": "seal.wildwood.acorn-knot",
              "codexID": "codex.wildwood",
              "displayName": {
                "key": "seal.wildwood.acorn-knot.name",
                "fallbackValue": "Acorn Knot"
              },
              "description": {
                "key": "seal.wildwood.acorn-knot.description",
                "fallbackValue": "A first-dispatch mark representing small beginnings and durable growth."
              },
              "rarity": "inscribed",
              "availability": "earned",
              "accessibility": {
                "label": {
                  "key": "resource.seal.wildwood.acorn-knot.accessibility.label",
                  "fallbackValue": "An acorn wrapped in a three-loop root knot."
                },
                "hint": null,
                "hidesRedundantGlyphs": true,
                "noColorOnlyState": true,
                "dynamicTypeSafe": true
              },
              "rightsID": "prov.Source.Masters.Seals.wildwood.acorn.knot.svg"
            },
            "vectorResourceID": "resource.seal.wildwood.acorn-knot.output.seal-vector-master",
            "colorResourceID": "resource.seal.wildwood.acorn-knot.output.seal-color-master",
            "monochromeFallbackResourceID": "resource.seal.wildwood.acorn-knot.output.seal-monochrome-fallback",
            "thumbnailResourceID": "resource.seal.wildwood.acorn-knot.output.seal-thumbnail",
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
              "id": "seal.wildwood.fern-spiral",
              "codexID": "codex.wildwood",
              "displayName": {
                "key": "seal.wildwood.fern-spiral.name",
                "fallbackValue": "Fern Spiral"
              },
              "description": {
                "key": "seal.wildwood.fern-spiral.description",
                "fallbackValue": "A receiving mark symbolizing messages that unfurl over time."
              },
              "rarity": "inscribed",
              "availability": "earned",
              "accessibility": {
                "label": {
                  "key": "resource.seal.wildwood.fern-spiral.accessibility.label",
                  "fallbackValue": "A curled fern frond forming a spiral."
                },
                "hint": null,
                "hidesRedundantGlyphs": true,
                "noColorOnlyState": true,
                "dynamicTypeSafe": true
              },
              "rightsID": "prov.Source.Masters.Seals.wildwood.fern.spiral.svg"
            },
            "vectorResourceID": "resource.seal.wildwood.fern-spiral.output.seal-vector-master",
            "colorResourceID": "resource.seal.wildwood.fern-spiral.output.seal-color-master",
            "monochromeFallbackResourceID": "resource.seal.wildwood.fern-spiral.output.seal-monochrome-fallback",
            "thumbnailResourceID": "resource.seal.wildwood.fern-spiral.output.seal-thumbnail",
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
              "id": "seal.wildwood.wild-fox",
              "codexID": "codex.wildwood",
              "displayName": {
                "key": "seal.wildwood.wild-fox.name",
                "fallbackValue": "Wild Fox"
              },
              "description": {
                "key": "seal.wildwood.wild-fox.description",
                "fallbackValue": "A clever woodland emblem earned through sustained Wildwood use."
              },
              "rarity": "rare",
              "availability": "earned",
              "accessibility": {
                "label": {
                  "key": "resource.seal.wildwood.wild-fox.accessibility.label",
                  "fallbackValue": "A fox head with a leaf-shaped mark on its forehead."
                },
                "hint": null,
                "hidesRedundantGlyphs": true,
                "noColorOnlyState": true,
                "dynamicTypeSafe": true
              },
              "rightsID": "prov.Source.Masters.Seals.wildwood.wild.fox.svg"
            },
            "vectorResourceID": "resource.seal.wildwood.wild-fox.output.seal-vector-master",
            "colorResourceID": "resource.seal.wildwood.wild-fox.output.seal-color-master",
            "monochromeFallbackResourceID": "resource.seal.wildwood.wild-fox.output.seal-monochrome-fallback",
            "thumbnailResourceID": "resource.seal.wildwood.wild-fox.output.seal-thumbnail",
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
              "id": "seal.wildwood.echo-seed",
              "codexID": "codex.wildwood",
              "displayName": {
                "key": "seal.wildwood.echo-seed.name",
                "fallbackValue": "Echo Seed"
              },
              "description": {
                "key": "seal.wildwood.echo-seed.description",
                "fallbackValue": "An encounter mark showing a Wildwood idea carried from another Scribe."
              },
              "rarity": "rare",
              "availability": "encountered",
              "accessibility": {
                "label": {
                  "key": "resource.seal.wildwood.echo-seed.accessibility.label",
                  "fallbackValue": "A seed with one root inside two circular rings."
                },
                "hint": null,
                "hidesRedundantGlyphs": true,
                "noColorOnlyState": true,
                "dynamicTypeSafe": true
              },
              "rightsID": "prov.Source.Masters.Seals.wildwood.echo.seed.svg"
            },
            "vectorResourceID": "resource.seal.wildwood.echo-seed.output.seal-vector-master",
            "colorResourceID": "resource.seal.wildwood.echo-seed.output.seal-color-master",
            "monochromeFallbackResourceID": "resource.seal.wildwood.echo-seed.output.seal-monochrome-fallback",
            "thumbnailResourceID": "resource.seal.wildwood.echo-seed.output.seal-thumbnail",
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
              "id": "frame.wildwood.living-root",
              "codexID": "codex.wildwood",
              "displayName": {
                "key": "frame.wildwood.living-root.name",
                "fallbackValue": "Living Root Frame"
              },
              "description": {
                "key": "frame.wildwood.living-root.description",
                "fallbackValue": "Thin interlaced roots, small moss patches, four leaf buds, and strict clearance around the safe region."
              },
              "rarity": "mythic",
              "availability": "mastery",
              "accessibility": {
                "label": {
                  "key": "resource.frame.wildwood.living-root.accessibility.label",
                  "fallbackValue": "Thin interlaced roots, small moss patches, four leaf buds, and strict clearance around the safe region."
                },
                "hint": null,
                "hidesRedundantGlyphs": true,
                "noColorOnlyState": true,
                "dynamicTypeSafe": true
              },
              "rightsID": "prov.Source.Masters.Frames.wildwood.living.root.svg"
            },
            "vectorResourceID": "resource.frame.wildwood.living-root.output.frame-vector-master",
            "staticFallbackResourceID": "resource.frame.wildwood.living-root.output.frame-static-fallback",
            "thumbnailResourceID": "resource.frame.wildwood.living-root.output.frame-thumbnail",
            "compatibleRelicIDs": [
              "relic.wildwood.rootsong-tablet",
              "relic.wildwood.mossbound-plaque",
              "relic.wildwood.elderbark-stele"
            ],
            "allowsStaticShare": true
          }
        ],
        "crests": [
          {
            "metadata": {
              "id": "crest.wildwood.heartwood-crown",
              "codexID": "codex.wildwood",
              "displayName": {
                "key": "crest.wildwood.heartwood-crown.name",
                "fallbackValue": "Heartwood Crown"
              },
              "description": {
                "key": "crest.wildwood.heartwood-crown.description",
                "fallbackValue": "A small crown formed from three root arches above a central seed."
              },
              "rarity": "mythic",
              "availability": "mastery",
              "accessibility": {
                "label": {
                  "key": "resource.crest.wildwood.heartwood-crown.accessibility.label",
                  "fallbackValue": "A small crown formed from three root arches above a central seed."
                },
                "hint": null,
                "hidesRedundantGlyphs": true,
                "noColorOnlyState": true,
                "dynamicTypeSafe": true
              },
              "rightsID": "prov.Source.Masters.Crests.wildwood.heartwood.crown.svg"
            },
            "vectorResourceID": "resource.crest.wildwood.heartwood-crown.output.crest-vector-master",
            "staticFallbackResourceID": "resource.crest.wildwood.heartwood-crown.output.crest-static-fallback"
          }
        ],
        "background": {
          "id": "background.wildwood.oldgrowth-hollow",
          "displayName": {
            "key": "background.wildwood.oldgrowth-hollow.name",
            "fallbackValue": "Oldgrowth Hollow"
          },
          "staticBaseResourceID": "resource.background.wildwood.oldgrowth-hollow.output.background-static-base",
          "reduceMotionResourceID": "resource.background.wildwood.oldgrowth-hollow.output.background-reduce-motion",
          "highContrastResourceID": "resource.background.wildwood.oldgrowth-hollow.output.background-high-contrast",
          "optionalMotionResourceID": null,
          "rendererParametersResourceID": null,
          "motionIntensity": "none",
          "performanceClass": "standard",
          "parallaxAllowed": false,
          "accessibility": {
            "label": {
              "key": "resource.background.wildwood.oldgrowth-hollow.accessibility.label",
              "fallbackValue": "Dense old forest, massive roots, moss, small fungi, filtered green-gold light, and no architectural structures."
            },
            "hint": null,
            "hidesRedundantGlyphs": true,
            "noColorOnlyState": true,
            "dynamicTypeSafe": true
          },
          "rightsID": "prov.Production.Sources.wildwood.wildwood.background.recipe.json"
        },
        "vault": {
          "id": "card.wildwood.codex",
          "grouping": {
            "key": "vault.wildwood.grouping",
            "fallbackValue": "Elven Series"
          },
          "cardResourceID": "resource.vault.wildwood.codex.output.vault-card",
          "lockedSilhouetteResourceID": "resource.vault.wildwood.codex.output.vault-locked-silhouette",
          "encounteredResourceID": "resource.vault.wildwood.codex.output.vault-encountered",
          "selectedResourceID": "resource.vault.wildwood.codex.output.vault-selected",
          "accessibility": {
            "label": {
              "key": "resource.vault.wildwood.codex.accessibility.label",
              "fallbackValue": "Wildwood Codex locked, encountered, owned, and selected presentation."
            },
            "hint": null,
            "hidesRedundantGlyphs": true,
            "noColorOnlyState": true,
            "dynamicTypeSafe": true
          },
          "rightsID": "prov.Production.Sources.wildwood.wildwood.vault.recipe.json"
        },
        "rightsID": "prov.Production.Sources.wildwood.wildwood.background.recipe.json"
      },
      "resources": [],
      "localizations": [
        {
          "localeIdentifier": "en-US",
          "stringsResourceID": "resource.localization.wildwood.control"
        }
      ],
      "defaultLocaleIdentifier": "en-US",
      "rights": [
        {
          "id": "prov.Source.Masters.Glyphs.wildwood.glyph.master.json",
          "creatorTool": "macOS byte-preserving canonicalization with Python 3.9.6 hashing",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "/Users/jimdaley/Documents/RavenForge/RuneScribe/Rune-Scribe-Elven-Series-Design-Package-v1.0/Source-Masters/Glyphs/wildwood/glyph-master.json",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        },
        {
          "id": "prov.Production.Sources.wildwood.wildwood.background.recipe.json",
          "creatorTool": "Python 3.9.6 with Pillow 11.3.0 and fontTools 4.60.2",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "owner-approved production design and manifest direction",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        },
        {
          "id": "prov.Production.Sources.wildwood.accepted.source.masters.recipe.json",
          "creatorTool": "Pinned deterministic v4.3 asset builder",
          "creationDate": "2026-08-27",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "docs/verification/theme-fidelity-v4-3/inventory/recipes/Wildwood-Accepted-Source-Master-Recipe-v4.3.json",
          "exportSettings": "{\"deterministic\":true,\"ownerReview\":\"PENDING\",\"pipeline\":\"scripts/build-sunspire-wildwood-gloamthorn-v43-assets.py\"}",
          "licenseNotice": "Project-local proprietary production masters; owner visual review remains pending"
        },
        {
          "id": "prov.Production.Sources.wildwood.wildwood.vault.recipe.json",
          "creatorTool": "Python 3.9.6 with Pillow 11.3.0 and fontTools 4.60.2",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "owner-approved production design and manifest direction",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        },
        {
          "id": "prov.Source.Masters.Frames.wildwood.living.root.svg",
          "creatorTool": "Python 3.9.6 with Pillow 11.3.0 and fontTools 4.60.2",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "/Users/jimdaley/Documents/RavenForge/RuneScribe/Rune-Scribe-Elven-Series-Design-Package-v1.0/Source-Masters/Frames/wildwood/living-root.svg",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        },
        {
          "id": "prov.Source.Masters.Crests.wildwood.heartwood.crown.svg",
          "creatorTool": "Python 3.9.6 with Pillow 11.3.0 and fontTools 4.60.2",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "/Users/jimdaley/Documents/RavenForge/RuneScribe/Rune-Scribe-Elven-Series-Design-Package-v1.0/Source-Masters/Crests/wildwood/heartwood-crown.svg",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        },
        {
          "id": "prov.Source.Masters.Relic.Geometry.wildwood.rootsong.tablet.geometry.svg",
          "creatorTool": "macOS byte-preserving canonicalization with Python 3.9.6 hashing",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "/Users/jimdaley/Documents/RavenForge/RuneScribe/Rune-Scribe-Elven-Series-Design-Package-v1.0/Source-Masters/Relic-Geometry/wildwood/rootsong-tablet-geometry.svg",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        },
        {
          "id": "prov.Source.Masters.Relic.Geometry.wildwood.mossbound.plaque.geometry.svg",
          "creatorTool": "Python 3.9.6 with Pillow 11.3.0 and fontTools 4.60.2",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "/Users/jimdaley/Documents/RavenForge/RuneScribe/Rune-Scribe-Elven-Series-Design-Package-v1.0/Source-Masters/Relic-Geometry/wildwood/mossbound-plaque-geometry.svg",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        },
        {
          "id": "prov.Source.Masters.Relic.Geometry.wildwood.elderbark.stele.geometry.svg",
          "creatorTool": "macOS byte-preserving canonicalization with Python 3.9.6 hashing",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "/Users/jimdaley/Documents/RavenForge/RuneScribe/Rune-Scribe-Elven-Series-Design-Package-v1.0/Source-Masters/Relic-Geometry/wildwood/elderbark-stele-geometry.svg",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        },
        {
          "id": "prov.Source.Masters.Seals.wildwood.rooted.tree.svg",
          "creatorTool": "macOS byte-preserving canonicalization with Python 3.9.6 hashing",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "/Users/jimdaley/Documents/RavenForge/RuneScribe/Rune-Scribe-Elven-Series-Design-Package-v1.0/Source-Masters/Seals/wildwood/rooted-tree.svg",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        },
        {
          "id": "prov.Source.Masters.Seals.wildwood.lantern.moth.svg",
          "creatorTool": "macOS byte-preserving canonicalization with Python 3.9.6 hashing",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "/Users/jimdaley/Documents/RavenForge/RuneScribe/Rune-Scribe-Elven-Series-Design-Package-v1.0/Source-Masters/Seals/wildwood/lantern-moth.svg",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        },
        {
          "id": "prov.Source.Masters.Seals.wildwood.acorn.knot.svg",
          "creatorTool": "macOS byte-preserving canonicalization with Python 3.9.6 hashing",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "/Users/jimdaley/Documents/RavenForge/RuneScribe/Rune-Scribe-Elven-Series-Design-Package-v1.0/Source-Masters/Seals/wildwood/acorn-knot.svg",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        },
        {
          "id": "prov.Source.Masters.Seals.wildwood.fern.spiral.svg",
          "creatorTool": "macOS byte-preserving canonicalization with Python 3.9.6 hashing",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "/Users/jimdaley/Documents/RavenForge/RuneScribe/Rune-Scribe-Elven-Series-Design-Package-v1.0/Source-Masters/Seals/wildwood/fern-spiral.svg",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        },
        {
          "id": "prov.Source.Masters.Seals.wildwood.wild.fox.svg",
          "creatorTool": "Python 3.9.6 with Pillow 11.3.0 and fontTools 4.60.2",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "/Users/jimdaley/Documents/RavenForge/RuneScribe/Rune-Scribe-Elven-Series-Design-Package-v1.0/Source-Masters/Seals/wildwood/wild-fox.svg",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        },
        {
          "id": "prov.Source.Masters.Seals.wildwood.echo.seed.svg",
          "creatorTool": "macOS byte-preserving canonicalization with Python 3.9.6 hashing",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "/Users/jimdaley/Documents/RavenForge/RuneScribe/Rune-Scribe-Elven-Series-Design-Package-v1.0/Source-Masters/Seals/wildwood/echo-seed.svg",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        }
      ]
    }
    """#
}

private enum WildwoodThemeDescriptorError: Error {
    case invalidSeed
}

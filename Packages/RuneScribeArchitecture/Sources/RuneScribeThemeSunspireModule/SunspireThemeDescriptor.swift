import Foundation
import RuneScribeContracts

public enum SunspireThemeDescriptorFactory {
    public static let discoveryDescriptor: ThemeDescriptor = {
        do { return try make() }
        catch { preconditionFailure("Invalid frozen Sunspire Theme descriptor: \(error)") }
    }()

    public static func make() throws -> ThemeDescriptor {
        guard var root = try JSONSerialization.jsonObject(
            with: Data(seedJSON.utf8)
        ) as? [String: Any],
        let resources = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(try SunspireThemeResourceCatalog.references())
        ) as? [[String: Any]]
        else {
            throw SunspireThemeDescriptorError.invalidSeed
        }
        root["resources"] = resources
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        return try JSONDecoder().decode(ThemeDescriptor.self, from: data)
    }

    private static let seedJSON = #"""
    {
      "id": "theme.sunspire.production",
      "moduleID": "com.runescribe.module.theme.sunspire",
      "moduleRole": "runescribe.theme.sunspire",
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
        "id": "codex.sunspire",
        "entitlementID": "unlock.codex.sunspire",
        "displayName": {
          "key": "codex.sunspire.name",
          "fallbackValue": "Sunspire Codex"
        },
        "shortDescription": {
          "key": "codex.sunspire.tagline",
          "fallbackValue": "Dawnlit inscriptions carried in ivory, gold, and living radiance."
        },
        "longDescription": {
          "key": "codex.sunspire.description",
          "fallbackValue": "A noble Elven Codex of sun-touched ivory, gilded leaves, and measured light. Its script rises with the ordered clarity of dawn."
        },
        "accessibility": {
          "label": {
            "key": "codex.sunspire.label",
            "fallbackValue": "Sunspire Codex"
          },
          "hint": {
            "key": "codex.sunspire.hint",
            "fallbackValue": "An optional Codex that remains unavailable until earned."
          },
          "hidesRedundantGlyphs": false,
          "noColorOnlyState": true,
          "dynamicTypeSafe": true
        },
        "palette": {
          "backgroundPrimary": "#1C160D",
          "backgroundSecondary": "#2B2112",
          "surfacePrimary": "#2D2417",
          "surfaceElevated": "#3B2F1E",
          "textPrimary": "#FFF3D6",
          "textSecondary": "#D7BF8C",
          "textInverse": "#2D2417",
          "accentPrimary": "#F2C66D",
          "accentSecondary": "#FFF0C8",
          "success": "#68E09B",
          "warning": "#FFD166",
          "danger": "#FF8A8A",
          "information": "#8FD8FF",
          "locked": "#85765E",
          "encountered": "#D3A953",
          "unavailable": "#6A6255",
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
        "primaryScriptID": "script.sunspire",
        "fallbackScriptID": "script.base-runes",
        "defaultRelicID": "relic.sunspire.dawnfire-tablet",
        "scripts": [
          {
            "id": "script.sunspire",
            "displayName": {
              "key": "script.sunspire.name",
              "fallbackValue": "Sunspire Script"
            },
            "portability": "fontDependent",
            "glyphs": [
              {
                "canonicalValue": 0,
                "glyphID": "sunspire-glyph-00",
                "textToken": "ᚠ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 1,
                "glyphID": "sunspire-glyph-01",
                "textToken": "ᚡ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 2,
                "glyphID": "sunspire-glyph-02",
                "textToken": "ᚢ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 3,
                "glyphID": "sunspire-glyph-03",
                "textToken": "ᚣ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 4,
                "glyphID": "sunspire-glyph-04",
                "textToken": "ᚤ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 5,
                "glyphID": "sunspire-glyph-05",
                "textToken": "ᚥ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 6,
                "glyphID": "sunspire-glyph-06",
                "textToken": "ᚦ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 7,
                "glyphID": "sunspire-glyph-07",
                "textToken": "ᚧ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 8,
                "glyphID": "sunspire-glyph-08",
                "textToken": "ᚨ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 9,
                "glyphID": "sunspire-glyph-09",
                "textToken": "ᚩ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 10,
                "glyphID": "sunspire-glyph-10",
                "textToken": "ᚪ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 11,
                "glyphID": "sunspire-glyph-11",
                "textToken": "ᚫ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 12,
                "glyphID": "sunspire-glyph-12",
                "textToken": "ᚬ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 13,
                "glyphID": "sunspire-glyph-13",
                "textToken": "ᚭ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 14,
                "glyphID": "sunspire-glyph-14",
                "textToken": "ᚮ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 15,
                "glyphID": "sunspire-glyph-15",
                "textToken": "ᚯ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 16,
                "glyphID": "sunspire-glyph-16",
                "textToken": "ᚰ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 17,
                "glyphID": "sunspire-glyph-17",
                "textToken": "ᚱ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 18,
                "glyphID": "sunspire-glyph-18",
                "textToken": "ᚲ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 19,
                "glyphID": "sunspire-glyph-19",
                "textToken": "ᚳ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 20,
                "glyphID": "sunspire-glyph-20",
                "textToken": "ᚴ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 21,
                "glyphID": "sunspire-glyph-21",
                "textToken": "ᚵ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 22,
                "glyphID": "sunspire-glyph-22",
                "textToken": "ᚶ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 23,
                "glyphID": "sunspire-glyph-23",
                "textToken": "ᚷ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 24,
                "glyphID": "sunspire-glyph-24",
                "textToken": "ᚸ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 25,
                "glyphID": "sunspire-glyph-25",
                "textToken": "ᚹ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 26,
                "glyphID": "sunspire-glyph-26",
                "textToken": "ᚺ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 27,
                "glyphID": "sunspire-glyph-27",
                "textToken": "ᚻ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 28,
                "glyphID": "sunspire-glyph-28",
                "textToken": "ᚼ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 29,
                "glyphID": "sunspire-glyph-29",
                "textToken": "ᚽ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 30,
                "glyphID": "sunspire-glyph-30",
                "textToken": "ᚾ",
                "vectorResourceID": null
              },
              {
                "canonicalValue": 31,
                "glyphID": "sunspire-glyph-31",
                "textToken": "ᚿ",
                "vectorResourceID": null
              }
            ],
            "fontResourceID": "resource.script.sunspire.output.script-font",
            "fontReferenceID": "rs-sunspire",
            "fontVersion": 1,
            "fontPostScriptName": "RavenForgeSunspireScript-Regular",
            "staticFallbackResourceID": "resource.script.sunspire.output.script-static-fallback",
            "fallbackScriptID": "script.base-runes",
            "recommendedPointSizes": {
              "minimum": 12.0,
              "maximum": 64.0
            },
            "accessibility": {
              "label": {
                "key": "resource.script.sunspire.accessibility.label",
                "fallbackValue": "Sunspire Codex script with complete static renderer fallback."
              },
              "hint": null,
              "hidesRedundantGlyphs": true,
              "noColorOnlyState": true,
              "dynamicTypeSafe": true
            },
        "rightsID": "prov.Project.Script.Calligraphic.sunspire.v1"
          }
        ],
        "relics": [
          {
            "metadata": {
              "id": "relic.sunspire.dawnfire-tablet",
              "codexID": "codex.sunspire",
              "displayName": {
                "key": "relic.sunspire.dawnfire-tablet.name",
                "fallbackValue": "Dawnfire Tablet"
              },
              "description": {
                "key": "relic.sunspire.dawnfire-tablet.description",
                "fallbackValue": "A luminous default Relic balancing ceremonial stature with generous inscription capacity."
              },
              "rarity": "forged",
              "availability": "included",
              "accessibility": {
                "label": {
                  "key": "resource.relic.sunspire.dawnfire-tablet.accessibility.label",
                  "fallbackValue": "A warm ivory tablet framed in gold leaves and crowned by a radiant sun medallion."
                },
                "hint": null,
                "hidesRedundantGlyphs": true,
                "noColorOnlyState": true,
                "dynamicTypeSafe": true
              },
              "rightsID": "prov.Source.Masters.Relic.Geometry.sunspire.dawnfire.tablet.geometry.svg"
            },
            "isDefault": true,
            "primaryResourceID": "resource.relic.sunspire.dawnfire-tablet.output.relic-master",
            "thumbnailResourceID": "resource.relic.sunspire.dawnfire-tablet.output.relic-thumbnail",
            "staticFallbackResourceID": "resource.relic.sunspire.dawnfire-tablet.output.relic-static-share-fallback",
            "highContrastResourceID": "resource.relic.sunspire.dawnfire-tablet.output.relic-high-contrast",
            "defaultLayoutID": "layout-profile.relic.sunspire.dawnfire-tablet",
            "layouts": [
              {
                "id": "layout-profile.relic.sunspire.dawnfire-tablet",
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
                  "x": 0.18000000000000002,
                  "y": 0.21000000000000002,
                  "width": 0.64,
                  "height": 0.54
                },
                "glyphSafeRegion": {
                  "x": 0.2,
                  "y": 0.23,
                  "width": 0.6,
                  "height": 0.5
                },
                "sealAnchors": [
                  {
                    "category": "lowerRight",
                    "point": {
                      "x": 0.82,
                      "y": 0.771875
                    }
                  },
                  {
                    "category": "lowerLeft",
                    "point": {
                      "x": 0.18,
                      "y": 0.771875
                    }
                  }
                ],
                "maximumGlyphLines": 6,
                "catalogSpecimenRows": 3,
                "catalogSpecimenColumns": 6,
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
          },
          {
            "metadata": {
              "id": "relic.sunspire.solvine-plaque",
              "codexID": "codex.sunspire",
              "displayName": {
                "key": "relic.sunspire.solvine-plaque.name",
                "fallbackValue": "Solvine Plaque"
              },
              "description": {
                "key": "relic.sunspire.solvine-plaque.description",
                "fallbackValue": "A compact radiant plaque for short and medium messages with stronger ornamental density."
              },
              "rarity": "inscribed",
              "availability": "earned",
              "accessibility": {
                "label": {
                  "key": "resource.relic.sunspire.solvine-plaque.accessibility.label",
                  "fallbackValue": "A square ivory plaque covered in gold sunleaf vines and a small sun emblem."
                },
                "hint": null,
                "hidesRedundantGlyphs": true,
                "noColorOnlyState": true,
                "dynamicTypeSafe": true
              },
              "rightsID": "prov.Source.Masters.Relic.Geometry.sunspire.solvine.plaque.geometry.svg"
            },
            "isDefault": false,
            "primaryResourceID": "resource.relic.sunspire.solvine-plaque.output.relic-master",
            "thumbnailResourceID": "resource.relic.sunspire.solvine-plaque.output.relic-thumbnail",
            "staticFallbackResourceID": "resource.relic.sunspire.solvine-plaque.output.relic-static-share-fallback",
            "highContrastResourceID": "resource.relic.sunspire.solvine-plaque.output.relic-high-contrast",
            "defaultLayoutID": "layout-profile.relic.sunspire.solvine-plaque",
            "layouts": [
              {
                "id": "layout-profile.relic.sunspire.solvine-plaque",
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
                  "height": 0.5
                },
                "glyphSafeRegion": {
                  "x": 0.18,
                  "y": 0.23,
                  "width": 0.64,
                  "height": 0.46
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
              "id": "relic.sunspire.auric-stele",
              "codexID": "codex.sunspire",
              "displayName": {
                "key": "relic.sunspire.auric-stele.name",
                "fallbackValue": "Auric Stele"
              },
              "description": {
                "key": "relic.sunspire.auric-stele.description",
                "fallbackValue": "A prestigious vertical Relic designed for formal long inscriptions."
              },
              "rarity": "rare",
              "availability": "earned",
              "accessibility": {
                "label": {
                  "key": "resource.relic.sunspire.auric-stele.accessibility.label",
                  "fallbackValue": "A tall arched ivory stele glowing with gold rays and resting on a small pedestal."
                },
                "hint": null,
                "hidesRedundantGlyphs": true,
                "noColorOnlyState": true,
                "dynamicTypeSafe": true
              },
              "rightsID": "prov.Source.Masters.Relic.Geometry.sunspire.auric.stele.geometry.svg"
            },
            "isDefault": false,
            "primaryResourceID": "resource.relic.sunspire.auric-stele.output.relic-master",
            "thumbnailResourceID": "resource.relic.sunspire.auric-stele.output.relic-thumbnail",
            "staticFallbackResourceID": "resource.relic.sunspire.auric-stele.output.relic-static-share-fallback",
            "highContrastResourceID": "resource.relic.sunspire.auric-stele.output.relic-high-contrast",
            "defaultLayoutID": "layout-profile.relic.sunspire.auric-stele",
            "layouts": [
              {
                "id": "layout-profile.relic.sunspire.auric-stele",
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
                  "x": 0.27999999999999997,
                  "y": 0.18000000000000002,
                  "width": 0.44,
                  "height": 0.6000000000000001
                },
                "glyphSafeRegion": {
                  "x": 0.3,
                  "y": 0.2,
                  "width": 0.4,
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
              "id": "seal.sunspire.sunleaf-crest",
              "codexID": "codex.sunspire",
              "displayName": {
                "key": "seal.sunspire.sunleaf-crest.name",
                "fallbackValue": "Sunleaf Crest"
              },
              "description": {
                "key": "seal.sunspire.sunleaf-crest.description",
                "fallbackValue": "The foundational Sunspire emblem of light joined with living growth."
              },
              "rarity": "forged",
              "availability": "included",
              "accessibility": {
                "label": {
                  "key": "resource.seal.sunspire.sunleaf-crest.accessibility.label",
                  "fallbackValue": "A round sun surrounded by eight leaf-shaped rays."
                },
                "hint": null,
                "hidesRedundantGlyphs": true,
                "noColorOnlyState": true,
                "dynamicTypeSafe": true
              },
              "rightsID": "prov.Source.Masters.Seals.sunspire.sunleaf.crest.svg"
            },
            "vectorResourceID": "resource.seal.sunspire.sunleaf-crest.output.seal-vector-master",
            "colorResourceID": "resource.seal.sunspire.sunleaf-crest.output.seal-color-master",
            "monochromeFallbackResourceID": "resource.seal.sunspire.sunleaf-crest.output.seal-monochrome-fallback",
            "thumbnailResourceID": "resource.seal.sunspire.sunleaf-crest.output.seal-thumbnail",
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
              "id": "seal.sunspire.golden-lark",
              "codexID": "codex.sunspire",
              "displayName": {
                "key": "seal.sunspire.golden-lark.name",
                "fallbackValue": "Golden Lark"
              },
              "description": {
                "key": "seal.sunspire.golden-lark.description",
                "fallbackValue": "A mark of messages carried openly and joyfully into the dawn."
              },
              "rarity": "forged",
              "availability": "included",
              "accessibility": {
                "label": {
                  "key": "resource.seal.sunspire.golden-lark.accessibility.label",
                  "fallbackValue": "A small golden songbird inside a ring with two leaves."
                },
                "hint": null,
                "hidesRedundantGlyphs": true,
                "noColorOnlyState": true,
                "dynamicTypeSafe": true
              },
              "rightsID": "prov.Source.Masters.Seals.sunspire.golden.lark.svg"
            },
            "vectorResourceID": "resource.seal.sunspire.golden-lark.output.seal-vector-master",
            "colorResourceID": "resource.seal.sunspire.golden-lark.output.seal-color-master",
            "monochromeFallbackResourceID": "resource.seal.sunspire.golden-lark.output.seal-monochrome-fallback",
            "thumbnailResourceID": "resource.seal.sunspire.golden-lark.output.seal-thumbnail",
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
              "id": "seal.sunspire.dawnflower",
              "codexID": "codex.sunspire",
              "displayName": {
                "key": "seal.sunspire.dawnflower.name",
                "fallbackValue": "Dawnflower"
              },
              "description": {
                "key": "seal.sunspire.dawnflower.description",
                "fallbackValue": "A first-dispatch reward representing the beginning of radiant correspondence."
              },
              "rarity": "inscribed",
              "availability": "earned",
              "accessibility": {
                "label": {
                  "key": "resource.seal.sunspire.dawnflower.accessibility.label",
                  "fallbackValue": "A five-petal flower opening around a small sun."
                },
                "hint": null,
                "hidesRedundantGlyphs": true,
                "noColorOnlyState": true,
                "dynamicTypeSafe": true
              },
              "rightsID": "prov.Source.Masters.Seals.sunspire.dawnflower.svg"
            },
            "vectorResourceID": "resource.seal.sunspire.dawnflower.output.seal-vector-master",
            "colorResourceID": "resource.seal.sunspire.dawnflower.output.seal-color-master",
            "monochromeFallbackResourceID": "resource.seal.sunspire.dawnflower.output.seal-monochrome-fallback",
            "thumbnailResourceID": "resource.seal.sunspire.dawnflower.output.seal-thumbnail",
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
              "id": "seal.sunspire.sunwheel",
              "codexID": "codex.sunspire",
              "displayName": {
                "key": "seal.sunspire.sunwheel.name",
                "fallbackValue": "Sunwheel"
              },
              "description": {
                "key": "seal.sunspire.sunwheel.description",
                "fallbackValue": "A receiving mark representing reciprocal light and returned words."
              },
              "rarity": "inscribed",
              "availability": "earned",
              "accessibility": {
                "label": {
                  "key": "resource.seal.sunspire.sunwheel.accessibility.label",
                  "fallbackValue": "An eight-spoke sun wheel with leaves at the ends."
                },
                "hint": null,
                "hidesRedundantGlyphs": true,
                "noColorOnlyState": true,
                "dynamicTypeSafe": true
              },
              "rightsID": "prov.Source.Masters.Seals.sunspire.sunwheel.svg"
            },
            "vectorResourceID": "resource.seal.sunspire.sunwheel.output.seal-vector-master",
            "colorResourceID": "resource.seal.sunspire.sunwheel.output.seal-color-master",
            "monochromeFallbackResourceID": "resource.seal.sunspire.sunwheel.output.seal-monochrome-fallback",
            "thumbnailResourceID": "resource.seal.sunspire.sunwheel.output.seal-thumbnail",
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
              "id": "seal.sunspire.radiant-spire",
              "codexID": "codex.sunspire",
              "displayName": {
                "key": "seal.sunspire.radiant-spire.name",
                "fallbackValue": "Radiant Spire"
              },
              "description": {
                "key": "seal.sunspire.radiant-spire.description",
                "fallbackValue": "A noble mark for sustained Sunspire use and elevated standing."
              },
              "rarity": "rare",
              "availability": "earned",
              "accessibility": {
                "label": {
                  "key": "resource.seal.sunspire.radiant-spire.accessibility.label",
                  "fallbackValue": "A slender golden spire with three sun rays rising behind it."
                },
                "hint": null,
                "hidesRedundantGlyphs": true,
                "noColorOnlyState": true,
                "dynamicTypeSafe": true
              },
              "rightsID": "prov.Source.Masters.Seals.sunspire.radiant.spire.svg"
            },
            "vectorResourceID": "resource.seal.sunspire.radiant-spire.output.seal-vector-master",
            "colorResourceID": "resource.seal.sunspire.radiant-spire.output.seal-color-master",
            "monochromeFallbackResourceID": "resource.seal.sunspire.radiant-spire.output.seal-monochrome-fallback",
            "thumbnailResourceID": "resource.seal.sunspire.radiant-spire.output.seal-thumbnail",
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
              "id": "seal.sunspire.echo-ember",
              "codexID": "codex.sunspire",
              "displayName": {
                "key": "seal.sunspire.echo-ember.name",
                "fallbackValue": "Echo Ember"
              },
              "description": {
                "key": "seal.sunspire.echo-ember.description",
                "fallbackValue": "An encounter mark carried from another Scribe’s Sunspire presentation."
              },
              "rarity": "rare",
              "availability": "encountered",
              "accessibility": {
                "label": {
                  "key": "resource.seal.sunspire.echo-ember.accessibility.label",
                  "fallbackValue": "A glowing ember inside two circular rings."
                },
                "hint": null,
                "hidesRedundantGlyphs": true,
                "noColorOnlyState": true,
                "dynamicTypeSafe": true
              },
              "rightsID": "prov.Source.Masters.Seals.sunspire.echo.ember.svg"
            },
            "vectorResourceID": "resource.seal.sunspire.echo-ember.output.seal-vector-master",
            "colorResourceID": "resource.seal.sunspire.echo-ember.output.seal-color-master",
            "monochromeFallbackResourceID": "resource.seal.sunspire.echo-ember.output.seal-monochrome-fallback",
            "thumbnailResourceID": "resource.seal.sunspire.echo-ember.output.seal-thumbnail",
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
              "id": "frame.sunspire.laurel-of-dawn",
              "codexID": "codex.sunspire",
              "displayName": {
                "key": "frame.sunspire.laurel-of-dawn.name",
                "fallbackValue": "Laurel of Dawn"
              },
              "description": {
                "key": "frame.sunspire.laurel-of-dawn.description",
                "fallbackValue": "Thin gold laurel branches, four sun nodes, restrained ivory enamel, and no intrusion into safe regions."
              },
              "rarity": "mythic",
              "availability": "mastery",
              "accessibility": {
                "label": {
                  "key": "resource.frame.sunspire.laurel-of-dawn.accessibility.label",
                  "fallbackValue": "Thin gold laurel branches, four sun nodes, restrained ivory enamel, and no intrusion into safe regions."
                },
                "hint": null,
                "hidesRedundantGlyphs": true,
                "noColorOnlyState": true,
                "dynamicTypeSafe": true
              },
              "rightsID": "prov.Source.Masters.Frames.sunspire.laurel.of.dawn.svg"
            },
            "vectorResourceID": "resource.frame.sunspire.laurel-of-dawn.output.frame-vector-master",
            "staticFallbackResourceID": "resource.frame.sunspire.laurel-of-dawn.output.frame-static-fallback",
            "thumbnailResourceID": "resource.frame.sunspire.laurel-of-dawn.output.frame-thumbnail",
            "compatibleRelicIDs": [
              "relic.sunspire.dawnfire-tablet",
              "relic.sunspire.solvine-plaque",
              "relic.sunspire.auric-stele"
            ],
            "allowsStaticShare": true
          }
        ],
        "crests": [
          {
            "metadata": {
              "id": "crest.sunspire.first-light",
              "codexID": "codex.sunspire",
              "displayName": {
                "key": "crest.sunspire.first-light.name",
                "fallbackValue": "First Light Crest"
              },
              "description": {
                "key": "crest.sunspire.first-light.description",
                "fallbackValue": "A rising sun above one open leaf crown, contained in a clean circular gold crest."
              },
              "rarity": "mythic",
              "availability": "mastery",
              "accessibility": {
                "label": {
                  "key": "resource.crest.sunspire.first-light.accessibility.label",
                  "fallbackValue": "A rising sun above one open leaf crown, contained in a clean circular gold crest."
                },
                "hint": null,
                "hidesRedundantGlyphs": true,
                "noColorOnlyState": true,
                "dynamicTypeSafe": true
              },
              "rightsID": "prov.Source.Masters.Crests.sunspire.first.light.svg"
            },
            "vectorResourceID": "resource.crest.sunspire.first-light.output.crest-vector-master",
            "staticFallbackResourceID": "resource.crest.sunspire.first-light.output.crest-static-fallback"
          }
        ],
        "background": {
          "id": "background.sunspire.hall-of-first-light",
          "displayName": {
            "key": "background.sunspire.hall-of-first-light.name",
            "fallbackValue": "Hall of First Light"
          },
          "staticBaseResourceID": "resource.background.sunspire.hall-of-first-light.output.background-static-base",
          "reduceMotionResourceID": "resource.background.sunspire.hall-of-first-light.output.background-reduce-motion",
          "highContrastResourceID": "resource.background.sunspire.hall-of-first-light.output.background-high-contrast",
          "optionalMotionResourceID": null,
          "rendererParametersResourceID": null,
          "motionIntensity": "none",
          "performanceClass": "standard",
          "parallaxAllowed": false,
          "accessibility": {
            "label": {
              "key": "resource.background.sunspire.hall-of-first-light.accessibility.label",
              "fallbackValue": "Abstracted sunlit court: warm shafts, ivory-gold botanical forms, distant arches without identifiable franchise architecture."
            },
            "hint": null,
            "hidesRedundantGlyphs": true,
            "noColorOnlyState": true,
            "dynamicTypeSafe": true
          },
          "rightsID": "prov.Production.Sources.sunspire.sunspire.background.recipe.json"
        },
        "vault": {
          "id": "card.sunspire.codex",
          "grouping": {
            "key": "vault.sunspire.grouping",
            "fallbackValue": "Elven Series"
          },
          "cardResourceID": "resource.vault.sunspire.codex.output.vault-card",
          "lockedSilhouetteResourceID": "resource.vault.sunspire.codex.output.vault-locked-silhouette",
          "encounteredResourceID": "resource.vault.sunspire.codex.output.vault-encountered",
          "selectedResourceID": "resource.vault.sunspire.codex.output.vault-selected",
          "accessibility": {
            "label": {
              "key": "resource.vault.sunspire.codex.accessibility.label",
              "fallbackValue": "Sunspire Codex locked, encountered, owned, and selected presentation."
            },
            "hint": null,
            "hidesRedundantGlyphs": true,
            "noColorOnlyState": true,
            "dynamicTypeSafe": true
          },
          "rightsID": "prov.Production.Sources.sunspire.sunspire.vault.recipe.json"
        },
        "rightsID": "prov.Production.Sources.sunspire.sunspire.background.recipe.json"
      },
      "resources": [],
      "localizations": [
        {
          "localeIdentifier": "en-US",
          "stringsResourceID": "resource.localization.sunspire.control"
        }
      ],
      "defaultLocaleIdentifier": "en-US",
      "rights": [
        {
          "id": "prov.Project.Script.Calligraphic.sunspire.v1",
          "creatorTool": "Python 3 with fontTools 4.60.2 and Pillow 11.3.0",
          "creationDate": "2026-09-15",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "scripts/make-elven-calligraphic-fonts.py",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/make-elven-calligraphic-fonts.py\",\"styleReference\":\"owner-supplied visual reference, 2026-09-15\"}",
          "licenseNotice": "Owner-supplied visual direction and proprietary project-local outlines"
        },
        {
          "id": "prov.Production.Sources.sunspire.sunspire.background.recipe.json",
          "creatorTool": "Python 3.9.6 with Pillow 11.3.0 and fontTools 4.60.2",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "owner-approved production design and manifest direction",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        },
        {
          "id": "prov.Production.Sources.sunspire.accepted.source.masters.recipe.json",
          "creatorTool": "Pinned deterministic v4.3 asset builder",
          "creationDate": "2026-08-27",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "docs/verification/theme-fidelity-v4-3/inventory/recipes/Sunspire-Accepted-Source-Master-Recipe-v4.3.json",
          "exportSettings": "{\"deterministic\":true,\"ownerReview\":\"PENDING\",\"pipeline\":\"scripts/build-sunspire-wildwood-gloamthorn-v43-assets.py\"}",
          "licenseNotice": "Project-local proprietary production masters; owner visual review remains pending"
        },
        {
          "id": "prov.Production.Sources.sunspire.sunspire.vault.recipe.json",
          "creatorTool": "Python 3.9.6 with Pillow 11.3.0 and fontTools 4.60.2",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "owner-approved production design and manifest direction",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        },
        {
          "id": "prov.Source.Masters.Frames.sunspire.laurel.of.dawn.svg",
          "creatorTool": "Python 3.9.6 with Pillow 11.3.0 and fontTools 4.60.2",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "/Users/jimdaley/Documents/RavenForge/RuneScribe/Rune-Scribe-Elven-Series-Design-Package-v1.0/Source-Masters/Frames/sunspire/laurel-of-dawn.svg",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        },
        {
          "id": "prov.Source.Masters.Crests.sunspire.first.light.svg",
          "creatorTool": "Python 3.9.6 with Pillow 11.3.0 and fontTools 4.60.2",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "/Users/jimdaley/Documents/RavenForge/RuneScribe/Rune-Scribe-Elven-Series-Design-Package-v1.0/Source-Masters/Crests/sunspire/first-light.svg",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        },
        {
          "id": "prov.Source.Masters.Relic.Geometry.sunspire.dawnfire.tablet.geometry.svg",
          "creatorTool": "Python 3.9.6 with Pillow 11.3.0 and fontTools 4.60.2",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "/Users/jimdaley/Documents/RavenForge/RuneScribe/Rune-Scribe-Elven-Series-Design-Package-v1.0/Source-Masters/Relic-Geometry/sunspire/dawnfire-tablet-geometry.svg",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        },
        {
          "id": "prov.Source.Masters.Relic.Geometry.sunspire.solvine.plaque.geometry.svg",
          "creatorTool": "Python 3.9.6 with Pillow 11.3.0 and fontTools 4.60.2",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "/Users/jimdaley/Documents/RavenForge/RuneScribe/Rune-Scribe-Elven-Series-Design-Package-v1.0/Source-Masters/Relic-Geometry/sunspire/solvine-plaque-geometry.svg",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        },
        {
          "id": "prov.Source.Masters.Relic.Geometry.sunspire.auric.stele.geometry.svg",
          "creatorTool": "macOS byte-preserving canonicalization with Python 3.9.6 hashing",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "/Users/jimdaley/Documents/RavenForge/RuneScribe/Rune-Scribe-Elven-Series-Design-Package-v1.0/Source-Masters/Relic-Geometry/sunspire/auric-stele-geometry.svg",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        },
        {
          "id": "prov.Source.Masters.Seals.sunspire.sunleaf.crest.svg",
          "creatorTool": "macOS byte-preserving canonicalization with Python 3.9.6 hashing",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "/Users/jimdaley/Documents/RavenForge/RuneScribe/Rune-Scribe-Elven-Series-Design-Package-v1.0/Source-Masters/Seals/sunspire/sunleaf-crest.svg",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        },
        {
          "id": "prov.Source.Masters.Seals.sunspire.golden.lark.svg",
          "creatorTool": "macOS byte-preserving canonicalization with Python 3.9.6 hashing",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "/Users/jimdaley/Documents/RavenForge/RuneScribe/Rune-Scribe-Elven-Series-Design-Package-v1.0/Source-Masters/Seals/sunspire/golden-lark.svg",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        },
        {
          "id": "prov.Source.Masters.Seals.sunspire.dawnflower.svg",
          "creatorTool": "macOS byte-preserving canonicalization with Python 3.9.6 hashing",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "/Users/jimdaley/Documents/RavenForge/RuneScribe/Rune-Scribe-Elven-Series-Design-Package-v1.0/Source-Masters/Seals/sunspire/dawnflower.svg",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        },
        {
          "id": "prov.Source.Masters.Seals.sunspire.sunwheel.svg",
          "creatorTool": "macOS byte-preserving canonicalization with Python 3.9.6 hashing",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "/Users/jimdaley/Documents/RavenForge/RuneScribe/Rune-Scribe-Elven-Series-Design-Package-v1.0/Source-Masters/Seals/sunspire/sunwheel.svg",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        },
        {
          "id": "prov.Source.Masters.Seals.sunspire.radiant.spire.svg",
          "creatorTool": "macOS byte-preserving canonicalization with Python 3.9.6 hashing",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "/Users/jimdaley/Documents/RavenForge/RuneScribe/Rune-Scribe-Elven-Series-Design-Package-v1.0/Source-Masters/Seals/sunspire/radiant-spire.svg",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        },
        {
          "id": "prov.Source.Masters.Seals.sunspire.echo.ember.svg",
          "creatorTool": "macOS byte-preserving canonicalization with Python 3.9.6 hashing",
          "creationDate": "2026-08-21",
          "origin": "derived",
          "rightsOwner": "Raven Forge Software",
          "sourceReference": "/Users/jimdaley/Documents/RavenForge/RuneScribe/Rune-Scribe-Elven-Series-Design-Package-v1.0/Source-Masters/Seals/sunspire/echo-ember.svg",
          "exportSettings": "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}",
          "licenseNotice": "Owner-supplied proprietary source and approved recovery authority"
        }
      ]
    }
    """#
}

private enum SunspireThemeDescriptorError: Error {
    case invalidSeed
}

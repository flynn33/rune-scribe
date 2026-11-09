// Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/ProductContent/AppLicense.swift

import Foundation

/// The Apache License 2.0 notice shown in Settings → View License.
///
/// The canonical terms are the LICENSE file at the repository root.
enum AppLicense {

    static let appName = "Rune Scribe"
    static let company = "Raven Forge Software"
    static let lastUpdated = "November 2026"

    static let text: String = """
    RUNE SCRIBE
    APACHE LICENSE, VERSION 2.0

    Last updated: \(lastUpdated)

    \(appName) is licensed under the Apache License, Version 2.0 (the "License").
    You may obtain a copy of the License at

        http://www.apache.org/licenses/LICENSE-2.0

    The full terms are in the LICENSE file distributed with the source.

    Copyright 2026 \(company)

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

        http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.

    The bundled Noto Sans Runic font is used under the SIL Open Font License
    and remains the property of its copyright holders.
    """
}

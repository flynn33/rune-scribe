// Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/ProductContent/AppLicense.swift

import Foundation

/// The proprietary End-User License Agreement shown in Settings → View License.
///
/// This is a custom EULA. It is written to meet or exceed the minimum terms Apple
/// requires of any developer who supplies their own agreement (Apple's "Instructions
/// for Minimum Terms of Developer's End-User License Agreement"), so it is suitable
/// for distribution through the Apple App Store and the Mac App Store. The same text
/// is mirrored in `EULA.md` at the repository root for App Store Connect.
enum AppLicense {

    static let appName = "Rune Scribe"
    static let company = "Raven Forge Software"
    static let lastUpdated = "June 2026"

    static let text: String = """
    RUNE SCRIBE
    END-USER LICENSE AGREEMENT

    Last updated: \(lastUpdated)

    This End-User License Agreement ("Agreement") is a binding agreement between you
    ("You" or "Licensee") and \(company) ("Licensor", "we", "us", or "our"). It
    governs your use of the \(appName) software application, together with all
    associated documentation, updates, and content (collectively, the "Application").

    By downloading, installing, or using the Application, you agree to be bound by
    this Agreement. If you do not agree, do not download, install, or use the
    Application.

    The Application is licensed, not sold, to you.

    1. ACKNOWLEDGEMENT
    This Agreement is concluded between You and \(company) only, and not with Apple
    Inc. ("Apple"). \(company), not Apple, is solely responsible for the Application
    and its content. Apple has no obligation whatsoever to furnish any maintenance or
    support services with respect to the Application.

    2. SCOPE OF LICENSE
    \(company) grants you a personal, limited, non-exclusive, non-transferable,
    revocable license to download, install, and use the Application solely for your
    own personal, non-commercial purposes, on any Apple-branded device that you own or
    control, and as permitted by the Usage Rules set forth in the Apple Media Services
    Terms and Conditions and the Apple App Store Terms of Service. This license does
    not allow you to use the Application on any device that you do not own or control,
    and except as permitted by Apple Family Sharing, you may not distribute or make the
    Application available over a network where it could be used by multiple devices at
    the same time.

    3. RESTRICTIONS
    You may not, and may not permit others to: (a) copy (except as expressly permitted
    by this license), modify, adapt, translate, or create derivative works of the
    Application; (b) reverse engineer, decompile, disassemble, or otherwise attempt to
    derive the source code of the Application, except to the extent such restriction is
    prohibited by applicable law; (c) rent, lease, lend, sell, sublicense, assign,
    distribute, publish, or otherwise commercially exploit the Application; (d) remove,
    alter, or obscure any proprietary notice; or (e) use the Application in any unlawful
    manner or for any unlawful purpose.

    4. OWNERSHIP AND INTELLECTUAL PROPERTY
    The Application, including all intellectual property rights therein, is and shall
    remain the exclusive property of \(company) and its licensors. All rights not
    expressly granted to you are reserved. The "Noto Sans Runic" font bundled with the
    Application is licensed under the SIL Open Font License and remains the property of
    its respective copyright holders.

    5. YOUR CONTENT AND PRIVACY
    The Application performs its substitution-cipher encoding and decoding entirely on
    your device. Your messages and your cipher keys are stored only on your device
    (cipher keys are kept encrypted in the device Keychain) and are not transmitted to,
    or collected by, \(company). You are solely responsible for the content you encode
    and for safeguarding any decoder files you export. The Application is an obfuscation
    and personal-privacy tool and is not intended to provide guaranteed or military-grade
    security; do not rely on it to protect information whose disclosure could cause
    serious harm.

    6. MAINTENANCE AND SUPPORT
    \(company) is solely responsible for providing any maintenance and support services
    with respect to the Application, as required under applicable law. You acknowledge
    that Apple has no obligation whatsoever to furnish any maintenance and support
    services with respect to the Application.

    7. WARRANTY
    The Application is provided "AS IS" and "AS AVAILABLE", without warranty of any
    kind. To the maximum extent permitted by applicable law, \(company) disclaims all
    warranties, whether express, implied, or statutory, including any implied warranties
    of merchantability, fitness for a particular purpose, and non-infringement. In the
    event of any failure of the Application to conform to any applicable warranty, you
    may notify Apple, and Apple will refund the purchase price (if any) for the
    Application to you; to the maximum extent permitted by applicable law, Apple will
    have no other warranty obligation whatsoever with respect to the Application, and
    any other claims, losses, liabilities, damages, costs, or expenses attributable to
    any failure to conform to any warranty will be \(company)'s sole responsibility.

    8. LIMITATION OF LIABILITY
    To the maximum extent permitted by applicable law, in no event will \(company) be
    liable for any indirect, incidental, special, consequential, or punitive damages, or
    any loss of data, use, goodwill, or profits, arising out of or related to your use
    of, or inability to use, the Application.

    9. PRODUCT CLAIMS
    \(company), not Apple, is responsible for addressing any claims by you or any third
    party relating to the Application or your possession and/or use of the Application,
    including, but not limited to: (a) product liability claims; (b) any claim that the
    Application fails to conform to any applicable legal or regulatory requirement; and
    (c) claims arising under consumer protection, privacy, or similar legislation.

    10. INTELLECTUAL PROPERTY RIGHTS CLAIMS
    In the event of any third-party claim that the Application or your possession and use
    of the Application infringes that third party's intellectual property rights,
    \(company), not Apple, will be solely responsible for the investigation, defense,
    settlement, and discharge of any such intellectual property infringement claim.

    11. LEGAL COMPLIANCE
    You represent and warrant that (a) you are not located in a country that is subject
    to a U.S. Government embargo, or that has been designated by the U.S. Government as a
    "terrorist supporting" country; and (b) you are not listed on any U.S. Government
    list of prohibited or restricted parties.

    12. THIRD-PARTY TERMS
    You must comply with applicable third-party terms of agreement when using the
    Application.

    13. THIRD-PARTY BENEFICIARY
    You acknowledge and agree that Apple, and Apple's subsidiaries, are third-party
    beneficiaries of this Agreement, and that, upon your acceptance of this Agreement,
    Apple will have the right (and will be deemed to have accepted the right) to enforce
    this Agreement against you as a third-party beneficiary thereof.

    14. TERM AND TERMINATION
    This Agreement is effective until terminated. Your rights under this Agreement will
    terminate automatically without notice if you fail to comply with any of its terms.
    Upon termination, you must cease all use of the Application and delete all copies.

    15. GOVERNING LAW
    Except to the extent expressly provided otherwise, this Agreement and your use of the
    Application are governed by the laws of the jurisdiction in which \(company) is
    established, without regard to its conflict-of-laws provisions, and excluding the
    United Nations Convention on Contracts for the International Sale of Goods.

    16. CONTACT
    If you have any questions, complaints, or claims with respect to the Application,
    they should be directed to \(company) at: support@ravenforgesoftware.com.

    © \(Calendar.current.component(.year, from: Date())) \(company). All rights reserved.
    """
}

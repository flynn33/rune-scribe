import XCTest
import Contacts
@testable import RuneScrib

final class ContactImporterTests: XCTestCase {
    func testSnapshotMapsNamePhonesEmails() {
        let cn = CNMutableContact()
        cn.givenName = "Freya"; cn.familyName = "Day"
        cn.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: "+15550001"))]
        cn.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: "freya@x.com" as NSString)]
        let c = ContactImporter.snapshot(from: cn)
        XCTAssertEqual(c.displayName, "Freya Day")
        XCTAssertEqual(c.phones, ["+15550001"])
        XCTAssertEqual(c.emails, ["freya@x.com"])
        XCTAssertEqual(c.appleContactID, cn.identifier)
        XCTAssertEqual(c.source, .imported)
    }

    func testSnapshotWithNoNameFallsBackToUnnamed() {
        let cn = CNMutableContact()   // no name fields set
        XCTAssertEqual(ContactImporter.snapshot(from: cn).displayName, "Unnamed")
    }

    func testSnapshotWithNoPhonesOrEmailsMapsToEmptyArrays() {
        let cn = CNMutableContact()
        cn.givenName = "Solo"
        let c = ContactImporter.snapshot(from: cn)
        XCTAssertEqual(c.displayName, "Solo")
        XCTAssertEqual(c.phones, [])
        XCTAssertEqual(c.emails, [])
    }
}

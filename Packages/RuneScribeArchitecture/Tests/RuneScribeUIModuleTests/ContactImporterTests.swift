#if os(iOS)
import Contacts
@testable import RuneScribeUIRuntime
import XCTest

final class ContactImporterTests: XCTestCase {
    func testSnapshotMapsNamePhonesEmailsAndIdentifier() {
        let contact = CNMutableContact()
        contact.givenName = "Freya"
        contact.familyName = "Day"
        contact.phoneNumbers = [
            CNLabeledValue(
                label: CNLabelPhoneNumberMobile,
                value: CNPhoneNumber(stringValue: "+15550001")
            ),
        ]
        contact.emailAddresses = [
            CNLabeledValue(label: CNLabelHome, value: "freya@example.com" as NSString),
        ]

        let snapshot = RuntimeSystemContactSnapshot.makeDTO(from: contact)

        XCTAssertEqual(snapshot.displayName, "Freya Day")
        XCTAssertEqual(snapshot.phoneNumbers, ["+15550001"])
        XCTAssertEqual(snapshot.emailAddresses, ["freya@example.com"])
        XCTAssertEqual(snapshot.systemIdentifier, contact.identifier)
    }

    func testSnapshotWithNoNameFallsBackToUnnamed() {
        XCTAssertEqual(
            RuntimeSystemContactSnapshot.makeDTO(
                from: CNMutableContact()
            ).displayName,
            "Unnamed"
        )
    }

    func testSnapshotWithoutChannelsUsesEmptyArrays() {
        let contact = CNMutableContact()
        contact.givenName = "Solo"

        let snapshot = RuntimeSystemContactSnapshot.makeDTO(from: contact)

        XCTAssertEqual(snapshot.displayName, "Solo")
        XCTAssertTrue(snapshot.phoneNumbers.isEmpty)
        XCTAssertTrue(snapshot.emailAddresses.isEmpty)
    }

    func testSnapshotIsIndependentOfLaterContactChanges() {
        let contact = CNMutableContact()
        contact.givenName = "Idunn"
        contact.phoneNumbers = [
            CNLabeledValue(
                label: CNLabelPhoneNumberMobile,
                value: CNPhoneNumber(stringValue: "+15550111")
            ),
        ]
        let original = RuntimeSystemContactSnapshot.makeDTO(from: contact)

        contact.givenName = "Changed"
        contact.phoneNumbers = []

        XCTAssertEqual(original.displayName, "Idunn")
        XCTAssertEqual(original.phoneNumbers, ["+15550111"])
        XCTAssertNotEqual(
            RuntimeSystemContactSnapshot.makeDTO(from: contact).displayName,
            original.displayName
        )
    }
}
#endif

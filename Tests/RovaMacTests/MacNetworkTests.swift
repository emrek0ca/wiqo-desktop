import XCTest
@testable import RovaMac

final class MacNetworkTests: XCTestCase {
    private func candidate(_ interface: String, _ address: String) -> MacNetwork.Candidate {
        MacNetwork.Candidate(interface: interface, address: address)
    }

    func testPrimaryInterfaceWins() {
        let candidates = [candidate("en0", "192.168.1.20"), candidate("en5", "10.0.0.7")]
        XCTAssertEqual(MacNetwork.preferredAddress(from: candidates, primaryInterface: "en5"), "10.0.0.7")
    }

    func testFallsBackToLowestEthernetOrWifiInterface() {
        let candidates = [candidate("en10", "10.0.0.9"), candidate("en1", "192.168.1.30")]
        XCTAssertEqual(MacNetwork.preferredAddress(from: candidates, primaryInterface: nil), "192.168.1.30")
    }

    func testVirtualAndTunnelInterfacesAreNeverChosen() {
        let candidates = [
            candidate("utun4", "100.101.102.103"),
            candidate("bridge100", "192.168.64.1"),
            candidate("vmnet8", "172.16.5.1"),
            candidate("lo0", "127.0.0.1"),
            candidate("en0", "192.168.1.20")
        ]
        XCTAssertEqual(MacNetwork.preferredAddress(from: candidates, primaryInterface: "utun4"), "192.168.1.20")
    }

    func testNothingUsableReturnsNil() {
        let candidates = [candidate("en0", "169.254.10.4"), candidate("en1", "8.8.8.8"), candidate("utun2", "10.1.1.1")]
        XCTAssertNil(MacNetwork.preferredAddress(from: candidates, primaryInterface: "en0"))
    }

    func testPrivateAddressRanges() {
        for address in ["10.0.0.1", "172.16.0.1", "172.31.255.255", "192.168.0.5", "100.64.0.1", "100.127.1.1"] {
            XCTAssertTrue(MacNetwork.isPrivateAddress(address), address)
        }
        for address in ["172.15.0.1", "172.32.0.1", "100.63.0.1", "100.128.0.1", "169.254.1.1", "8.8.8.8", "1.2.3", "300.1.1.1", "x"] {
            XCTAssertFalse(MacNetwork.isPrivateAddress(address), address)
        }
    }

    func testPhysicalInterfaceNames() {
        XCTAssertTrue(MacNetwork.isPhysicalInterface("en0"))
        XCTAssertTrue(MacNetwork.isPhysicalInterface("en12"))
        for name in ["en", "ens1", "utun3", "bridge0", "awdl0", "lo0", "llw0"] {
            XCTAssertFalse(MacNetwork.isPhysicalInterface(name), name)
        }
    }
}

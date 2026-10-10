import Testing
import Foundation
@testable import Uploader

struct PKCETests {
    @Test func rfcVector() {
        #expect(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
                == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")  // RFC 7636 Appendix B
    }
    @Test func verifierShape() {
        let v = PKCE.makeVerifier()
        #expect(v.count >= 43 && v.count <= 128)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        #expect(v.unicodeScalars.allSatisfy { allowed.contains($0) })
        #expect(PKCE.makeVerifier() != v)
    }
}

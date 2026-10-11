import Foundation

/// Owned synthetic fixtures; tests never need Pillow, cwebp or a WebP encoder.
/// Generated with Pillow12.3.0 PNGs and libwebp1.6.0 cwebp -lossless -exact (lossy: -q75).
/// The 320x160 source has RGBA red/green/blue/yellow quadrants and a transparent20x20 center.
/// Animation: img2webp -loop0 -lossless -d100 frame0.png -d200 cyan-frame1.png.
/// Partial canvas: webpmux first20x10 red at(100,60), second320x160, transparent background.
enum UploadWebPFixture {
    case staticLossless, staticLossy, animated, partialCanvas, small, overAxis

    var data: Data {
        let base64: String
        switch self {
        // 92B SHA256 928519afa0cfc7456bfd64e1abce36b99043b6bbbbe62bdc5f4dbf81c98b146c
        case .staticLossless:
            base64 = "UklGRlQAAABXRUJQVlA4TEcAAAAvP8EnECcgEEjaH3qN+RcQFPk/2vwH8EUC1DSSAmEBC1g4C/iXddWWPBH9n4DGLdz337Ht/RfmqJekjkgHNFzhvv8OZO8/AQA="
        // 580B SHA256 100e5081d947d5f2d6a3219d2ffb4badac0b6e2ea9107da92f4b3d3586e628b2
        case .staticLossy:
            base64 = "UklGRjwCAABXRUJQVlA4WAoAAAAQAAAAPwEAnwAAQUxQSB4AAAABDzD/ERFCQds2TJmVP6cHYkcR/Z+APsAJaDZ8twFWUDgg+AEAAPAYAJ0BKkABoAA+kUigS6WkoyGlG9gAsBIJZ27hc/EDQS/kBpq/yZ/FXrKdp/Bn4Z4qV+A+zP3gf1XCXf7d7OX9m/quqc+gB+lfkAfB7+4Ho5AIWu3or70eZ4RfIKnNrtxXQQVObXb0WAr72fcWq4aYCwFgHiOVObXb0WAsA5hGPKlAia490wFfd73Md+axzHfmscx3K253wG07t2Qeyv1o+IYUFRTsdjsdgb0nS3sLewL6LAV97PuLVcNMBYCwDxHKnNrt6LAWAq66CCpzZoAA/v4aw+tXM+Xe6n4hbqr1yXH1DXu5Zn6Ctc4rgBU7kfrG7+xlf7GV7E3jt00aJcMTgQ/igb4rc6X0WASB3hIdAbbIGDcUrs52xsb7SlOPFrd20w5crs7hL1fPziAKEc5jHqrDoiFHKRzlOeTen1iifmEn9Y6ujpAqAvmkPJXVe/i/WNiQjccjTGeoONtUlAgXSTJORwvmStGjckAFx/Jj/6X+sd1od904e2w4JNOJjf++nExr66Q9H98q4gPLvDxH4Yiiy8fRKliNBMk5jeQG2xcSSWOrAzbAhfwcv+iG30HGO6l6SgObYDXcM0seD4ahzesSPGIh88qoktqChF6qDo8VcYeIJVtsd/quqICHwsSmjYeRzToJHmIBHSrAfhoSIRUcdYAAAA=="
        // 204B SHA256 b50b06f7261a549223399100ba808fbbed5b65298dbd19f42721217a2cdcb327
        case .animated:
            base64 = "UklGRsQAAABXRUJQVlA4WAoAAAASAAAAPwEAnwAAQU5JTQYAAAD/////AABBTk1GYAAAAAAAAAAAAD8BAJ8AAGQAAAJWUDhMRwAAAC8/wScQJyAQSNofeo35FxAU+T/a/AfwRQLUNJICYQELWDgL+Jd11ZY8Ef2fgMYt3Pffse39F+aol6SOSAc0XOG+/w5k7z8BAEFOTUYwAAAAAAAAAAAAPwEAnwAAyAAAAFZQOEwYAAAALz/BJwAH0P/of/8DApLE//+piP6n/e8f"
        // 196B SHA256 48ba6acd332384247e3c685e51de7954f6053fde3ea3a230c0c733b5679584d6
        case .partialCanvas:
            base64 = "UklGRrwAAABXRUJQVlA4WAoAAAASAAAAPwEAnwAAQU5JTQYAAAAAAAAAAABBTk1GKAAAADIAAB4AABMAAAkAAGQAAAJWUDhMDwAAAC8TQAIABxD9j/4HIqL/AQBBTk1GYAAAAAAAAAAAAD8BAJ8AAMgAAAJWUDhMRwAAAC8/wScQJyAQSNofeo35FxAU+T/a/AfwRQLUNJICYQELWDgL+Jd11ZY8Ef2fgMYt3Pffse39F+aol6SOSAc0XOG+/w5k7z8BAA=="
        // 36B SHA256 77f2130344d76654d827912bdc7c82d3d8229ee0bcbbdbee9a4d56ffc62db7a5
        case .small:
            base64 = "UklGRhwAAABXRUJQVlA4TA8AAAAvE0ACAAcQ/Y/+ByKi/wEA"
        // Valid56B WebP of8193x40, beyond the independent decode safety bound.
        // SHA256 06622c8533e754c795dc1c5973e48a5b94fe3009623d83b1a2c90bff9418ea9c
        case .overAxis:
            base64 = "UklGRjAAAABXRUJQVlA4TCQAAAAvAOAJAAcQBSxg/wMCgWR/9QGK6H/Gf/7zn//85z//+c9//g8="
        }
        return Data(base64Encoded: base64)!
    }
}

func writeUploadWebPFixture(_ url: URL, fixture: UploadWebPFixture = .staticLossless) throws {
    try fixture.data.write(to: url)
}

/// Repeat the owned full-canvas frame to test actual native frame-count admission.
func uploadWebPAnimationFixture(frameCount: Int) throws -> Data {
    precondition((1...257).contains(frameCount))
    let source = UploadWebPFixture.animated.data
    var position = 12, header = Data(), frame: Data?
    while position < source.count {
        let length = source[position + 4..<position + 8].enumerated().reduce(0) {
            $0 | Int($1.element) << (8 * $1.offset)
        }
        let end = position + 8 + length + length % 2
        let chunk = source.subdata(in: position..<end)
        if String(decoding: chunk.prefix(4), as: UTF8.self) == "ANMF" {
            if frame == nil { frame = chunk }
        } else { header.append(chunk) }
        position = end
    }
    guard let frame else { throw CocoaError(.fileReadCorruptFile) }
    var payload = header
    for _ in 0..<frameCount { payload.append(frame) }
    var result = Data("RIFF".utf8)
    var length = UInt32(payload.count + 4).littleEndian
    withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
    result.append(Data("WEBP".utf8)); result.append(payload)
    return result
}

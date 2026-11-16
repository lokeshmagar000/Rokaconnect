import Foundation
import CryptoKit
import CommonCrypto

// UKEY2 handshake + D2D SecureMessage channel, written from Google's Apache-2.0 reference
// implementation (github.com/google/ukey2). Used by Android's Nearby Share / Quick Share.

enum NearbyCryptoError: Error { case badMessage(String), badSignature, badSequence, crypto }

enum NearbyCrypto {
    static let nextProtocol = "AES_256_CBC-HMAC_SHA256"
    static let p256Sha512: Int64 = 100
    /// SHA256("D2D")
    static let d2dSalt = Data([0x82, 0xAA, 0x55, 0xA0, 0xD3, 0x97, 0xF8, 0x83, 0x46, 0xCA, 0x1C, 0xEE, 0x8D, 0x39, 0x09, 0xB9,
                               0x5F, 0x13, 0xFA, 0x7D, 0xEB, 0x1D, 0x4A, 0xB3, 0x83, 0x76, 0xB8, 0x25, 0x6D, 0xA8, 0x55, 0x10])
    /// SHA256("SecureMessage")
    static let secureMessageSalt = Data(SHA256.hash(data: Data("SecureMessage".utf8)))

    static func hkdf(_ ikm: Data, salt: Data, info: Data, length: Int = 32) -> Data {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt, info: info, outputByteCount: length)
            .withUnsafeBytes { Data($0) }
    }

    static func aesCBC(_ op: CCOperation, key: Data, iv: Data, _ input: Data) throws -> Data {
        var out = Data(count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let outCap = out.count
        let status = out.withUnsafeMutableBytes { o in
            input.withUnsafeBytes { i in key.withUnsafeBytes { k in iv.withUnsafeBytes { v in
                CCCrypt(op, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                        k.baseAddress, key.count, v.baseAddress, i.baseAddress, input.count, o.baseAddress, outCap, &moved)
            } } }
        }
        guard status == kCCSuccess else { throw NearbyCryptoError.crypto }
        return out.prefix(moved)
    }

    /// Big-endian two's-complement encoding, as Java's BigInteger.toByteArray() produces.
    static func signedBytes(_ d: Data) -> Data {
        var d = d
        while d.count > 1, d.first == 0, let second = d.dropFirst().first, second & 0x80 == 0 { d = d.dropFirst() }
        if let f = d.first, f & 0x80 != 0 { d.insert(0, at: 0) }
        return Data(d)
    }
    static func unsigned32(_ d: Data) -> Data {
        var d = Data(d)
        while d.count > 32, d.first == 0 { d = d.dropFirst() }
        if d.count < 32 { d = Data(repeating: 0, count: 32 - d.count) + d }
        return Data(d)
    }

    /// securemessage.GenericPublicKey { type: EC_P256, ec_p256_public_key { x, y } }
    static func encode(publicKey: P256.KeyAgreement.PublicKey) -> Data {
        let raw = publicKey.x963Representation   // 0x04 || X || Y
        let x = raw.subdata(in: 1..<33), y = raw.subdata(in: 33..<65)
        let ec = PBWriter.build { $0.bytes(1, signedBytes(x)); $0.bytes(2, signedBytes(y)) }
        return PBWriter.build { $0.int(1, 1); $0.message(2, ec) }.data
    }
    static func decodePublicKey(_ d: Data) throws -> P256.KeyAgreement.PublicKey {
        let g = try PBMessage(d)
        guard g.int(1) == 1, let ec = g.message(2), let x = ec.data(1), let y = ec.data(2) else {
            throw NearbyCryptoError.badMessage("public key")
        }
        return try P256.KeyAgreement.PublicKey(x963Representation: Data([4]) + unsigned32(x) + unsigned32(y))
    }

    /// Four-digit confirmation PIN shown on both devices, derived from the UKEY2 auth string.
    static func pin(_ auth: Data) -> String {
        var hash = 0, multiplier = 1
        for byte in auth {
            hash = (hash + Int(Int8(bitPattern: byte)) * multiplier) % 9973
            multiplier = (multiplier * 31) % 9973
        }
        return String(format: "%04d", abs(hash))
    }
}

/// Result of a completed UKEY2 handshake: an encrypted, authenticated, sequenced channel.
final class D2DChannel {
    private let encOut: Data, sigOut: Data, encIn: Data, sigIn: Data
    private var seqOut: Int32 = 0, seqIn: Int32 = 0
    let pin: String

    /// - Parameters: isClient = we sent ClientInit (we are the sender of the connection).
    init(sharedSecret: Data, clientInit: Data, serverInit: Data, isClient: Bool) {
        let dhs = Data(SHA256.hash(data: sharedSecret))
        let info = clientInit + serverInit
        let auth = NearbyCrypto.hkdf(dhs, salt: Data("UKEY2 v1 auth".utf8), info: info)
        let next = NearbyCrypto.hkdf(dhs, salt: Data("UKEY2 v1 next".utf8), info: info)
        let clientKey = NearbyCrypto.hkdf(next, salt: NearbyCrypto.d2dSalt, info: Data("client".utf8))
        let serverKey = NearbyCrypto.hkdf(next, salt: NearbyCrypto.d2dSalt, info: Data("server".utf8))
        func enc(_ k: Data) -> Data { NearbyCrypto.hkdf(k, salt: NearbyCrypto.secureMessageSalt, info: Data("ENC:2".utf8)) }
        func sig(_ k: Data) -> Data { NearbyCrypto.hkdf(k, salt: NearbyCrypto.secureMessageSalt, info: Data("SIG:1".utf8)) }
        let outKey = isClient ? clientKey : serverKey, inKey = isClient ? serverKey : clientKey
        encOut = enc(outKey); sigOut = sig(outKey); encIn = enc(inKey); sigIn = sig(inKey)
        pin = NearbyCrypto.pin(auth)
    }

    func seal(_ message: Data) throws -> Data {
        seqOut += 1
        let d2d = PBWriter.build { $0.bytes(1, message); $0.int(2, Int64(seqOut)) }
        let iv = Data.random(16)
        let body = try NearbyCrypto.aesCBC(CCOperation(kCCEncrypt), key: encOut, iv: iv, d2d.data)
        let meta = PBWriter.build { $0.int(1, 13); $0.int(2, 1) }       // GcmMetadata{DEVICE_TO_DEVICE_MESSAGE, v1}
        let header = PBWriter.build { $0.int(1, 1); $0.int(2, 2); $0.bytes(5, iv); $0.message(6, meta) } // HMAC_SHA256, AES_256_CBC
        let hb = PBWriter.build { $0.message(1, header); $0.bytes(2, body) }
        let mac = Data(HMAC<SHA256>.authenticationCode(for: hb.data, using: SymmetricKey(data: sigOut)))
        return PBWriter.build { $0.bytes(1, hb.data); $0.bytes(2, mac) }.data
    }

    func open(_ secureMessage: Data) throws -> Data {
        let sm = try PBMessage(secureMessage)
        guard let hbData = sm.data(1), let mac = sm.data(2) else { throw NearbyCryptoError.badMessage("SecureMessage") }
        guard HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: hbData, using: SymmetricKey(data: sigIn)) else {
            throw NearbyCryptoError.badSignature
        }
        let hb = try PBMessage(hbData)
        guard let header = hb.message(1), let iv = header.data(5), let body = hb.data(2) else {
            throw NearbyCryptoError.badMessage("HeaderAndBody")
        }
        let plain = try NearbyCrypto.aesCBC(CCOperation(kCCDecrypt), key: encIn, iv: iv, body)
        let d2d = try PBMessage(plain)
        let seq = Int32(truncatingIfNeeded: d2d.int(2) ?? 0)
        guard seq == seqIn + 1 else { throw NearbyCryptoError.badSequence }
        seqIn = seq
        return d2d.data(1) ?? Data()
    }
}

/// One side of a UKEY2 (P256_SHA512) handshake.
final class Ukey2 {
    let key = P256.KeyAgreement.PrivateKey()

    private func wrap(_ type: Int, _ payload: Data) -> Data { PBWriter.build { $0.int(1, type); $0.bytes(2, payload) }.data }
    private func unwrap(_ raw: Data, expect type: Int64) throws -> PBMessage {
        let m = try PBMessage(raw)
        if m.int(1) == 1 { throw NearbyCryptoError.badMessage("peer sent UKEY2 alert") }
        guard m.int(1) == type, let d = m.data(2) else { throw NearbyCryptoError.badMessage("unexpected UKEY2 message") }
        return try PBMessage(d)
    }
    private func secret(with peer: P256.KeyAgreement.PublicKey) throws -> Data {
        try key.sharedSecretFromKeyAgreement(with: peer).withUnsafeBytes { Data($0) }
    }

    // MARK: responder (we received the connection)

    /// Returns (ServerInit to send, a function that consumes ClientFinish and yields the channel).
    func respond(toClientInit raw: Data) throws -> (serverInit: Data, finish: (Data) throws -> D2DChannel) {
        let ci = try unwrap(raw, expect: 2)
        guard ci.int(1) == 1 else { throw NearbyCryptoError.badMessage("UKEY2 version") }
        guard let commitment = ci.messages(3).first(where: { $0.int(1) == NearbyCrypto.p256Sha512 })?.data(2) else {
            throw NearbyCryptoError.badMessage("no P256 cipher")
        }
        let si = PBWriter.build {
            $0.int(1, 1); $0.bytes(2, Data.random(32)); $0.int(3, NearbyCrypto.p256Sha512)
            $0.bytes(4, NearbyCrypto.encode(publicKey: key.publicKey))
        }
        let serverInit = wrap(3, si.data)
        return (serverInit, { finishRaw in
            guard Data(SHA512.hash(data: finishRaw)) == commitment else { throw NearbyCryptoError.badMessage("commitment mismatch") }
            let cf = try self.unwrap(finishRaw, expect: 4)
            guard let pk = cf.data(1) else { throw NearbyCryptoError.badMessage("ClientFinished") }
            let peer = try NearbyCrypto.decodePublicKey(pk)
            return D2DChannel(sharedSecret: try self.secret(with: peer), clientInit: raw, serverInit: serverInit, isClient: false)
        })
    }

    // MARK: initiator (we opened the connection)

    func clientMessages() -> (clientInit: Data, clientFinish: Data) {
        let cf = PBWriter.build { $0.bytes(1, NearbyCrypto.encode(publicKey: key.publicKey)) }
        let clientFinish = wrap(4, cf.data)
        let commitment = PBWriter.build { $0.int(1, NearbyCrypto.p256Sha512); $0.bytes(2, Data(SHA512.hash(data: clientFinish))) }
        let ci = PBWriter.build {
            $0.int(1, 1); $0.bytes(2, Data.random(32)); $0.message(3, commitment); $0.string(4, NearbyCrypto.nextProtocol)
        }
        return (wrap(2, ci.data), clientFinish)
    }

    func channel(clientInit: Data, serverInit raw: Data) throws -> D2DChannel {
        let si = try unwrap(raw, expect: 3)
        guard si.int(3) == NearbyCrypto.p256Sha512, let pk = si.data(4) else { throw NearbyCryptoError.badMessage("ServerInit") }
        let peer = try NearbyCrypto.decodePublicKey(pk)
        return D2DChannel(sharedSecret: try secret(with: peer), clientInit: clientInit, serverInit: raw, isClient: true)
    }
}

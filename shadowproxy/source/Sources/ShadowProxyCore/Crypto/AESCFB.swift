import Foundation
import CommonCrypto

/// AES-128-CFB cipher using CommonCrypto
/// Used by VMess for legacy encryption mode
public struct AESCFB {

    public static func encrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        try crypt(data, key: key, iv: iv, operation: CCOperation(kCCEncrypt))
    }

    public static func decrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        try crypt(data, key: key, iv: iv, operation: CCOperation(kCCDecrypt))
    }

    private static func crypt(_ data: Data, key: Data, iv: Data, operation: CCOperation) throws -> Data {
        guard key.count == kCCKeySizeAES128 || key.count == kCCKeySizeAES256 else {
            throw CryptoError.invalidKeyLength
        }
        guard iv.count == kCCBlockSizeAES128 else {
            throw CryptoError.invalidData
        }

        var cryptor: CCCryptorRef?
        var status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                CCCryptorCreateWithMode(
                    operation,
                    CCMode(kCCModeCFB),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding),
                    ivBytes.baseAddress,
                    keyBytes.baseAddress,
                    key.count,
                    nil, 0, 0,
                    CCModeOptions(kCCModeOptionCTR_BE),
                    &cryptor
                )
            }
        }

        guard status == kCCSuccess, let c = cryptor else {
            throw CryptoError.invalidData
        }
        defer { CCCryptorRelease(c) }

        let outputSize = data.count
        var output = Data(count: outputSize)
        var moved = 0

        status = data.withUnsafeBytes { inputBytes in
            output.withUnsafeMutableBytes { outputBytes in
                CCCryptorUpdate(
                    c,
                    inputBytes.baseAddress,
                    data.count,
                    outputBytes.baseAddress,
                    outputSize,
                    &moved
                )
            }
        }

        guard status == kCCSuccess else {
            throw CryptoError.invalidData
        }

        output.count = moved
        return output
    }
}

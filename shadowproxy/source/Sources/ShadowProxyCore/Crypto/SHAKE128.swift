import Foundation

/// SHAKE-128 XOF (Extendable Output Function) based on Keccak-f[1600]
///
/// Parameters: rate=168 bytes (1344 bits), capacity=256 bits, padding=0x1F
public struct SHAKE128: Sendable {
    private static let rate = 168      // bytes
    private static let stateSize = 25  // 25 x UInt64 = 1600 bits

    private var state = [UInt64](repeating: 0, count: 25)
    private var absorbed = false
    private var squeezeOffset = 0  // current offset within the rate portion after squeeze

    // Rho rotation offsets indexed by [x + 5*y]
    // Computed from the Keccak spec: (x,y) starting at (1,0), iterate (x,y)=(y,(2x+3y)%5)
    private static let rhoOffsets: [Int] = [
        //  x=0  x=1  x=2  x=3  x=4
             0,   1,  62,  28,  27,  // y=0
            36,  44,   6,  55,  20,  // y=1
             3,  10,  43,  25,  39,  // y=2
            41,  45,  15,  21,   8,  // y=3
            18,   2,  61,  56,  14,  // y=4
    ]

    // MARK: - Public API

    /// Absorb input data. Must be called before squeeze. Can only be called once.
    public mutating func absorb(_ data: Data) {
        precondition(!absorbed, "SHAKE128: absorb called after finalization")

        var offset = 0
        // Absorb full blocks
        while offset + Self.rate <= data.count {
            xorBlock(data, offset: offset, count: Self.rate)
            keccakF1600()
            offset += Self.rate
        }

        // Absorb remaining bytes + padding
        let remaining = data.count - offset
        var lastBlock = [UInt8](repeating: 0, count: Self.rate)
        if remaining > 0 {
            for i in 0..<remaining {
                lastBlock[i] = data[data.startIndex + offset + i]
            }
        }
        // SHAKE padding: 0x1F at end of message, 0x80 at end of rate block
        lastBlock[remaining] = 0x1F
        lastBlock[Self.rate - 1] |= 0x80

        xorBlock(Data(lastBlock), offset: 0, count: Self.rate)
        keccakF1600()

        absorbed = true
        squeezeOffset = 0
    }

    /// Squeeze output bytes. Can be called multiple times for streaming output.
    public mutating func squeeze(count: Int) -> Data {
        precondition(absorbed, "SHAKE128: squeeze called before absorb")

        var output = Data(capacity: count)
        var remaining = count

        while remaining > 0 {
            let available = Self.rate - squeezeOffset
            let take = min(remaining, available)

            // Extract bytes from state at current offset
            for i in 0..<take {
                let pos = squeezeOffset + i
                let laneIndex = pos / 8
                let byteIndex = pos % 8
                output.append(UInt8(truncatingIfNeeded: state[laneIndex] >> (byteIndex * 8)))
            }

            squeezeOffset += take
            remaining -= take

            if squeezeOffset == Self.rate {
                keccakF1600()
                squeezeOffset = 0
            }
        }

        return output
    }

    // MARK: - Internal

    /// XOR a block of bytes into the state
    private mutating func xorBlock(_ data: Data, offset: Int, count: Int) {
        for i in 0..<count {
            let laneIndex = i / 8
            let byteIndex = i % 8
            let byte = UInt64(data[data.startIndex + offset + i])
            state[laneIndex] ^= byte << (byteIndex * 8)
        }
    }

    /// Keccak-f[1600] permutation (24 rounds)
    private mutating func keccakF1600() {
        // Round constants
        let rc: [UInt64] = [
            0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
            0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
            0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
            0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
            0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
            0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
        ]

        for round in 0..<24 {
            // Theta
            var c = [UInt64](repeating: 0, count: 5)
            for x in 0..<5 {
                c[x] = state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20]
            }
            var d = [UInt64](repeating: 0, count: 5)
            for x in 0..<5 {
                d[x] = c[(x + 4) % 5] ^ rotl64(c[(x + 1) % 5], 1)
            }
            for i in 0..<25 {
                state[i] ^= d[i % 5]
            }

            // Rho + Pi
            // Pi: state'[y][2x+3y] = state[x][y], indexing state[x+5y]
            // We do rho on the original, then place into pi destination
            var temp = [UInt64](repeating: 0, count: 25)
            for x in 0..<5 {
                for y in 0..<5 {
                    let src = x + 5 * y
                    let dst = y + 5 * ((2 * x + 3 * y) % 5)
                    temp[dst] = rotl64(state[src], Self.rhoOffsets[src])
                }
            }

            // Chi
            for y in stride(from: 0, to: 25, by: 5) {
                let t0 = temp[y]
                let t1 = temp[y + 1]
                let t2 = temp[y + 2]
                let t3 = temp[y + 3]
                let t4 = temp[y + 4]
                state[y]     = t0 ^ (~t1 & t2)
                state[y + 1] = t1 ^ (~t2 & t3)
                state[y + 2] = t2 ^ (~t3 & t4)
                state[y + 3] = t3 ^ (~t4 & t0)
                state[y + 4] = t4 ^ (~t0 & t1)
            }

            // Iota
            state[0] ^= rc[round]
        }
    }

    @inline(__always)
    private func rotl64(_ x: UInt64, _ n: Int) -> UInt64 {
        (x << n) | (x >> (64 - n))
    }
}

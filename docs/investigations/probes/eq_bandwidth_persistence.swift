import AVFoundation
import Foundation

// Does AVAudioUnitEQFilterParameters.bandwidth persist a written value, and
// does that depend on the band's filterType? EQNode stores user-facing Q as
// `bandwidth` on .highPass / .lowPass bands and reads it back on snapshot.

func qToBandwidth(_ q: Float) -> Float {
    Float((2.0 / log(2.0)) * asinh(1.0 / (2.0 * Double(max(q, 0.0001)))))
}
func bandwidthToQ(_ bw: Float) -> Float {
    Float(1.0 / (2.0 * sinh(Double(max(bw, 0.0001)) * log(2.0) / 2.0)))
}

let types: [(String, AVAudioUnitEQFilterType)] = [
    ("parametric", .parametric),
    ("lowPass", .lowPass),
    ("highPass", .highPass),
    ("resonantLowPass", .resonantLowPass),
    ("resonantHighPass", .resonantHighPass),
    ("bandPass", .bandPass),
    ("bandStop", .bandStop),
    ("lowShelf", .lowShelf),
    ("highShelf", .highShelf),
]

print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
print("")
print(String(format: "%-20s %12s %12s %12s", ("filterType" as NSString).utf8String!,
             ("wrote bw" as NSString).utf8String!,
             ("read bw" as NSString).utf8String!,
             ("Q back" as NSString).utf8String!))

let targetQ: Float = 1.5
let wrote = qToBandwidth(targetQ)

for (name, type) in types {
    let eq = AVAudioUnitEQ(numberOfBands: 1)
    let band = eq.bands[0]
    band.filterType = type
    band.frequency = 1000.0
    band.bypass = false
    band.bandwidth = wrote
    let read = band.bandwidth
    let qBack = bandwidthToQ(read)
    let flag = abs(read - wrote) < 0.0001 ? "" : "   <-- NOT PERSISTED"
    print(String(format: "%-20@ %12.6f %12.6f %12.3f%@",
                 name as NSString, wrote, read, qBack, flag as NSString))
}

print("")
print("EQNode's exact sequence (hp band, .highPass, Q=1.5):")
let eq = AVAudioUnitEQ(numberOfBands: 2)
let hp = eq.bands[0]
hp.filterType = .highPass
hp.frequency = 80.0
hp.bandwidth = qToBandwidth(0.707)
hp.bypass = false
print("  after configureEQBands: bandwidth=\(hp.bandwidth) -> Q=\(bandwidthToQ(hp.bandwidth))")
hp.frequency = 100.0
hp.bandwidth = qToBandwidth(1.5)
print("  after setParameter(hp.Q, 1.5): bandwidth=\(hp.bandwidth) -> Q=\(bandwidthToQ(hp.bandwidth))")
print("  expected Q back: 1.5")

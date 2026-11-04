// Standalone harness for the buddy pets (builds without Xcode):
//
//   swiftc -O Sources/CodeIslandCore/PetFrame.swift Sources/CodeIslandCore/PetSprites.swift \
//       scripts/pet_preview/main.swift -o .build/pet-preview
//   .build/pet-preview frames.json
//
// Runs the same checks as Tests/CodeIslandCoreTests/PetFrameTests.swift, then
// exports every frame the app draws for each of design/v25's motions (0.05s
// steps over the motion's loop), so design/v25/候选/compare_swift.py can check
// it pixel for pixel against the prototype's direction B.
import Foundation

var failures = 0
func check(_ ok: Bool, _ msg: @autoclosure () -> String) {
    if !ok { failures += 1; print("FAIL:", msg()) }
}

for species in PetSpecies.allCases {
    let s = species.sprite
    check(s.rows.count == 16, "\(species) rows")
    for row in s.rows {
        check(row.count == 16, "\(species) cols")
        for ch in row where ch != "." { check(s.palette[ch] != nil, "\(species) missing color \(ch)") }
    }
    check(s.waist > s.eyeBottom && s.waist < s.bodyBottom, "\(species) waist \(s.waist) not under the face")
}

/// design/v25's motions: what the app shows and for how long it loops.
let motions: [(key: String, state: PetState, work: PetWork?, loop: Double)] = [
    ("sleep", .sleep, nil, 4.8), ("idle", .idle, nil, 12.0),
    ("think", .busy, .think, 4.8), ("read", .busy, .read, 4.8), ("search", .busy, .search, 3.0),
    ("edit", .busy, .edit, 4.2), ("shell", .busy, .shell, 3.6), ("web", .busy, .web, 4.8),
    ("agent", .busy, .agent, 4.8), ("other", .busy, .other, 2.4), ("compact", .busy, .compact, 3.6),
    ("approval", .attention, nil, 2.4), ("question", .question, nil, 4.8),
    ("done", .celebrate, nil, 3.0), ("failed", .dizzy, nil, 4.0), ("heart", .heart, nil, 3.2),
]
let step = 0.05
var out: [String: [String: [String]]] = [:]
for species in PetSpecies.allCases {
    var clips: [String: [String]] = [:]
    for m in motions {
        var frames: [String] = []
        for i in 0..<Int((m.loop / step).rounded()) {
            let px = PetFrame.pixels(sprite: species.sprite, state: m.state, t: Double(i) * step, work: m.work)
            check(!px.isEmpty, "\(species) \(m.key) empty")
            var grid = Array(repeating: ".", count: PetFrame.canvasWidth * PetFrame.canvasHeight)
            for p in px {
                check((0..<PetFrame.canvasWidth).contains(p.x) && (0..<PetFrame.canvasHeight).contains(p.y), "out of canvas")
                grid[p.y * PetFrame.canvasWidth + p.x] = String(format: "%06X", p.rgb)
            }
            frames.append(grid.joined(separator: ","))
        }
        check(Set(frames).count > 1, "\(species) \(m.key) never moves")
        clips[m.key] = frames
    }
    out[species.rawValue] = clips
}

// Eye checks on Clawd (when this sprite set has it): eyes at canvas x 6/13, rows 10-11.
if let clawd = PetSpecies(rawValue: "clawd") {
    func eyeRows(_ state: PetState, _ t: Double = 0) -> Set<Int> {
        Set(PetFrame.pixels(sprite: clawd.sprite, state: state, t: t)
            .filter { $0.rgb == 0x000000 && [6, 13].contains($0.x) }.map(\.y))
    }
    check(eyeRows(.idle) == [10, 11], "idle eyes \(eyeRows(.idle))")
    // Asleep the top half sinks a row on the out-breath.
    check(eyeRows(.sleep) == [12], "sleep eyes \(eyeRows(.sleep))")
    check(eyeRows(.sleep, 1.3) == [11], "sleep eyes in-breath \(eyeRows(.sleep, 1.3))")
    check(eyeRows(.heart) == [10], "heart eyes \(eyeRows(.heart))")
}

let doc: [String: Any] = ["step": step, "clips": out]
if CommandLine.arguments.count > 1 {
    let data = try JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys])
    try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    print("wrote \(CommandLine.arguments[1]) (\(data.count / 1024) KB)")
}
print(failures == 0 ? "all checks passed" : "\(failures) checks failed")
exit(failures == 0 ? 0 : 1)

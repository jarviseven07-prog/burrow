// Standalone harness for the buddy pets (builds without Xcode):
//
//   swiftc -O Sources/CodeIslandCore/PetFrame.swift Sources/CodeIslandCore/PetSprites.swift \
//       scripts/pet_preview/main.swift -o .build/pet-preview
//   .build/pet-preview design/v02/frames.json
//
// Runs the same checks as Tests/CodeIslandCoreTests/PetFrameTests.swift, then
// exports every frame the app draws (0.1s steps over 9.6s) for the design page.
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
}

let step = 0.1, frameCount = 96
var out: [String: Any] = [:]
var palettes: [String: [String]] = [:]
for species in PetSpecies.allCases {
    var colors: [UInt32] = []
    var states: [String: [String]] = [:]
    for state in PetState.allCases {
        var frames: [String] = []
        for i in 0..<frameCount {
            let px = PetFrame.pixels(sprite: species.sprite, state: state, t: Double(i) * step)
            check(!px.isEmpty, "\(species) \(state) empty")
            var grid = Array(repeating: Character("."), count: PetFrame.canvasWidth * PetFrame.canvasHeight)
            for p in px {
                check((0..<PetFrame.canvasWidth).contains(p.x) && (0..<PetFrame.canvasHeight).contains(p.y), "out of canvas")
                var idx = colors.firstIndex(of: p.rgb)
                if idx == nil { colors.append(p.rgb); idx = colors.count - 1 }
                let code = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")[idx!]
                grid[p.y * PetFrame.canvasWidth + p.x] = code
            }
            frames.append(String(grid))
        }
        check(Set(frames).count > 1, "\(species) \(state) never moves")
        states[state.rawValue] = frames
    }
    palettes[species.rawValue] = colors.map { String(format: "#%06X", $0) }
    out[species.rawValue] = ["name": species.displayName, "states": states]
}

// Eye checks on Clawd (when this sprite set has it): eyes at canvas x 6/13, rows 10-11.
if let clawd = PetSpecies(rawValue: "clawd") {
    func eyeRows(_ state: PetState) -> Set<Int> {
        Set(PetFrame.pixels(sprite: clawd.sprite, state: state, t: 0)
            .filter { $0.rgb == 0x000000 && [6, 13].contains($0.x) }.map(\.y))
    }
    check(eyeRows(.idle) == [10, 11], "idle eyes \(eyeRows(.idle))")
    check(eyeRows(.sleep) == [11], "sleep eyes \(eyeRows(.sleep))")
    check(eyeRows(.heart) == [10], "heart eyes \(eyeRows(.heart))")
}

let doc: [String: Any] = [
    "canvas": [PetFrame.canvasWidth, PetFrame.canvasHeight],
    "origin": [PetFrame.originX, PetFrame.originY],
    "step": step,
    "species": out,
    "order": PetSpecies.allCases.map(\.rawValue),
    "palettes": palettes,
    "sources": PetSpecies.bySource.mapValues(\.rawValue),
]
if CommandLine.arguments.count > 1 {
    let data = try JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys])
    try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    print("wrote \(CommandLine.arguments[1]) (\(data.count / 1024) KB)")
}
print(failures == 0 ? "all checks passed" : "\(failures) checks failed")
exit(failures == 0 ? 0 : 1)

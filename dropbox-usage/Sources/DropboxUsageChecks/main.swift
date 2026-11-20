import DropboxUsageCore
import Foundation

var failures = 0

@MainActor
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    if condition() {
        print("PASS: \(name)")
    } else {
        failures += 1
        print("FAIL: \(name)")
    }
}

check(
    SpaceFormatter.menuTitle(usedBytes: 2_480_000_000, allocatedBytes: 2_684_354_560)
        == "2.31 / 2.5",
    "requested menu format"
)
check(SpaceFormatter.gibibytes(0) == "0", "zero formatting")
check(SpaceFormatter.gibibytes(2_147_483_648) == "2", "trailing zero trimming")
check(SpaceFormatter.gibibytes(2_208_000_000) == "2.06", "hundredth rounding")

do {
    let json = Data(#"{"used":2230000000,"allocation":{".tag":"individual","allocated":2500000000}}"#.utf8)
    let usage = try JSONDecoder().decode(SpaceUsage.self, from: json)
    check(usage.used == 2_230_000_000, "individual used bytes decode")
    check(usage.allocation.allocated == 2_500_000_000, "individual allocation decode")
} catch {
    failures += 1
    print("FAIL: individual response decode: \(error)")
}

do {
    let json = Data(#"{"used":100,"allocation":{".tag":"team","used":200,"allocated":300,"user_within_team_space_allocated":400}}"#.utf8)
    let usage = try JSONDecoder().decode(SpaceUsage.self, from: json)
    check(usage.allocation.allocated == 300, "team response decode")
} catch {
    failures += 1
    print("FAIL: team response decode: \(error)")
}

if failures > 0 {
    fatalError("\(failures) check(s) failed")
}

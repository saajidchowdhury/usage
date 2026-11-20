import Foundation

public struct SpaceUsage: Decodable, Equatable {
    public struct Allocation: Decodable, Equatable {
        public let allocated: Int64
    }

    public let used: Int64
    public let allocation: Allocation
}

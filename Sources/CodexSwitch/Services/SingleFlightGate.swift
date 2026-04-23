import Foundation

actor SingleFlightGate {
    private var inFlight = false

    func begin() -> Bool {
        guard !inFlight else { return false }
        inFlight = true
        return true
    }

    func end() {
        inFlight = false
    }
}

enum RuntimeHotSwapContract {
    static let commonMarkers = [
        "sighup-verified",
        "SIGHUP: auth reloaded",
        "hotswap-ack",
        "CodexSwitch rotated accounts after a usage limit",
        "CodexSwitch rotated accounts after an auth failure",
        "Auth changed, opening new WebSocket with fresh credentials",
        "codexswitch-runtime-convergence-v3",
        "codexswitch-runtime-rotation-handoff-v1",
    ]

    static let externalAppServerMarkers = [
        "CodexSwitch account/updated frontend write acknowledged after auth reload",
        "codexswitch-hotswap-contract-v3",
    ]

    static let headlessRemoteControlMarkers = [
        "codexswitch-hotswap-headless-idle-v1",
    ]

    static let localInteractiveMarkers = [
        "codexswitch-hotswap-cli-contract-v3",
    ]

    static let fullMarkers = commonMarkers
        + externalAppServerMarkers
        + headlessRemoteControlMarkers
        + localInteractiveMarkers
}

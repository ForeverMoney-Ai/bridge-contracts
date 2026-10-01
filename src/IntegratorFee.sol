// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Per-call integrator ("frontend") fee: a cut of the BRIDGED TOKEN amount charged ON TOP
///         (the bridged amount is never reduced), paid to
///         `recipient` on the source chain in the same transaction. Whoever prepares the bridge tx
///         sets it; the gateway only enforces a governance-set ceiling. `bps == 0` means no fee and
///         `recipient` is ignored.
struct IntegratorFee {
    address recipient;
    uint16 bps;
}

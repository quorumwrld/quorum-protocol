// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Mock ERC-20 that deducts a configurable basis-points fee on every
///         transfer. Used to exercise the H-02 fix: `ForumExecutor.createBounty`
///         must reject any token that isn't a Quorum factory-deployed idea,
///         and a fee-on-transfer token would break `BondingEscrow` accounting
///         if accepted (1:1 deposit assumption broken — final claimers
///         starve as the contract's balance < sum of recorded stakes).
contract FeeOnTransferMockERC20 is ERC20 {
    uint16 public immutable feeBps;

    constructor(string memory name_, string memory symbol_, uint16 feeBps_) ERC20(name_, symbol_) {
        require(feeBps_ <= 10_000, "fee>100%");
        feeBps = feeBps_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// Override the internal hook so both `transfer` and `transferFrom` take the cut.
    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || feeBps == 0) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = (value * feeBps) / 10_000;
        uint256 net = value - fee;
        // Burn the fee. The recipient only receives `net`, so any accounting
        // that records `value` as the credited amount is now out of sync.
        super._update(from, address(0), fee);
        super._update(from, to, net);
    }
}

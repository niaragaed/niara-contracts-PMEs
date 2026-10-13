// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Malicious currency used ONLY in tests: when transferred out of a contract
/// (`transfer`), it tries to re-enter a configurable target before returning. Simulates a real
/// BRL stablecoin that, unlike `MockBRL`, had a hook/callback; the gotcha documented in
/// CLAUDE.md ("treat the currency as if it could have a callback") exists precisely for this case.
contract ReentrantMockBRL is ERC20 {
    address public target;
    bytes public attackCallData;
    bool public active;
    bool public reentryBlocked;

    constructor() ERC20("Reentrant Mock BRL", "rBRL") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @dev Arms the next `transfer`/`transferFrom` to try to re-enter `target` with
    /// `callData_` (full calldata: selector + arguments, e.g.
    /// `abi.encodeWithSelector(OfertaCaptacao.reembolsar.selector)`).
    function armAttack(address target_, bytes calldata callData_) external {
        target = target_;
        attackCallData = callData_;
        active = true;
        reentryBlocked = false;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool ok = super.transfer(to, amount);
        _tryReenter();
        return ok;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool ok = super.transferFrom(from, to, amount);
        _tryReenter();
        return ok;
    }

    function _tryReenter() internal {
        if (!active) return;
        active = false; // avoids an infinite loop in the attack attempt itself
        (bool success,) = target.call(attackCallData);
        reentryBlocked = !success;
    }
}

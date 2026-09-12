// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {AbstractTrigger} from "vela/contracts/trigger/AbstractTrigger.sol";
import {IProcessorEndpoint} from "vela/contracts/interfaces/IProcessorEndpoint.sol";
import {Structs} from "vela/contracts/Structs.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// The companion of `app/app.syn`: the hands of the treasury. When the enclave decides a payment
/// (inside the policy, or approved by the owner), it withdraws the amount to this contract and
/// emits one public app event — abi.encode(bytes16 id, address payee, address token, uint256 amount).
/// During stateUpdate the ProcessorEndpoint claims the funds into this contract and calls
/// `execute`; the transfer to the payee runs here. Whatever is left is swept back by the base
/// `withdraw()`, and `getTrustProcessPayload` hands the enclave abi.encode(id, outcome) as a
/// TRUSTPROCESS: 0 = paid, 1 = the transfer reverted and the funds went back (the app refunds).
/// It holds nothing between payments and has no owner: the policy lives in the enclave.
contract TreasuryTrigger is AbstractTrigger {
    error PayFailed();

    event Paid(bytes16 indexed id, address indexed payee, address token, uint256 amount);

    constructor(IProcessorEndpoint _processorEndpoint) AbstractTrigger(_processorEndpoint) {}

    function _execute(Structs.EventData calldata appEventData) internal override {
        if (appEventData.events.length == 0) return; // a TRUSTPROCESS carries no app events
        (bytes16 id, address payee, address token, uint256 amount) =
            abi.decode(appEventData.events[0], (bytes16, address, address, uint256));
        if (token == address(0)) {
            (bool ok, ) = payee.call{value: amount}("");
            if (!ok) revert PayFailed();
        } else if (!IERC20(token).transfer(payee, amount)) {
            revert PayFailed();
        }
        emit Paid(id, payee, token, amount);
    }

    function _getTrustProcessPayload(
        Structs.EventData calldata appEventData,
        bool executeSuccess,
        bool, /* withdrawSuccess */
        Structs.TokenAndAmount[] calldata, /* returnedTokens */
        Structs.TokenAndAmount[] calldata /* failedTokens */
    ) internal pure override returns (bytes memory) {
        if (appEventData.events.length == 0) return ""; // no follow-up: the loop ends here
        (bytes16 id, , , ) = abi.decode(appEventData.events[0], (bytes16, address, address, uint256));
        return abi.encode(id, uint8(executeSuccess ? 0 : 1));
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {TreasuryTrigger} from "./TreasuryTrigger.sol";
import {IProcessorEndpoint} from "vela/contracts/interfaces/IProcessorEndpoint.sol";

/// One TreasuryTrigger per treasury app, made on demand. A Synsema program cannot send a
/// contract-creation transaction (`tx_eip1559` wants a recipient), so the console calls `create()`
/// here — an ordinary transaction — and reads the new trigger's address from the `Created` event.
/// Deployed once per stack (scripts/trigger/build.sh); the address travels as VELA_TRIGGER_FACTORY.
contract TreasuryTriggerFactory {
    IProcessorEndpoint public immutable processorEndpoint;

    event Created(address indexed trigger, address indexed by);

    constructor(IProcessorEndpoint _processorEndpoint) {
        processorEndpoint = _processorEndpoint;
    }

    function create() external returns (address) {
        TreasuryTrigger t = new TreasuryTrigger(processorEndpoint);
        emit Created(address(t), msg.sender);
        return address(t);
    }
}

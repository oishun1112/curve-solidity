pragma solidity >=0.6.0 <0.8.0;

// @version 0.2.4
/**
*@title Vesting Escrow Factory
*@author Curve Finance
*@license MIT
*@notice Stores and distributes `ERC20CRV` tokens by deploying `VestingEscrowSimple` contracts
*/

//@shun //from vyper.interfaces import ERC20
interface VestingEscrowSimple{
        function initialize(
            address _admin,
            address _token,
            address _recipient,
            uint256 _amount,
            uint256 _start_time,
            uint256 _end_time,
            bool _can_disable 
        )nonpayable returns (bool){}// ;?
}

contract VestingEscrowFactory{
    uint256 constant MIN_VESTING_DURATION = 86400 * 365;


    


    event CommitOwnership(address admin);
    event ApplyOwnership(address admin);


    address public admin;
    address public future_admin;
    address public target;

    function __init__(address _target ,address _admin)external{
        /**
        @notice Contract constructor
        @dev Prior to deployment you must deploy one copy of `VestingEscrowSimple` which
            is used as a library for vesting contracts deployed by this factory
        @param _target `VestingEscrowSimple` contract address
        */
        target = _target;
        admin = _admin;
    }

    function deploy_vesting_contract(
        address _token,
        address _recipient,
        uint256 _amount,
        bool _can_disable,
        uint256 _vesting_duration,
        uint256 _vesting_start = block.timestamp
    )external returns (address){
        /**
        *@notice Deploy a new vesting contract
        *@dev Each contract holds tokens which vest for a single account. Tokens
        *    must be sent to this contract via the regular `ERC20.transfer` method
        *    prior to calling this method.
        *@param _token Address of the ERC20 token being distributed
        *@param _recipient Address to vest tokens for
        *@param _amount Amount of tokens being vested for `_recipient`
        *@param _can_disable Can admin disable recipient's ability to claim tokens?
        *@param _vesting_duration Time period over which tokens are released
        *@param _vesting_start Epoch time when tokens begin to vest
        */
        assert (msg.sender == admin);  // dev admin only
        assert (_vesting_start >= block.timestamp);  // dev start time too soon
        assert (_vesting_duration >= MIN_VESTING_DURATION);  // dev duration too short

        address _contract = create_forwarder_to(target);
        assert (ERC20(_token).approve(_contract, _amount));  // dev approve failed
        VestingEscrowSimple(_contract).initialize(
            admin,
            _token,
            _recipient,
            _amount,
            _vesting_start,
            _vesting_start + _vesting_duration,
            _can_disable
        )

        return _contract;
    }

    function commit_transfer_ownership(address addr)external returns (bool){
        /**
        *@notice Transfer ownership of GaugeController to `addr`
        *@param addr Address to have ownership transferred to
        */
        assert (msg.sender == admin);  // dev admin only
        future_admin = addr;
        emit CommitOwnership(addr);

        return true;
    }

    function apply_transfer_ownership()external returns (bool){
        /**
        *@notice Apply pending ownership transfer
        */
        assert (msg.sender == admin ); // dev admin only
        address _admin = future_admin;
        assert (_admin != ZERO_ADDRESS);  // dev admin not set
        admin = _admin;
        emit ApplyOwnership(_admin);

        return true;
    }
}
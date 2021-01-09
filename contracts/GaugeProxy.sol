pragma solidity >=0.6.0 <0.8.0;
// @version 0.2.8
/**
*@title Curve LiquidityGaugeV2 Ownerhip Proxy
*@author Curve Finance
*@license MIT
*/


interface LiquidityGauge{
    function set_rewards(address _reward_contract, bytes32 _sigs, address[8] _reward_tokens) nonpayable;
    function set_killed(bool _is_killed)nonpayable;
    function commit_transfer_ownership(address addr)nonpayable;
    function accept_transfer_ownership() nonpayable;
}

contract GaugeProxy{

    event CommitAdmins (address ownership_admin, address emergency_admin);
    event ApplyAdmins(address ownership_admin, address emergency_admin);

    address public ownership_admin;
    address public emergency_admin;
    address public future_ownership_admin;
    address public future_emergency_admin;

    function __init__(address _ownership_admin , address _emergency_admin )external{
        ownership_admin = _ownership_admin;
        emergency_admin = _emergency_admin;
    }

    function commit_set_admins(address _o_admin , address _e_admin )external{
        /**
        *@notice Set ownership admin to `_o_admin` and emergency admin to `_e_admin`
        *@param _o_admin Ownership admin
        *@param _e_admin Emergency admin
        */
        assert (msg.sender == ownership_admin, "Access denied");

        future_ownership_admin = _o_admin;
        future_emergency_admin = _e_admin;

        emit CommitAdmins(_o_admin, _e_admin);
    }

    function accept_set_admins()external{
        /**
        *@notice Apply the effects of `commit_set_admins`
        *@dev Only callable by the new owner admin
        */
        assert (msg.sender == future_ownership_admin, "Access denied");

        address e_admin = future_emergency_admin;
        ownership_admin = msg.sender;
        emergency_admin = e_admin;

        emit ApplyAdmins(msg.sender, e_admin);
    }

    //@shun: @nonreentrant('lock')
    function commit_transfer_ownership(address _gauge, address new_owner)external{
        /**
        *@notice Transfer ownership for liquidity gauge `_gauge` to `new_owner`
        *@param _gauge Gauge which ownership is to be transferred
        *@param new_owner New gauge owner address
        */
        assert (msg.sender == ownership_admin, "Access denied");
        LiquidityGauge(_gauge).commit_transfer_ownership(new_owner);
    }

    //@shun: @nonreentrant('lock')
    function accept_transfer_ownership(address _gauge)external{
        /**
        *@notice Apply transferring ownership of `_gauge`
        *@param _gauge Gauge address
        */
        LiquidityGauge(_gauge).accept_transfer_ownership();
    }

    //@shun: @nonreentrant('lock')
    function set_killed(address _gauge , bool _is_killed )external{
        /**
        *@notice Set the killed status for `_gauge`
        *@dev When killed, the gauge always yields a rate of 0 and so cannot mint CRV
        *@param _gauge Gauge address
        *@param _is_killed Killed status to set
        */
        assert(msg.sender == ownership_admin || msg.sender == emergency_admin, "Access denied"); //@shun: assert(msg.sender in [ownership_admin, emergency_admin], "Access denied");

        LiquidityGauge(_gauge).set_killed(_is_killed);
    }

    //@shun: @nonreentrant('lock')
    function set_rewards(address _gauge, address _reward_contract , bytes32 _sigs , address[8] _reward_tokens)external{
        /**
        *@notice Set the active reward contract for `_gauge`
        *@param _gauge Gauge address
        *@param _reward_contract Reward contract address. Set to ZERO_ADDRESS to
        *                        disable staking.
        *@param _sigs Four byte selectors for staking, withdrawing and claiming,
        *            right padded with zero bytes. If the reward contract can
        *            be claimed from but does not require staking, the staking
        *            and withdraw selectors should be set to 0x00
        *@param _reward_tokens List of claimable tokens for this reward contract
        */
        assert (msg.sender == ownership_admin, "Access denied");

        LiquidityGauge(_gauge).set_rewards(_reward_contract, _sigs, _reward_tokens);
    }
}

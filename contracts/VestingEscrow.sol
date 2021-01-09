pragma solidity >=0.6.0 <0.8.0;

// @version 0.2.4
/**
*@title Vesting Escrow
*@author Curve Finance
*@license MIT
*@notice Vests `ERC20CRV` tokens for multiple addresses over multiple vesting periods
*/


//@shun: //from vyper.interfaces import ERC20

contract VestingEscrow{
    
    event Fund(address indexed recipient, uint256 amount);
    event Claim(address indexed recipient, uint256 claimed);
    event ToggleDisable(address recipient, bool disabled);
    event CommitOwnership(address admin);
    event ApplyOwnership(address admin);


    address public token;
    uint256 public start_time;
    uint256 public end_time;
    mapping(address => uint256)public initial_locked;
    mapping(address => uint256)public total_claimed;

    uint256 public initial_locked_supply;
    uint256 public unallocated_supply;

    bool public can_disable;
    mapping(address => uint256) public disabled_at;

    address public admin;
    address public future_admin;

    bool public fund_admins_enabled;
    mapping(address => bool) public fund_admins;


    
    function __init__(
        address _token,
        uint256 _start_time,
        uint256 _end_time,
        bool _can_disable,
        address[4] _fund_admins
    )external {
        /**
        *@param _token Address of the ERC20 token being distributed
        *@param _start_time Timestamp at which the distribution starts. Should be in
        *    the future, so that we have enough time to VoteLock everyone
        *@param _end_time Time until everything should be vested
        *@param _can_disable Whether admin can disable accounts in this deployment
        *@param _fund_admins Temporary admin accounts used only for funding
        */
        assert (_start_time >= block.timestamp);
        assert (_end_time > _start_time);

        token = _token;
        admin = msg.sender;
        start_time = _start_time;
        end_time = _end_time;
        can_disable = _can_disable;

        bool _fund_admins_enabled = false;
        for (uint i; i < _fund_admins.length; i++){
            address addr = _fund_admins[i];
            if (addr != address(0)){
                fund_admins[addr] = true;
                if (!_fund_admins_enabled){
                    _fund_admins_enabled = true;
                    fund_admins_enabled = true;
                }
            }
        }

    }

    
    function add_tokens(uint256 _amount)external{
        /**
        *@notice Transfer vestable tokens into the contract
        *@dev Handled separate from `fund` to reduce transaction count when using funding admins
        *@param _amount Number of tokens to transfer
        */
        assert (msg.sender == admin); // dev admin only
        assert (ERC20(token).transferFrom(msg.sender, self, _amount));  // dev transfer failed
        unallocated_supply += _amount;
    }


    
    //@shun: //@nonreentrant('lock')
    function fund(address[100] _recipients, uint256[100] _amounts)external{
        /**
        *@notice Vest tokens for multiple recipients
        *@param _recipients List of addresses to fund
        *@param _amounts Amount of vested tokens for each address
        */
        if (msg.sender != admin){
            assert (fund_admins[msg.sender]);  // dev admin only
            assert (fund_admins_enabled);  // dev fund admins disabled
        }

        uint256 _total_amount = 0;
        for(uint i;  i<= 100; i++){
            uint256 amount = _amounts[i];
            address recipient = _recipients[i];
            if (recipient == address(0)){
                break;
            }
            _total_amount += amount;
            initial_locked[recipient] += amount;
            emit Fund(recipient, amount);
        }

        initial_locked_supply += _total_amount;
        unallocated_supply -= _total_amount;
    }


    
    function toggle_disable(address _recipient)external{
        /**
        *@notice Disable or re-enable a vested address's ability to claim tokens
        *@dev When disabled, the address is only unable to claim tokens which are still
        *    locked at the time of this call. It is not possible to block the claim
        *    of tokens which have already vested.
        *@param _recipient Address to disable or enable
        */
        assert (msg.sender == admin);  // dev admin only
        assert (can_disable, "Cannot disable");

        bool is_disabled = disabled_at[_recipient] == 0;
        if (is_disabled){
            disabled_at[_recipient] = block.timestamp;
        }else{
            disabled_at[_recipient] = 0;
        }

        emit ToggleDisable(_recipient, is_disabled);
    }

    
    function disable_can_disable()external{
        /**
        *@notice Disable the ability to call `toggle_disable`
        */
        assert (msg.sender == admin);  // dev admin only
        can_disable = false;
    }


    
    function disable_fund_admins()external{
        /**
        *@notice Disable the funding admin accounts
        */
        assert (msg.sender == admin);  // dev admin only
        fund_admins_enabled = false;
    }
    
    function _total_vested_of(address _recipient, uint256 _time = block.timestamp)internal view returns (uint256){
        uint256 start = start_time;
        uint256 end = end_time;
        uint256 locked = initial_locked[_recipient];
        if (_time < start){
            return 0;
        }
        return min(locked * (_time - start) / (end - start), locked);
    }

    
    
    function _total_vested()internal view returns (uint256){
        uint256 start = start_time;
        uint256 end = end_time;
        uint256 locked = initial_locked_supply;
        if (block.timestamp < start){
            return 0;
        }
        return min(locked * (block.timestamp - start) / (end - start), locked);
    }


    
    
    function vestedSupply()external view returns (uint256){
        /**
        *@notice Get the total number of tokens which have vested, that are held
        *        by this contract
        */
        return _total_vested();
    }


    
    
    function lockedSupply()external view returns (uint256){
        /**
        *@notice Get the total number of tokens which are still locked
        *        (have not yet vested)
        */
        return initial_locked_supply - _total_vested();
    }


    
    
    function vestedOf(address _recipient)external view returns (uint256){
        /**
        *@notice Get the number of tokens which have vested for a given address
        *@param _recipient address to check
        */
        return _total_vested_of(_recipient);
    }


    
    
    function balanceOf(address _recipient)external view returns (uint256){
        /**
        *@notice Get the number of unclaimed, vested tokens for a given address
        *@param _recipient address to check
        */
        return _total_vested_of(_recipient) - total_claimed[_recipient];
    }


    
    
    function lockedOf(address _recipient)external view returns (uint256){
        /**
        *@notice Get the number of locked tokens for a given address
        *@param _recipient address to check
        */
        return initial_locked[_recipient] - _total_vested_of(_recipient);
    }


    
    //@shun: //@nonreentrant('lock')
    function claim(address addr = msg.sender)external{
        /**
        *@notice Claim tokens which have vested
        *@param addr Address to claim tokens for
        */
        uint256 t = disabled_at[addr];
        if (t == 0){
            t = block.timestamp;
        }
        uint256 claimable = _total_vested_of(addr, t) - total_claimed[addr];
        total_claimed[addr] += claimable;
        assert (ERC20(token).transfer(addr, claimable));

        emit Claim(addr, claimable);
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
        assert (msg.sender == admin); // dev admin only
        address _admin = future_admin;
        assert (_admin != address(0));  // dev admin not set
        admin = _admin;
        emit ApplyOwnership(_admin);

        return true;
}
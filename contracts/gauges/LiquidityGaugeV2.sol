pragma solidity >=0.6.0 <0.8.0;
// @version 0.2.8
/**
*@title Liquidity Gauge v2
*@author Curve Finance
*@license MIT
*/

//from vyper.interfaces import ERC20

//implements ERC20

/**
*interface CRV20
*    function future_epoch_time_write() returns uint256 nonpayable
*    function rate() returns uint256 view
*
*interface Controller
*    function period() returns int128 view
*    function period_write() returns int128 nonpayable
*    function period_timestamp(p int128) returns uint256 view
*    function gauge_relative_weight(addr address, time uint256) returns uint256 view
*    function voting_escrow() returns address view
*    function checkpoint() nonpayable
*    function checkpoint_gauge(addr address) nonpayable
*
*interface Minter
*    function token() returns address view
*    function controller() returns address view
*    function minted(user address, gauge address) returns uint256 view
*
*interface VotingEscrow
*    function user_point_epoch(addr address) returns uint256 view
*    function user_point_history__ts(addr address, epoch uint256) returns uint256 view
*
*interface ERC20Extended
*    function symbol() returns bytes26 view
*/
contract LiquidityGaugeV2 {
    event Deposit(address indexed provider, uint256 value);

    event Withdraw(address indexed provider, uint256 value);

    event UpdateLiquidityLimit(address user, uint256 original_balance, uint256 original_supply, uint256 working_balance, uint256 working_supply);

    event CommitOwnership(address admin);

    event ApplyOwnership(address admin);

    event Transfer( address indexed _from, address indexed _to, uint256 _value);

    event Approval(address indexed _owner, address indexed _spender, uint256 _value);


    uint256 constant MAX_REWARDS = 8;
    uint256 constant TOKENLESS_PRODUCTION = 40;
    uint256 constant WEEK = 604800;

    address public minter;
    address public crv_token;
    address public lp_token;
    address public controller;
    address public voting_escrow;
    uint256 public future_epoch_time;

    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;
    mapping(address => mapping(address => uint256)) public allowances;

    bytes64 public name;
    bytes32 public symbol;

    // caller -> recipient -> can deposit?
    mapping(address => mapping(address => bool)) public approved_to_deposit;

    mapping(address => uint256) public working_balances;
    uint256 public working_supply;

    // The goal is to be able to calculate ∫(rate * balance / totalSupply dt) from 0 till checkpoint
    // All values are kept in units of being multiplied by 1e18
    int128 public period;
    uint256[100000000000000000000000000000] public period_timestamp;

    // 1e18 * ∫(rate(t) / totalSupply(t) dt) from 0 till checkpoint
    uint256[100000000000000000000000000000] public integrate_inv_supply;  // bump epoch when rate() changes

    // 1e18 * ∫(rate(t) / totalSupply(t) dt) from (last_action) till checkpoint
    mapping(address => uint256) public integrate_inv_supply_of;
    mapping(address => uint256) public integrate_checkpoint_of;

    // ∫(balance * rate(t) / totalSupply(t) dt) from 0 till checkpoint
    // Units rate * t = already number of coins per address to issue
    mapping(address => uint256) public integrate_fraction;

    uint256 public inflation_rate;

    // For tracking external rewards
    address public reward_contract;
    address[MAX_REWARDS] public reward_tokens;

    // deposit / withdraw / claim
    rbytes32 eward_sigs;

    // reward token -> integral
    mapping(address => uint256) public reward_integral;

    // reward token -> claiming address -> integral
    mapping(address => mapping(address => uint256)) public reward_integral_for;

    address public admin;
    address public future_admin;  // Can and will be a smart contract
    bool public is_killed;

    function __init__(address _lp_token, address _minter, address _admin)external{
        /**
        *@notice Contract constructor
        *@param _lp_token Liquidity Pool contract address
        *@param _minter Minter contract address
        *@param _admin Admin who can kill the gauge
        */

        bytes26 symbol = ERC20Extended(_lp_token).symbol();
        name = concat("Curve.fi ", symbol, " Gauge Deposit");
        symbol = concat(symbol, "-gauge");

        address crv_token = Minter(_minter).token();
        address controller = Minter(_minter).controller();

        lp_token = _lp_token;
        minter = _minter;
        admin = _admin;
        crv_token = crv_token;
        controller = controller;
        voting_escrow = Controller(controller).voting_escrow();

        period_timestamp[0] = block.timestamp;
        inflation_rate = CRV20(crv_token).rate();
        future_epoch_time = CRV20(crv_token).future_epoch_time_write();
    }


    function decimals()external view returns (uint256){
        /**
        *@notice Get the number of decimals for this token
        *@dev Implemented as a view method to reduce gas costs
        *@return uint256 decimal places
        */
        return 18;
    }

    function integrate_checkpoint()external view returns (uint256){
        return period_timestamp[period];
    }

    function _update_liquidity_limit(address addr, uint256 l, uint256 L)internal{
        /**
        *@notice Calculate limits which depend on the amount of CRV token per-user.
        *        Effectively it calculates working balances to apply amplification
        *        of CRV production by CRV
        *@param addr User address
        *@param l User's amount of liquidity (LP tokens)
        *@param L Total amount of liquidity (LP tokens)
        */
        // To be called after totalSupply is updated
        address _voting_escrow = voting_escrow;
        uint256 voting_balance = ERC20(_voting_escrow).balanceOf(addr);
        uint256 voting_total = ERC20(_voting_escrow).totalSupply();

        uint256 lim = l * TOKENLESS_PRODUCTION / 100;
        if (voting_total > 0){
            lim += L * voting_balance / voting_total * (100 - TOKENLESS_PRODUCTION) / 100;
        }

        lim = min(l, lim);
        uint256 old_bal = working_balances[addr];
        working_balances[addr] = lim;
        uint256 _working_supply = working_supply + lim - old_bal;
        working_supply = _working_supply;

        emit UpdateLiquidityLimit(addr, l, L, lim, _working_supply);
    }


    function _checkpoint_rewards(address _addr, uint256 _total_supply)internal{
        /**
        @notice Claim pending rewards and checkpoint rewards for a user
        */
        if (_total_supply == 0){
            return;
        }

        uint256[MAX_REWARDS] reward_balances = empty(uint256[MAX_REWARDS]);
        address[MAX_REWARDS] reward_tokens = empty(address[MAX_REWARDS]);
        for( uint i; i < MAX_REWARDS; i++){
            address token = reward_tokens[i];
            if (token == address(0)){
                break;
            }
            reward_tokens[i] = token;
            reward_balances[i] = ERC20(token).balanceOf(address(this));
        }

        // claim from reward contract
        raw_call(reward_contract, slice(reward_sigs, 8, 4));  // dev bad claim sig

        uint256 user_balance = balanceOf[_addr];
        for (uint i; i<MAX_REWARDS; i++){
            address token = reward_tokens[i];
            if (token == address(0)){
                break;
            }
            uint256 dI = 10**18 * (ERC20(token).balanceOf(address(this)) - reward_balances[i]) / _total_supply;
            if (_addr == address(0)){
                if (dI != 0){
                    reward_integral[token] += dI;
                }
                continue;
            }

            uint256 integral = reward_integral[token] + dI;
            if (dI != 0){
                reward_integral[token] = integral;
            }

            uint256 integral_for = reward_integral_for[token][_addr];
            if (integral_for < integral){
                uint256 claimable = user_balance * (integral - integral_for) / 10**18;
                reward_integral_for[token][_addr] = integral;
                if (claimable != 0){
                    Bytes[32] response = raw_call(
                        token,
                        concat(
                            method_id("transfer(address,uint256)"),
                            convert(_addr, bytes32),
                            convert(claimable, bytes32),
                        ),
                        max_outsize=32,
                    );
                    if (len(response) != 0){
                        assert (convert(response, bool));
                    }
                }
            }
        }
    }

    function _checkpoint(address addr)internal{
        /**
        *@notice Checkpoint for a user
        *@param addr User address
        */
        int128 _period = period;
        uint256 _period_time = period_timestamp[_period];
        uint256 _integrate_inv_supply = integrate_inv_supply[_period];
        uint256 rate = inflation_rate;
        uint256 new_rate = rate;
        uint256 prev_future_epoch = future_epoch_time;
        if (prev_future_epoch >= _period_time){
            address _token = crv_token;
            future_epoch_time = CRV20(_token).future_epoch_time_write();
            new_rate = CRV20(_token).rate();
            inflation_rate = new_rate;
        }

        if (is_killed){
            // Stop distributing inflation as soon as killed
            rate = 0;
        }

        // Update integral of 1/supply
        if (block.timestamp > _period_time){
            uint256 _working_supply = working_supply;
            address _controller = controller;
            Controller(_controller).checkpoint_gauge(address(this));
            uint256 prev_week_time = _period_time;
            uint256 week_time = min((_period_time + WEEK) / WEEK * WEEK, block.timestamp);

            for (uint i; i<500; i++){
                uint256 dt = week_time - prev_week_time;
                uint256 w = Controller(_controller).gauge_relative_weight(address(this), prev_week_time / WEEK * WEEK);

                if (_working_supply > 0){
                    if (prev_future_epoch >= prev_week_time && prev_future_epoch < week_time){
                        // If we went across one or multiple epochs, apply the rate
                        // of the first epoch until it ends, and then the rate of
                        // the last epoch.
                        // If more than one epoch is crossed - the gauge gets less,
                        // but that'd meen it wasn't called for more than 1 year
                        _integrate_inv_supply += rate * w * (prev_future_epoch - prev_week_time) / _working_supply;
                        rate = new_rate;
                        _integrate_inv_supply += rate * w * (week_time - prev_future_epoch) / _working_supply;
                    }else{
                        _integrate_inv_supply += rate * w * dt / _working_supply;
                    }
                    // On precisions of the calculation
                    // rate ~= 10e18
                    // last_weight > 0.01 * 1e18 = 1e16 (if pool weight is 1%)
                    // _working_supply ~= TVL * 1e18 ~= 1e26 ($100M for example)
                    // The largest loss is at dt = 1
                    // Loss is 1e-9 - acceptable
                }

                if (week_time == block.timestamp){
                    break;
                }
                prev_week_time = week_time;
                week_time = min(week_time + WEEK, block.timestamp);
            }
        }

        _period += 1;
        period = _period;
        period_timestamp[_period] = block.timestamp;
        integrate_inv_supply[_period] = _integrate_inv_supply;

        // Update user-specific integrals
        uint256 _working_balance = working_balances[addr];
        integrate_fraction[addr] += _working_balance * (_integrate_inv_supply - integrate_inv_supply_of[addr]) / 10 ** 18;
        integrate_inv_supply_of[addr] = _integrate_inv_supply;
        integrate_checkpoint_of[addr] = block.timestamp;
    }

    function user_checkpoint(address addr)external returns (bool){
        /**
        *@notice Record a checkpoint for `addr`
        *@param addr User address
        *@return bool success
        */
        assert ((msg.sender == addr) || (msg.sender == minter));  // dev unauthorized
        _checkpoint(addr);
        _update_liquidity_limit(addr, balanceOf[addr], totalSupply);
        return true;
    }

    function claimable_tokens(address addr)external returns (uint256){
        /**
        *@notice Get the number of claimable tokens per user
        *@dev This function should be manually changed to "view" in the ABI
        *@return uint256 number of claimable tokens per user
        */
        _checkpoint(addr);
        return (integrate_fraction[addr] - Minter(minter).minted(addr, address(this)));
    }

    //@shun: //@nonreentrant('lock')
    function claimable_reward(address _addr, address _token)external returns (uint256){
        /**
        *@notice Get the number of claimable reward tokens for a user
        *@dev This function should be manually changed to "view" in the ABI
        *    Calling it via a transaction will claim available reward tokens
        *@param _addr Account to get reward amount for
        *@param _token Token to get reward amount for
        *@return uint256 Claimable reward token amount
        */
        uint256 claimable = ERC20(_token).balanceOf(_addr);
        if (reward_contract != address(0)){
            _checkpoint_rewards(_addr, totalSupply);
        }
        claimable = ERC20(_token).balanceOf(_addr) - claimable;

        uint256 integral = reward_integral[_token];
        uint256 integral_for = reward_integral_for[_token][_addr];

        if (integral_for < integral){
            claimable += balanceOf[_addr] * (integral - integral_for) / 10**18;
        }

        return claimable;
    }


    //@shun: //@nonreentrant('lock')
    function claim_rewards(address _addr = msg.sender)external{
        /**
        *@notice Claim available reward tokens for `_addr`
        *@param _addr Address to claim for
        */
        _checkpoint_rewards(_addr, totalSupply);
    }

    //@shun: //@nonreentrant('lock')
    function claim_historic_rewards(address[MAX_REWARDS] _reward_tokens, address _addr = msg.sender)external{
        /**
        *@notice Claim reward tokens available from a previously-set staking contract
        *@param _reward_tokens Array of reward token addresses to claim
        *@param _addr Address to claim for
        */
        for(uint i; i<_reward_tokens.length; i++){ //token in _reward_tokens
            address token = _reward_tokens[i];
            if (token == address(0)){
                break;
            }
            uint256 integral = reward_integral[token];
            uint256 integral_for = reward_integral_for[token][_addr];

            if (integral_for < integral){
                uint256 claimable = balanceOf[_addr] * (integral - integral_for) / 10**18;
                reward_integral_for[token][_addr] = integral;
                Bytes[32] response = raw_call(
                    token,
                    concat(
                        method_id("transfer(address,uint256)"),
                        convert(_addr, bytes32),
                        convert(claimable, bytes32),
                    ),
                    max_outsize=32,
                );
                if (len(response) != 0){
                    assert (convert(response, bool));
                }
            }
        }
    }

    function kick(address addr)external{
        /**
        *@notice Kick `addr` for abusing their boost
        *@dev Only if either they had another voting event, or their voting escrow lock expired
        *@param addr Address to kick
        */
        address _voting_escrow = voting_escrow;
        uint256 t_last = integrate_checkpoint_of[addr];
        uint256 t_ve = VotingEscrow(_voting_escrow).user_point_history__ts(
            addr, VotingEscrow(_voting_escrow).user_point_epoch(addr)
        );
        uint256 _balance = balanceOf[addr];

        assert (ERC20(voting_escrow).balanceOf(addr) == 0 || t_ve > t_last); // dev kick not allowed
        assert (working_balances[addr] > _balance * TOKENLESS_PRODUCTION / 100);  // dev kick not needed

        _checkpoint(addr);
        _update_liquidity_limit(addr, balanceOf[addr], totalSupply);
    }

    function set_approve_deposit(address addr, bool can_deposit)external{
        /**
        *@notice Set whether `addr` can deposit tokens for `msg.sender`
        *@param addr Address to set approval on
        *@param can_deposit bool - can this account deposit for `msg.sender`?
        */
        approved_to_deposit[addr][msg.sender] = can_deposit;
    }

    //@shun: //@nonreentrant('lock')
    function deposit(uint256 _value, address _addr = msg.sender)external{
        /**
        *@notice Deposit `_value` LP tokens
        *@dev Depositting also claims pending reward tokens
        *@param _value Number of tokens to deposit
        *@param _addr Address to deposit for
        */
        if (_addr != msg.sender){
            assert(approved_to_deposit[msg.sender][_addr], "Not approved");
        }

        _checkpoint(_addr);

        if (_value != 0){
            address reward_contract = reward_contract;
            uint256 total_supply = totalSupply;
            if (reward_contract != address(0)){
                _checkpoint_rewards(_addr, total_supply);
            }

            total_supply += _value;
            uint256 new_balance = balanceOf[_addr] + _value;
            balanceOf[_addr] = new_balance;
            totalSupply = total_supply;

            _update_liquidity_limit(_addr, new_balance, total_supply);

            ERC20(lp_token).transferFrom(msg.sender, address(this), _value);
            if (reward_contract != address(0)){
                Bytes[4] deposit_sig = slice(reward_sigs, 0, 4);
                if (convert(deposit_sig, uint256) != 0){
                    raw_call(
                        reward_contract,
                        concat(deposit_sig, convert(_value, bytes32))
                    );
                }
            }
        }

        emit Deposit(_addr, _value);
        emit Transfer(address(0), _addr, _value);
    }


    //@shun: //@nonreentrant('lock')
    function withdraw(uint256 _value)external{
        /**
        *@notice Withdraw `_value` LP tokens
        *@dev Withdrawing also claims pending reward tokens
        *@param _value Number of tokens to withdraw
        */
        _checkpoint(msg.sender);

        if (_value != 0){
            address reward_contract = reward_contract;
            uint256 total_supply = totalSupply;
            if (reward_contract != address(0)){
                _checkpoint_rewards(msg.sender, total_supply);
            }

            total_supply -= _value;
            uint256 new_balance = balanceOf[msg.sender] - _value;
            balanceOf[msg.sender] = new_balance;
            totalSupply = total_supply;

            _update_liquidity_limit(msg.sender, new_balance, total_supply);

            if (reward_contract != address(0)){
                Bytes[4] withdraw_sig = slice(reward_sigs, 4, 4);
                if (convert(withdraw_sig, uint256) != 0){
                    raw_call(
                        reward_contract,
                        concat(withdraw_sig, convert(_value, bytes32))
                    );
                }
            }
            ERC20(lp_token).transfer(msg.sender, _value);
        }

        emit Withdraw(msg.sender, _value);
        emit Transfer(msg.sender, address(0), _value);
    }


    function allowance(address _owner, address _spender)external view returns (uint256){
        /**
        *@notice Check the amount of tokens that an owner allowed to a spender
        *@param _owner The address which owns the funds
        *@param _spender The address which will spend the funds
        *@return uint256 Amount of tokens still available for the spender
        */
        return allowances[_owner][_spender]
    }


    function _transfer(address _from, address _to, uint256 _value)internal{
        _checkpoint(_from);
        _checkpoint(_to);
        address reward_contract = reward_contract;

        if (_value != 0){
            uint256 total_supply = totalSupply;
            if (reward_contract != address(0)){
                _checkpoint_rewards(_from, total_supply);
            }
            uint256 new_balance = balanceOf[_from] - _value;
            balanceOf[_from] = new_balance;
            _update_liquidity_limit(_from, new_balance, total_supply);

            if (reward_contract != address(0)){
                _checkpoint_rewards(_to, total_supply);
            }
            new_balance = balanceOf[_to] + _value;
            balanceOf[_to] = new_balance;
            _update_liquidity_limit(_to, new_balance, total_supply);
        }

        emit Transfer(_from, _to, _value);
    }

    //@shun: //@nonreentrant('lock')
    function transfer(address _to, uint256 _value)external returns (bool){
        /**
        *@notice Transfer token for a specified address
        *@dev Transferring claims pending reward tokens for the sender and receiver
        *@param _to The address to transfer to.
        *@param _value The amount to be transferred.
        */
        _transfer(msg.sender, _to, _value);

        return true;
    }
    //@shun: //@nonreentrant('lock')
    function transferFrom(address _from, address _to, uint256 _value)external returns (bool){
        /**
        *@notice Transfer tokens from one address to another.
        *@dev Transferring claims pending reward tokens for the sender and receiver
        *@param _from address The address which you want to send tokens from
        *@param _to address The address which you want to transfer to
        *@param _value uint256 the amount of tokens to be transferred
        */
        uint256 _allowance = allowances[_from][msg.sender];
        if (_allowance != MAX_UINT256){
            allowances[_from][msg.sender] = _allowance - _value;
        }
        _transfer(_from, _to, _value);

        return true;

    }

    function approve(address _spender, uint256 _value)external returns (bool){
        /**
        *@notice Approve the passed address to transfer the specified amount of
        *        tokens on behalf of msg.sender
        *@dev Beware that changing an allowance via this method brings the risk
        *    that someone may use both the old and new allowance by unfortunate
        *    transaction ordering. This may be mitigated with the use of
        *    {incraseAllowance} and {decreaseAllowance}.
        *    https//github.com/ethereum/EIPs/issues/20//issuecomment-263524729
        *@param _spender The address which will transfer the funds
        *@param _value The amount of tokens that may be transferred
        *@return bool success
        */
        allowances[msg.sender][_spender] = _value;
        emit Approval(msg.sender, _spender, _value);

        return true;
    }

    function increaseAllowance(_spender address, _added_value uint256)external returns (bool){
        /**
        *@notice Increase the allowance granted to `_spender` by the caller
        *@dev This is alternative to {approve} that can be used as a mitigation for
        *    the potential race condition
        *@param _spender The address which will transfer the funds
        *@param _added_value The amount of to increase the allowance
        *@return bool success
        */
        uint256 allowance = allowances[msg.sender][_spender] + _added_value;
        allowances[msg.sender][_spender] = allowance;

        emit Approval(msg.sender, _spender, allowance);

        return true;
    }

    function decreaseAllowance(address _spender, uint256 _subtracted_value)external returns (bool){
        /**
        *@notice Decrease the allowance granted to `_spender` by the caller
        *@dev This is alternative to {approve} that can be used as a mitigation for
        *    the potential race condition
        *@param _spender The address which will transfer the funds
        *@param _subtracted_value The amount of to decrease the allowance
        *@return bool success
        */
        uint256 allowance = allowances[msg.sender][_spender] - _subtracted_value;
        allowances[msg.sender][_spender] = allowance;

        emit Approval(msg.sender, _spender, allowance);

        return true;
    }

    //@shun: //@nonreentrant('lock')
    function set_rewards(address _reward_contract, bytes32 _sigs, address[MAX_REWARDS] _reward_tokens)external{
        /**
        *@notice Set the active reward contract
        *@dev A reward contract cannot be set while this contract has no deposits
        *@param _reward_contract Reward contract address. Set to address(0) to
        *                        disable staking.
        *@param _sigs Four byte selectors for staking, withdrawing and claiming,
        *            right padded with zero bytes. If the reward contract can
        *            be claimed from but does not require staking, the staking
        *            and withdraw selectors should be set to 0x00
        *@param _reward_tokens List of claimable tokens for this reward contract
        */
        assert (msg.sender == admin);

        address lp_token = lp_token;
        address current_reward_contract = reward_contract;
        uint256 total_supply = totalSupply;
        if (current_reward_contract != address(0)){
            _checkpoint_rewards(address(0), total_supply);
            Bytes[4] withdraw_sig = slice(reward_sigs, 4, 4);
            if (convert(withdraw_sig, uint256) != 0){
                if (total_supply != 0){
                    raw_call(
                        current_reward_contract,
                        concat(withdraw_sig, convert(total_supply, bytes32))
                    );
                }
                ERC20(lp_token).approve(current_reward_contract, 0);
            }
        }

        if (_reward_contract != address(0)){
            assert _reward_contract.is_contract;  // dev not a contract
            bytes32 sigs = _sigs;
            Bytes[4] deposit_sig = slice(sigs, 0, 4);
            Bytes[4] withdraw_sig = slice(sigs, 4, 4);

            if (convert(deposit_sig, uint256) != 0){
                // need a non-zero total supply to verify the sigs
                assert (total_supply != 0);  // dev zero total supply
                ERC20(lp_token).approve(_reward_contract, MAX_UINT256);

                // it would be Very Bad if we get the signatures wrong here, so
                // we do a test deposit and withdrawal prior to setting them
                raw_call(
                    _reward_contract,
                    concat(deposit_sig, convert(total_supply, bytes32))
                );  // dev failed deposit
                assert (ERC20(lp_token).balanceOf(address(this)) == 0);
                raw_call(
                    _reward_contract,
                    concat(withdraw_sig, convert(total_supply, bytes32))
                );  // dev failed withdraw
                assert (ERC20(lp_token).balanceOf(address(this)) == total_supply);

                // deposit and withdraw are good, time to make the actual deposit
                raw_call(
                    _reward_contract,
                    concat(deposit_sig, convert(total_supply, bytes32))
                );
            }else{
                assert (convert(withdraw_sig, uint256) == 0);  // dev withdraw without deposit
            }
        }

        reward_contract = _reward_contract;
        reward_sigs = _sigs;
        for (uint i; i<MAX_REWARDS; i++){
            if (_reward_tokens[i] != address(0)){
                reward_tokens[i] = _reward_tokens[i];
            }else if (reward_tokens[i] != address(0)){
                reward_tokens[i] = address(0);
            }else{
                assert (i != 0);  // dev no reward token
                break;
            }
        }

        if (_reward_contract != address(0)){
            // do an initial checkpoint to verify that claims are working
            _checkpoint_rewards(address(0), total_supply);
        }
    }

    function set_killed(bool _is_killed)external{
        /**
        *@notice Set the killed status for this contract
        *@dev When killed, the gauge always yields a rate of 0 and so cannot mint CRV
        *@param _is_killed Killed status to set
        */
        assert (msg.sender == admin);

        is_killed = _is_killed;
    }


    function commit_transfer_ownership(address addr)external{
        /**
        *@notice Transfer ownership of GaugeController to `addr`
        *@param addr Address to have ownership transferred to
        */
        assert (msg.sender == admin ); // dev admin only

        future_admin = addr;
        emit CommitOwnership(addr);
    }

    function accept_transfer_ownership()external{
        /**
        *@notice Accept a pending ownership transfer
        */
        address _admin = future_admin;
        assert(msg.sender == _admin);  // dev future admin only

        admin = _admin;
        emit ApplyOwnership(_admin);
    }
}

// @version 0.2.4
/**
@title Staking Liquidity Gauge
@author Curve Finance
@license MIT
@notice Simultaneously stakes using Synthetix (== YFI) rewards contract
*/

//from vyper.interfaces import ERC20
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
*interface CurveRewards
*    function stake(amount uint256) nonpayable
*    function withdraw(amount uint256) nonpayable
*    function getReward() nonpayable
*    function earned(addr address) returns uint256 view
*/
contract LiquidityGaugeReward{

    event Deposit(address indexed provider,uint256 value);
    event Withdraw(address indexed provider, uint256 value);
    event UpdateLiquidityLimit(address user, uint256 original_balance, uint256 original_supply, uint256 working_balance, uint256 working_supply);
    event CommitOwnership(address admin);
    event ApplyOwnership(address admin);


    uint256 constant TOKENLESS_PRODUCTION = 40;
    uint256 constant BOOST_WARMUP = 2 * 7 * 86400;
    uint256 constant WEEK = 604800;

    address public minter;
    address public crv_token;
    address public lp_token;
    address public controller;
    address public voting_escrow;
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;
    uint256 public future_epoch_time;

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
    address public rewarded_token;

    uint256 public reward_integral;
    mapping(address => uint256) public reward_integral_for;
    mapping(address => uint256) public rewards_for;
    mapping(address => uint256) public claimed_rewards_for;

    address public admin;
    address public future_admin; // Can and will be a smart contract
    bool public is_killed;
    bool public is_claiming_rewards;

    function __init__(address lp_addr, address _minter, address _reward_contract, address _rewarded_token, address _admin)external{
        /**
        *@notice Contract constructor
        *@param lp_addr Liquidity Pool contract address
        *@param _minter Minter contract address
        *@param _reward_contract Synthetix reward contract address
        *@param _rewarded_token Received synthetix token contract address
        *@param _admin Admin who can kill the gauge
        */
        assert (lp_addr != address(0));
        assert (_minter != address(0));
        assert (_reward_contract != address(0));

        lp_token = lp_addr;
        minter = _minter;
        address crv_addr = Minter(_minter).token();
        crv_token = crv_addr;
        address controller_addr = Minter(_minter).controller();
        controller = controller_addr;
        voting_escrow = Controller(controller_addr).voting_escrow();
        period_timestamp[0] = block.timestamp;
        inflation_rate = CRV20(crv_addr).rate();
        future_epoch_time = CRV20(crv_addr).future_epoch_time_write();
        reward_contract = _reward_contract;
        assert (ERC20(lp_addr).approve(_reward_contract, MAX_UINT256));
        rewarded_token = _rewarded_token;
        admin = _admin;
        is_claiming_rewards = true;
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
        if ((voting_total > 0) && (block.timestamp > period_timestamp[0] + BOOST_WARMUP)){
            lim += L * voting_balance / voting_total * (100 - TOKENLESS_PRODUCTION) / 100;
        }
        lim = min(l, lim);
        uint256 old_bal = working_balances[addr];
        working_balances[addr] = lim;
        uint256 _working_supply = working_supply + lim - old_bal;
        working_supply = _working_supply;

        emit UpdateLiquidityLimit(addr, l, L, lim, _working_supply);
    }

    function _checkpoint_rewards(address addr, bool claim_rewards)internal{
        // Update reward integrals (no gauge weights involved easy)
        _rewarded_token address = rewarded_token;

        uint256 d_reward = 0;
        if (claim_rewards){
            d_reward = ERC20(_rewarded_token).balanceOf(address(this));
            CurveRewards(reward_contract).getReward();
            d_reward = ERC20(_rewarded_token).balanceOf(address(this)) - d_reward;
        }

        uint256 user_balance = balanceOf[addr];
        uint256 total_balance = totalSupply;
        uint256 dI = 0;
        if (total_balance > 0){
            dI = 10 ** 18 * d_reward / total_balance;
        }
        uint256 I = reward_integral + dI;
        reward_integral = I;
        rewards_for[addr] += user_balance * (I - reward_integral_for[addr]) / 10 ** 18;
        reward_integral_for[addr] = I;
    }

    function _checkpoint(address addr, bool claim_rewards)internal{
        /**
        *@notice Checkpoint for a user
        *@param addr User address
        */
        address _token = crv_token;
        address _controller = controller;
        int128 _period = period;
        uint256 _period_time = period_timestamp[_period];
        uint256 _integrate_inv_supply = integrate_inv_supply[_period];
        uint256 rate = inflation_rate;
        uint256 new_rate = rate;
        uint256 prev_future_epoch = future_epoch_time;
        if (prev_future_epoch >= _period_time){
            future_epoch_time = CRV20(_token).future_epoch_time_write();
            new_rate = CRV20(_token).rate();
            inflation_rate = new_rate;
        Controller(_controller).checkpoint_gauge(address(this));

        uint256 _working_balance = working_balances[addr];
        uint256 _working_supply = working_supply;

        if (is_killed){
            rate = 0;  // Stop distributing inflation as soon as killed
        }

        // Update integral of 1/supply
        if (block.timestamp > _period_time){
            uint256 prev_week_time = _period_time;
            uint256 week_time = min((_period_time + WEEK) / WEEK * WEEK, block.timestamp);

            for (uint i; i < 500; i++){
                uint256 dt = week_time - prev_week_time;
                uint256 w = Controller(_controller).gauge_relative_weight(address(this), prev_week_time / WEEK * WEEK);

                if (_working_supply > 0){
                    if (prev_future_epoch >= prev_week_time and prev_future_epoch < week_time){
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
        integrate_fraction[addr] += _working_balance * (_integrate_inv_supply - integrate_inv_supply_of[addr]) / 10 ** 18;
        integrate_inv_supply_of[addr] = _integrate_inv_supply;
        integrate_checkpoint_of[addr] = block.timestamp;

        _checkpoint_rewards(addr, claim_rewards);
    }


    function user_checkpoint(address addr)external returns(bool){
        /**
        *@notice Record a checkpoint for `addr`
        *@param addr User address
        *@return bool success
        */
        assert( (msg.sender == addr) || (msg.sender == minter) ); // dev unauthorized
        _checkpoint(addr, is_claiming_rewards);
        _update_liquidity_limit(addr, balanceOf[addr], totalSupply);
        return true;
    }

    function claimable_tokens(address addr)external returns (uint256){
        /**
        *@notice Get the number of claimable tokens per user
        *@dev This function should be manually changed to "view" in the ABI
        *@return uint256 number of claimable tokens per user
        */
        _checkpoint(addr, true);
        return integrate_fraction[addr] - Minter(minter).minted(addr, address(this));
    }

    function claimable_reward(addr address)external view returns (uint256){
        /**
        *@notice Get the number of claimable reward tokens for a user
        *@param addr Account to get reward amount for
        *@return uint256 Claimable reward token amount
        */
        uint256 d_reward = CurveRewards(reward_contract).earned(address(this));

        uint256 user_balance  = balanceOf[addr];
        uint256 total_balance  = totalSupply;
        uint256 dI  = 0;
        if (total_balance > 0){
            dI = 10 ** 18 * d_reward / total_balance;
        }
        uint256 I  = reward_integral + dI;

        return rewards_for[addr] + user_balance * (I - reward_integral_for[addr]) / 10 ** 18;
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

        assert (ERC20(voting_escrow).balanceOf(addr) == 0 or t_ve > t_last); // dev kick not allowed
        assert (working_balances[addr] > _balance * TOKENLESS_PRODUCTION / 100);  // dev kick not needed

        _checkpoint(addr, is_claiming_rewards);
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
    function deposit(uint256 _value, address addr = msg.sender)external{
        /**
        *@notice Deposit `_value` LP tokens
        *@param _value Number of tokens to deposit
        *@param addr Address to deposit for
        */
        if (addr != msg.sender){
            assert (approved_to_deposit[msg.sender][addr], "Not approved");
        }

        _checkpoint(addr, true);

        if (_value != 0){
            uint256 _balance = balanceOf[addr] + _value;
            uint256 _supply = totalSupply + _value;
            balanceOf[addr] = _balance;
            totalSupply = _supply;

            _update_liquidity_limit(addr, _balance, _supply);

            assert (ERC20(lp_token).transferFrom(msg.sender, address(this), _value));
            CurveRewards(reward_contract).stake(_value);
        }

        emit Deposit(addr, _value);
    }

    //@shun: //@nonreentrant('lock')
    function withdraw(uint256 _value, bool claim_rewards = true)external{
        /**
        *@notice Withdraw `_value` LP tokens
        *@param _value Number of tokens to withdraw
        */
        _checkpoint(msg.sender, claim_rewards);

        uint256 _balance = balanceOf[msg.sender] - _value;
        uint256 _supply = totalSupply - _value;
        balanceOf[msg.sender] = _balance;
        totalSupply = _supply;

        _update_liquidity_limit(msg.sender, _balance, _supply);

        if (_value > 0){
            CurveRewards(reward_contract).withdraw(_value);
            assert (ERC20(lp_token).transfer(msg.sender, _value));
        }

        emit Withdraw(msg.sender, _value)
    }

    //@shun: //@nonreentrant('lock')
    function claim_rewards(address addr = msg.sender)external{
        _checkpoint_rewards(addr, true);
        uint256 _rewards_for = rewards_for[addr];
        assert (ERC20(rewarded_token).transfer(
            addr, _rewards_for - claimed_rewards_for[addr]));
        claimed_rewards_for[addr] = _rewards_for;
    }

    function integrate_checkpoint()external view returns (uint256){
        return period_timestamp[period];
    }


    function kill_me()external{
        assert (msg.sender == admin)
        is_killed = !is_killed
    }

    function commit_transfer_ownership(address addr)external{
        /**
        *@notice Transfer ownership of GaugeController to `addr`
        *@param addr Address to have ownership transferred to
        */
        assert (msg.sender == admin);  // dev admin only
        future_admin = addr;
        emit CommitOwnership(addr);
    }

    function apply_transfer_ownership()external{
        /**
        *@notice Apply pending ownership transfer
        */
        assert( msg.sender == admin ); // dev admin only
        address _admin = future_admin;
        assert (_admin != address(0));  // dev admin not set
        admin = _admin;
        emit ApplyOwnership(_admin);
    }

    function toggle_external_rewards_claim(bool val)external{
        /**
        *@notice Switch claiming rewards on/off. 
        *        This is to prevent a malicious rewards contract from preventing CRV claiming
        */ 
        assert (msg.sender == admin);
        is_claiming_rewards = val;
    }
}

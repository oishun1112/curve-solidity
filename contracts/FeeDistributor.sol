pragma solidity >=0.6.0 <0.8.0;
/**
*@title Curve Fee Distribution
*@author Curve Finance
*@license MIT
*/

//@shun: from vyper.interfaces import ERC20

contract FeeDistribution {

    interface VotingEscrow{
        function user_point_epoch(address addr) view returns(uint256);
        function epoch() view returns(uint256);
        function user_point_history(address addr, uint256 loc) view returns(Point);
        function point_history(uint256 loc) view returns(Point);
        function checkpoint() nonpayable;
    }

    event CommitAdmin(address admin);
    event ApplyAdmin(address admin);
    event ToggleAllowCheckpointToken(bool toggle_flag);
    event CheckpointToken(uint256 time, uint256 tokens);
    event Claimed(address indexed recipient, uint256 amount, uint256 claim_epoch, uint256 max_epoch);

    struct Point{
        int128 bias;
        int128 slope; // - dweight / dt
        uint256 ts;
        uint256 blk;  // block
    }

    uint256 constant WEEK = 7 * 86400;
    uint256 constant TOKEN_CHECKPOINT_DEADLINE = 86400;

    uint256 public start_time;
    uint256 public time_cursor;
    mapping(address => uint256) public time_cursor_of;
    mapping(address => uint256) public user_epoch_of;

    uint256 public last_token_time;
    uint256[1000000000000000] public tokens_per_week;

    address public voting_escrow;
    address public token;
    uint256 public total_received;
    uint256 public token_last_balance;

    uint256[1000000000000000] public ve_supply;  // VE total supply at week bounds

    address public admin;
    address public future_admin;
    bool public can_checkpoint_token;
    address public emergency_return;
    bool public is_killed;


    function __init__(
        address _voting_escrow,
        uint256 _start_time,
        address _token,
        address _admin,
        address _emergency_return
    )external {
        /**
        *@notice Contract constructor
        *@param _voting_escrow VotingEscrow contract address
        *@param _start_time Epoch time for fee distribution to start
        *@param _token Fee token address (3CRV)
        *@param _admin Admin address
        *@param _emergency_return Address to transfer `_token` balance to
        *                        if this contract is killed
        */
        uint256 t = _start_time / WEEK * WEEK;
        start_time = t;
        last_token_time = t;
        time_cursor = t;
        token = _token;
        voting_escrow = _voting_escrow;
        admin = _admin;
        emergency_return = _emergency_return;
    }

    function _checkpoint_token()internal {
        uint256 token_balance = ERC20(token).balanceOf(self); //@shun: inheritate
        uint256 to_distribute = token_balance - token_last_balance;
        token_last_balance = token_balance;

        tuint256 = last_token_time;
        uint256 since_last = block.timestamp - t;
        last_token_time = block.timestamp;
        uint256 this_week = t / WEEK * WEEK;
        uint256 next_week = 0;

        for(uint i; i <= 20; i++){
            next_week = this_week + WEEK;
            if (block.timestamp < next_week){
                if (since_last == 0 and block.timestamp == t){
                    tokens_per_week[this_week] += to_distribute;
                }else{
                    tokens_per_week[this_week] += to_distribute * (block.timestamp - t) / since_last;
                }
                break;
            }else{
                if (since_last == 0 and next_week == t){
                    tokens_per_week[this_week] += to_distribute;
                }else{
                    tokens_per_week[this_week] += to_distribute * (next_week - t) / since_last;
                }
            }
            t = next_week;
            this_week = next_week;
        }
        emit CheckpointToken(block.timestamp, to_distribute);
    }

    function checkpoint_token()external {
        /**
        *@notice Update the token checkpoint
        *@dev Calculates the total number of tokens to be distributed in a given week.
        *    During setup for the initial distribution this function is only callable
        *    by the contract owner. Beyond initial distro, it can be enabled for anyone
        *    to call.
        */
        assert (msg.sender == admin || can_checkpoint_token && (block.timestamp > last_token_time + TOKEN_CHECKPOINT_DEADLINE));
        _checkpoint_token();
    }

    function _find_timestamp_epoch(address ve, uint256 _timestamp)internal returns (uint256){
        uint256 _min = 0
        uint256 _max = VotingEscrow(ve).epoch();
        for (uint i; i<= 128; i++)
            if (_min >= _max){
                break;
            }
            uint256 _mid = (_min + _max + 2) / 2;
            Point pt = VotingEscrow(ve).point_history(_mid);
            if (pt.ts <= _timestamp){
                _min = _mid;
            }else{
                _max = _mid - 1;
            }
        return _min;
    }

    function _find_timestamp_user_epoch(address ve , address user , uint256 _timestamp , uint256 max_user_epoch )internal view returns(uint256){
        uint256 _min  = 0;
        uint256 _max  = max_user_epoch;
        for (uint i; i<= 128; i++){
            if (_min >= _max){
                break;
            }
            uint256 _mid = (_min + _max + 2) / 2;
            Point pt = VotingEscrow(ve).user_point_history(user, _mid);
            if (pt.ts <= _timestamp){
                _min = _mid;
            }else{
                _max = _mid - 1;
            }
        }
        return _min;
    }
    
    function max(uint a, uint b) private pure returns (uint) {//@shun: I added
        return a > b ? a : b;
    }
    function max(uint a, int b) private pure returns (uint) {//@shun: I added
        return a > b ? a : b;
    }
    function min(uint a, uint b) internal pure returns (uint256) {//@shun: I added
        return a < b ? a : b;
    }
    function min(uint a, int b) internal pure returns (uint256) {//@shun: I added
        return a < b ? a : b;
    }

    function ve_for_at(address _user, uint256 _timestamp )external view returns (uint256){
        /**
        *@notice Get the veCRV balance for `_user` at `_timestamp`
        *@param _user Address to query balance for
        *@param _timestamp Epoch time
        *@return uint256 veCRV balance
        */
        address ve  = voting_escrow;
        uint256 max_user_epoch  = VotingEscrow(ve).user_point_epoch(_user);
        uint256 epoch  = _find_timestamp_user_epoch(ve, _user, _timestamp, max_user_epoch);
        Point pt  = VotingEscrow(ve).user_point_history(_user, epoch);
        return convert(max(pt.bias - pt.slope * convert(_timestamp - pt.ts, int128), 0), uint256);
    }

    function _checkpoint_total_supply()internal{
        address ve  = voting_escrow;
        uint256 t  = time_cursor;
        uint256 rounded_timestamp  = block.timestamp / WEEK * WEEK;
        VotingEscrow(ve).checkpoint();

        for(uint i; i <= 20; i++){
            if (t > rounded_timestamp){
                break;
            }else{
                uint256 epoch = _find_timestamp_epoch(ve, t);
                Point pt = VotingEscrow(ve).point_history(epoch);
                int128 dt = 0;
                if (t > pt.ts){
                    // If the point is at 0 epoch, it can actually be earlier than the first deposit
                    // Then make dt 0
                    dt = convert(t - pt.ts, int128);
                }
                ve_supply[t] = convert(max(pt.bias - pt.slope * dt, 0), uint256);
            }
            t += WEEK;
        }
        time_cursor = t;
    }

    function checkpoint_total_supply()external {
        /**
        *@notice Update the veCRV total supply checkpoint
        *@dev The checkpoint is also updated by the first claimant each
        *    new epoch week. This function may be called independently
        *    of a claim, to reduce claiming gas costs.
        */
        _checkpoint_total_supply();
    }

    function _claim(address addr, address ve, uint256 _last_token_time )internal returns (uint256){
        // Minimal user_epoch is 0 (if user had no point)
        uint256 user_epoch  = 0;
        uint256 to_distribute  = 0;

        uint256 max_user_epoch  = VotingEscrow(ve).user_point_epoch(addr);
        uint256 _start_time  = start_time;

        if (max_user_epoch == 0){
            // No lock = no fees
            return 0;
        }
        uint256 week_cursor  = time_cursor_of[addr];
        if (week_cursor == 0){
            // Need to do the initial binary search
            user_epoch = _find_timestamp_user_epoch(ve, addr, _start_time, max_user_epoch);
        }else{
            user_epoch = user_epoch_of[addr];
        }
        if (user_epoch == 0){
            user_epoch = 1;
        }

        user_point Point = VotingEscrow(ve).user_point_history(addr, user_epoch);

        if (week_cursor == 0){
            week_cursor = (user_point.ts + WEEK - 1) / WEEK * WEEK;
        }

        if (week_cursor >= _last_token_time){
            return 0;
        }

        if (week_cursor < _start_time){
            week_cursor = _start_time;
        }
        old_user_point Point = empty(Point);

        // Iterate over weeks
        for (uint i; i<= 50; i++)
            if (week_cursor >= _last_token_time){
                break;
            }

            if (week_cursor >= user_point.ts && user_epoch <= max_user_epoch){
                user_epoch += 1;
                old_user_point = user_point;
                if (user_epoch > max_user_epoch){
                    user_point = empty(Point);
                }else{
                    user_point = VotingEscrow(ve).user_point_history(addr, user_epoch);
                }
            }else{
                // Calc
                // + i * 2 is for rounding errors
                int128 dt  = convert(week_cursor - old_user_point.ts, int128);
                uint256 balance_of  = convert(max(old_user_point.bias - dt * old_user_point.slope, 0), uint256);
                if (balance_of == 0 && user_epoch > max_user_epoch){
                    break;
                }
                if (balance_of > 0){
                    to_distribute += balance_of * tokens_per_week[week_cursor] / ve_supply[week_cursor];
                }

                week_cursor += WEEK;

        user_epoch = min(max_user_epoch, user_epoch - 1);
        user_epoch_of[addr] = user_epoch;
        time_cursor_of[addr] = week_cursor;

        emit Claimed(addr, to_distribute, user_epoch, max_user_epoch);

        return to_distribute;
    }

    @nonreentrant('lock') //@shun: OpenZeppelin’s ReentrancyGuard
    function claim(address _addr = msg.sender) external returns (uint256){
        /**
        *@notice Claim fees for `_addr`
        *@dev Each call to claim look at a maximum of 50 user veCRV points.
        *    For accounts with many veCRV related actions, this function
        *    may need to be called more than once to claim all available
        *    fees. In the `Claimed` event that fires, if `claim_epoch` is
        *    less than `max_epoch`, the account may claim again.
        *@param _addr Address to claim fees for
        *@return uint256 Amount of fees claimed in the call
        */
        assert(is_killed == false);

        if (block.timestamp >= time_cursor){
            _checkpoint_total_supply();
        }

        uint256 last_token_time  = last_token_time;

        if (can_checkpoint_token && (block.timestamp > last_token_time + TOKEN_CHECKPOINT_DEADLINE)){
            _checkpoint_token();
            last_token_time = block.timestamp;
        }
        last_token_time = last_token_time / WEEK * WEEK;

        uint256 amount = _claim(_addr, voting_escrow, last_token_time);
        if (amount != 0){
            address token  = token;
            assert(ERC20(token).transfer(_addr, amount));
            token_last_balance -= amount;
        }
        return amount;
    }

    @nonreentrant('lock')
    function claim_many(_receivers address[20])external returns (bool){
        /**
        @notice Make multiple fee claims in a single call
        @dev Used to claim for many accounts at once, or to make
            multiple claims for the same address when that address
            has significant veCRV history
        @param _receivers List of addresses to claim for. Claiming
                        terminates at the first `address(0)`.
        @return bool success
        */
        assert(is_killed == false);

        if (block.timestamp >= time_cursor){
            _checkpoint_total_supply();
        }

        uint256 last_token_time  = last_token_time;

        if (can_checkpoint_token && (block.timestamp > last_token_time + TOKEN_CHECKPOINT_DEADLINE)){
            _checkpoint_token();
            last_token_time = block.timestamp;
        }

        last_token_time = last_token_time / WEEK * WEEK;
        address voting_escrow  = voting_escrow;
        address token  = token;
        uint256 total  = 0;

        while(addr <= _receivers){
            if(addr == address(0)){
                break;
            }

            uint256 amount  = _claim(addr, voting_escrow, last_token_time);
            if (amount != 0){
                assert (ERC20(token).transfer(addr, amount));
                total += amount;
            }
        }
        if (total != 0){
            token_last_balance -= total;
        }

        return True
    }

    function burn(_coin address)external returns (bool){
        /**
        *@notice Receive 3CRV into the contract and trigger a token checkpoint
        *@param _coin Address of the coin being received (must be 3CRV)
        *@return bool success
        */
        assert (_coin == token);
        assert (is_killed == false);

        uint256 amount  = ERC20(_coin).balanceOf(msg.sender);
        if (amount != 0){
            ERC20(_coin).transferFrom(msg.sender, self, amount);
            if (can_checkpoint_token && (block.timestamp > last_token_time + TOKEN_CHECKPOINT_DEADLINE)){
                _checkpoint_token();
            }
        }
        return True;
    }

    function commit_admin(address _addr)external {
        /**
        *@notice Commit transfer of ownership
        *@param _addr New admin address
        */
        assert (msg.sender == admin);  // dev access denied
        future_admin = _addr;
        emit CommitAdmin(_addr);
    }

    function apply_admin()external {
        /**
        *@notice Apply transfer of ownership
        */
        assert (msg.sender == admin);
        assert (future_admin != address(0));
        address future_admin = future_admin;
        admin = future_admin;
        emit ApplyAdmin(future_admin);
    }

    function toggle_allow_checkpoint_token()external {
        /**
        *@notice Toggle permission for checkpointing by any account
        */
        assert (msg.sender == admin);
        bool flag = not can_checkpoint_token;
        can_checkpoint_token = flag;
        emit ToggleAllowCheckpointToken(flag);
    }

    function kill_me()external {
        /**
        *@notice Kill the contract
        *@dev Killing transfers the entire 3CRV balance to the emergency return address
        *    and blocks the ability to claim or burn. The contract cannot be unkilled.
        */
        assert (msg.sender == admin);

        is_killed = True;

        address token = token;
        assert (ERC20(token).transfer(emergency_return, ERC20(token).balanceOf(self)));
    }

    function recover_balance(_coin address)external returns (bool){
        /**
        *@notice Recover ERC20 tokens from this contract
        *@dev Tokens are sent to the emergency return address.
        *@param _coin Token address
        *@return bool success
        */
        assert (msg.sender == admin);
        assert (_coin != token);

        uint256 amount = ERC20(_coin).balanceOf(self);
        Bytes[32] response = raw_call(//@shun: 
            _coin, //@shun: the destination address to call to
            concat(//@shun: the data to send the called address
                method_id("transfer(address,uint256)"),
                convert(emergency_return, bytes32),
                convert(amount, bytes32),
            ),
            max_outsize=32,//@shun: the max-length for the bytes array returned from the call.
        );
        if (len(response) != 0){
            assert convert(response, bool)
        }
        return True;
    }
}

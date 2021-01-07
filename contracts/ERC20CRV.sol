

event Transfer(address indexed _from, address indexed _to, uint256 _value);
event Approval(address indexed _owner, address indexed _spender, uint256 _value);
event UpdateMiningParameters(uint256 time, uint256 rate, uint256 supply);
event SetMinter(address minter);
event SetAdmin(address admin);

string public name;
string public symbol;
uint256 public decimals;

mapping (address => uint256) public balanceOf;
mapping (address => mapping (address => uint256)) _allowances;
uint256 total_Supply;

address public minter;
address public admin;

//General constants
uint constant YEAR = 86400 * 365

// Allocation:
// =========
// * shareholders - 30%
// * emplyees - 3%
// * DAO-controlled reserve - 5%
// * Early users - 5%
// == 43% ==
// left for inflation: 57%

// Supply parameters
uint256 constant INITIAL_SUPPLY = 1_303_030_303;
uint256 constant INITIAL_RATE = 274_815_283 * 10 ** 18 / YEAR; // leading to 43% premine
uint256 constant RATE_REDUCTION_TIME = YEAR;

uint256 constant RATE_REDUCTION_COEFFICIENT = 1189207115002721024;  // 2 ** (1/4) * 1e18
uint256 constant RATE_DENOMINATOR = 10 ** 18;
uint256 constant INFLATION_DELAY = 86400;

// Supply variables
int128 public mining_epoch;
uint256 public start_epoch_time;
uint256 public rate;

uint256 start_epoch_supply;

function __init__(string _name, string _symbol, uint256 _decimals) external { //@shun constractor?
    /*
     @notice Contract constructor
     @param _name Token full name
     @param _symbol Token symbol
     @param _decimals Number of decimals for token
    */

    uint256 init_supply = INITIAL_SUPPLY * 10 ** _decimals;
    name = _name;
    symbol = _symbol;
    decimals = _decimals;
    balanceOf[msg.sender] = init_supply;
    total_supply = init_supply;
    admin = msg.sender;
    emit Transfer(account(0), msg.sender, init_supply);

    start_epoch_time = block.timestamp + INFLATION_DELAY - RATE_REDUCTION_TIME;
    mining_epoch = -1;
    rate = 0;
    start_epoch_supply = init_supply;
}


function _update_mining_parameters() internal{
    /*
    @dev Update mining rate and supply at the start of the epoch
         Any modifying mining call must also call this
    */
    uint256 _rate = rate;
    uint256 _start_epoch_supply = start_epoch_supply;

    start_epoch_time += RATE_REDUCTION_TIME;
    mining_epoch += 1;

    if (_rate == 0){
        _rate = INITIAL_RATE;
    }else{
        _start_epoch_supply += _rate * RATE_REDUCTION_TIME;
        start_epoch_supply = _start_epoch_supply;
        _rate = _rate * RATE_DENOMINATOR / RATE_REDUCTION_COEFFICIENT;
    }
    rate = _rate;
    emit UpdateMiningParameters(block.timestamp, _rate, _start_epoch_supply);
}

function update_mining_parameters() external{
    /*
    @notice Update mining rate and supply at the start of the epoch
    @dev Callable by any address, but only once per epoch
         Total supply becomes slightly larger if this function is called late
    */
    assert(block.timestamp >= start_epoch_time + RATE_REDUCTION_TIME);  // dev: too soon!
    _update_mining_parameters();
}

function start_epoch_time_write() external returns(uint256){
    /*
    @notice Get timestamp of the current mining epoch start
            while simultaneously updating mining parameters
    @return Timestamp of the epoch
    */
    uint256 _start_epoch_time = start_epoch_time;
    if (block.timestamp >= _start_epoch_time + RATE_REDUCTION_TIME){
        _update_mining_parameters();
        return start_epoch_time;
    }else{
        return _start_epoch_time;
    }
}


function future_epoch_time_write() external returns(uint256){
    /*
    @notice Get timestamp of the next mining epoch start
            while simultaneously updating mining parameters
    @return Timestamp of the next epoch
    */

    uint256 _start_epoch_time = start_epoch_time;
    if (block.timestamp >= _start_epoch_time + RATE_REDUCTION_TIME){
        _update_mining_parameters();
        return start_epoch_time + RATE_REDUCTION_TIME;
    }else{
        return _start_epoch_time + RATE_REDUCTION_TIME;
    }
}

function _available_supply() internal view returns(uint256){
    return start_epoch_supply + (block.timestamp - start_epoch_time) * rate;
}

function available_supply() external view returns(uint256){

    /*
    @notice Current number of tokens in existence (claimed or unclaimed)
    */
    return _available_supply();
}

function mintable_in_timeframe(uint256 start, uint256 end)external view returns(uint256){
    /*
    @notice How much supply is mintable from start timestamp till end timestamp
    @param start Start of the time interval (timestamp)
    @param end End of the time interval (timestamp)
    @return Tokens mintable from `start` till `end`
    */
    assert (start <= end);  // dev: start > end
    uint256 to_mint = 0;
    uint256 current_epoch_time = start_epoch_time;
    uint256 current_rate = rate;

    // Special case if end is in future (not yet minted) epoch
    if (end > current_epoch_time + RATE_REDUCTION_TIME){
        current_epoch_time += RATE_REDUCTION_TIME;
        current_rate = current_rate * RATE_DENOMINATOR / RATE_REDUCTION_COEFFICIENT;
    }

    assert (end <= current_epoch_time + RATE_REDUCTION_TIME);  // dev: too far in future

    for(uint i = 0; i < 999; i++){  // Curve will not work in 1000 years. Darn!
        if(end >= current_epoch_time){
            uint256 current_end = end;
            if(current_end > current_epoch_time + RATE_REDUCTION_TIME){
                current_end = current_epoch_time + RATE_REDUCTION_TIME;
            }
            uint256 current_start = start;
            if (current_start >= current_epoch_time + RATE_REDUCTION_TIME){
                break;  // We should never get here but what if...
            }else if(current_start < current_epoch_time){
                current_start = current_epoch_time;
            }
            to_mint += current_rate * (current_end - current_start);

            if (start >= current_epoch_time){
                break;
            }
        }
        current_epoch_time -= RATE_REDUCTION_TIME;
        current_rate = current_rate * RATE_REDUCTION_COEFFICIENT / RATE_DENOMINATOR;  // double-division with rounding made rate a bit less => good
        assert(current_rate <= INITIAL_RATE);  // This should never happen
    }

    return to_mint;
}

function set_minter(address _minter) external {
    /*
    @notice Set the minter address
    @dev Only callable once, when minter has not yet been set
    @param _minter Address of the minter
    */
    assert (msg.sender == admin);  // dev: admin only
    assert (minter == ZERO_ADDRESS);  // dev: can set the minter only once, at creation
    minter = _minter;
    emit SetMinter(_minter);
}

function set_admin(address _admin) external{
    /*
    @notice Set the new admin.
    @dev After all is set up, admin only can change the token name
    @param _admin New admin address
    */
    assert (msg.sender == admin);  // dev: admin only
    admin = _admin;
    emit SetAdmin(_admin);
}

function totalSupply()external view returns(uint256){
    /*
    @notice Total number of tokens in existence.
    */
    return total_supply;
}

function allowance(address _owner, address _spender)external view returns(uint256){
    /*
    @notice Check the amount of tokens that an owner allowed to a spender
    @param _owner The address which owns the funds
    @param _spender The address which will spend the funds
    @return uint256 specifying the amount of tokens still available for the spender
    */
    return allowances[_owner][_spender];
}

function transfer(address _to, uint256 _value) external returns(bool){
    /*
    @notice Transfer `_value` tokens from `msg.sender` to `_to`
    @dev Vyper does not allow underflows, so the subtraction in
         this function will revert on an insufficient balance
    @param _to The address to transfer to
    @param _value The amount to be transferred
    @return bool success
    */
    assert(_to != ZERO_ADDRESS); // dev: transfers to 0x0 are not allowed
    balanceOf[msg.sender] -= _value;
    balanceOf[_to] += _value;
    emit Transfer(msg.sender, _to, _value);
    return True;
}

function transferFrom(address _from, address _to, uint256 _value)external returns(bool){
    /*
     @notice Transfer `_value` tokens from `_from` to `_to`
     @param _from address The address which you want to send tokens from
     @param _to address The address which you want to transfer to
     @param _value uint256 the amount of tokens to be transferred
     @return bool success
    */
    assert (_to != ZERO_ADDRESS);  // dev: transfers to 0x0 are not allowed
    // NOTE: vyper does not allow underflows
    //       so the following subtraction would revert on insufficient balance
    balanceOf[_from] -= _value;
    balanceOf[_to] += _value;
    allowances[_from][msg.sender] -= _value;
    emit Transfer(_from, _to, _value);
    return True;
}

function approve(address _spender, uint256 _value)external returns(bool){
    /*
    @notice Approve `_spender` to transfer `_value` tokens on behalf of `msg.sender`
    @dev Approval may only be from zero -> nonzero or from nonzero -> zero in order
        to mitigate the potential race condition described here:
        https://github.com/ethereum/EIPs/issues/20//issuecomment-263524729
    @param _spender The address which will spend the funds
    @param _value The amount of tokens to be spent
    @return bool success
    */
    assert(_value == 0 or allowances[msg.sender][_spender] == 0);
    allowances[msg.sender][_spender] = _value;
    emit Approval(msg.sender, _spender, _value);
    return True;
}

function mint(address _to, uint256 _value)external returns(bool){
    /*
    @notice Mint `_value` tokens and assign them to `_to`
    @dev Emits a Transfer event originating from 0x00
    @param _to The account that will receive the created tokens
    @param _value The amount that will be created
    @return bool success
    */
    assert(msg.sender == minter);  // dev: minter only
    assert(_to != ZERO_ADDRESS);  // dev: zero address

    if (block.timestamp >= start_epoch_time + RATE_REDUCTION_TIME){
        _update_mining_parameters();
    }
    uint256 _total_supply = total_supply + _value;
    assert(_total_supply <= _available_supply());  // dev: exceeds allowable mint amount
    total_supply = _total_supply;

    balanceOf[_to] += _value;
    emit Transfer(ZERO_ADDRESS, _to, _value);

    return True;
}

function burn(uint256 _value)external returns(bool){
    /*
    @notice Burn `_value` tokens belonging to `msg.sender`
    @dev Emits a Transfer event with a destination of 0x00
    @param _value The amount that will be burned
    @return bool success
    */
    balanceOf[msg.sender] -= _value;
    total_supply -= _value;

    emit Transfer(msg.sender, ZERO_ADDRESS, _value);
    return True;
}

function set_name(_name: String[64], _symbol: String[32])external {
    /*
    @notice Change the token name and symbol to `_name` and `_symbol`
    @dev Only callable by the admin account
    @param _name New token name
    @param _symbol New token symbol
    */
    assert(msg.sender == admin, "Only admin is allowed to change name");
    name = _name;
    symbol = _symbol;
}
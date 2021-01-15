pragma solidity >=0.6.0 <0.8.0;

// @version 0.2.8
/**
@title Tokenized Liquidity Gauge Wrapper
@author Curve Finance
@license MIT
@notice Allows tokenized deposits and claiming from `LiquidityGauge`
*/

//from vyper.interfaces import ERC20

//implements ERC20
/**
*interface LiquidityGauge
*    function lp_token() -> address view
*    function minter() -> address view
*    function crv_token() -> address view
*    function deposit(_value uint256) nonpayable
*    function withdraw(_value uint256) nonpayable
*    function claimable_tokens(addr address) -> uint256 nonpayable
*
*interface Minter
*    function mint(gauge_addr address) nonpayable
*/
contract LiquidityGaugeWrapper{
    event Deposit(address indexed provider, uint256 value);

    event Withdraw(address indexed provider, uint256 value);

    event CommitOwnership(address admin);

    event ApplyOwnership(address admin);

    event Transfer(address indexed _from, address indexed _to, uint256 _value);

    event Approval(address indexed _owner, address  indexed _spender, uint256 _value);


    address public minter;
    address public crv_token;
    address public lp_token;
    address public gauge;

    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;
    mapping(address => mapping(address => uint256)) allowances;

    bytes64 public name;
    bytes32 public symbol;
    uint256 public decimals;

    // caller -> recipient -> can deposit?
    mapping(address => mapping(address => bool))public approved_to_deposit;

    uint256 crv_integral;
    mapping(address => uint256) crv_integral_for;
    mapping(address => uint256) public claimable_crv;

    address public admin;
    address public future_admin;
    bool public is_killed;

    function __init__(
        bytes64 _name,
        bytes32 _symbol,
        address _gauge,
        address _admin
    )external{
        /**
        *@notice Contract constructor
        *@param _name Token full name
        *@param _symbol Token symbol
        *@param _gauge Liquidity gauge contract address
        *@param _admin Admin who can kill the gauge
        */

        name = _name;
        symbol = _symbol;
        decimals = 18;

        address lp_token = LiquidityGauge(_gauge).lp_token();
        ERC20(lp_token).approve(_gauge, MAX_UINT256);

        minter = LiquidityGauge(_gauge).minter();
        crv_token = LiquidityGauge(_gauge).crv_token();
        lp_token = lp_token;
        gauge = _gauge;
        admin = _admin;
    }

    function _checkpoint(address addr)internal{
        address crv_token = crv_token;

        uint256 d_reward = ERC20(crv_token).balanceOf(address(this));
        Minter(minter).mint(gauge);
        d_reward = ERC20(crv_token).balanceOf(address(this)) - d_reward;

        uint256 total_balance = totalSupply;
        uint256 dI = 0;
        if (total_balance > 0){
            dI = 10 ** 18 * d_reward / total_balance;
        }
        uint256 I = crv_integral + dI;
        crv_integral = I;
        claimable_crv[addr] += balanceOf[addr] * (I - crv_integral_for[addr]) / 10 ** 18;
        crv_integral_for[addr] = I;
    }

    function user_checkpoint(address addr)external returns (bool){
        /**
        *@notice Record a checkpoint for `addr`
        *@param addr User address
        *@return bool success
        */
        assert (msg.sender == addr || msg.sender == minter ); // dev unauthorized
        _checkpoint(addr);
        return ture;
    }

    function claimable_tokens(address addr)external returns (uint256){
        /**
        *@notice Get the number of claimable tokens per user
        *@dev This function should be manually changed to "view" in the ABI
        *@return uint256 number of claimable tokens per user
        */
        uint256 d_reward = LiquidityGauge(gauge).claimable_tokens(address(this));

        uint256 total_balance = totalSupply;
        uint256 dI = 0;
        if (total_balance > 0){
            dI = 10 ** 18 * d_reward / total_balance;
        }
        uint256 I = crv_integral + dI;

        return claimable_crv[addr] + balanceOf[addr] * (I - crv_integral_for[addr]) / 10 ** 18;

    }

    //@shun //@nonreentrant('lock')
    function claim_tokens(address addr = msg.sender)external{
        /**
        *@notice Claim mintable CR
        *@param addr Address to claim for
        */
        _checkpoint(addr);
        ERC20(crv_token).transfer(addr, claimable_crv[addr]);

        claimable_crv[addr] = 0;
    }

    function set_approve_deposit(address addr, bool can_deposit)external{
        /**
        *@notice Set whether `addr` can deposit tokens for `msg.sender`
        *@param addr Address to set approval on
        *@param can_deposit bool - can this account deposit for `msg.sender`?
        */
        approved_to_deposit[addr][msg.sender] = can_deposit;
    }

    //@shun //@nonreentrant('lock')
    function deposit(uint256 _value, address addr = msg.sender)external{
        /**
        *@notice Deposit `_value` LP tokens
        *@param _value Number of tokens to deposit
        *@param addr Address to deposit for
        */
        assert(!is_killed);

        if (addr != msg.sender){
            assert (approved_to_deposit[msg.sender][addr], "Not approved");
        }

        _checkpoint(addr);

        if (_value != 0){
            balanceOf[addr] += _value;
            totalSupply += _value;

            ERC20(lp_token).transferFrom(msg.sender, address(this), _value);
            LiquidityGauge(gauge).deposit(_value);
        }
        emit Deposit(addr, _value);
        emit Transfer(address(0), addr, _value);

    }
    //@shun //@nonreentrant('lock')
    function withdraw(uint256 _value)external{
        /**
        *@notice Withdraw `_value` LP tokens
        *@param _value Number of tokens to withdraw
        */
        _checkpoint(msg.sender);

        if( _value != 0){
            balanceOf[msg.sender] -= _value;
            totalSupply -= _value;

            LiquidityGauge(gauge).withdraw(_value);
            ERC20(lp_token).transfer(msg.sender, _value);
        }

        emit Withdraw(msg.sender, _value);
        emit Transfer(msg.sender, address(0), _value);
    }

    function allowance(address _owner, address _spender)external view returns (uint256){
        /**
        *@dev Function to check the amount of tokens that an owner allowed to a spender.
        *@param _owner The address which owns the funds.
        *@param _spender The address which will spend the funds.
        *@return An uint256 specifying the amount of tokens still available for the spender.
        */
        return allowances[_owner][_spender];
    }

    function _transfer(address _from, address _to, uint256 _value)internal{
        assert(!is_killed);

        _checkpoint(_from);
        _checkpoint(_to);

        if (_value != 0){
            balanceOf[_from] -= _value;
            balanceOf[_to] += _value;
        }

        emit Transfer(_from, _to, _value);
    }

    //@shun //@nonreentrant('lock')
    function transfer(address _to, uint256 _value)external returns (bool){
        /**
        *@dev Transfer token for a specified address
        *@param _to The address to transfer to.
        *@param _value The amount to be transferred.
        */
        _transfer(msg.sender, _to, _value);

        return ture;
    }

    //@shun //@nonreentrant('lock')
    function transferFrom(address _from, address _to, uint256 _value)external returns (bool){
        /**
        *@dev Transfer tokens from one address to another.
        *@param _from address The address which you want to send tokens from
        *@param _to address The address which you want to transfer to
        *@param _value uint256 the amount of tokens to be transferred
        */
        uint256 _allowance = allowances[_from][msg.sender];
        if (_allowance != MAX_UINT256){
            allowances[_from][msg.sender] = _allowance - _value;
        }

        _transfer(_from, _to, _value);

        return ture;
    }

    function approve(address _spender, uint256 _value )external returns (bool){
        /**
        *@notice Approve the passed address to transfer the specified amount of
        *        tokens on behalf of msg.sender
        *@dev Beware that changing an allowance via this method brings the risk
        *    that someone may use both the old and new allowance by unfortunate
        *    transaction ordering. This may be mitigated with the use of
        *    {increaseAllowance} and {decreaseAllowance}.
        *    https//github.com/ethereum/EIPs/issues/20//issuecomment-263524729
        *@param _spender The address which will transfer the funds
        *@param _value The amount of tokens that may be transferred
        *@return bool success
        */
        allowances[msg.sender][_spender] = _value;
        emit Approval(msg.sender, _spender, _value);

        return ture;
    }

    function increaseAllowance(address _spender, uint256 _added_value)external returns (bool){
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

        return ture;
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

        return ture;
    }
    function kill_me()external{
        assert (msg.sender == admin);
        is_killed = !is_killed;
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
        assert (msg.sender == admin);  // dev admin only
        address _admin = future_admin;
        assert (_admin != address(0));  // dev admin not set
        admin = _admin;
        emit ApplyOwnership(_admin);
}
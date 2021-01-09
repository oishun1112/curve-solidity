pragma solidity >=0.6.0 <0.8.0;
// @version 0.2.7
/**
*@title Curve StableSwap Proxy
*@author Curve Finance
*@license MIT
*/

interface Burner{
    function burn(address _coin) payable returns(bool);
}

interface Curve{
    function withdraw_admin_fees() nonpayable;
    function kill_me() nonpayable;
    function unkill_me() nonpayable;
    function commit_transfer_ownership(address new_owner) nonpayable;
    function apply_transfer_ownership() nonpayable;
    function accept_transfer_ownership() nonpayable;
    function revert_transfer_ownership() nonpayable;
    function commit_new_parameters(uint256 amplification, uint256 new_fee, uint256 new_admin_fee) nonpayable;
    function apply_new_parameters() nonpayable;
    function revert_new_parameters() nonpayable;
    function commit_new_fee(uint256 new_fee, uint256 new_admin_fee) nonpayable;
    function apply_new_fee() nonpayable;
    function ramp_A(uint256 _future_A , uint256 _future_time) nonpayable;
    function stop_ramp_A() nonpayable;
    function set_aave_referral(uint256 referral_code) nonpayable;
    function donate_admin_fees() nonpayable;
}

interface AddressProvider{
    function get_registry() view returns(address);
}

interface Registry{
    function get_decimals(address _pool) view returns(uint256[8]);
    function get_underlying_balances(address _pool) view returns(uint256[8]);
}

contract PoolProxy{
    int128 constant MAX_COINS = 8;
    address constant ADDRESS_PROVIDER = 0x0000000022D53366457F9d5E68Ec105046FC4383;

    struct PoolInfo{
        uint256[MAX_COINS] balances;
        uint256[MAX_COINS] underlying_balances;
        uint256[MAX_COINS] decimals;
        uint256[MAX_COINS] underlying_decimals;
        address lp_token;
        uint256 A;
        uint256 fee;
    }

    event CommitAdmins(address ownership_admin, address parameter_admin, address emergency_admin);
    event ApplyAdmins(address ownership_admin, address parameter_admin, address emergency_admin);
    event AddBurner(address burner);


    address public ownership_admin;
    address public parameter_admin;
    address public emergency_admin;

    address public future_ownership_admin;
    address public future_parameter_admin;
    address public future_emergency_admin;

    mapping(address => uint256) public min_asymmetries;

    mapping(address => address) public burners;
    bool public burner_kill;

    // pool -> caller -> can call `donate_admin_fees`
    mapping(address => mapping(address => bool))public donate_approval;

    function __init__(
        address _ownership_admin,
        address _parameter_admin,
        address _emergency_admin
    )external{
        ownership_admin = _ownership_admin;
        parameter_admin = _parameter_admin;
        emergency_admin = _emergency_admin;
    }

    function __functionault__()external payable{
        // required to receive ETH fees
        pass;
    }


    function commit_set_admins(address _o_admin, address _p_admin, address _e_admin)external{
        /**
        *@notice Set ownership admin to `_o_admin`, parameter admin to `_p_admin` and emergency admin to `_e_admin`
        *@param _o_admin Ownership admin
        *@param _p_admin Parameter admin
        *@param _e_admin Emergency admin
        */
        assert (msg.sender == ownership_admin, "Access denied");

        future_ownership_admin = _o_admin;
        future_parameter_admin = _p_admin;
        future_emergency_admin = _e_admin;

        emit CommitAdmins(_o_admin, _p_admin, _e_admin);
    }


    function apply_set_admins()external{
        /**
        *@notice Apply the effects of `commit_set_admins`
        */
        assert (msg.sender == ownership_admin, "Access denied");

        address _o_admin  = future_ownership_admin;
        address _p_admin  = future_parameter_admin;
        address _e_admin  = future_emergency_admin;
        ownership_admin = _o_admin;
        parameter_admin = _p_admin;
        emergency_admin = _e_admin;

        emit ApplyAdmins(_o_admin, _p_admin, _e_admin);
    }

    function _set_burner(address _coin, address _burner)internal{
        address old_burner  = burners[_coin];
        if (_coin != 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE){
            if (old_burner != address(0)){
                // revoke approval on previous burner
                Bytes[32] response = raw_call(
                    _coin,
                    concat(
                        method_id("approve(address,uint256)"),
                        convert(old_burner, bytes32),
                        convert(0, bytes32),
                    ),
                    max_outsize=32,
                );
                if (len(response) != 0){
                    assert convert(response, bool);
                }
            }
            if (_burner != address(0)){
                // infinite approval for current burner
                Bytes[32] response = raw_call(
                    _coin,
                    concat(
                        method_id("approve(address,uint256)"),
                        convert(_burner, bytes32),
                        convert(MAX_UINT256, bytes32),
                    ),
                    max_outsize=32,
                );
                if (len(response) != 0){
                    assert convert(response, bool);
                }
            }
        }
        burners[_coin] = _burner;

        emit AddBurner(_burner);
    }


    //@shun: //@nonreentrant('lock')
    function set_burner(address _coin, address _burner )external{
        /**
        *@notice Set burner of `_coin` to `_burner` address
        *@param _coin Token address
        *@param _burner Burner contract address
        */
        assert( msg.sender == ownership_admin, "Access denied");

        _set_burner(_coin, _burner);
    }


    //@shun: //@nonreentrant('lock')
    function set_many_burners(address[20] _coins, address[20] _burners)external{
        /**
        *@notice Set burner of `_coin` to `_burner` address
        *@param _coins Token address
        *@param _burners Burner contract address
        */
        assert (msg.sender == ownership_admin, "Access denied");

        for(uint i; i <= 20; i++){
            address coin = _coins[i];
            if (coin == address(0)){
                break;
            }
            _set_burner(coin, _burners[i]);
        }
    }


    //@shun: //@nonreentrant('lock')
    function withdraw_admin_fees(address _pool)external{
        /**
        *@notice Withdraw admin fees from `_pool`
        *@param _pool Pool address to withdraw admin fees from
        */
        Curve(_pool).withdraw_admin_fees();
    }



    //@shun: //@nonreentrant('lock')
    function withdraw_many(address[20] _pools)external{
        /**
        *@notice Withdraw admin fees from multiple pools
        *@param _pools List of pool address to withdraw admin fees from
        */

        //@shun: for pool in _pools
        //    if pool == address(0)
        //        break
        //   Curve(pool).withdraw_admin_fees()
        
        for(uint i=0; i<_pools.length; i++){
            address pool = _pools[i];
            if (pool == address(0)){
                break;
            }
            Curve(pool).withdraw_admin_fees();
        }
    }



    //@shun: //@nonreentrant('burn')
    function burn(address _coin)external{
        /**
        *@notice Burn accrued `_coin` via a preset burner
        *@dev Only callable by an EOA to prevent flashloan exploits
        *@param _coin Coin address
        */
        assert (tx.origin == msg.sender);
        assert (!burner_kill); //@shun: //assert not burner_kill

        uint256 _value = 0;
        if (_coin == 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE){
            _value = balance;
        }

        Burner(burners[_coin]).burn(_coin, value=_value);  // dev should implement burn()
    }


    //@shun: //@nonreentrant('burn')
    function burn_many(address[20] _coins)external{
        /**
        *@notice Burn accrued admin fees from multiple coins
        *@dev Only callable by an EOA to prevent flashloan exploits
        *@param _coins List of coin addresses
        */
        assert (tx.origin == msg.sender);
        assert (!burner_kill);

        for(uint i=0; i< _coins.length; i++){
            address coin = _coins[i];
            if (coin == address(0)){
                break;
            }
            uint256 _value = 0;
            if (coin == 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE){
                _value = balance;
            }

            Burner(burners[coin]).burn(coin, value=_value);  // dev should implement burn()
        }
    }


    //@shun: //@nonreentrant('lock')
    function kill_me(address _pool)external{
        /**
        *@notice Pause the pool `_pool` - only remove_liquidity will be callable
        *@param _pool Pool address to pause
        */
        assert (msg.sender == emergency_admin, "Access denied");
        Curve(_pool).kill_me();
    }



    //@shun: //@nonreentrant('lock')
    function unkill_me(address _pool)external{
        /**
        *@notice Unpause the pool `_pool`, re-enabling all functionality
        *@param _pool Pool address to unpause
        */
        assert (msg.sender == emergency_admin || msg.sender == ownership_admin, "Access denied");
        Curve(_pool).unkill_me();
    }



    function set_burner_kill(bool _is_killed)external{
        /**
        *@notice Kill or unkill `burn` functionality
        *@param _is_killed Burner kill status
        */
        assert (msg.sender == emergency_admin || msg.sender == ownership_admin, "Access denied");
        burner_kill = _is_killed;
    }



    //@shun: //@nonreentrant('lock')
    function commit_transfer_ownership(address _pool, address new_owner)external{
        /**
        *@notice Transfer ownership for `_pool` pool to `new_owner` address
        *@param _pool Pool which ownership is to be transferred
        *@param new_owner New pool owner address
        */
        assert (msg.sender == ownership_admin, "Access denied");
        Curve(_pool).commit_transfer_ownership(new_owner);
    }



    //@shun: //@nonreentrant('lock')
    function apply_transfer_ownership(address _pool)external{
        /**
        *@notice Apply transferring ownership of `_pool`
        *@param _pool Pool address
        */
        Curve(_pool).apply_transfer_ownership();
    }



    //@shun: //@nonreentrant('lock')
    function accept_transfer_ownership(address _pool)external{
        /**
        *@notice Apply transferring ownership of `_pool`
        *@param _pool Pool address
        */
        Curve(_pool).accept_transfer_ownership();
    }



    //@shun: //@nonreentrant('lock')
    function revert_transfer_ownership(address _pool)external{
        /**
        *@notice Revert commited transferring ownership for `_pool`
        *@param _pool Pool address
        */
        assert (msg.sender == ownership_admin || msg.sender == emergency_admin, "Access denied");
        Curve(_pool).revert_transfer_ownership();
    }



    //@shun: //@nonreentrant('lock')
    function commit_new_parameters(address _pool,
                            uint256 amplification,
                            uint256 new_fee,
                            uint256 new_admin_fee,
                            uint256 min_asymmetry)external{
        /**
        *@notice Commit new parameters for `_pool`, A `amplification`, fee `new_fee` and admin fee `new_admin_fee`
        *@param _pool Pool address
        *@param amplification Amplification coefficient
        *@param new_fee New fee
        *@param new_admin_fee New admin fee
        *@param min_asymmetry Minimal asymmetry factor allowed.
        *        Asymmetry factor is
        *        Prod(balances) / (Sum(balances) / N) ** N
        */
        assert (msg.sender == parameter_admin, "Access denied");
        min_asymmetries[_pool] = min_asymmetry;
        Curve(_pool).commit_new_parameters(amplification, new_fee, new_admin_fee);  // dev if implemented by the pool
    }


    //@shun: //@nonreentrant('lock')
    function apply_new_parameters(address _pool)external{
        /**
        *@notice Apply new parameters for `_pool` pool
        *@dev Only callable by an EOA
        *@param _pool Pool address
        */
        assert (msg.sender == tx.origin);

        uint256 min_asymmetry = min_asymmetries[_pool];

        if (min_asymmetry > 0){
            address registry = AddressProvider(ADDRESS_PROVIDER).get_registry();
            uint256[8] underlying_balances = Registry(registry).get_underlying_balances(_pool);
            uint256[8] decimals = Registry(registry).get_decimals(_pool);

            uint256[MAX_COINS] balances; //@shun: balances uint256[MAX_COINS] = empty(uint256[MAX_COINS])
            // asymmetry = prod(x_i) / (sum(x_i) / N) ** N =
            // = prod( (N * x_i) / sum(x_j) )
            uint256 S = 0;
            uint256 N = 0;
            for( uint i; i<= MAX_COINS; i++){
                uint256 x = underlying_balances[i];
                if (x == 0){
                    N = i;
                    break;
                }
                x *= 10 ** (18 - decimals[i]);
                balances[i] = x;
                S += x;
            }
            uint256 asymmetry = N * 10 ** 18;
            for(uint i; i <= MAX_COINS; i++){
                uint256 x = balances[i];
                if (x == 0){
                    break;
                }
                asymmetry = asymmetry * x / S;
            }
            assert(asymmetry >= min_asymmetry, "Unsafe to apply");
        }
        Curve(_pool).apply_new_parameters();  // dev if implemented by the pool
    }


    //@shun: //@nonreentrant('lock')
    function revert_new_parameters(address _pool)external{
        /**
        *@notice Revert comitted new parameters for `_pool` pool
        *@param _pool Pool address
        */
        assert (msg.sender == ownership_admin || msg.sender == parameter_admin || msg.sender == emergency_admin, "Access denied");
        Curve(_pool).revert_new_parameters();  // dev if implemented by the pool
    }



    //@shun: //@nonreentrant('lock')
    function commit_new_fee(address _pool, uint256 new_fee, uint256 new_admin_fee)external{
        /**
        *@notice Commit new fees for `_pool` pool, fee `new_fee` and admin fee `new_admin_fee`
        *@param _pool Pool address
        *@param new_fee New fee
        *@param new_admin_fee New admin fee
        */
        assert (msg.sender == parameter_admin, "Access denied");
        Curve(_pool).commit_new_fee(new_fee, new_admin_fee);
    }


    //@shun: //@nonreentrant('lock')
    function apply_new_fee(address _pool)external{
        /**
        *@notice Apply new fees for `_pool` pool
        *@param _pool Pool address
        */
        Curve(_pool).apply_new_fee();
    }



    //@shun: //@nonreentrant('lock')
    function ramp_A(address _pool, uint256 _future_A, uint256 _future_time)external{
        /**
        *@notice Start gradually increasing A of `_pool` reaching `_future_A` at `_future_time` time
        *@param _pool Pool address
        *@param _future_A Future A
        *@param _future_time Future time
        */
        assert( msg.sender == parameter_admin, "Access denied");
        Curve(_pool).ramp_A(_future_A, _future_time);
    }


    //@shun: //@nonreentrant('lock')
    function stop_ramp_A(address _pool)external{
        /**
        *@notice Stop gradually increasing A of `_pool`
        *@param _pool Pool address
        */
        assert (msg.sender == parameter_admin || msg.sender == emergency_admin, "Access denied");
        Curve(_pool).stop_ramp_A();
    }


    //@shun: //@nonreentrant('lock')
    function set_aave_referral(address _pool, uint256 referral_code)external{
        /**
        *@notice Set Aave referral for undelying tokens of `_pool` to `referral_code`
        *@param _pool Pool address
        *@param referral_code Aave referral code
        */
        assert (msg.sender == ownership_admin, "Access denied");
        Curve(_pool).set_aave_referral(referral_code);  // dev if implemented by the pool
    }


    function set_donate_approval(address _pool, address _caller, bool _is_approved)external{
        /**
        *@notice Set approval of `_caller` to donate admin fees for `_pool`
        *@param _pool Pool address
        *@param _caller Adddress to set approval for
        *@param _is_approved Approval status
        */
        assert (msg.sender == ownership_admin, "Access denied");

        donate_approval[_pool][_caller] = _is_approved;
    }


    //@shun: //@nonreentrant('lock')
    function donate_admin_fees(address _pool)external{
        /**
        *@notice Donate admin fees of `_pool` pool
        *@param _pool Pool address
        */
        if (msg.sender != ownership_admin){
            assert (donate_approval[_pool][msg.sender], "Access denied");
        }

        Curve(_pool).donate_admin_fees();  // dev if implemented by the pool
    }
}
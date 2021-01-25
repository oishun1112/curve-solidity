pragma solidity >=0.6.0 <0.8.0;
// @version 0.2.4
/**
*@title Token Minter
*@author Curve Finance
*@license MIT
*/

/**
*interface LiquidityGauge{
*    // Presumably, other gauges will provide the same interfaces
*    function integrate_fraction(address addr ) view returns(uint256);
*    function user_checkpoint(address addr)nonpayable returns(bool); 
*}
*
*interface MERC20{
*    function mint(address _to, uint256 _value)nonpayable returns(bool);
*}
*
*interface GaugeController{
*    function gauge_types(address addr)view returns (int128);
*}
*/
contract Minter is LiquidityGauge{
    event Minted(address indexed recipient, address gauge, uint256 minted);

    address public token;
    address public controller;

    // user -> gauge -> value
    mapping(address => mapping(address => uint256))public minted;

    // minter -> user -> can mint?
    mapping(address => mapping(address => bool))public allowed_to_mint_for;


    function __init__(address _token, address _controller)external{
        token = _token;
        controller = _controller;
    }

    function _mint_for(address gauge_addr, address _for)internal{
        assert (GaugeController(controller).gauge_types(gauge_addr) >= 0);  // dev gauge is not added

        LiquidityGauge(gauge_addr).user_checkpoint(_for);
        uint256 total_mint = LiquidityGauge(gauge_addr).integrate_fraction(_for);
        uint256 to_mint = total_mint - minted[_for][gauge_addr];

        if (to_mint != 0){
            MERC20(token).mint(_for, to_mint);
            minted[_for][gauge_addr] = total_mint;

            emit Minted(_for, gauge_addr, total_mint);
        }
    }

    //@shun: //@nonreentrant('lock')
    function mint(address gauge_addr)external{
        /**
        *@notice Mint everything which belongs to `msg.sender` and send to them
        *@param gauge_addr `LiquidityGauge` address to get mintable amount from
        */
        _mint_for(gauge_addr, msg.sender);
    }

    //@shun: //@nonreentrant('lock')
    function mint_many(address[8] gauge_addrs)external{
        /**
        *@notice Mint everything which belongs to `msg.sender` across multiple gauges
        *@param gauge_addrs List of `LiquidityGauge` addresses
        */
        for(uint i; i<= 8; i++){
            if (gauge_addrs[i] == address(0)){
                break;
            }
            _mint_for(gauge_addrs[i], msg.sender);
        }
    }

    //@shun: //@nonreentrant('lock')
    function mint_for(address gauge_addr, address _for)external{
        /**
        *@notice Mint tokens for `_for`
        *@dev Only possible when `msg.sender` has been approved via `toggle_approve_mint`
        *@param gauge_addr `LiquidityGauge` address to get mintable amount from
        *@param _for Address to mint to
        */
        if (allowed_to_mint_for[msg.sender][_for]){
            _mint_for(gauge_addr, _for);
        }
    }

    function toggle_approve_mint(address minting_user)external{
        /**
        *@notice allow `minting_user` to mint for `msg.sender`
        *@param minting_user Address to toggle permission for
        */
        
        allowed_to_mint_for[minting_user][msg.sender] = !allowed_to_mint_for[minting_user][msg.sender]; //@shun: //allowed_to_mint_for[minting_user][msg.sender] = not allowed_to_mint_for[minting_user][msg.sender];
    }
}

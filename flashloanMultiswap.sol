// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;


import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { FlashLoanSimpleReceiverBase } from "@aave/core-v3/contracts/flashloan/base/FlashLoanSimpleReceiverBase.sol";
import { IPoolAddressesProvider } from "@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol";
import { ISwapRouter } from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import { IQuoter } from "@uniswap/v3-periphery/contracts/interfaces/IQuoter.sol";

interface IUniswapRouter is ISwapRouter {
    function refundETH() external payable;
}

interface IUniswapV2Router02 {
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    function swapTokensForExactTokens(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    function swapExactETHForTokens(uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        payable
        returns (uint[] memory amounts);
    function swapTokensForExactETH(uint amountOut, uint amountInMax, address[] calldata path, address to, uint deadline)
        external
        returns (uint[] memory amounts);
    function swapExactTokensForETH(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        returns (uint[] memory amounts);
    function swapETHForExactTokens(uint amountOut, address[] calldata path, address to, uint deadline)
        external
        payable
        returns (uint[] memory amounts);
}

interface IBancorNetwork {
    function convertByPath(
        address[] memory _path, 
        uint256 _amount, 
        uint256 _minReturn, 
        address _beneficiary, 
        address _affiliateAccount, 
        uint256 _affiliateFee
    ) external payable returns (uint256);

    function rateByPath(
        address[] memory _path, 
        uint256 _amount
    ) external view returns (uint256);
}

contract FlashloanMultiswap is FlashLoanSimpleReceiverBase {
    using SafeERC20 for IERC20;

    IBancorNetwork private constant bancorNetwork = IBancorNetwork(0xb3fa5DcF7506D146485856439eb5e401E0796B5D);
    address private constant BANCOR_ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address private constant BANCOR_ETHBNT_POOL = 0x1aCE5DD13Ba14CA42695A905526f2ec366720b13;
    address private constant BNT = 0xF35cCfbcE1228014F66809EDaFCDB836BFE388f5;

    IUniswapV2Router02 private constant sushiRouter = IUniswapV2Router02(0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506);
    address private constant INJ = 0x9108Ab1bb7D054a3C1Cd62329668536f925397e5;  

    IUniswapRouter private constant uniswapRouter = IUniswapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    address private constant DAI = 0xaD6D458402F60fD3Bd25163575031ACDce07538D;

    constructor(IPoolAddressesProvider provider) FlashLoanSimpleReceiverBase(provider) {
        IERC20(BNT).safeApprove(address(sushiRouter), type(uint256).max);
        IERC20(INJ).safeApprove(address(uniswapRouter), type(uint256).max);
    }


    // Banchor Network Swap
    function _tradeOnBancor(uint256 amountIn, uint256 amountOutMin) private {
    bancorNetwork.convertByPath{value: msg.value}(_getPathForBancor(), amountIn, amountOutMin, address(0), address(0), 0);
    }
    
    function _getPathForBancor() private pure returns (address[] memory) {
        address[] memory path = new address[](3);
        path[0] = BANCOR_ETH_ADDRESS;
        path[1] = BANCOR_ETHBNT_POOL;
        path[2] = BNT;
        
        return path;
    }

    // Sushiswap
    function _tradeOnSushi(uint256 amountIn, uint256 amountOutMin, uint256 deadline) private {
        address recipient = address(this);
      
        sushiRouter.swapExactTokensForTokens(
            amountIn,
            amountOutMin,
            _getPathForSushiSwap(),
            recipient,
            deadline
        );
    }

    function _getPathForSushiSwap() private pure returns (address[] memory) {
        address[] memory path = new address[](2);
        path[0] = BNT;
        path[1] = INJ;
        
        return path;
    }

    // Uniswap trading
    function _tradeOnUniswap(uint256 amountIn, uint256 amountOutMin, uint256 deadline) private {
        address tokenIn = INJ;
        address tokenOut = DAI;
        uint24 fee = 3000;
        address recipient = msg.sender;
        uint160 sqrtPriceLimitX96 = 0;
        
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams(
            tokenIn,
            tokenOut,
            fee,
            recipient,
            deadline,
            amountIn,
            amountOutMin,
            sqrtPriceLimitX96
        );
    
    uniswapRouter.exactInputSingle(params);
    uniswapRouter.refundETH();
    
    // refund leftover ETH to user
    (bool success,) = msg.sender.call{ value: address(this).balance }("");
    require(success, "refund failed");
}

    // Multiswap
    function multiSwap(uint256 deadline, uint256 amountOutMinUniswap) external payable {
        uint256 amountOutMinBancor = 1;
        uint256 amountOutMinSushiSwap = 1;

        _tradeOnBancor(msg.value, amountOutMinBancor);
        _tradeOnSushi(IERC20(BNT).balanceOf(address(this)), amountOutMinSushiSwap, deadline);
        _tradeOnUniswap(IERC20(INJ).balanceOf(address(this)), amountOutMinUniswap, deadline);
    }

    // meant to be called as view function
    function multiSwapPreview() external payable returns(uint256) {
        uint256 daiBalanceUserBeforeTrade = IERC20(DAI).balanceOf(msg.sender);
        uint256 deadline = block.timestamp + 300;
        
        uint256 amountOutMinBancor = 1;
        uint256 amountOutMinSushiSwap = 1;
        uint256 amountOutMinUniswap = 1;
        
        _tradeOnBancor(msg.value, amountOutMinBancor);
        _tradeOnSushi(IERC20(BNT).balanceOf(address(this)), amountOutMinSushiSwap, deadline);
        _tradeOnUniswap(IERC20(INJ).balanceOf(address(this)), amountOutMinUniswap, deadline);
        
        uint256 daiBalanceUserAfterTrade = IERC20(DAI).balanceOf(msg.sender);
        return daiBalanceUserAfterTrade - daiBalanceUserBeforeTrade;
    }
    
    
    function requestFlashLoan(address _token, uint256 _amount) public {
        address receiverAddress = address(this);
        address asset = _token;
        uint256 amount = _amount;
        bytes memory params = "";
        uint16 referralCode = 0;

        POOL.flashLoanSimple(
            receiverAddress,
            asset,
            amount,
            params,
            referralCode
        );
    }


    function  executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    )  external override returns (bool) {
        //
        // This contract now has the funds requested.
        // Your logic goes here.
        //
        // At the end of your logic above, this contract owes
        // the flashloaned amount + premiums.
        // Therefore ensure your contract has enough to repay
        // these amounts.

        // Approve the Pool contract allowance to *pull* the owed amount
        uint256 totalAmount = amount + premium;
        IERC20(asset).approve(address(POOL), totalAmount);

        return true;
    }



    receive() external payable {}

    

}
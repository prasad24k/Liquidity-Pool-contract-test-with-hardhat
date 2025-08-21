// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

import "@openzeppelin/contracts/access/Ownable.sol";

interface IERC20Decimals is IERC20 {
    function decimals() external view returns (uint8);
}

/**
 * @title ETHUSDAMM
 * @notice Minimal constant-product AMM between native ETH and a USD-like ERC20.
 */
contract ETHUSDAMM is ERC20, ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    IERC20Decimals public immutable usdToken;
    address public feeRecipient;

    // Reserves tracked in 18-decimals space for both sides
    uint256 public reserveETH18; // wei (18)
    uint256 public reserveUSD18; // USD scaled to 18

    // Fee (bps) 0.3%
    uint256 public constant FEE_BPS = 30; // 0.3%
    uint256 public constant FEE_DENOMINATOR = 10_000;

    // USD token decimals and scaling factor to 18
    uint8 public immutable usdDecimals;
    uint256 public immutable usdScaleTo18; // 10 ** (18 - usdDecimals)
    uint256 public immutable usdScaleFrom18; // 10 ** (usdDecimals)

    event LiquidityAdded(
        address indexed provider,
        uint256 ethUsed,
        uint256 usdUsed,
        uint256 lpMinted,
        uint256 ethRefund,
        uint256 usdRefund
    );
    event LiquidityRemoved(
        address indexed provider,
        uint256 ethOut,
        uint256 usdOut,
        uint256 lpBurned
    );
    event Swap(
        address indexed user,
        address inputToken,
        address outputToken,
        uint256 amountIn,
        uint256 amountOut,
        uint256 feeAmount
    );
    event FeeRecipientChanged(address indexed oldRecipient, address indexed newRecipient);
    event Synced(uint256 reserveETH18, uint256 reserveUSD18);

    constructor(address _usdToken, address _feeRecipient, address _initialOwner)
        ERC20("ETH-USD LP Token", "ETHUSDLP")
        Ownable(_initialOwner)
    {
        require(_usdToken != address(0), "Invalid USD token");
        require(_feeRecipient != address(0), "Invalid fee recipient");
        usdToken = IERC20Decimals(_usdToken);
        feeRecipient = _feeRecipient;

        uint8 dec = IERC20Decimals(_usdToken).decimals();
        usdDecimals = dec;
        
        // FIXED: Support any decimal configuration
        if (dec <= 18) {
            usdScaleTo18 = 10 ** (18 - dec);
            usdScaleFrom18 = 1;
        } else {
            usdScaleTo18 = 1;
            usdScaleFrom18 = 10 ** (dec - 18);
        }
    }

    // -------------------- Admin --------------------

    function setFeeRecipient(address newRecipient) external onlyOwner {
        require(newRecipient != address(0), "Invalid fee recipient");
        emit FeeRecipientChanged(feeRecipient, newRecipient);
        feeRecipient = newRecipient;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function sync() public {
        uint256 ethBal = address(this).balance;
        uint256 usdBal = usdToken.balanceOf(address(this));
        reserveETH18 = ethBal;
        reserveUSD18 = _to18(usdBal);
        emit Synced(reserveETH18, reserveUSD18);
    }

    // -------------------- Liquidity --------------------

    function addLiquidity(
        uint256 usdDesired,
        uint256 usdMin,
        uint256 ethMin,
        uint256 deadline
    ) external payable nonReentrant whenNotPaused returns (uint256 lpMinted, uint256 ethUsed, uint256 usdUsed, uint256 ethRefund, uint256 usdRefund) {
        require(block.timestamp <= deadline, "Expired");
        require(msg.value > 0 && usdDesired > 0, "Zero amounts");

        uint256 totalSupplyCache = totalSupply();
        uint256 ethIn = msg.value;

        // Pull USD tokens
        uint256 usdBalBefore = usdToken.balanceOf(address(this));
        IERC20(address(usdToken)).safeTransferFrom(msg.sender, address(this), usdDesired);
        uint256 usdReceived = usdToken.balanceOf(address(this)) - usdBalBefore;
        require(usdReceived > 0, "No USD received");
        uint256 usdIn18 = _to18(usdReceived);

        if (totalSupplyCache == 0) {
            require(ethIn >= ethMin, "ETH < min");
            require(usdReceived >= usdMin, "USD < min");

            lpMinted = _sqrt(ethIn * usdIn18);
            require(lpMinted > 0, "LP=0");

            _mint(msg.sender, lpMinted);
            reserveETH18 += ethIn;
            reserveUSD18 += usdIn18;

            emit LiquidityAdded(msg.sender, ethIn, usdReceived, lpMinted, 0, 0);
            return (lpMinted, ethIn, usdReceived, 0, 0);
        } else {
            uint256 ethRes = reserveETH18;
            uint256 usdRes18 = reserveUSD18;
            require(ethRes > 0 && usdRes18 > 0, "Empty pool");

            uint256 usdReq18 = (ethIn * usdRes18) / ethRes;

            if (usdIn18 >= usdReq18) {
                usdUsed = _from18(usdReq18);
                usdRefund = usdReceived - usdUsed;
                if (usdRefund > 0) {
                    IERC20(address(usdToken)).safeTransfer(msg.sender, usdRefund);
                }
                ethUsed = ethIn;
                ethRefund = 0;
            } else {
                ethUsed = (usdIn18 * ethRes) / usdRes18;
                require(ethIn >= ethUsed, "calc err");
                ethRefund = ethIn - ethUsed;
                if (ethRefund > 0) {
                    (bool ok, ) = payable(msg.sender).call{value: ethRefund}("");
                    require(ok, "ETH refund failed");
                }
                usdUsed = usdReceived;
            }

            require(ethUsed >= ethMin, "ETH < min");
            require(usdUsed >= usdMin, "USD < min");

            lpMinted = _min(
                (ethUsed * totalSupplyCache) / ethRes,
                (usdIn18 * totalSupplyCache) / usdRes18
            );
            require(lpMinted > 0, "LP=0");

            _mint(msg.sender, lpMinted);
            reserveETH18 = ethRes + ethUsed;
            reserveUSD18 = usdRes18 + _to18(usdUsed);

            emit LiquidityAdded(msg.sender, ethUsed, usdUsed, lpMinted, ethRefund, usdRefund);
        }
    }

    function removeLiquidity(
        uint256 lpAmount,
        uint256 minEthOut,
        uint256 minUsdOut,
        uint256 deadline
    )
        external
        nonReentrant
        returns (uint256 ethAmount, uint256 usdAmount)
    {
        require(block.timestamp <= deadline, "Expired");
        require(lpAmount > 0, "LP=0");

        uint256 _totalSupply = totalSupply();
        require(_totalSupply > 0, "No LP");

        uint256 ethRes = reserveETH18;
        uint256 usdRes18 = reserveUSD18;

        ethAmount = (ethRes * lpAmount) / _totalSupply;
        uint256 usdOut18 = (usdRes18 * lpAmount) / _totalSupply;
        usdAmount = _from18(usdOut18);

        require(ethAmount >= minEthOut, "ETH < min");
        require(usdAmount >= minUsdOut, "USD < min");

        _burn(msg.sender, lpAmount);
        
        // Update reserves
        reserveETH18 = ethRes - ethAmount;
        reserveUSD18 = usdRes18 - usdOut18;

        // Transfer tokens
        (bool ok1, ) = payable(msg.sender).call{value: ethAmount}("");
        require(ok1, "ETH send failed");
        IERC20(address(usdToken)).safeTransfer(msg.sender, usdAmount);

        emit LiquidityRemoved(msg.sender, ethAmount, usdAmount, lpAmount);
    }

    // -------------------- Swaps --------------------

    function swapETHForUSD(uint256 minUsdOut, uint256 deadline) external payable nonReentrant whenNotPaused {
        require(block.timestamp <= deadline, "Expired");
        require(msg.value > 0, "No ETH");

        uint256 feeETH = (msg.value * FEE_BPS) / FEE_DENOMINATOR;
        uint256 ethInAfterFee = msg.value - feeETH;

        uint256 usdOut18 = _getAmountOut(ethInAfterFee, reserveETH18, reserveUSD18);
        uint256 usdOut = _from18(usdOut18);
        require(usdOut > 0 && usdOut <= _from18(reserveUSD18), "Out of range");
        require(usdOut >= minUsdOut, "Slippage");

        // Transfer fee first
        if (feeETH > 0) {
            (bool okFee, ) = payable(feeRecipient).call{value: feeETH}("");
            require(okFee, "Fee send failed");
        }

        // Transfer output
        IERC20(address(usdToken)).safeTransfer(msg.sender, usdOut);

        // Update reserves last (CEI pattern)
        reserveETH18 += ethInAfterFee;
        reserveUSD18 -= usdOut18;

        emit Swap(msg.sender, address(0), address(usdToken), msg.value, usdOut, feeETH);
    }

    function swapUSDForETH(uint256 usdIn, uint256 minEthOut, uint256 deadline) external nonReentrant whenNotPaused {
        require(block.timestamp <= deadline, "Expired");
        require(usdIn > 0, "No USD");

        uint256 balBefore = usdToken.balanceOf(address(this));
        IERC20(address(usdToken)).safeTransferFrom(msg.sender, address(this), usdIn);
        uint256 receivedUSD = usdToken.balanceOf(address(this)) - balBefore;
        require(receivedUSD > 0, "No USD received");

        uint256 feeUSD = (receivedUSD * FEE_BPS) / FEE_DENOMINATOR;
        uint256 usdAfterFee = receivedUSD - feeUSD;
        uint256 usdAfterFee18 = _to18(usdAfterFee);

        uint256 ethOut = _getAmountOut(usdAfterFee18, reserveUSD18, reserveETH18);
        require(ethOut > 0 && ethOut <= reserveETH18, "Out of range");
        require(ethOut >= minEthOut, "Slippage");

        // Transfer fee first
        if (feeUSD > 0) {
            IERC20(address(usdToken)).safeTransfer(feeRecipient, feeUSD);
        }

        // Transfer output
        (bool ok, ) = payable(msg.sender).call{value: ethOut}("");
        require(ok, "ETH send failed");

        // Update reserves last (CEI pattern)
        reserveUSD18 += usdAfterFee18;
        reserveETH18 -= ethOut;

        emit Swap(msg.sender, address(usdToken), address(0), receivedUSD, ethOut, feeUSD);
    }

    // -------------------- Views / Math --------------------

    function getReserves() external view returns (uint256 ethReserveWei, uint256 usdReserveTokens) {
        ethReserveWei = reserveETH18;
        usdReserveTokens = _from18(reserveUSD18);
    }

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) external pure returns (uint256) {
        return _getAmountOut(amountIn, reserveIn, reserveOut);
    }

    function _getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256) {
        require(reserveIn > 0 && reserveOut > 0, "Insufficient liquidity");
        return (reserveOut * amountIn) / (reserveIn + amountIn);
    }

    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y == 0) return 0;
        uint256 x = y / 2 + 1;
        z = y;
        while (x < z) {
            z = x;
            x = (y / x + x) / 2;
        }
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _to18(uint256 amtUSD) internal view returns (uint256) {
        if (usdDecimals <= 18) {
            return amtUSD * usdScaleTo18;
        } else {
            return amtUSD / usdScaleFrom18;
        }
    }
    
    function _from18(uint256 amt18) internal view returns (uint256) {
        if (usdDecimals <= 18) {
            return amt18 / usdScaleTo18;
        } else {
            return amt18 * usdScaleFrom18;
        }
    }

    // -------------------- Fallback --------------------

    receive() external payable {}
}
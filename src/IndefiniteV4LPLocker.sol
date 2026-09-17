/*
//////////////////////////////////////////////////////////////////////
//////////////////////////////////////////////////////////////////////
//
//      ██╗███╗   ██╗██████╗ ███████╗███████╗██╗███╗   ██╗██╗████████╗███████╗
//      ██║████╗  ██║██╔══██╗██╔════╝██╔════╝██║████╗  ██║██║╚══██╔══╝██╔════╝
//      ██║██╔██╗ ██║██║  ██║█████╗  █████╗  ██║██╔██╗ ██║██║   ██║   █████╗
//      ██║██║╚██╗██║██║  ██║██╔══╝  ██╔══╝  ██║██║╚██╗██║██║   ██║   ██╔══╝
//      ██║██║ ╚████║██████╔╝███████╗██║     ██║██║ ╚████║██║   ██║   ███████╗
//      ╚═╝╚═╝  ╚═══╝╚═════╝ ╚══════╝╚═╝     ╚═╝╚═╝  ╚═══╝╚═╝   ╚═╝   ╚══════╝
//
//                    UNISWAP V4 LP LOCKER
//
//                    DEVELOPED BY XQFT
//                    https://x.com/xqft7
//
//          LOCK FOREVER. COLLECT FEES FOREVER.
//
//////////////////////////////////////////////////////////////////////
//////////////////////////////////////////////////////////////////////
*/

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Indefinite V4 LP Locker
/// @notice Permanently locks Uniswap v4 LP NFTs.
///         Principal can NEVER be withdrawn.
///         Original depositor can claim trading fees forever.
///         1% of collected fees goes to the protocol fee recipient,
///         except positions deposited by the fee recipient itself.

struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

interface IV4PositionManager {
    function safeTransferFrom(address from, address to, uint256 tokenId) external;

    function ownerOf(uint256 tokenId) external view returns (address);

    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;

    function getPoolAndPositionInfo(uint256 tokenId)
        external
        view
        returns (PoolKey memory poolKey, uint256 positionInfo);

    function getPositionLiquidity(uint256 tokenId) external view returns (uint128);
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

contract IndefiniteV4LPLocker {
    // ----------------------------------------------------------
    // CONSTANTS
    // ----------------------------------------------------------

    address public constant FEE_RECIPIENT = 0x9a30Cf4527D2CC80884405e16337149ab59e3d6E;

    uint256 public constant PROTOCOL_FEE_BPS = 100; // 1%
    uint256 public constant BPS_DENOMINATOR = 10_000;

    bytes1 private constant DECREASE_LIQUIDITY = 0x01;
    bytes1 private constant TAKE_PAIR = 0x11;

    // ----------------------------------------------------------
    // IMMUTABLES / STORAGE
    // ----------------------------------------------------------

    IV4PositionManager public immutable positionManager;

    /// tokenId => permanent fee beneficiary
    mapping(uint256 => address) public beneficiary;

    uint256 private entered;

    // ----------------------------------------------------------
    // ERRORS
    // ----------------------------------------------------------

    error AlreadyLocked();
    error NotLocked();
    error NotBeneficiary();
    error NotPositionManager();
    error InvalidSender();
    error ReentrantCall();
    error TransferFailed();
    error BalanceCheckFailed();

    // ----------------------------------------------------------
    // EVENTS
    // ----------------------------------------------------------

    event Locked(uint256 indexed tokenId, address indexed beneficiary);

    event FeesClaimed(
        uint256 indexed tokenId,
        address indexed beneficiary,
        uint256 amount0,
        uint256 amount1,
        uint256 protocolFee0,
        uint256 protocolFee1
    );

    // ----------------------------------------------------------
    // CONSTRUCTOR
    // ----------------------------------------------------------

    constructor(address _positionManager) {
        require(_positionManager != address(0), "ZERO_ADDRESS");
        positionManager = IV4PositionManager(_positionManager);
    }

    // ----------------------------------------------------------
    // REENTRANCY
    // ----------------------------------------------------------

    modifier nonReentrant() {
        if (entered != 0) revert ReentrantCall();

        entered = 1;
        _;
        entered = 0;
    }

    // ----------------------------------------------------------
    // LOCKING
    // ----------------------------------------------------------

    /// @notice Permanently lock a Uniswap v4 LP NFT.
    /// @dev User must approve this contract for the NFT first.
    function lock(uint256 tokenId) external nonReentrant {
        if (beneficiary[tokenId] != address(0)) {
            revert AlreadyLocked();
        }

        positionManager.safeTransferFrom(msg.sender, address(this), tokenId);
    }

    /// @notice Allows direct safeTransferFrom deposits.
    function onERC721Received(address, address from, uint256 tokenId, bytes calldata) external returns (bytes4) {
        if (msg.sender != address(positionManager)) {
            revert NotPositionManager();
        }

        if (from == address(0)) {
            revert InvalidSender();
        }

        if (beneficiary[tokenId] != address(0)) {
            revert AlreadyLocked();
        }

        beneficiary[tokenId] = from;

        emit Locked(tokenId, from);

        return this.onERC721Received.selector;
    }

    // ----------------------------------------------------------
    // CLAIM FEES
    // ----------------------------------------------------------

    /// @notice Claim fees for positions that require no hookData.
    function claimFees(uint256 tokenId) external nonReentrant {
        _claimFees(tokenId, "");
    }

    /// @notice Claim fees from hooked positions requiring hookData.
    function claimFees(uint256 tokenId, bytes calldata hookData) external nonReentrant {
        _claimFees(tokenId, hookData);
    }

    function _claimFees(uint256 tokenId, bytes memory hookData) internal {
        address receiver = beneficiary[tokenId];

        if (receiver == address(0)) {
            revert NotLocked();
        }

        if (msg.sender != receiver) {
            revert NotBeneficiary();
        }

        (PoolKey memory key,) = positionManager.getPoolAndPositionInfo(tokenId);

        // Record balances before fee collection.
        uint256 balance0Before = _balanceOf(key.currency0);
        uint256 balance1Before = _balanceOf(key.currency1);

        /*
            DECREASE_LIQUIDITY with liquidity = 0:
            collects accrued fees WITHOUT removing principal.

            TAKE_PAIR:
            sends both collected currencies to this locker,
            allowing us to split them 99% / 1%.
        */

        bytes memory actions = abi.encodePacked(DECREASE_LIQUIDITY, TAKE_PAIR);

        bytes[] memory params = new bytes[](2);

        params[0] = abi.encode(
            tokenId,
            uint256(0), // ZERO liquidity removed
            uint128(0),
            uint128(0),
            hookData
        );

        params[1] = abi.encode(key.currency0, key.currency1, address(this));

        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        // Calculate exactly what this claim produced.
        uint256 amount0 = _balanceOf(key.currency0) - balance0Before;

        uint256 amount1 = _balanceOf(key.currency1) - balance1Before;

        uint256 protocolFee0;
        uint256 protocolFee1;

        // Positions deposited by FEE_RECIPIENT pay no protocol fee.
        if (receiver != FEE_RECIPIENT) {
            protocolFee0 = (amount0 * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;

            protocolFee1 = (amount1 * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;
        }

        uint256 userAmount0 = amount0 - protocolFee0;
        uint256 userAmount1 = amount1 - protocolFee1;

        // Pay user 99% (or 100% if exempt).
        _transferCurrency(key.currency0, receiver, userAmount0);

        _transferCurrency(key.currency1, receiver, userAmount1);

        // Pay protocol 1%.
        if (protocolFee0 > 0) {
            _transferCurrency(key.currency0, FEE_RECIPIENT, protocolFee0);
        }

        if (protocolFee1 > 0) {
            _transferCurrency(key.currency1, FEE_RECIPIENT, protocolFee1);
        }

        emit FeesClaimed(tokenId, receiver, amount0, amount1, protocolFee0, protocolFee1);
    }

    // ----------------------------------------------------------
    // VIEWS
    // ----------------------------------------------------------

    function isLocked(uint256 tokenId) external view returns (bool) {
        return beneficiary[tokenId] != address(0);
    }

    function lockedLiquidity(uint256 tokenId) external view returns (uint128) {
        if (beneficiary[tokenId] == address(0)) {
            revert NotLocked();
        }

        return positionManager.getPositionLiquidity(tokenId);
    }

    function isFeeExempt(uint256 tokenId) external view returns (bool) {
        return beneficiary[tokenId] == FEE_RECIPIENT;
    }

    // ----------------------------------------------------------
    // INTERNAL TOKEN HANDLING
    // ----------------------------------------------------------

    function _balanceOf(address currency) internal view returns (uint256) {
        // Uniswap v4 represents native ETH as address(0).
        if (currency == address(0)) {
            return address(this).balance;
        }

        (bool success, bytes memory data) =
            currency.staticcall(abi.encodeWithSelector(IERC20.balanceOf.selector, address(this)));

        if (!success || data.length < 32) {
            revert BalanceCheckFailed();
        }

        return abi.decode(data, (uint256));
    }

    function _transferCurrency(address currency, address recipient, uint256 amount) internal {
        if (amount == 0) return;

        // Native ETH
        if (currency == address(0)) {
            (bool success,) = payable(recipient).call{value: amount}("");

            if (!success) {
                revert TransferFailed();
            }

            return;
        }

        // ERC20
        (bool success, bytes memory data) =
            currency.call(abi.encodeWithSelector(IERC20.transfer.selector, recipient, amount));

        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) {
            revert TransferFailed();
        }
    }

    /// @notice Required for native ETH fee collection.
    receive() external payable {}
}

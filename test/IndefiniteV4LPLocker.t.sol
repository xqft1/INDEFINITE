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

import {Test} from "forge-std/Test.sol";
import "../src/IndefiniteV4LPLocker.sol";

contract MockERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "BALANCE");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockPositionManager {
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => PoolKey) internal keys;
    mapping(uint256 => uint128) internal liquidity;
    mapping(uint256 => uint256) internal fee0;
    mapping(uint256 => uint256) internal fee1;
    mapping(uint256 => bytes) public lastHookData;

    function mintPosition(address owner, uint256 tokenId, address currency0, address currency1, uint128 amount)
        external
    {
        ownerOf[tokenId] = owner;

        keys[tokenId] =
            PoolKey({currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 60, hooks: address(0)});

        liquidity[tokenId] = amount;
    }

    function accrueFees(uint256 tokenId, uint256 amount0, uint256 amount1) external {
        fee0[tokenId] += amount0;
        fee1[tokenId] += amount1;
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        require(ownerOf[tokenId] == from, "NOT_OWNER");

        ownerOf[tokenId] = to;

        IERC721ReceiverTest(to).onERC721Received(msg.sender, from, tokenId, "");
    }

    function getPoolAndPositionInfo(uint256 tokenId) external view returns (PoolKey memory, uint256) {
        return (keys[tokenId], 0);
    }

    function getPositionLiquidity(uint256 tokenId) external view returns (uint128) {
        return liquidity[tokenId];
    }

    function modifyLiquidities(bytes calldata unlockData, uint256) external payable {
        (bytes memory actions, bytes[] memory params) = abi.decode(unlockData, (bytes, bytes[]));

        require(actions.length == 2, "BAD_ACTIONS");
        require(actions[0] == bytes1(uint8(0x01)), "NOT_DECREASE");
        require(actions[1] == bytes1(uint8(0x11)), "NOT_TAKE_PAIR");

        (uint256 tokenId, uint256 liquidityRemoved,,, bytes memory hookData) =
            abi.decode(params[0], (uint256, uint256, uint128, uint128, bytes));

        require(ownerOf[tokenId] == msg.sender, "LOCKER_NOT_OWNER");
        require(liquidityRemoved == 0, "PRINCIPAL_REMOVED");

        (address currency0, address currency1, address recipient) = abi.decode(params[1], (address, address, address));

        require(currency0 == keys[tokenId].currency0, "BAD_TOKEN0");
        require(currency1 == keys[tokenId].currency1, "BAD_TOKEN1");

        lastHookData[tokenId] = hookData;

        uint256 amount0 = fee0[tokenId];
        uint256 amount1 = fee1[tokenId];

        fee0[tokenId] = 0;
        fee1[tokenId] = 0;

        MockERC20(currency0).mint(recipient, amount0);
        MockERC20(currency1).mint(recipient, amount1);
    }
}

interface IERC721ReceiverTest {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4);
}

contract IndefiniteV4LPLockerTest is Test {
    address constant FEE_RECIPIENT = 0x9a30Cf4527D2CC80884405e16337149ab59e3d6E;

    address alice;
    address bob;

    MockERC20 token0;
    MockERC20 token1;
    MockPositionManager manager;
    IndefiniteV4LPLocker locker;

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        token0 = new MockERC20();
        token1 = new MockERC20();

        manager = new MockPositionManager();

        locker = new IndefiniteV4LPLocker(address(manager));
    }

    function testLockIsPermanent() public {
        manager.mintPosition(alice, 1, address(token0), address(token1), 1_000_000);

        vm.prank(alice);
        locker.lock(1);

        assertEq(manager.ownerOf(1), address(locker));
        assertEq(locker.beneficiary(1), alice);
        assertTrue(locker.isLocked(1));
    }

    function testClaimDoesNotRemoveLiquidity() public {
        manager.mintPosition(alice, 1, address(token0), address(token1), 1_000_000);

        vm.prank(alice);
        locker.lock(1);

        manager.accrueFees(1, 10_000, 20_000);

        uint128 beforeLiquidity = manager.getPositionLiquidity(1);

        vm.prank(alice);
        locker.claimFees(1);

        assertEq(manager.getPositionLiquidity(1), beforeLiquidity);

        assertEq(manager.ownerOf(1), address(locker));
    }

    function testOtherUserPaysOnePercent() public {
        manager.mintPosition(alice, 1, address(token0), address(token1), 1_000_000);

        vm.prank(alice);
        locker.lock(1);

        manager.accrueFees(1, 10_000, 20_000);

        vm.prank(alice);
        locker.claimFees(1);

        assertEq(token0.balanceOf(alice), 9_900);
        assertEq(token1.balanceOf(alice), 19_800);

        assertEq(token0.balanceOf(FEE_RECIPIENT), 100);

        assertEq(token1.balanceOf(FEE_RECIPIENT), 200);
    }

    function testYourPositionPaysNoFee() public {
        manager.mintPosition(FEE_RECIPIENT, 2, address(token0), address(token1), 1_000_000);

        vm.prank(FEE_RECIPIENT);
        locker.lock(2);

        manager.accrueFees(2, 10_000, 20_000);

        vm.prank(FEE_RECIPIENT);
        locker.claimFees(2);

        assertEq(token0.balanceOf(FEE_RECIPIENT), 10_000);

        assertEq(token1.balanceOf(FEE_RECIPIENT), 20_000);
    }

    function testOtherPersonCannotClaim() public {
        manager.mintPosition(alice, 1, address(token0), address(token1), 1_000_000);

        vm.prank(alice);
        locker.lock(1);

        vm.prank(bob);

        vm.expectRevert(IndefiniteV4LPLocker.NotBeneficiary.selector);

        locker.claimFees(1);
    }

    function testHookDataPassesThrough() public {
        manager.mintPosition(alice, 1, address(token0), address(token1), 1_000_000);

        vm.prank(alice);
        locker.lock(1);

        manager.accrueFees(1, 100, 100);

        bytes memory hookData = hex"deadbeef1234";

        vm.prank(alice);
        locker.claimFees(1, hookData);

        assertEq(keccak256(manager.lastHookData(1)), keccak256(hookData));
    }
}

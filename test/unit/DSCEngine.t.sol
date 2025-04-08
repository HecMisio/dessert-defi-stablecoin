// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.18;

import {DeployDSC} from "script/DeployDSC.s.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {Test, console} from "forge-std/Test.sol";
import {ERC20Mock} from "test/mocks/ERC20Mock.sol";
import {MockFailedTransferFrom} from "test/mocks/MockFailedTransferFrom.sol";
import {MockV3Aggregator} from "test/mocks/MockV3Aggregator.sol";
import {MockMoreDebtDSC} from "test/mocks/MockMoreDebtDSC.sol";

contract DSCEngineTest is Test {
    HelperConfig public helperConfig;
    DecentralizedStableCoin public dsc;
    DSCEngine public dscEngine;
    uint256 public amountToMint = 100 ether;

    address weth;
    address wbtc;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    uint256 public deployKey;

    address public Alice = makeAddr("Alice");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant STARTING_USER_BALANCE = 10 ether;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;

    address public liquidator = makeAddr("Liquidator");
    uint256 public constant LIQUIDATION_THRESHOLD = 50; // 50%
    uint256 public collateralToCover = 20 ether;

    function setUp() public {
        DeployDSC deployer = new DeployDSC();
        (dsc, dscEngine, helperConfig) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, deployKey) = helperConfig.activeNetworkConfig();
        if (block.chainid == 31_337) {
            vm.deal(Alice, STARTING_USER_BALANCE);
        }

        ERC20Mock(weth).mint(Alice, STARTING_ERC20_BALANCE);
        ERC20Mock(wbtc).mint(Alice, STARTING_ERC20_BALANCE);
    }

    address[] public tokenAddresses;
    address[] public feedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeedLength() public {
        tokenAddresses.push(weth);
        feedAddresses.push(ethUsdPriceFeed);
        feedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, feedAddresses, address(dsc));
    }

    function testGetCollateralValueInUsd() public view {
        uint256 ethAmount = 15e18;
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dscEngine.getCollateralValueInUsd(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 ethAmount = 0.05 ether;
        uint256 amountWeth = dscEngine.getTokenAmountFromUsd(weth, 100 ether);
        assertEq(ethAmount, amountWeth);
    }

    function testRevertsIfTransferFromFails() public {
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransferFrom mockCollateralToken = new MockFailedTransferFrom();
        tokenAddresses = [address(mockCollateralToken)];
        feedAddresses = [ethUsdPriceFeed];
        // DSCEngine receives the third parameter as dscAddress, not the tokenAddress used as collateral.
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(tokenAddresses, feedAddresses, address(dsc));
        mockCollateralToken.mint(Alice, AMOUNT_COLLATERAL);
        vm.startPrank(Alice);
        ERC20Mock(address(mockCollateralToken)).approve(address(mockDsce), AMOUNT_COLLATERAL);
        // Act / Assert
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        mockDsce.depositCollateral(address(mockCollateralToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRevertsIfCollateralZero() public {
        vm.startPrank(Alice);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock randToken = new ERC20Mock("RAN", "RAN", Alice, 100e18);
        vm.startPrank(Alice);
        ERC20Mock(randToken).approve(address(dscEngine), AMOUNT_COLLATERAL);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__TokenNotAllowed.selector, address(randToken)));
        dscEngine.depositCollateral(address(randToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(Alice);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralWithoutMinting() public depositedCollateral {
        uint256 dscBalance = dsc.balanceOf(Alice);
        assertEq(dscBalance, 0);
    }

    function testCanDepositedCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(Alice);
        uint256 expectedDepositedAmount = dscEngine.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, 0);
        assertEq(expectedDepositedAmount, AMOUNT_COLLATERAL);
    }

    function testRevertsIfMintedDscBreaksHealthFactor() public {
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        amountToMint =
            (AMOUNT_COLLATERAL * (uint256(price) * dscEngine.getAdditionalFeedPrecision())) / dscEngine.getPrecision();
        vm.startPrank(Alice);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);

        uint256 expectedHealthFactor =
            dscEngine.calculateHealthFactor(amountToMint, dscEngine.getCollateralValueInUsd(weth, AMOUNT_COLLATERAL));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
    }

    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(Alice);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
        _;
    }

    function testCanMintWithDepositedCollateral() public depositedCollateralAndMintedDsc {
        uint256 AliceBalance = dsc.balanceOf(Alice);
        assertEq(AliceBalance, amountToMint);
    }

    function testCanMintDsc() public depositedCollateral {
        vm.prank(Alice);
        dscEngine.mintDsc(amountToMint);

        uint256 AliceBalance = dsc.balanceOf(Alice);
        assertEq(AliceBalance, amountToMint);
    }

    function testRevertsIfBurnAmountIsZero() public {
        vm.startPrank(Alice);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.burnDsc(0);
        vm.stopPrank();
    }

    function testCantBurnMoreThanUserHas() public {
        vm.prank(Alice);
        vm.expectRevert();
        dscEngine.burnDsc(1);
    }

    function testCanBurnDsc() public depositedCollateralAndMintedDsc {
        vm.startPrank(Alice);
        dsc.approve(address(dscEngine), amountToMint);
        dscEngine.burnDsc(amountToMint);
        vm.stopPrank();

        uint256 AliceBalance = dsc.balanceOf(Alice);
        assertEq(AliceBalance, 0);
    }

    function testProperlyReportsHealthFactor() public depositedCollateralAndMintedDsc {
        uint256 expectedHealthFactor = 100 ether;
        uint256 healthFactor = dscEngine.getHealthFactor(Alice);
        // $100 minted with $20,000 collateral at 50% liquidation threshold
        // means that we must have $200 collatareral at all times.
        // 20,000 * 0.5 = 10,000
        // 10,000 / 100 = 100 health factor
        assertEq(healthFactor, expectedHealthFactor);
    }

    function testHealthFactorCanGoBelowOne() public depositedCollateralAndMintedDsc {
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        // Remember, we need $200 at all times if we have $100 of debt

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        uint256 AliceHealthFactor = dscEngine.getHealthFactor(Alice);
        // 180*50 (LIQUIDATION_THRESHOLD) / 100 (LIQUIDATION_PRECISION) / 100 (PRECISION) = 90 / 100 (totalDscMinted) =
        // 0.9
        assert(AliceHealthFactor == 0.9 ether);
    }

    // This test needs it's own setup
    function testMustImproveHealthFactorOnLiquidation() public {
        // Arrange - Setup
        MockMoreDebtDSC mockDsc = new MockMoreDebtDSC(ethUsdPriceFeed);
        tokenAddresses = [weth];
        feedAddresses = [ethUsdPriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(tokenAddresses, feedAddresses, address(mockDsc));
        mockDsc.transferOwnership(address(mockDsce));
        // Arrange - User
        vm.startPrank(Alice);
        ERC20Mock(weth).approve(address(mockDsce), AMOUNT_COLLATERAL);
        mockDsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();

        // Arrange - Liquidator
        collateralToCover = 1 ether;
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(mockDsce), collateralToCover);
        uint256 debtToCover = 10 ether;
        mockDsce.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
        mockDsc.approve(address(mockDsce), debtToCover);
        // Act
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        // Act/Assert
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorNotImproved.selector);
        mockDsce.liquidate(weth, Alice, debtToCover);
        vm.stopPrank();
    }

    function testCantLiquidateGoodHealthFactor() public depositedCollateralAndMintedDsc {
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dscEngine), collateralToCover);
        dscEngine.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
        dsc.approve(address(dscEngine), amountToMint);

        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dscEngine.liquidate(weth, Alice, amountToMint);
        vm.stopPrank();
    }

    modifier liquidated() {
        vm.startPrank(Alice);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 AliceHealthFactor = dscEngine.getHealthFactor(Alice);

        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dscEngine), collateralToCover);
        dscEngine.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
        dsc.approve(address(dscEngine), amountToMint);
        dscEngine.liquidate(weth, Alice, amountToMint); // We are covering their whole debt
        vm.stopPrank();
        _;
    }

    function testLiquidationPayoutIsCorrect() public liquidated {
        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(liquidator);
        uint256 expectedWeth = dscEngine.getTokenAmountFromUsd(weth, amountToMint)
            + (
                dscEngine.getTokenAmountFromUsd(weth, amountToMint) * dscEngine.getLiquidationBonus()
                    / dscEngine.getLiquidationPrecision()
            );
        uint256 hardCodedExpected = 6_111_111_111_111_111_110;
        assertEq(liquidatorWethBalance, hardCodedExpected);
        assertEq(liquidatorWethBalance, expectedWeth);
    }

    function testUserStillHasSomeEthAfterLiquidation() public liquidated {
        // Get how much WETH the Alice lost
        uint256 amountLiquidated = dscEngine.getTokenAmountFromUsd(weth, amountToMint)
            + (
                dscEngine.getTokenAmountFromUsd(weth, amountToMint) * dscEngine.getLiquidationBonus()
                    / dscEngine.getLiquidationPrecision()
            );

        uint256 usdAmountLiquidated = dscEngine.getCollateralValueInUsd(weth, amountLiquidated);
        uint256 expectedUserCollateralValueInUsd =
            dscEngine.getCollateralValueInUsd(weth, AMOUNT_COLLATERAL) - (usdAmountLiquidated);

        (, uint256 AliceCollateralValueInUsd) = dscEngine.getAccountInformation(Alice);
        uint256 hardCodedExpectedValue = 70_000_000_000_000_000_020;
        assertEq(AliceCollateralValueInUsd, expectedUserCollateralValueInUsd);
        assertEq(AliceCollateralValueInUsd, hardCodedExpectedValue);
    }

    function testLiquidatorTakesOnUsersDebt() public liquidated {
        (uint256 liquidatorDscMinted,) = dscEngine.getAccountInformation(liquidator);
        assertEq(liquidatorDscMinted, amountToMint);
    }

    function testUserHasNoMoreDebt() public liquidated {
        (uint256 AliceDscMinted,) = dscEngine.getAccountInformation(Alice);
        assertEq(AliceDscMinted, 0);
    }

    function testGetCollateralTokenPriceFeed() public view {
        address priceFeed = dscEngine.getCollateralTokenPriceFeed(weth);
        assertEq(priceFeed, ethUsdPriceFeed);
    }

    function testGetCollateralTokens() public view {
        address[] memory collateralTokens = dscEngine.getCollateralTokens();
        assertEq(collateralTokens[0], weth);
    }

    function testGetMinHealthFactor() public view {
        uint256 minHealthFactor = dscEngine.getMinHealthFactor();
        assertEq(minHealthFactor, MIN_HEALTH_FACTOR);
    }

    function testGetLiquidationThreshold() public view {
        uint256 liquidationThreshold = dscEngine.getLiquidationThreshold();
        assertEq(liquidationThreshold, LIQUIDATION_THRESHOLD);
    }

    function testGetAccountCollateralValueFromInformation() public depositedCollateral {
        (, uint256 collateralValue) = dscEngine.getAccountInformation(Alice);
        uint256 expectedCollateralValue = dscEngine.getCollateralValueInUsd(weth, AMOUNT_COLLATERAL);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetCollateralBalanceOfUser() public {
        vm.startPrank(Alice);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        uint256 collateralBalance = dscEngine.getCollateralBalanceOfUser(Alice, weth);
        assertEq(collateralBalance, AMOUNT_COLLATERAL);
    }

    function testGetAccountCollateralValue() public {
        vm.startPrank(Alice);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        uint256 collateralValue = dscEngine.getAccountCollateralValue(Alice);
        uint256 expectedCollateralValue = dscEngine.getCollateralValueInUsd(weth, AMOUNT_COLLATERAL);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetDsc() public view {
        address dscAddress = dscEngine.getDsc();
        assertEq(dscAddress, address(dsc));
    }

    function testLiquidationPrecision() public view {
        uint256 expectedLiquidationPrecision = 100;
        uint256 actualLiquidationPrecision = dscEngine.getLiquidationPrecision();
        assertEq(actualLiquidationPrecision, expectedLiquidationPrecision);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSC} from "script/DeployDSC.s.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console} from "forge-std/console.sol";
import {Handler} from "test/fuzz/Handler.t.sol";

contract Invariants is StdInvariant, Test {
    DeployDSC deployer;
    DSCEngine dsce;
    DecentralizedStableCoin dsc;
    HelperConfig config;
    address weth;
    address wbtc;
    Handler handler;

    function setUp() external {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (,, weth, wbtc,) = config.activeNetworkConfig();
        // targetContract(address(dsce));
        handler = new Handler(dsce, dsc);
        targetContract(address(handler));
    }

    function invariant_ProtocolTotalSupplyLessThanCollateralValue() public view {
        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dsce));
        uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dsce));

        uint256 wethValue = dsce.getCollateralValueInUsd(weth, totalWethDeposited);
        uint256 wbtcValue = dsce.getCollateralValueInUsd(wbtc, totalWbtcDeposited);
        console.log("totalSupply: ", totalSupply);
        console.log("wethValue: ", wethValue);
        console.log("wbtcValue: ", wbtcValue);
        console.log("Times Mint Called: ", handler.timesMintIsCalled());
        assert(wethValue + wbtcValue >= totalSupply);
    }

    function invariant_gettersCantRevert() public view {
        dsce.getAdditionalFeedPrecision();
        dsce.getCollateralTokens();
        dsce.getLiquidationBonus();
        dsce.getLiquidationThreshold();
        dsce.getMinHealthFactor();
        dsce.getPrecision();
        dsce.getDsc();
    }
}

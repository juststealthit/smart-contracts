// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {StealthToken} from "../../src/StealthToken.sol";
import {StealthTokenDeployer} from "../../src/StealthTokenDeployer.sol";
import {StealthFactory} from "../../src/StealthFactory.sol";
import {StealthConstants as C} from "../../src/libraries/StealthConstants.sol";

contract StealthTokenTest is BaseTest {
    address internal token;

    function setUp() public override {
        super.setUp();
        token = _launch(TAX, 4 ether);
    }

    function test_metadataOnChain() public view {
        StealthToken t = StealthToken(token);
        assertEq(t.name(), "Stealth Test");
        assertEq(t.symbol(), "MKT");
        assertEq(t.decimals(), 18);
        assertEq(t.logo(), "ipfs://bafystealthtestlogo");
        assertEq(t.description(), "A Stealth test token.");
        (string memory x, string memory tg, string memory dc, string memory web, string memory fc) = t.socials();
        assertEq(x, "https://x.com/stealthpad");
        assertEq(tg, "https://t.me/stealthpad");
        assertEq(dc, "");
        assertEq(web, "https://stealthpad.xyz");
        assertEq(fc, "");
        assertEq(t.launchpad(), "Stealth");
    }

    function test_getTokenInfoTuple() public view {
        (address dep, string memory logo, string memory desc, StealthToken.Socials memory s) =
            StealthToken(token).getTokenInfo();
        assertEq(dep, creator);
        assertEq(logo, "ipfs://bafystealthtestlogo");
        assertEq(desc, "A Stealth test token.");
        assertEq(s.twitter, "https://x.com/stealthpad");
        assertEq(s.website, "https://stealthpad.xyz");
    }

    function test_references() public view {
        StealthToken t = StealthToken(token);
        assertEq(t.deployer(), creator);
        assertEq(t.launchFactory(), address(factory));
        assertEq(t.locker(), address(locker));
        assertEq(t.hook(), address(hook));
        assertEq(t.poolId(), _poolId(token), "token knows its pool id");
        assertEq(t.feeVault(), address(vault));
        assertEq(t.poolManager(), address(manager));
        assertEq(t.settlement(), settlementAddr);
        assertEq(t.quote(), address(0), "paired with native");
    }

    /// @dev The deployer searches salts until the token's address is above the quote's; one that cannot be beaten
    ///      within MAX_SALT_TRIES is refused.
    function test_tokenDeployer_minesAboveQuote() public {
        StealthToken.Args memory a = _args(address(uint160(15 << 156)));
        address predicted = tokenDeployer.predict(bytes32(uint256(9)), a);
        assertGt(uint160(predicted), uint160(a.quote));
        vm.prank(address(factory));
        assertEq(tokenDeployer.deploy(bytes32(uint256(9)), a), predicted);

        a.quote = address(type(uint160).max - 1);
        vm.expectRevert(StealthTokenDeployer.QuoteAddressTooHigh.selector);
        tokenDeployer.predict(bytes32(uint256(9)), a);
    }

    function test_supplyIsFixedAndAllPlaced() public view {
        uint256 supply = IERC20(token).totalSupply();
        assertLe(supply, C.TOTAL_SUPPLY);
        assertGe(supply, C.TOTAL_SUPPLY - 1e9, "only rounding dust (under 1e-9 tokens) unminted");
        assertEq(IERC20(token).balanceOf(settlementAddr), supply, "the pool's settlement contract holds every token");
    }

    function test_holdersCanBurn() public {
        uint256 got = _buy(traders[0], token, 0.1 ether);
        uint256 supply = IERC20(token).totalSupply();
        vm.prank(traders[0]);
        StealthToken(token).burn(got / 2);
        assertEq(IERC20(token).totalSupply(), supply - got / 2);
    }

    function test_plainTransfersNoTax() public {
        uint256 got = _buy(traders[0], token, 0.1 ether);
        vm.prank(traders[0]);
        IERC20(token).transfer(traders[1], got);
        assertEq(IERC20(token).balanceOf(traders[1]), got, "no transfer tax");
    }

    function test_hasNoAdminSurface() public {
        bytes[5] memory calls = [
            abi.encodeWithSignature("owner()"),
            abi.encodeWithSignature("mint(address,uint256)", attacker, 1),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("blacklist(address)", attacker),
            abi.encodeWithSignature("transferOwnership(address)", attacker)
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = token.call(calls[i]);
            assertFalse(ok, "unexpected admin function");
        }
    }

    function test_revert_zeroAddresses() public {
        address[6] memory good = [address(1), address(2), address(3), address(4), address(5), address(6)];
        for (uint256 i; i < 6; ++i) {
            address[6] memory w = good;
            w[i] = address(0);
            vm.expectRevert(StealthToken.ZeroAddress.selector);
            new StealthToken(w[0], w[1], w[2], w[3], w[4], w[5]);
        }
    }

    function test_tokenDeployer_onlyFactory_andPredicts() public {
        StealthToken.Args memory a = _args(address(0));
        vm.prank(attacker);
        vm.expectRevert(StealthTokenDeployer.NotFactory.selector);
        tokenDeployer.deploy(bytes32(0), a);

        address predicted = tokenDeployer.predict(bytes32(uint256(7)), a);
        vm.prank(address(factory));
        address deployed = tokenDeployer.deploy(bytes32(uint256(7)), a);
        assertEq(deployed, predicted);

        vm.expectRevert(StealthTokenDeployer.ZeroAddress.selector);
        new StealthTokenDeployer(address(0), address(1), address(2), address(3), address(4), address(5));
    }

    // ---------------------------------------------------------------------
    // The clone
    // ---------------------------------------------------------------------

    function _args(address quote) internal view returns (StealthToken.Args memory) {
        return StealthToken.Args({
            name: "X",
            symbol: "X",
            logo: "",
            description: "",
            socials: _socials(),
            deployer: creator,
            quote: quote,
            maxWalletBps: 0,
            limitsWindow: 0,
            firstBuyLock: 0
        });
    }

    /// @notice A token is an EIP-1167 proxy of the one implementation: fixed code, no slot that could repoint it.
    function test_clone_isAMinimalProxyOfTheImplementation() public {
        address impl = address(tokenDeployer.implementation());
        bytes memory code = token.code;
        assertEq(code.length, 45 + Clones.fetchCloneArgs(token).length);
        bytes memory expected = abi.encodePacked(
            hex"363d3d373d3d3d363d73", impl, hex"5af43d82803e903d91602b57fd5bf3"
        );
        for (uint256 i; i < expected.length; ++i) {
            assertEq(code[i], expected[i], "EIP-1167 runtime");
        }
        address other = _launch(575, 5 ether);
        assertTrue(other != token);
        assertEq(StealthToken(other).locker(), StealthToken(token).locker(), "same implementation");
        assertEq(StealthToken(token).launchFactory(), StealthToken(impl).launchFactory(), "immutables come from it");
    }

    /// @notice The implementation itself has no supply and never gets any.
    function test_clone_implementationHoldsNothing() public {
        StealthToken impl = tokenDeployer.implementation();
        assertEq(impl.totalSupply(), 0);
        vm.prank(attacker);
        vm.expectRevert(StealthToken.NotLocker.selector);
        impl.mintSupply(attacker, 1);
    }

    /// @notice A launch writes its metadata into code: every string comes back byte for byte at the longest lengths.
    function test_clone_longestMetadataRoundTrips() public {
        StealthFactory.LaunchParams memory p = _params(TAX, 4 ether, 0);
        p.name = _text("n", C.MAX_NAME_LENGTH);
        p.symbol = _text("s", C.MAX_SYMBOL_LENGTH);
        p.logo = _text("l", C.MAX_LOGO_LENGTH);
        p.description = _text("d", C.MAX_DESCRIPTION_LENGTH);
        p.socials.twitter = _text("t", C.MAX_SOCIAL_LENGTH);
        p.socials.telegram = _text("g", C.MAX_SOCIAL_LENGTH);
        p.socials.discord = _text("c", C.MAX_SOCIAL_LENGTH);
        p.socials.website = _text("w", C.MAX_SOCIAL_LENGTH);
        p.socials.farcaster = _text("f", C.MAX_SOCIAL_LENGTH);
        vm.prank(creator);
        StealthToken t = StealthToken(factory.launch(p));
        assertEq(t.name(), p.name);
        assertEq(t.symbol(), p.symbol);
        assertEq(t.logo(), p.logo);
        assertEq(t.description(), p.description);
        (string memory x, string memory tg, string memory dc, string memory web, string memory fc) = t.socials();
        assertEq(x, p.socials.twitter);
        assertEq(tg, p.socials.telegram);
        assertEq(dc, p.socials.discord);
        assertEq(web, p.socials.website);
        assertEq(fc, p.socials.farcaster);
    }

    /// @notice Multibyte names and empty fields survive the packing, whatever bytes they are.
    function testFuzz_clone_metadataRoundTrips(string memory name, string memory logo, string memory discord) public {
        vm.assume(bytes(name).length != 0 && bytes(name).length <= C.MAX_NAME_LENGTH);
        vm.assume(bytes(logo).length <= C.MAX_LOGO_LENGTH && bytes(discord).length <= C.MAX_SOCIAL_LENGTH);
        StealthFactory.LaunchParams memory p = _params(TAX, 4 ether, 0);
        p.name = name;
        p.logo = logo;
        p.socials.discord = discord;
        vm.prank(creator2);
        StealthToken t = StealthToken(factory.launch(p));
        assertEq(t.name(), name);
        assertEq(t.symbol(), p.symbol);
        assertEq(t.logo(), logo);
        assertEq(t.description(), p.description);
        (,, string memory dc,,) = t.socials();
        assertEq(dc, discord);
        assertEq(t.deployer(), creator2);
        assertEq(t.quote(), address(0));
    }

    function test_revert_mintSupply_onlyLockerOnce() public {
        vm.prank(attacker);
        vm.expectRevert(StealthToken.NotLocker.selector);
        StealthToken(token).mintSupply(attacker, 1);
        vm.prank(address(locker));
        vm.expectRevert(StealthToken.AlreadyMinted.selector);
        StealthToken(token).mintSupply(attacker, 1);
    }

    function test_revert_setFirstBuyLock_onlyLocker() public {
        vm.prank(attacker);
        vm.expectRevert(StealthToken.NotLocker.selector);
        StealthToken(token).setFirstBuyLock(attacker, 1);
    }

    function _text(string memory unit, uint256 length) internal pure returns (string memory) {
        bytes memory out = new bytes(length);
        for (uint256 i; i < length; ++i) {
            out[i] = bytes(unit)[0];
        }
        return string(out);
    }
}

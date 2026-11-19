// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PaymentGate, IERC20} from "../src/PaymentGate.sol";

interface Vm {
    function prank(address msgSender) external;
    function expectRevert(bytes4 revertData) external;
    function expectRevert(bytes calldata revertData) external;
    function expectEmit(bool checkTopic1, bool checkTopic2, bool checkTopic3, bool checkData) external;
}

contract MockTUSD8 is IERC20 {
    mapping(address => uint256) public balanceOf;
    bool public failTransfer;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function setFailTransfer(bool _fail) external {
        failTransfer = _fail;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        if (failTransfer) return false;
        require(balanceOf[msg.sender] >= amount, "INSUFFICIENT_BALANCE");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract PaymentGateTest {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    MockTUSD8 internal tusd8;
    PaymentGate internal gate;

    address internal settler = address(0x1111);
    address internal payee = address(0x2222);
    address internal attacker = address(0x3333);

    bytes internal validPk;
    bytes internal validSig;

    event Released(
        address indexed payee,
        uint256 amount,
        uint256 indexed nonce,
        bytes32 indexed authHash,
        bytes32 signatureHash
    );

    function setUp() public {
        tusd8 = new MockTUSD8();
        validPk = new bytes(1952);
        validPk[0] = 0xAA;
        validPk[1951] = 0xBB;

        validSig = new bytes(3309);
        validSig[0] = 0x11;
        validSig[3308] = 0x22;

        gate = new PaymentGate(address(tusd8), settler, validPk);
        tusd8.mint(address(gate), 1_000_000); // 1.000000 tUSD8 (6 decimals)
    }

    function testConstructorValidatesZeroAddresses() public {
        vm.expectRevert(PaymentGate.ZeroAddress.selector);
        new PaymentGate(address(0), settler, validPk);

        vm.expectRevert(PaymentGate.ZeroAddress.selector);
        new PaymentGate(address(tusd8), address(0), validPk);
    }

    function testConstructorValidatesPublicKeyLength() public {
        bytes memory badPk = new bytes(1951);
        vm.expectRevert(
            abi.encodeWithSelector(PaymentGate.InvalidPublicKeyLength.selector, 1951, 1952)
        );
        new PaymentGate(address(tusd8), settler, badPk);
    }

    function testReleaseHappyPathAndEvent() public {
        uint256 amount = 250_000; // 0.25 tUSD8
        uint256 nonce = 1;
        bytes32 authHash = gate.computeAuthHash(payee, amount, nonce);

        vm.expectEmit(true, true, true, true);
        emit Released(payee, amount, nonce, authHash, keccak256(validSig));

        vm.prank(settler);
        gate.release(payee, amount, nonce, validSig);

        require(tusd8.balanceOf(payee) == amount, "Payee did not receive tUSD8");
        require(tusd8.balanceOf(address(gate)) == 750_000, "Escrow balance mismatch");
        require(gate.used(authHash), "authHash not marked used");
    }

    function testReleaseRevertsIfNotSettler() public {
        vm.prank(attacker);
        vm.expectRevert(PaymentGate.OnlySettler.selector);
        gate.release(payee, 100, 1, validSig);
    }

    function testReleaseRevertsOnInvalidSignatureLength() public {
        bytes memory shortSig = new bytes(3308);
        vm.prank(settler);
        vm.expectRevert(
            abi.encodeWithSelector(PaymentGate.InvalidSignatureLength.selector, 3308, 3309)
        );
        gate.release(payee, 100, 1, shortSig);
    }

    function testReleaseRevertsOnReplay() public {
        vm.prank(settler);
        gate.release(payee, 100, 1, validSig);

        bytes32 authHash = gate.computeAuthHash(payee, 100, 1);
        vm.prank(settler);
        vm.expectRevert(abi.encodeWithSelector(PaymentGate.AuthAlreadyUsed.selector, authHash));
        gate.release(payee, 100, 1, validSig);
    }

    function testReleaseRevertsIfERC20TransferReturnsFalse() public {
        tusd8.setFailTransfer(true);
        vm.prank(settler);
        vm.expectRevert(PaymentGate.TransferFailed.selector);
        gate.release(payee, 100, 1, validSig);
    }
}
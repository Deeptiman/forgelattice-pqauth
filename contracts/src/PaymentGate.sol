// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
}

contract PaymentGate {
    uint256 public constant MLDSA65_PK_LEN = 1952;
    uint256 public constant MLDSA65_SIG_LEN = 3309;

    IERC20 public immutable tusd8;
    address public immutable settler;
    bytes public dilithiumPublicKey;
    bytes32 public immutable dilithiumPublicKeyHash;

    mapping(bytes32 => bool) public used;

    event Released(
        address indexed payee,
        uint256 amount,
        uint256 indexed nonce,
        bytes32 indexed authHash,
        bytes32 signatureHash
    );

    error ZeroAddress();
    error OnlySettler();
    error InvalidPublicKeyLength(uint256 got, uint256 expected);
    error InvalidSignatureLength(uint256 got, uint256 expected);
    error AuthAlreadyUsed(bytes32 authHash);
    error TransferFailed();

    constructor(
        address _tusd8,
        address _settler,
        bytes memory _publicKey
    ) {
        if (_tusd8 == address(0) || _settler == address(0)) revert ZeroAddress();
        if (_publicKey.length != MLDSA65_PK_LEN) {
            revert InvalidPublicKeyLength(_publicKey.length, MLDSA65_PK_LEN);
        }
        tusd8 = IERC20(_tusd8);
        settler = _settler;
        dilithiumPublicKey = _publicKey;
        dilithiumPublicKeyHash = keccak256(_publicKey);
    }

    function computeAuthHash(
        address payee,
        uint256 amount,
        uint256 nonce
    ) public view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "FORGELATTICE_MLDSA65_PAYMENT_V1",
                block.chainid,
                address(this),
                dilithiumPublicKeyHash,
                payee,
                amount,
                nonce
            )
        );
    }

    function release(
        address payee,
        uint256 amount,
        uint256 nonce,
        bytes calldata signature
    ) external {
        if (msg.sender != settler) revert OnlySettler();
        if (signature.length != MLDSA65_SIG_LEN) {
            revert InvalidSignatureLength(signature.length, MLDSA65_SIG_LEN);
        }

        bytes32 authHash = computeAuthHash(payee, amount, nonce);
        if (used[authHash]) revert AuthAlreadyUsed(authHash);

        used[authHash] = true;
        emit Released(payee, amount, nonce, authHash, keccak256(signature));

        if (!tusd8.transfer(payee, amount)) revert TransferFailed();
    }
}
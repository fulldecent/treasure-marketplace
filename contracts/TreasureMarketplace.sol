// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;

import '@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/interfaces/IERC165Upgradeable.sol';
import '@openzeppelin/contracts-upgradeable/token/ERC1155/IERC1155Upgradeable.sol';
import '@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol';
import '@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol';
import '@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol';
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

/// @title Treasure NFT marketplace
/// @notice NFT marketplace contract for selling and buying ERC721 and ERC1155 token.
/// @dev This contract does not store any tokens at any time, it's only collects details
/// of "the sale" and approvals from both parties and preforms non-custodial transaction
/// by transfering NFT from owner to buying and payment token from buying to NFT owner.
contract TreasureMarketplace is OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    bytes4 private constant INTERFACE_ID_ERC721 = 0x80ac58cd;
    bytes4 private constant INTERFACE_ID_ERC1155 = 0xd9b67a26;

    /// @dev basis point constant for fee calcualtion
    uint256 public constant BASIS_POINTS = 10000;

    /// @dev token used for payments
    address public paymentToken;

    /// @dev fee taken on each sale in basis points,
    /// for example 100 is 100 basis points => 100/10000 = 1/100 = 1%
    uint256 public fee;
    /// @dev address that collects fees
    address public feeReceipient;

    struct Listing {
        /// @dev amount of tokens for sale. For ERC721 it's always 1.
        uint256 quantity;
        /// @dev price for each token listed. For ERC721 it's the price of sale,
        /// for ERC1155 this price is multiplied by amount of tokens being bought
        uint256 pricePerItem;
        /// @dev timestamp after which the listing is invalid
        uint256 expirationTime;
    }

    /// @dev mapping for listings, maps: nftAddress => tokenId => owner
    mapping(address => mapping(uint256 => mapping(address => Listing))) public listings;
    /// @dev nfts that are allowed to be sold on the marketplace, maps: nftAddress => bool
    mapping(address => bool) public nftWhitelist;

    event UpdateFee(uint256 fee);
    event UpdateFeeRecipient(address feeRecipient);
    event UpdatePaymentToken(address paymentToken);

    event NftWhitelistAdd(address nft);
    event NftWhitelistRemove(address nft);

    event ItemListed(
        address seller,
        address nftAddress,
        uint256 tokenId,
        uint256 quantity,
        uint256 pricePerItem,
        uint256 expirationTime
    );

    event ItemUpdated(
        address seller,
        address nftAddress,
        uint256 tokenId,
        uint256 quantity,
        uint256 pricePerItem,
        uint256 expirationTime
    );

    event ItemSold(
        address seller,
        address buyer,
        address nftAddress,
        uint256 tokenId,
        uint256 quantity,
        uint256 pricePerItem
    );

    event ItemCanceled(address seller, address nftAddress, uint256 tokenId);

    /// @dev checks if token is listed, if not reverts
    /// @param _nftAddress address of the NFT
    /// @param _tokenId token ID of the NFT
    /// @param _owner owner of the NFT
    modifier isListed(
        address _nftAddress,
        uint256 _tokenId,
        address _owner
    ) {
        Listing memory listing = listings[_nftAddress][_tokenId][_owner];
        require(listing.quantity > 0, "not listed item");
        _;
    }

    /// @dev checks if token is not listed, if it is, reverts
    /// @param _nftAddress address of the NFT
    /// @param _tokenId token ID of the NFT
    /// @param _owner owner of the NFT
    modifier notListed(
        address _nftAddress,
        uint256 _tokenId,
        address _owner
    ) {
        Listing memory listing = listings[_nftAddress][_tokenId][_owner];
        require(listing.quantity == 0, "already listed");
        _;
    }

    /// @dev validates listing, checks if seller still owns the token,
    /// checks if expirations date is not past, checks if quantity is above 0 and so is price
    /// @param _nftAddress address of the NFT
    /// @param _tokenId token ID of the NFT
    /// @param _owner owner of the NFT
    modifier validListing(
        address _nftAddress,
        uint256 _tokenId,
        address _owner
    ) {
        Listing memory listedItem = listings[_nftAddress][_tokenId][_owner];
        if (IERC165Upgradeable(_nftAddress).supportsInterface(INTERFACE_ID_ERC721)) {
            IERC721Upgradeable nft = IERC721Upgradeable(_nftAddress);
            require(nft.ownerOf(_tokenId) == _owner, "not owning item");
        } else if (IERC165Upgradeable(_nftAddress).supportsInterface(INTERFACE_ID_ERC1155)) {
            IERC1155Upgradeable nft = IERC1155Upgradeable(_nftAddress);
            require(nft.balanceOf(_owner, _tokenId) >= listedItem.quantity, "not owning item");
        } else {
            revert("invalid nft address");
        }
        require(listedItem.expirationTime >= block.timestamp, "listing expired");
        require(listedItem.quantity > 0, "listing quantity invalid");
        require(listedItem.pricePerItem > 0, "listing price invalid");
        _;
    }
    /// @dev check if NFT is whitelisted
    /// @param _nft address of the NFT
    modifier onlyWhitelisted(address _nft) {
        require(nftWhitelist[_nft], "nft not whitelisted");
        _;
    }

    /// @dev initializer
    /// @param _fee fee to be paid on each sale, in basis points
    /// @param _feeRecipient wallet to collets fees
    /// @param _paymentToken address of the token that is used for settlement
    function init(uint256 _fee, address _feeRecipient, address _paymentToken) external initializer {
        __Ownable_init_unchained();
        __Pausable_init_unchained();
        __ReentrancyGuard_init_unchained();

        setFee(_fee);
        setFeeRecipient(_feeRecipient);
        setPaymentToken(_paymentToken);
    }

    /// @dev Creates a NFT listing
    /// @param _nftAddress address of the NFT to be sold
    /// @param _tokenId token ID of the NFT to be sold
    /// @param _quantity number of tokens to be sold, for ERC721 must be 1
    /// @param _pricePerItem amount of payment token (ERC20) chrged for each sold token (ERC1155) or for 1 NFT (ERC721)
    /// @param _expirationTime timestamp after which listing is invalid
    function createListing(
        address _nftAddress,
        uint256 _tokenId,
        uint256 _quantity,
        uint256 _pricePerItem,
        uint256 _expirationTime
    )
        external
        whenNotPaused
        notListed(_nftAddress, _tokenId, _msgSender())
        onlyWhitelisted(_nftAddress)
    {
        if (_expirationTime == 0) _expirationTime = type(uint256).max;
        require(_expirationTime > block.timestamp, "invalid expiration time");
        require(_pricePerItem > 0, "cannot sell for 0");

        if (IERC165Upgradeable(_nftAddress).supportsInterface(INTERFACE_ID_ERC721)) {
            IERC721Upgradeable nft = IERC721Upgradeable(_nftAddress);
            require(nft.ownerOf(_tokenId) == _msgSender(), "not owning item");
            require(nft.isApprovedForAll(_msgSender(), address(this)), "item not approved");
            require(_quantity == 1, "cannot list multiple ERC721");
        } else if (IERC165Upgradeable(_nftAddress).supportsInterface(INTERFACE_ID_ERC1155)) {
            IERC1155Upgradeable nft = IERC1155Upgradeable(_nftAddress);
            require(nft.balanceOf(_msgSender(), _tokenId) >= _quantity, "must hold enough nfts");
            require(nft.isApprovedForAll(_msgSender(), address(this)), "item not approved");
            require(_quantity > 0, "nothing to list");
        } else {
            revert("invalid nft address");
        }

        listings[_nftAddress][_tokenId][_msgSender()] = Listing(
            _quantity,
            _pricePerItem,
            _expirationTime
        );

        emit ItemListed(
            _msgSender(),
            _nftAddress,
            _tokenId,
            _quantity,
            _pricePerItem,
            _expirationTime
        );
    }

    /// @dev Update existing listing
    /// @param _nftAddress address of the NFT to be sold
    /// @param _tokenId token ID of the NFT to be sold
    /// @param _newQuantity new number of tokens to be sold, for ERC721 must be 1
    /// @param _newPricePerItem new amount of payment token (ERC20) chrged for each sold token (ERC1155) or for 1 NFT (ERC721)
    /// Higher amount is allowed because front-running protection is implemented in `buyItem` function
    /// @param _newExpirationTime new timestamp after which listing is invalid
    function updateListing(
        address _nftAddress,
        uint256 _tokenId,
        uint256 _newQuantity,
        uint256 _newPricePerItem,
        uint256 _newExpirationTime
    )
        external
        nonReentrant
        whenNotPaused
        isListed(_nftAddress, _tokenId, _msgSender())
    {
        require(_newExpirationTime > block.timestamp, "invalid expiration time");
        require(_newPricePerItem > 0, "cannot sell for 0");

        Listing storage listedItem = listings[_nftAddress][_tokenId][_msgSender()];
        require(_newPricePerItem <= listedItem.pricePerItem, "Cannot increase price");

        if (IERC165Upgradeable(_nftAddress).supportsInterface(INTERFACE_ID_ERC721)) {
            IERC721Upgradeable nft = IERC721Upgradeable(_nftAddress);
            require(nft.ownerOf(_tokenId) == _msgSender(), "not owning item");
            require(_newQuantity == 1, "Cannot list multiple ERC721");
        } else if (IERC165Upgradeable(_nftAddress).supportsInterface(INTERFACE_ID_ERC1155)) {
            IERC1155Upgradeable nft = IERC1155Upgradeable(_nftAddress);
            require(nft.balanceOf(_msgSender(), _tokenId) >= _newQuantity, "must hold enough nfts");
            require(_newQuantity > 0, "cannot update quantity to 0");
        } else {
            revert("invalid nft address");
        }

        listedItem.quantity = _newQuantity;
        listedItem.pricePerItem = _newPricePerItem;
        listedItem.expirationTime = _newExpirationTime;

        emit ItemUpdated(
            _msgSender(),
            _nftAddress,
            _tokenId,
            _newQuantity,
            _newPricePerItem,
            _newExpirationTime
        );
    }

    /// @dev Cancel existing listing
    /// @param _nftAddress address of the NFT to be sold
    /// @param _tokenId token ID of the NFT to be sold
    function cancelListing(address _nftAddress, uint256 _tokenId)
        external
        nonReentrant
        whenNotPaused
        isListed(_nftAddress, _tokenId, _msgSender())
    {
        _cancelListing(_nftAddress, _tokenId, _msgSender());
    }

    /// @dev Delete listing
    /// @param _nftAddress address of the NFT to be sold
    /// @param _tokenId token ID of the NFT to be sold
    /// @param _owner current owner of the NFT
    function _cancelListing(
        address _nftAddress,
        uint256 _tokenId,
        address _owner
    ) internal {
        Listing memory listedItem = listings[_nftAddress][_tokenId][_owner];
        if (IERC165Upgradeable(_nftAddress).supportsInterface(INTERFACE_ID_ERC721)) {
            IERC721Upgradeable nft = IERC721Upgradeable(_nftAddress);
            require(nft.ownerOf(_tokenId) == _owner, "not owning item");
        } else if (IERC165Upgradeable(_nftAddress).supportsInterface(INTERFACE_ID_ERC1155)) {
            IERC1155Upgradeable nft = IERC1155Upgradeable(_nftAddress);
            require(nft.balanceOf(_msgSender(), _tokenId) >= listedItem.quantity, "not owning item");
        } else {
            revert("invalid nft address");
        }

        delete (listings[_nftAddress][_tokenId][_owner]);
        emit ItemCanceled(_owner, _nftAddress, _tokenId);
    }


    /// @dev Buy listed NFT
    /// @param _nftAddress address of the NFT to be bought
    /// @param _tokenId token ID of the NFT to be bought
    /// @param _owner current owner of the NFT to be bought
    /// @param _quantity number of tokens to be bought For ERC721 must be 1,
    /// for ERC1155 can be between 1 and number of tokens being sold
    /// @param _maxPricePerItem maximum amount of payment token (ERC20) that buyer is willing to pay.
    /// For ERC721 it's the price paid, for ERC1155 is the price per token that is multiplied by `_quantity` provided.
    function buyItem(
        address _nftAddress,
        uint256 _tokenId,
        address _owner,
        uint256 _quantity,
        uint256 _maxPricePerItem
    )
        external
        nonReentrant
        whenNotPaused
        isListed(_nftAddress, _tokenId, _owner)
        validListing(_nftAddress, _tokenId, _owner)
    {
        require(_msgSender() != _owner, "Cannot buy your own item");

        Listing storage listedItem = listings[_nftAddress][_tokenId][_owner];
        uint256 pricePerItem = listedItem.pricePerItem;

        require(_quantity > 0, "Nothing to buy");
        require(listedItem.quantity >= _quantity, "not enough quantity");
        require(pricePerItem <= _maxPricePerItem, "price increased");

        _buyItem(_nftAddress, _tokenId, _owner, _quantity, pricePerItem);
    }

    /// @dev Transfers ERC721 or number of ERC1155, deletes listing if there's nothing else
    /// to sell and transfer payment to seller.
    /// @param _nftAddress address of the NFT to be bought
    /// @param _tokenId token ID of the NFT to be bought
    /// @param _owner current owner of the NFT to be bought
    /// @param _quantity number of tokens to be bought For ERC721 must be 1,
    /// for ERC1155 can be between 1 and number of tokens being sold
    /// @param _pricePerItem amount of payment token (ERC20) that buyer is willing to pay.
    /// For ERC721 it's the price paid, for ERC1155 is the price per token that is multiplied
    /// by `_quantity` provided.
    function _buyItem(
        address _nftAddress,
        uint256 _tokenId,
        address _owner,
        uint256 _quantity,
        uint256 _pricePerItem
    ) internal {
        Listing storage listedItem = listings[_nftAddress][_tokenId][_owner];

        // Transfer NFT to buyer
        if (IERC165Upgradeable(_nftAddress).supportsInterface(INTERFACE_ID_ERC721)) {
            require(_quantity == 1, "Cannot buy multiple ERC721");
            IERC721Upgradeable(_nftAddress).safeTransferFrom(_owner, _msgSender(), _tokenId);
        } else {
            IERC1155Upgradeable(_nftAddress).safeTransferFrom(_owner, _msgSender(), _tokenId, _quantity, bytes(""));
        }

        if (listedItem.quantity == _quantity) {
            delete (listings[_nftAddress][_tokenId][_owner]);
        } else {
            listings[_nftAddress][_tokenId][_owner].quantity -= _quantity;
        }

        emit ItemSold(
            _owner,
            _msgSender(),
            _nftAddress,
            _tokenId,
            _quantity,
            _pricePerItem
        );

        uint256 totalPrice = _pricePerItem * _quantity;
        uint256 feeAmount = totalPrice * fee / BASIS_POINTS;
        IERC20Upgradeable(paymentToken).safeTransferFrom(_msgSender(), feeReceipient, feeAmount);
        IERC20Upgradeable(paymentToken).safeTransferFrom(_msgSender(), _owner, totalPrice - feeAmount);
    }

    // admin

    /// @dev Sets fee in basis points. Callable by owner only.
    /// @param _fee fee to be paid on each sale, in basis points
    function setFee(uint256 _fee) public onlyOwner {
        require(_fee < BASIS_POINTS, "max fee");
        fee = _fee;
        emit UpdateFee(_fee);
    }

    /// @dev Sets fee recipient. Callable by owner only.
    /// @param _feeRecipient wallet to collets fees
    function setFeeRecipient(address _feeRecipient) public onlyOwner {
        feeReceipient = _feeRecipient;
        emit UpdateFeeRecipient(_feeRecipient);
    }

    /// @dev Sets payment token address. Callable by owner only.
    /// @param _paymentToken address of the token that is used for settlement
    function setPaymentToken(address _paymentToken) public onlyOwner {
        paymentToken = _paymentToken;
        emit UpdatePaymentToken(_paymentToken);
    }

    /// @dev Whitelists NFT address
    /// @param _nft address of the NFT to be whitelisted
    function addToWhitelist(address _nft) external onlyOwner {
        require(!nftWhitelist[_nft], "nft already whitelisted");
        nftWhitelist[_nft] = true;
        emit NftWhitelistAdd(_nft);
    }

    /// @dev Removes NFT address from whitelist
    /// @param _nft address of the NFT to be removed
    function removeFromWhitelist(address _nft) external onlyOwner onlyWhitelisted(_nft) {
        nftWhitelist[_nft] = false;
        emit NftWhitelistRemove(_nft);
    }

    /// @dev Pauses marketplace. Creating, updating, canceling and buying is paused.
    function pause() external onlyOwner {
        _pause();
    }

    /// @dev Unpauses marketplace
    function unpause() external onlyOwner {
        _unpause();
    }
}

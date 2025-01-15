// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

contract THJBera is ERC4626Upgradeable, OwnableUpgradeable, PausableUpgradeable {
    /*###############################################################
                            STORAGE
    ###############################################################*/
    /*###############################################################
                            CONSTRUCTOR
    ###############################################################*/
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    /*###############################################################
                            INITIALIZER
    ###############################################################*/
    /*
        The asset should be WBERA.
    */
    function initialize(address _asset, address _owner) external initializer {
        __ERC4626_init(IERC20(_asset));
        __ERC20_init("THJBera", "thjBERA");
        __Ownable_init(_owner);
        _pause();
    }
    /*###############################################################
                            OWNER LOGIC
    ###############################################################*/
    function pause() external onlyOwner {
        _pause();
    }
    function unpause() external onlyOwner {
        _unpause();
    }
    function withdraw(uint256 assets, address receiver) external onlyOwner {
        SafeERC20.safeTransferFrom(IERC20(asset()), address(this), receiver, assets);
    }
    /*###############################################################
                            EXTERNAL LOGIC
    ###############################################################*/
    function withdraw(uint256 assets, address receiver, address owner)
    public
    override
    whenNotPaused
    returns (uint256) {
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner)
    public
    override
    whenNotPaused
    returns (uint256) {
        return super.redeem(shares, receiver, owner);
    }
    /*###############################################################
                            VIEW LOGIC
    ###############################################################*/

    /*###############################################################
    ###############################################################*/
    receive() external payable {}
}

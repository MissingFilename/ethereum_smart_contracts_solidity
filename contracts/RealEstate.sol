//SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title RealEstate.sol
 * @notice This is the contract that implements the lease functionality using an ERC20 token
 */
contract RealEstate {
    using SafeERC20 for IERC20;
    
    IERC20 public token;
    
    uint8 public avgBlockTime;                          // Avg block time in seconds
    uint8 public tax;                                   // Can Preset Tax rate in constructor. To be changed by government only.
    uint8 public rentalLimitMonths;                     // Months any tenant can pay rent in advance for.
    uint256 public rentalLimitBlocks;                   // ...in Blocks.
    uint256 constant private MAX_UINT256 = 2**256 - 1;  // Very large number.
    uint256 public rentPer30Day;                        // rate charged by mainPropertyOwner for 30 Days of rent.
    uint256 public accumulated;                         // Globally accumulated funds not distributed to stakeholder yet excluding gov.
    uint256 public blocksPer30Day;                      // Calculated from avgBlockTime. Acts as time measurement for rent.
    uint256 public rentalBegin;                         // begin of rental(in blocknumber)
    uint256 public occupiedUntill;                      // Blocknumber until the Property is occupied.
    uint256 private _taxdeduct;                         // amount of tax to be paid for incoming ether.

    address public gov = msg.sender;                    // Government will deploy contract.
    address public tenant;                              // only tenant can pay the Smart Contract.

    address[] public stakeholders;                      // Array of stakeholders. Government can addStakeholder or removeStakeholder. 
                                                       // Recipient of token needs to be isStakeholder = true to be able to receive token.

    mapping (address => uint256) public revenues;       // Distributed revenue account balance for each stakeholder including gov.
    mapping (address => uint256) public rentpaidUntill; // Blocknumber until the rent is paid.
    mapping (address => uint256) public sharesOffered;  // Number of Shares a Stakeholder wants to offer to other stakeholders
    mapping (address => uint256) public shareSellPrice; // Price per Share a Stakeholder wants to have when offering to other Stakeholders

    // Define events
    event ShareTransfer(address indexed from, address indexed to, uint256 shares);
    event Seizure(address indexed seizedfrom, address indexed to, uint256 shares);
    event ChangedTax(uint256 NewTax);
    event MainPropertyOwner(address NewMainPropertyOwner);
    event NewStakeHolder(address StakeholderAdded);
    event CurrentlyEligibletoPayRent(address Tenant);
    event PrePayRentLimit (uint8 Months);
    event AvgBlockTimeChangedTo(uint8 s);
    event RentPer30DaySetTo (uint256 WEIs);
    event StakeHolderBanned (address banned);
    event RevenuesDistributed (address shareholder, uint256 gained, uint256 total);
    event Withdrawal (address shareholder, uint256 withdrawn);
    event Rental (uint256 date, address renter, uint256 rentPaid, uint256 tax, uint256 distributableRevenue, uint256 rentedFrom, uint256 rentedUntill);
    event SharesOffered(address Seller, uint256 AmmountShares, uint256 PricePerShare);
    event SharesSold(address Seller, address Buyer, uint256 Sharesold, uint256 PricePerShare);
    event NewStakeholderArray();

    constructor (
        address _token,
        uint8 _tax,
        uint8 _avgBlockTime,
        address[] memory _stakeholders
    ) {
        token = IERC20(_token);
        tax = _tax;
        avgBlockTime = _avgBlockTime;
        createStakeholderArray(_stakeholders);
        blocksPer30Day = 60*60*24*30/avgBlockTime;
        rentalLimitMonths = 12;
        rentalLimitBlocks = rentalLimitMonths * blocksPer30Day;
    }
    
    // Define modifiers in this section
    modifier onlyGov{
        require(msg.sender == gov);
        _;
    }

    modifier eligibleToPayRent{                             // only one tenant at a time can be allowed to pay rent.
        require(msg.sender == tenant);
        _;
    }

    // Define functions in this section

    // Viewable functions
    function showSharesOf(address _owner) public view returns (uint256 balance) {
        return token.balanceOf(_owner);
    }

    function isStakeholder(address _address) public view returns(bool, uint256) {
        for (uint256 s = 0; s < stakeholders.length; s += 1){
            if (_address == stakeholders[s]) return (true, s);
        }
        return (false, 0);
    }

    function currentTenantCheck(address _tenantcheck) public view returns(bool, uint256) {
        require(occupiedUntill == rentpaidUntill[tenant], "The entered address is not the current tenant");
        if (rentpaidUntill[_tenantcheck] > block.number) {
            uint256 daysRemaining = (rentpaidUntill[_tenantcheck] - block.number) * avgBlockTime / 86400;  // 86400 seconds in a day.
            return (true, daysRemaining);  // gives tenant paid status true or false and days remaining
        }
        else return (false, 0);
    }

    // Functions of government
    /**
     * @notice This function takes an array of Stakeholder addresses and creates the
     * stakeholder array.
     * @dev The function assumes an empty stakeholders array. So we don't have to perform
     * isStakeholder checking.
     */
    function createStakeholderArray(address[] memory _stakeholders) public onlyGov {
        address[] memory stakeholdersNew = new address[](_stakeholders.length + 1);
        stakeholdersNew[0] = gov;
        for(uint i=0; i<_stakeholders.length; i++) {
            stakeholdersNew[i+1] = _stakeholders[i];
        }

        stakeholders = stakeholdersNew;
        emit NewStakeholderArray();
    }

    function addStakeholder(address _stakeholder) public onlyGov {
        (bool _isStakeholder, ) = isStakeholder(_stakeholder);
        if (!_isStakeholder) stakeholders.push(_stakeholder);
        emit NewStakeHolder(_stakeholder);
    }

    function banStakeholder(address _stakeholder) public onlyGov {
        (bool _isStakeholder, uint256 s) = isStakeholder(_stakeholder);
        if (_isStakeholder) {
            stakeholders[s] = stakeholders[stakeholders.length - 1];
            stakeholders.pop();
            
            // Transfer tokens from banned stakeholder to government
            uint256 tokensToSeize = token.balanceOf(_stakeholder);
            if (tokensToSeize > 0) {
                // This will fail unless the contract has approval
                bool seized = seizureFrom(_stakeholder, msg.sender, tokensToSeize);
                require(seized, "Token seizure failed");
            }
            
            emit StakeHolderBanned(_stakeholder);
        }
    }

    function setTax(uint8 _x) public onlyGov {
        require(_x <= 100, "Valid tax rate (0% - 100%) required");
        tax = _x;
        emit ChangedTax(tax);
    }

    function SetAvgBlockTime(uint8 _sPerBlock) public onlyGov {
        require(_sPerBlock > 0, "Please enter a Value above 0");
        avgBlockTime = _sPerBlock;
        blocksPer30Day = (60*60*24*30) / avgBlockTime;
        emit AvgBlockTimeChangedTo(avgBlockTime);
    }

    function distribute() public onlyGov {
        uint256 _accumulated = accumulated;
        accumulated = 0;
        
        uint256 totalSupply = token.totalSupply() / 1e18;
        require(totalSupply > 0, "Total supply must be greater than 0");
        
        for (uint256 s = 0; s < stakeholders.length; s += 1) {
            address stakeholder = stakeholders[s];
            uint256 _shares = token.balanceOf(stakeholder);
            if (_shares > 0) {
                uint256 ethertoreceive = (_accumulated * _shares) / totalSupply;
                revenues[stakeholder] = revenues[stakeholder] + ethertoreceive;
                emit RevenuesDistributed(stakeholder, ethertoreceive, revenues[stakeholder]);
            }
        }
    }

    // Hybrid Governmental
    function seizureFrom(address _from, address _to, uint256 _value) public returns (bool success) {
        require(msg.sender == gov, "Only government can seize tokens");
        
        // This will fail unless the contract has been approved as a spender
        try token.transferFrom(_from, _to, _value) {
            emit Seizure(_from, _to, _value);
            return true;
        } catch {
            return false;
        }
    }

    // mainPropertyOwner functions
    function canPayRent(address _tenant) public onlyGov {
        tenant = _tenant;
        emit CurrentlyEligibletoPayRent(tenant);
    }
    
    function limitadvancedrent(uint8 _monthstolimit) public onlyGov {
        rentalLimitMonths = _monthstolimit;
        rentalLimitBlocks = _monthstolimit * blocksPer30Day;
        emit PrePayRentLimit(_monthstolimit);
    }

    function setRentper30Day(uint256 _rent) public onlyGov {
        rentPer30Day = _rent;
        emit RentPer30DaySetTo(rentPer30Day);
    }

    // Stakeholder functions
    function offerShares(uint256 _sharesOffered, uint256 _shareSellPrice) public {
        (bool _isStakeholder, ) = isStakeholder(msg.sender);
        require(_isStakeholder, "Must be a stakeholder to offer shares");
        require(_sharesOffered <= token.balanceOf(msg.sender), "Cannot offer more shares than owned");
        
        sharesOffered[msg.sender] = _sharesOffered;
        shareSellPrice[msg.sender] = _shareSellPrice;
        emit SharesOffered(msg.sender, _sharesOffered, _shareSellPrice);
    }

    function buyShares(uint256 _sharesToBuy, address payable _from) public payable {
        (bool _isStakeholder, ) = isStakeholder(msg.sender);
        require(_isStakeholder, "Must be a stakeholder to buy shares");
        require(msg.value == _sharesToBuy * shareSellPrice[_from], "Incorrect payment amount");
        require(_sharesToBuy <= sharesOffered[_from], "Cannot buy more shares than offered");
        require(_sharesToBuy <= token.balanceOf(_from), "Seller doesn't have enough shares");
        require(_from != msg.sender, "Cannot buy from yourself");
        
        // Transfer shares (tokens) from seller to buyer
        // This will fail if the seller hasn't approved this contract to transfer their tokens
        token.transferFrom(_from, msg.sender, _sharesToBuy);
            // Update offered shares
        sharesOffered[_from] -= _sharesToBuy;
            // Transfer payment to seller
        _from.transfer(msg.value);
    }

    function withdraw() public payable {
        uint256 revenue = revenues[msg.sender];
        require(revenue > 0, "No revenue to withdraw");
        
        revenues[msg.sender] = 0;
        payable(msg.sender).transfer(revenue);
        emit Withdrawal(msg.sender, revenue);
    }

    // Renter function
    function payRent(uint8 _months) public payable eligibleToPayRent {
        uint256 _rentdue = _months * rentPer30Day;
        uint256 _additionalBlocks = _months * blocksPer30Day;
        
        require(msg.value == _rentdue, "Incorrect rent payment amount");
        require(block.number + _additionalBlocks < block.number + rentalLimitBlocks, "Exceeds rental limit");
        
        _taxdeduct = (msg.value * tax) / 100;  // Deduct taxes (% of total payment)
        accumulated += (msg.value - _taxdeduct);  // Accumulate revenues
        revenues[gov] += _taxdeduct;  // Accumulate taxes
        
        if (rentpaidUntill[tenant] == 0 && occupiedUntill < block.number) {  // Hasn't rented yet & flat is empty
            rentpaidUntill[tenant] = block.number + _additionalBlocks;  // Rents from now on
            rentalBegin = block.number;
        } else if (rentpaidUntill[tenant] == 0 && occupiedUntill > block.number) {  // Hasn't rented yet & flat is occupied
            rentpaidUntill[tenant] = occupiedUntill + _additionalBlocks;  // Rents from when it is free
            rentalBegin = occupiedUntill;
        } else if (rentpaidUntill[tenant] > block.number) {  // Is renting, contract is running
            rentpaidUntill[tenant] += _additionalBlocks;  // Extends rental
            rentalBegin = occupiedUntill;
        } else if (rentpaidUntill[tenant] < block.number && occupiedUntill > block.number) {  // Has rented before & flat is occupied
            rentpaidUntill[tenant] = occupiedUntill + _additionalBlocks;  // Rents from when it is free
            rentalBegin = occupiedUntill;
        } else if (rentpaidUntill[tenant] < block.number && occupiedUntill < block.number) {  // Has rented before & flat is empty
            rentpaidUntill[tenant] = block.number + _additionalBlocks;  // Rents from now on
            rentalBegin = block.number;
        }
        
        occupiedUntill = rentpaidUntill[tenant];  // Set new occupiedUntill
        emit Rental(block.timestamp, msg.sender, msg.value, _taxdeduct, (msg.value - _taxdeduct), rentalBegin, occupiedUntill);
    }

    // Fallback
    receive() external payable {
        payable(msg.sender).transfer(msg.value);
    }
}
pragma solidity ^0.5.1;

import "./ownable.sol";
import "./safemath.sol";

/*
    This contract describes an investment offer opened up to everyone. Members of the blockchain
    can invest into this offer up to the requested amount. The offer goes through 2 cycles :
    an investment cycle of at least 6hours and a dividend cycle of an arbitrary time.

    For the first cycle, the contract owner sets a minimum and a maximum amount a user can
    invest. Everyone can participate and withdraw at any time during the first cycle.

    The dividend cycle is defined using a percentage interest. During this cycle, the contract
    owner must pay each one of its investors the indicated percentage interest of the original
    requested amount. The contract owner sets the second cycle duration at contract's creation.
    The owner has to agree on a rate at which it will pay dividends to the investors
    (e.g. monthly).
    At the end of the second cycle, the owner should refund every investor of its investment
    amount.

    @author Nicolas d'Argenlieu
*/
contract Offer is Ownable
{
    // Declares using safe math operations on uint256/uint
    using SafeMath for uint;

    // Describes the structure of a single investment
    struct Investment {
        string investorName; // Could be optional
        address payable investorAddress;
        uint amount;
    }

    // The requested amount for the investment offer to succeed
    uint private target_amount;
    // The maximum funds a user can invest
    uint private maxFund;
    // The minimum funds a user can invest
    uint private minFund;
    // The cycle in which the contract is
    uint private cycle;
    // Percentage gain
    uint private percentage;
    // Minimal duration of the investment cycle
    uint private minBlock;

    // Holds all the investments for this current offer.
    // Key is a hash of the address of the investment
    mapping (uint => Investment) public investments;
    // Holds the keys for the investments
    uint[] private mappedKeys;

    // Notifies when a new fund is brought to the investment
    event NewFunds(address addr, uint amount);
    // Notifies when the requested amount was reached
    event TargetReached();
    // Notifies if the offer was cancelled
    event OfferCancelled();
    //Notifies everyone was refunded
    event GlobalRefundDone();
    // Notifies in case of a withdrawal
    event Withdrawal(address addr, uint amount);
    // Notifies when a user wants to invest too much
    event TooMuchInvest(address addr, uint needed, uint provided);
    // Notifies passage to second cycle
    event ToSecondCycle();

    // Creates the investment offer with the requested amount, min and max investments,
    // percentage gain for the investors and first & second cycle duration
    constructor(uint _requestedAmount, uint _minFund, uint _maxFund, uint _percentage) public {
        // The first cycle lasts at east 6h
        uint meanBlockDuration = 17; // average duration between ethereum block creation
        uint minCycleDuration = 21600; // 6h in seconds
        minBlock = now + uint(minCycleDuration/meanBlockDuration);

        require(_minFund <= _maxFund);
        maxFund = _maxFund;
        minFund = _minFund;

        // The maximum amount of funds has to be at most the goal
        require(_requestedAmount >= _maxFund);
        target_amount = _requestedAmount;

        require(_percentage<=100);
        percentage = _percentage;

        cycle = 1;
    }

    // Verifies the contract is in its first cycle
    modifier investmentPossible() {
        require(cycle == 1);
        _;
    }

    // Verifies the contract is in the second cycle
    modifier secondCycle() {
        require(cycle==2);
        _;
    }

    // Verifies that the given amount does the exceed the goal limit
    modifier isNotTooMuch(address _address, uint _amount) {
        uint currentFunds = getCurrentFunds();
        uint futureFunds = currentFunds.add(_amount);
        if (futureFunds >= target_amount) {
            emit TooMuchInvest(_address, target_amount.sub(currentFunds), _amount);
        }
        require(futureFunds <= target_amount);
        _;
    }

    // Verifies that an investment is possible
    modifier validInvestment(uint _amount, address _address) {
        require(_amount <= maxFund);
        require(_amount >= minFund);
        require(!alreadyInvested(_address));
        _;
    }

    // Returns the current amount of investment
    function getCurrentFunds() view public returns(uint) {
        uint total = 0;
        for (uint i = 0; i < mappedKeys.length; i++) {
            total = total.add(investments[mappedKeys[i]].amount);
        }
        return total;
    }

    // Generates the key for a specified address
    function generateKey(address _address) public pure returns(uint) {
        return uint(keccak256(abi.encodePacked(_address)));
    }

    // Verifies if an account has already invested during the current cycle
    function alreadyInvested(address _address) public view returns(bool) {
        uint key = generateKey(_address);
        for (uint i = 0; i < mappedKeys.length; i++) {
            if (mappedKeys[i] == key) {
                return true;
            }
        }
        return false;
    }

    // Allows a user to invest in the offer
    function invest(string calldata _name) external payable
    investmentPossible() isNotTooMuch(msg.sender, msg.value) validInvestment(msg.value, msg.sender) {
        uint key = generateKey(msg.sender);
        mappedKeys.push(key);
        investments[key] = Investment(_name, msg.sender, msg.value);

        emit NewFunds(msg.sender, msg.value);

        if (getCurrentFunds() == target_amount) {
            emit TargetReached();
        }
    }

    // Allows investor to withdraw from the offer
    function withdrawInvestment() external investmentPossible() returns(bool) {
        require(alreadyInvested(msg.sender));
        uint key = generateKey(msg.sender);
        for (uint i = 0; i < mappedKeys.length; i++) {

            if (mappedKeys[i] == key) {
                require(msg.sender.send(investments[key].amount)); // Verification needed regarding gas limit for transfer
                emit Withdrawal(msg.sender, investments[key].amount);
                delete(investments[key]);
                return true;
            }

        }
        return false;
    }

    // Allows the owner to pass to second cycle
    function toSecondCycle() public investmentPossible() onlyOwner() {
        require(getCurrentFunds() == target_amount);
        require(msg.sender.send(target_amount));
        cycle=2;
        emit ToSecondCycle();
    }

    // Indicates the amount the owner has to collect to pay interests once to all the investors
    function interestAmount() public view onlyOwner() secondCycle() returns(uint) {
        return getCurrentFunds()*percentage;
    }

    // Allows the owner to pay interests once to all the investors
    function payInterests() external payable onlyOwner() secondCycle() {
        require(msg.value == interestAmount());

        for (uint i = 0; i < mappedKeys.length; i++) {
            Investment memory inv = investments[mappedKeys[i]];
            require(inv.investorAddress.send(inv.amount.mul(percentage)));
        }
    }

    // Utility function to refund all investors
    function refundInvestors() private {
        emit OfferCancelled();

        for (uint i = 0; i < mappedKeys.length; i++) {
            Investment memory inv = investments[mappedKeys[i]];
            require(inv.investorAddress.send(inv.amount));
            // emit Withdrawal(inv.investorAddress, inv.amount); // tradeoff between information and gas consumption
            delete inv;
            mappedKeys[i] = 0;
        }

        emit GlobalRefundDone();
    }

    // Allows the offer to be canceled during the first cycle.
    function cancelOffer() public onlyOwner() investmentPossible() {
        refundInvestors();
        cycle = 3;
    }

    // Allows the offer to be canceled during the second cycle.
    function cancelOfferSecondCycle() public payable onlyOwner() secondCycle() {
        require(msg.value == getCurrentFunds());
        refundInvestors();
        cycle = 3;
    }

}

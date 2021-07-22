pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "./interfaces/IDecentraDollar.sol";
import "./interfaces/IDecentraStock.sol";
import "./interfaces/IDScore.sol";

////////////////////////////////////////////////////////////////////////////////////////////
/// @title DecentraCore
/// @author Christopher Dixon
////////////////////////////////////////////////////////////////////////////////////////////

contract DecentraCore is Ownable {
    using SafeMath for uint256;
    /// @notice proposalID is used to track proposals
    uint256 public proposalID;
    /// @notice proposalTime is the time in seconds a proposal is considered active
    uint256 public proposalTime;
    /// @notice quorum is the minimum percentage of voteWeight needed for a vote to pass
    uint256 public quorum;
    /// @notice dd is the DecentraDollar contract
    DecentraDollar public dd;
    /// @notice ds is the DecentraStock contract
    DecentraStock public ds;
    /// @notice dScore is the D-Score contract
    IDScore public DScore;

    /// @notice frozenAccounts is a mapping of which accounts are frozen
    mapping(address => bool) public frozenAccounts;

    /// @notice freezeFrame is a mapping of an accounts frozen time
    mapping(address => bool) public freezeFrame;

    /// @notice Proposal stores proposals
    mapping(uint256 => Proposal) public proposals;

    /**
    @notice minters is a mapping of DecentraCorp contracts
                that gives them elevated minting privledges
    */
    mapping(address => bool) public minters;

    /**
    @notice burners is a mapping of DecentraCorp contracts
                that gives them elevated burning privledges
    */
    mapping(address => bool) public burners;

    /**
    @notice dScoreMod is a mapping of official DecentraCorp contracts
                that gives them elevated dScore modification privledges
    */
    mapping(address => bool) public dScoreMod;

    /**
    @notice Proposal struct stores proposal information
    @param maker is the address of the account that made the proposal
    @param target is the address that the call_data will be passed to as a function call
    @param timeCreated is a blockstamp of when a proposal was created
    @param voteWeights stores the current weight of all votes for a proposal
    @param amount is used to store an ETH amount to be passed along with a function call
    @param executed is a bool representing whether or not a proposal has been executed
    @param proposalHash is an IPFS hash for a file representing a proposal
    @param call_data is a bytes representing a function call on the target contract
    @param votes is an array of Vote structs representing a users vote
    @param voted is a mapping that represents whether or not an account has voted
    **/
    struct Proposal {
        address maker;
        address payable target;
        uint256 timeCreated;
        uint256 voteWeights;
        uint256 voteID;
        uint256 amount;
        bool executed;
        bool proposalPassed;
        string proposalHash;
        bytes call_data;
        mapping(uint256 => Vote) votes;
        mapping(address => bool) voted;
    }

    /**
    @notice Vote is a struct used to store the information of a specific vote
    @param inSupport is a bool representing whether a vote supports a proposal or not
    @param voter is the address of the account that voted
    @param voteWeight is the weight of the account who voted based off the # of rep tokens it holds
    **/
    struct Vote {
        bool inSupport;
        address voter;
        uint256 voteWeight;
    }

    /**
    @notice the modifier onlyMember requires that the function caller must be a member of the DAO to call a function
    @dev this requires the caller to have atleast 1e18 of a token(standard 1 for ERC20's)
    **/
    modifier onlyMint() {
        require(minters[msg.sender], "DecentraCore: Caller is not a minter");
        _;
    }
    /**
    @notice the modifier onlyMember requires that the function caller must be a member of the DAO to call a function
    @dev this requires the caller to have atleast 1e18 of a token(standard 1 for ERC20's)
    **/
    modifier onlyBurn() {
        require(burners[msg.sender], "DecentraCore: Caller is not a burner");
        _;
    }

    /**
    @notice the modifier onlyMember requires that the function caller must be a member of the DAO to call a function
    @dev this requires the caller to have atleast 1e18 of a token(standard 1 for ERC20's)
    **/
    modifier onlyMember() {
        require(
            dScore.checkStaked(msg.sender),
            "DecentraCore: Caller is not an active member"
        );
        _;
    }

    constructor(
        address _dDollar,
        address _dStock,
        address _dScore
    ) {
        dd = IDecentraDollar(_dDollar);
        ds = IDecentraStock(_dStock);
        dScore = IDScore(_dScore);
    }

    ///fallback function so this contract can receive ETH
    function() external payable {}

    /**
    @notice delegateFunctionCall allows the DecentraCore contract to make arbitrary calls to other contracts
    @param _target is the target address where the function will be called
    @param _amount is an eth amount to be passed from this contract to the target contract
    @param call_data is a bytes representation of the function the Decentracorp contract is calling and its input paramters
    **/
    function delegateFunctionCall(
        address payable _target,
        uint256 _amount,
        bytes memory call_data
    ) public onlyApprovedDelegator {
        (bool success, bytes memory data) = _target.call(call_data);
        require(success, "delegateFunctionCall Failed");
    }

    /**
    @notice transferxDAI is used to easily transfer xDAI from the DecentraCorp contract
    @param _to is the address tokens are being minted to
    @param _amount is the amount of tokens being minted
    @dev this function is intended to be used with the proposal system
    **/
    function transferxDAI(address payable _to, uint256 _amount)
        public
        onlyOwner
    {
        _to.transfer(_amount);
    }

    /**
    @notice newProposaln allows a user to create a proposal
    @param _target is the address this proposal is targeting
    @param _amount is a value amount associated with the call
    @param _proposalHash is an IPFS hash of a file representing a proposal
    @param _calldata is a bytes representation of a function call
    **/
    function newProposal(
        address payable _target,
        uint256 _amount,
        string memory _proposalHash,
        bytes memory _calldata
    ) public payable onlyMember returns (uint256) {
        proposalID++;
        Proposal storage p = proposals[proposalID];
        p.maker = msg.sender;
        p.target = _target;
        p.amount = _amount;
        p.voteWeights = 0;
        p.voteID = 0;
        p.amount = 0;
        p.timeCreated = now;
        p.proposalHash = _proposalHash;
        p.call_data = _calldata;
        return proposalID;
    }

    /**
    @notice setQuorum allows the owner of the DAO(normally set as the the DAO itself) to change
            the quorum used in voting
    @notice _quorum is the input quarum number being set
    **/
    function setQuorum(uint256 _quorum) public onlyOwner {
        quorum = _quorum;
    }

    /**
    @notice percent is an internal function used to calculate the ratio between a given numerator && denominator
    @param _numerator is the numerator of the equation
    @param _denominator is the denominator of the equation
    @param _precision is a precision point to ensure that decimals dont trail outside what the EVM can handle
    **/
    function _percent(
        uint256 _numerator,
        uint256 _denominator,
        uint256 _precision
    ) internal pure returns (uint256 quotient) {
        // caution, check safe-to-multiply here
        uint256 numerator = _numerator * 10**(_precision + 1);
        // with rounding of last digit
        uint256 _quotient = ((numerator / _denominator) + 5) / 10;
        return (_quotient);
    }

    /**
    @notice _checkThreshold is an internal function used by a vote counts to see if enough of the community has voted
    @param _numOfvotes is the total  voteWeight a proposal has received
    @param _numOfTokens is the total supply of the synaps
    @notice this function returns a bool
                -true if the threshold is met
                -false if the threshold is not met
    **/
    function _checkThreshold(uint256 _numOfvotes, uint256 _numOfTokens)
        internal
        view
        returns (bool)
    {
        uint256 percOfMemVoted = _percent(_numOfvotes, _numOfTokens, 2);
        if (_numOfvotes == _numOfTokens) {
            return true;
        }
        if (percOfMemVoted >= quorum) {
            return true;
        } else {
            return false;
        }
    }

    /**
    @notice the vote function allows a DecentraCorp member to vote on proposals
    @param _ProposalID is the number ID associated with the particular proposal the user wishes to vote on
    @param  supportsProposal is a bool value(true or false) representing whether or not a member supports a proposal
                    -true if they do support the proposal
                    -false if they do not support the proposal
    @dev this function will trigger the _checkThreshold function which determines if enough members have voted to
              fire the executeProposal function.
    **/
    function vote(uint256 _ProposalID, bool supportsProposal)
        public
        onlyMember
    {
        Proposal storage p = proposals[_ProposalID];
        require(
            p.voted[msg.sender] != true,
            "You Have already voted on this proposal"
        );
        uint256 vw = synaps.balanceOf(msg.sender);

        p.voteID = p.voteID++;
        p.votes[p.voteID] = Vote({
            inSupport: supportsProposal,
            voter: msg.sender,
            voteWeight: vw
        });
        p.voteWeights = p.voteWeights.add(vw);
        p.voted[msg.sender] = true;
        uint256 ts = synaps.totalSupply();
        //checks if enough members have voted
        bool met = _checkThreshold(p.voteWeights, ts);
        if (met) {
            executeProposal(_ProposalID);
        }
    }

    /**
    @notice executeProposal is the function that executes the terms of a proposal
    @dev this function is called by the vote function when the number of votes reaches the quorum
    @param _proposalID is the ID number of the proposal being executed.
    **/
    function executeProposal(uint256 _proposalID) internal {
        Proposal storage p = proposals[_proposalID];

        if (now.sub(p.timeCreated) >= proposalTime) {
            // mark the proposal as executed and failed
            p.executed = true;
            p.proposalPassed = false;
        } else {
            // sets p equal to the specific proposalNumber

            require(!p.executed, "This proposal has already been executed");

            uint256 yea = 0;
            uint256 nay = 0;

            //this for loop cycles through each members vote and adds its value to the yea or nay tally
            for (uint256 i = 0; i <= p.voteID; ++i) {
                Vote storage v = p.votes[i];

                if (v.inSupport) {
                    yea = yea.add(v.voteWeight);
                } else {
                    nay = nay.add(v.voteWeight);
                }
            }

            //check if the yea votes outway the nay votes
            if (yea > nay) {
                delegateFunctionCall(p.target, p.amount, p.call_data);

                ///mark the proposal as executed and passed
                p.executed = true;
                p.proposalPassed = true;
            } else {
                // mark the proposal as executed and failed
                p.executed = true;
                p.proposalPassed = false;
            }
        }
    }

    /**
    @notice setApprovedContract is a protected function that allows a successful proposal to grant
            privledges to DecentraCorp contracts
    @param _contract is the address of the contract being approved
    @param _privledge is a number representing which privledge is being set
    @dev privledges:
                    1. Minting
                    2. Burning
                    3. D-Score
    */
    function setApprovedContract(address _contract, uint256 _privledge)
        external
        onlyOwner
    {
        require(
            _privledge > 0 && _privledge < 4,
            "DecentraCore: Invalid Input Privledge"
        );
        if (_privledge == 1) {
            minters[_contract] = true;
        }
        if (_privledge == 2) {
            burners[_contract] = true;
        }
        if (_privledge == 3) {
            dScoreMod[_contract] = true;
        }
    }

    /**
    @notice freezeMember is a protected function used to allow for a DecentraCorp contract to freeze an account
            in the case of suspected fraud
    @param _member is the address of the member who is being frozen
    @dev this function is intended to be called by the audit contracts of phase two and will not play an active role in phase one
    @dev this function can also be used to un-freeze an account
    */
    function freezeMember(address _member) external onlyOnwer {
        if (frozenAccounts[_member]) {
            frozenAccounts[_member] = false;
        } else {
            frozenAccounts[_member] = true;
            freezeFrame[_member] = now;
        }
    }

    /**
    @notice proxyMintDD is a protected function that allows an approved contract to mint DecentraDollar
    @param _to is the address the DecentraDollar is being minted to
    @param _amount is the amount being minted
    */
    function proxyMintDD(address _to, uint256 _amount) public onlyMint {
        dd.mintDD(_to, _amount);
    }

    /**
    @notice proxyMintDS is a protected function that allows an approved contract to issue DecentraStock
    @param _to is the address the DecentraStock is being issued to
    @param _amount is the amount being issued
    */
    function proxyMintDS(address _to, uint256 _amount) public onlyMint {
        ds.issueStock(_to, _amount);
    }

    /**
    @notice proxyBurnDD is a protected function that allows an approved contract to burn DecentraDollar
    @param _from is the address the DecentraDollar is being burned from
    @param _amount is the amount being burned
    */
    function proxyBurnDD(address _from, uint256 _amount) public onlyBurn {
        dd.burnDD(_from, _amount);
    }

    /**
    @notice proxyBurnDS is a protected function that allows an approved contract to burn DecentraStock
    @param _from is the address the DecentraStock is being burned from
    @param _amount is the amount being burned
    */
    function proxyBurnDS(address _from, uint256 _amount) public onlyBurn {
        ds.burnStock(_from, _amount);
    }
}

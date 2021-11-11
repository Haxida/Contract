// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.10;

import "./IBEP20.sol";
import "./SafeMath.sol";
import "./Math.sol";
import "./Ownable.sol";
import "./IUniswapV2Router01.sol";
import "./IUniswapV2Router02.sol";
import "./IUniswapV2Factory.sol";
import "./IUniswapV2Pair.sol";


contract Haxida is Ownable, IBEP20 {
	using SafeMath for uint256;
	using Math for uint256;

	struct PastTx {
		uint256 cumTransfer;
		uint256 cumTax;
		uint256 lastTimestamp;
	}

	mapping(address => uint256) private _balances;
	mapping(address => PastTx) public lastTx;
	mapping(address => mapping(address => uint256)) private _allowances;
	mapping(address => bool) private excluded;

	string private constant _NAME = "Haxida";
	string private constant _SYMBOL = "HAX";
	uint8 private constant _DECIMALS = 8;
	uint256 private constant _TOTAL_SUPPLY = 10**14 * 10**_DECIMALS;
	uint256 public swapForLiquidityThreshold = 10**10 * 10**_DECIMALS;

	uint32 public constant RESET_RATE = 1 days;
	uint8 public constant JOBS_FEE = 1; // 0.1%
	uint8 public constant FIXED_FEE = 50; // 5%
	uint8 public constant MAX_DAILY_SELL = 1; // 0.1%

	bool public circuitBreaker;
	bool public isFunctionRenounced = false;
	bool private _liqSwapReentrancyGuard;

	address public constant JOBS_WALLET = address(0x4E93Dbe9349d8eD0085A44A1c81079672261c242); // Pay wages for future work to be done.
	address public constant RESOURCES_WALLET = address(0x7e4d31D3D92941a0C9A36850Cf4db347450a0b39); // Marketing, Publi, Exchange rates, etc.
	address public constant ROUTER = address(0x10ED43C718714eb63d5aA57B78B54704E256024E); //Main NET PancakeSwap V2 Router

	//address public constant ROUTER = address(0xD99D1c33F9fC3444f8101754aBC46c52416550D1); //Test NET PancakeSwap V2 Router
	//address public constant ROUTER = address(0x9Ac64Cc6e4415144C455BD8E4837Fea55603e5c3); //Test NET https://bsc.kiemtienonline360.com/

	IUniswapV2Pair public pair;
	IUniswapV2Router02 public router;

	event AddToLiquidity(string);

	modifier isNotRenounced() {
		require(isFunctionRenounced == false, "The function has been renounced");
		_;
	}

	constructor() {
		excluded[_msgSender()] = true;
		excluded[address(this)] = true;
		excluded[JOBS_WALLET] = true;
		excluded[RESOURCES_WALLET] = true;

		circuitBreaker = true; //ERC20 behavior by default/presale

		_balances[_msgSender()] = _TOTAL_SUPPLY;

		//create pair to get the pair address
		router = IUniswapV2Router02(ROUTER);
		IUniswapV2Factory factory = IUniswapV2Factory(router.factory());
		pair = IUniswapV2Pair(factory.createPair(address(this), router.WETH()));

		emit Transfer(address(0), _msgSender(), _TOTAL_SUPPLY);
	}

	function decimals() external pure override returns (uint8) {
		return _DECIMALS;
	}

	function name() external pure override returns (string memory) {
		return _NAME;
	}

	function symbol() external pure override returns (string memory) {
		return _SYMBOL;
	}

	function totalSupply() public pure override returns (uint256) {
		return _TOTAL_SUPPLY;
	}

	function balanceOf(address account) external view override returns (uint256) {
		return _balances[account];
	}

	function getOwner() external view override returns (address) {
		return owner();
	}

	function transfer(address recipient, uint256 amount) external override returns (bool) {
		_transfer(_msgSender(), recipient, amount);
		return true;
	}

	function allowance(address _owner, address spender) public view override returns (uint256) {
		return _allowances[_owner][spender];
	}

	function approve(address spender, uint256 amount) external override returns (bool) {
		_approve(_msgSender(), spender, amount);
		return true;
	}

	function transferFrom(
		address sender,
		address recipient,
		uint256 amount
	) external override returns (bool) {
		_transfer(sender, recipient, amount);

		uint256 currentAllowance = _allowances[sender][_msgSender()];
		require(currentAllowance >= amount, "HAXIDA: transfer amount exceeds allowance");
		_approve(sender, _msgSender(), currentAllowance - amount);

		return true;
	}

	function increaseAllowance(address spender, uint256 addedValue) external returns (bool) {
		_approve(_msgSender(), spender, _allowances[_msgSender()][spender] + addedValue);
		return true;
	}

	function decreaseAllowance(address spender, uint256 subtractedValue) external returns (bool) {
		uint256 currentAllowance = _allowances[_msgSender()][spender];
		require(currentAllowance >= subtractedValue, "HAXIDA: decreased allowance below zero");
		_approve(_msgSender(), spender, currentAllowance - subtractedValue);

		return true;
	}

	function _approve(address _owner, address spender, uint256 amount) private {
		require(_owner != address(0), "HAXIDA: approve from the zero address");
		require(spender != address(0), "HAXIDA: approve to the zero address");

		_allowances[_owner][spender] = amount;
		emit Approval(_owner, spender, amount);
	}

	function _transfer(address sender, address recipient, uint256 amount) private {
		require(sender != address(0), "HAXIDA: transfer from the zero address");

		uint256 senderBalance = _balances[sender];
		require(senderBalance >= amount, "HAXIDA: transfer amount exceeds balance");

		// >1 day since last tx
		if (block.timestamp > lastTx[sender].lastTimestamp + RESET_RATE) {
			lastTx[sender].cumTransfer = 0;
			lastTx[sender].cumTax = 0;
		}

		uint256 sellTax = 0;
		uint256 jobsTax = 0;
		uint256 balancerTax = 0;

		if (!excluded[sender] && !excluded[recipient] && !circuitBreaker) {
			if (recipient == address(pair)) {
				sellTax = sellingTax(sender, amount);
			}

			jobsTax = amount.mul(JOBS_FEE).ceilDiv(10**3);

			balancerTax = amount.mul(FIXED_FEE).ceilDiv(10**3).add(sellTax);

			balancer(balancerTax);
		}

		lastTx[sender].lastTimestamp = block.timestamp;

		_balances[sender] = senderBalance.sub(amount);
		_balances[JOBS_WALLET] += jobsTax;
		_balances[recipient] += amount.sub(jobsTax).sub(balancerTax);

		emit Transfer(sender, recipient, amount.sub(jobsTax).sub(balancerTax));
		emit Transfer(sender, JOBS_WALLET, jobsTax);
	}

	// @dev take a selling tax based on amount of token dumped
	function sellingTax(address sender, uint256 amount) private returns (uint256) {
		uint256 newCumSum = amount.add(lastTx[sender].cumTransfer);

		if (newCumSum > totalSupply().mul(MAX_DAILY_SELL).div(10**3)) {
			revert("HAXIDA: selling amount is above max allowed");
		}

		uint256 taxAmount = newCumSum.mul(newCumSum).mul(100).ceilDiv(totalSupply());
		uint256 sellTax = taxAmount - lastTx[sender].cumTax;

		lastTx[sender].cumTransfer = newCumSum;
		lastTx[sender].cumTax += sellTax;

		return sellTax;
	}

	// @dev take the fixed tax as input, split it between resources and liq pool
	// according to pool condition
	function balancer(uint256 amount) private {
		//divide in 50/50 tokens
		uint256 half = amount.div(2);
		uint256 half_2 = amount.sub(half);

		//send half tokens to resources
		_balances[RESOURCES_WALLET] += half;
		emit Transfer(_msgSender(), RESOURCES_WALLET, half);

		//send half tokens to contract wallet
		_balances[address(this)] += half_2;
		emit Transfer(_msgSender(), address(this), half_2);

		//swap if limit is reached
		uint256 _liquidityPool = _balances[address(this)];
		if (_liquidityPool >= swapForLiquidityThreshold && !_liqSwapReentrancyGuard) {
			_liqSwapReentrancyGuard = true;
			addLiquidity(_liquidityPool);
			_liqSwapReentrancyGuard = false;
		}
	}

	//@dev when triggered, will swap and provide liquidity
	function addLiquidity(uint256 tokenAmount) private returns (uint256) {
		uint256 BNBBeforeSwap = address(this).balance;

		if (allowance(address(this), address(router)) < tokenAmount) {
			_allowances[address(this)][address(router)] = type(uint256).max;
			emit Approval(address(this), address(router), type(uint256).max);
		}

		//odd numbers management
		uint256 half = tokenAmount.div(2);
		uint256 half_2 = tokenAmount.sub(half);

		address[] memory route = new address[](2);
		route[0] = address(this);
		route[1] = router.WETH();

		router.swapExactTokensForETHSupportingFeeOnTransferTokens(half, 0, route, address(this), block.timestamp);

		uint256 BNBfromSwap = address(this).balance.sub(BNBBeforeSwap);
		router.addLiquidityETH{ value: BNBfromSwap }(address(this), half_2, 0, 0, RESOURCES_WALLET, block.timestamp);
		emit AddToLiquidity("Liquidity increased");
		return tokenAmount;
	}

	function excludeFromTaxes(address adr) external onlyOwner {
		require(!excluded[adr], "already excluded");
		excluded[adr] = true;
	}

	function includeInTaxes(address adr) external onlyOwner {
		require(excluded[adr], "already taxed");
		excluded[adr] = false;
	}

	function isExcluded(address adr) external view returns (bool) {
		return excluded[adr];
	}

	//@dev frontend integration
	function endOfPenaltyPeriod() external view returns (uint256) {
		return lastTx[_msgSender()].lastTimestamp + RESET_RATE;
	}

	//@dev will bypass all the taxes and act as erc20.
	//pools & balancer balances will remain untouched
	function setCircuitBreaker(bool status) external onlyOwner {
		circuitBreaker = status;
	}

	function changeLiquidityThreshold(uint256 newThreshold) external onlyOwner {
		swapForLiquidityThreshold = newThreshold;
	}

	function retrieveStuckBNB() external onlyOwner isNotRenounced {
		address payable contractOwner = payable(_msgSender());
		uint256 stuckBNB = address(this).balance;
		contractOwner.transfer(stuckBNB);
	}

	function renounceStuckBNBFunction() external onlyOwner {
		isFunctionRenounced = true;
	}

	//@dev fallback in order to receive BNB
	receive() external payable {}
}
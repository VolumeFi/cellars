//SPDX-License-Identifier: Unlicense
pragma solidity ^0.7.6;
pragma abicoder v2;

import {
    IERC20
} from "OpenZeppelin/openzeppelin-contracts@3.4.1-solc-0.7-2/contracts/token/ERC20/IERC20.sol";

import {
    SafeERC20
} from "OpenZeppelin/openzeppelin-contracts@3.4.1-solc-0.7-2/contracts/token/ERC20/SafeERC20.sol";

import {
    SafeMath
} from "OpenZeppelin/openzeppelin-contracts@3.4.1-solc-0.7-2/contracts/math/SafeMath.sol";

import {
    INonfungiblePositionManager
} from "Uniswap/uniswap-v3-periphery@1.0.0/contracts/interfaces/INonfungiblePositionManager.sol";

import {
    IUniswapV3Factory
} from "Uniswap/uniswap-v3-core@1.0.0/contracts/interfaces/IUniswapV3Factory.sol";

import {
    IUniswapV3Pool
} from "Uniswap/uniswap-v3-core@1.0.0/contracts/interfaces/IUniswapV3Pool.sol";

import {
    FixedPoint96
} from "Uniswap/uniswap-v3-core@1.0.0/contracts/libraries/FixedPoint96.sol";

import {
    FullMath
} from "Uniswap/uniswap-v3-core@1.0.0/contracts/libraries/FullMath.sol";

import {
    TickMath
} from "Uniswap/uniswap-v3-core@1.0.0/contracts/libraries/TickMath.sol";

interface ICellarPoolShare is IERC20 {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    struct MintResult {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0;
        uint256 amount1;
    }

    struct CellarAddParams {
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    struct CellarRemoveParams {
        uint256 tokenAmount;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    struct CellarTickInfo {
        uint184 tokenId;
        int24 tickUpper;
        int24 tickLower;
        uint24 weight;
    }

    struct PoolInfo {
        address token0;
        address token1;
        uint24 feeLevel;
    }

    event AddedLiquidity(
        address indexed token0,
        address indexed token1,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );

    event RemovedLiquidity(
        address indexed token0,
        address indexed token1,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );

    function addLiquidityForUniV3(CellarAddParams calldata cellarParams)
        external;

    function addLiquidityEthForUniV3(CellarAddParams calldata cellarParams)
        external
        payable;

    function removeLiquidityFromUniV3(CellarRemoveParams calldata cellarParams)
        external;

    function removeLiquidityEthFromUniV3(
        CellarRemoveParams calldata cellarParams
    ) external;

    function reinvest() external;

    function setValidator(address _validator, bool value) external;

    function owner() external view returns (address);
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint) external;
}

contract CellarPoolShare is ICellarPoolShare {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public constant NONFUNGIBLEPOSITIONMANAGER =
        0xC36442b4a4522E871399CD717aBDD847Ab11FE88;

    address public constant UNISWAPV3FACTORY =
        0x1F98431c8aD98523631AE4a59f267346ea31F984;

    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    mapping(address => uint256) private _balances;

    mapping(address => mapping(address => uint256)) private _allowances;

    mapping(address => bool) public validator;
    uint256 private _totalSupply;
    address private _owner;
    string private _name;
    string private _symbol;

    address public token0;
    address public token1;

    uint24 public feeLevel;
    CellarTickInfo[] public cellarTickInfo;
    bool isEntered;

    constructor(
        string memory name_,
        string memory symbol_,
        address _token0,
        address _token1,
        uint24 _feeLevel,
        CellarTickInfo[] memory _cellarTickInfo
    ) {
        _name = name_;
        _symbol = symbol_;
        require(_token0 < _token1, "Tokens are not sorted");
        token0 = _token0;
        token1 = _token1;
        feeLevel = _feeLevel;
        for (uint256 i = 0; i < _cellarTickInfo.length; i++) {
            require(_cellarTickInfo[i].weight > 0, "Weight cannot be zero");
            require(_cellarTickInfo[i].tokenId == 0, "tokenId is not empty");
            cellarTickInfo.push(_cellarTickInfo[i]);
        }
        _owner = msg.sender;
    }

    modifier onlyValidator() {
        require(validator[msg.sender], "Not validator");
        _;
    }

    modifier nonReentrant() {
        require(!isEntered, "reentrant call");
        isEntered = true;
        _;
        isEntered = false;
    }

    function transfer(address recipient, uint256 amount)
        external
        override
        returns (bool)
    {
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    function approve(address spender, uint256 amount)
        external
        override
        returns (bool)
    {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) external override returns (bool) {
        _transfer(sender, recipient, amount);
        uint256 currentAllowance = _allowances[sender][msg.sender];
        require(currentAllowance >= amount, "transfer exceeds allowance");
        _approve(sender, msg.sender, currentAllowance - amount);
        return true;
    }

    function addLiquidityForUniV3(CellarAddParams calldata cellarParams)
        external
        override
    {
        address _token0 = token0;
        address _token1 = token1;
        IERC20(_token0).safeTransferFrom(
            msg.sender,
            address(this),
            cellarParams.amount0Desired
        );

        IERC20(_token1).safeTransferFrom(
            msg.sender,
            address(this),
            cellarParams.amount1Desired
        );

        (uint256 inAmount0, uint256 inAmount1, uint128 liquidity) =
            _addLiquidity(cellarParams);

        require(inAmount0 >= cellarParams.amount0Min, "Less than Amount0Min");
        require(inAmount1 >= cellarParams.amount1Min, "Less than Amount1Min");

        IERC20(_token0).safeTransfer(
            msg.sender,
            cellarParams.amount0Desired - inAmount0
        );
        IERC20(_token1).safeTransfer(
            msg.sender,
            cellarParams.amount1Desired - inAmount1
        );
        emit AddedLiquidity(_token0, _token1, liquidity, inAmount0, inAmount1);
    }

    function addLiquidityEthForUniV3(CellarAddParams calldata cellarParams)
        external
        payable
        override
        nonReentrant
    {
        address _token0 = token0;
        address _token1 = token1;
        if (_token0 == WETH) {
            if (msg.value > cellarParams.amount0Desired) {
                payable(msg.sender).transfer(
                    msg.value - cellarParams.amount0Desired
                );
            } else {
                require(
                    msg.value == cellarParams.amount0Desired,
                    "Eth not enough"
                );
            }
            IWETH(WETH).deposit{value: cellarParams.amount0Desired}();
            IERC20(_token1).safeTransferFrom(
                msg.sender,
                address(this),
                cellarParams.amount1Desired
            );
        } else {
            require(_token1 == WETH, "Not Eth Pair");
            if (msg.value > cellarParams.amount1Desired) {
                payable(msg.sender).transfer(
                    msg.value - cellarParams.amount1Desired
                );
            } else {
                require(
                    msg.value == cellarParams.amount1Desired,
                    "Eth not enough"
                );
            }
            IWETH(WETH).deposit{value: cellarParams.amount1Desired}();
            IERC20(_token0).safeTransferFrom(
                msg.sender,
                address(this),
                cellarParams.amount0Desired
            );
        }

        (uint256 inAmount0, uint256 inAmount1, uint128 liquidity) =
            _addLiquidity(cellarParams);

        require(inAmount0 >= cellarParams.amount0Min, "Less than Amount0Min");
        require(inAmount1 >= cellarParams.amount1Min, "Less than Amount1Min");

        uint256 retAmount0 = cellarParams.amount0Desired.sub(inAmount0);
        uint256 retAmount1 = cellarParams.amount1Desired.sub(inAmount1);
        
        if (retAmount0 > 0) {
            if (_token0 == WETH) {
                IWETH(WETH).withdraw(retAmount0);
                msg.sender.transfer(retAmount0);
            }
            else {
                IERC20(_token0).safeTransfer(
                    msg.sender,
                    retAmount0
                );
            }
        }
        if (retAmount1 > 0) {
            if (_token1 == WETH) {
                IWETH(WETH).withdraw(retAmount1);
                msg.sender.transfer(retAmount1);
            }
            else {
                IERC20(_token1).safeTransfer(
                    msg.sender,
                    retAmount1
                );
            }
        }
        emit AddedLiquidity(_token0, _token1, liquidity, inAmount0, inAmount1);
    }

    function removeLiquidityEthFromUniV3(CellarRemoveParams calldata cellarParams)
        external
        override
        nonReentrant
    {
        (uint256 outAmount0, uint256 outAmount1, uint128 liquiditySum) =
            _removeLiquidity(cellarParams);
        require(outAmount0 >= cellarParams.amount0Min, "Less than Amount0Min");
        require(outAmount1 >= cellarParams.amount1Min, "Less than Amount1Min");
        address _token0 = token0;
        address _token1 = token1;
        if (_token0 == WETH) {
            IWETH(WETH).withdraw(outAmount0);
            msg.sender.transfer(outAmount0);
            IERC20(_token1).safeTransfer(msg.sender, outAmount1);
        }
        else {
            require(_token1 == WETH, "Not Eth Pair");
            IWETH(WETH).withdraw(outAmount1);
            msg.sender.transfer(outAmount1);
            IERC20(_token0).safeTransfer(msg.sender, outAmount0);
        }
        emit RemovedLiquidity(
            _token0,
            _token1,
            liquiditySum,
            outAmount0,
            outAmount1
        );
    }

    function removeLiquidityFromUniV3(
        CellarRemoveParams calldata cellarParams
    ) external override {
        address _token0 = token0;
        address _token1 = token1;
        (uint256 outAmount0, uint256 outAmount1, uint128 liquiditySum) =
            _removeLiquidity(cellarParams);

        require(outAmount0 >= cellarParams.amount0Min, "Less than Amount0Min");
        require(outAmount1 >= cellarParams.amount1Min, "Less than Amount1Min");

        IERC20(_token0).safeTransfer(msg.sender, outAmount0);
        IERC20(_token1).safeTransfer(msg.sender, outAmount1);
        emit RemovedLiquidity(
            _token0,
            _token1,
            liquiditySum,
            outAmount0,
            outAmount1
        );
    }

    function reinvest() external override onlyValidator {
        CellarTickInfo[] memory _cellarTickInfo = cellarTickInfo;
        uint256 weightSum;
        for (uint256 index = 0; index < _cellarTickInfo.length; index++) {
            require(_cellarTickInfo[index].tokenId != 0, "NFLP doesnot exist");
            weightSum += _cellarTickInfo[index].weight;
            INonfungiblePositionManager(NONFUNGIBLEPOSITIONMANAGER).collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: _cellarTickInfo[index].tokenId,
                    recipient: address(this),
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            );
        }
        address _token0 = token0;
        address _token1 = token1;
        uint256 balance0 = IERC20(_token0).balanceOf(address(this));
        uint256 balance1 = IERC20(_token1).balanceOf(address(this));
        if (balance0 > 0 && balance1 > 0) {
            (uint256 inAmount0, uint256 inAmount1, uint128 liquidity) =
                _addLiquidity(
                    CellarAddParams({
                        amount0Desired: balance0,
                        amount1Desired: balance1,
                        amount0Min: 0,
                        amount1Min: 0,
                        recipient: address(this),
                        deadline: type(uint256).max
                    })
                );

            emit AddedLiquidity(
                _token0,
                _token1,
                liquidity,
                inAmount0,
                inAmount1
            );
        }
    }

    function setValidator(address _validator, bool value) external override {
        require(msg.sender == _owner, "Not owner");
        validator[_validator] = value;
    }

    function owner() external view override returns (address) {
        return _owner;
    }

    function name() public view returns (string memory) {
        return _name;
    }

    function symbol() public view returns (string memory) {
        return _symbol;
    }

    function decimals() public pure returns (uint8) {
        return 18;
    }

    function totalSupply() public view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return _balances[account];
    }

    function allowance(address owner_, address spender)
        public
        view
        override
        returns (uint256)
    {
        return _allowances[owner_][spender];
    }

    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal {
        require(sender != address(0), "transfer from zero address");
        require(recipient != address(0), "transfer to zero address");

        _beforeTokenTransfer(sender, recipient, amount);

        uint256 senderBalance = _balances[sender];
        require(senderBalance >= amount, "transfer exceeds balance");
        _balances[sender] = senderBalance - amount;
        _balances[recipient] += amount;

        emit Transfer(sender, recipient, amount);
    }

    function _mint(address account, uint256 amount) internal {
        require(account != address(0), "mint to zero address");

        _beforeTokenTransfer(address(0), account, amount);

        _totalSupply += amount;
        _balances[account] += amount;
        emit Transfer(address(0), account, amount);
    }

    function _burn(address account, uint256 amount) internal {
        require(account != address(0), "burn from zero address");

        _beforeTokenTransfer(account, address(0), amount);

        uint256 accountBalance = _balances[account];
        require(accountBalance >= amount, "burn exceeds balance");
        _balances[account] = accountBalance - amount;
        _totalSupply -= amount;

        emit Transfer(account, address(0), amount);
    }

    function _approve(
        address owner_,
        address spender,
        uint256 amount
    ) internal {
        require(owner_ != address(0), "approve from zero address");
        require(spender != address(0), "approve to zero address");

        _allowances[owner_][spender] = amount;
        emit Approval(owner_, spender, amount);
    }

    function _getWeightInfo(
        PoolInfo memory poolInfo,
        CellarTickInfo[] memory _cellarTickInfo
    )
        internal
        view
        returns (
            uint256 weightSum0,
            uint256 weightSum1,
            uint256 liquidityBefore,
            uint256[] memory weight0,
            uint256[] memory weight1
        )
    {
        weight0 = new uint256[](_cellarTickInfo.length);
        weight1 = new uint256[](_cellarTickInfo.length);
        (uint160 sqrtPriceX96, int24 currentTick, , , , , ) =
            IUniswapV3Pool(
                IUniswapV3Factory(UNISWAPV3FACTORY).getPool(
                    poolInfo.token0,
                    poolInfo.token1,
                    poolInfo.feeLevel
                )
            )
                .slot0();
        for (uint16 i = 0; i < _cellarTickInfo.length; i++) {
            if (_cellarTickInfo[i].tokenId > 0) {
                (, , , , , , , uint128 liquidity, , , , ) =
                    INonfungiblePositionManager(NONFUNGIBLEPOSITIONMANAGER)
                        .positions(_cellarTickInfo[i].tokenId);
                liquidityBefore += liquidity;
            }
            if (currentTick <= _cellarTickInfo[i].tickLower) {
                weight0[i] = _cellarTickInfo[i].weight * FixedPoint96.Q96;
                weightSum0 += weight0[i];
            } else if (currentTick >= _cellarTickInfo[i].tickUpper) {
                weight1[i] += _cellarTickInfo[i].weight * FixedPoint96.Q96;
                weightSum1 += weight1[i];
            } else {
                (weight0[i], weight1[i]) = _getWeights(
                    TickMath.getSqrtRatioAtTick(_cellarTickInfo[i].tickLower),
                    TickMath.getSqrtRatioAtTick(_cellarTickInfo[i].tickUpper),
                    sqrtPriceX96,
                    _cellarTickInfo[i].weight
                );
                weightSum0 += weight0[i];
                weightSum1 += weight1[i];
            }
        }
    }

    function _addLiquidity(CellarAddParams memory cellarParams)
        internal
        returns (
            uint256 inAmount0,
            uint256 inAmount1,
            uint128 liquiditySum
        )
    {
        CellarTickInfo[] memory _cellarTickInfo = cellarTickInfo;
        PoolInfo memory poolInfo =
            PoolInfo({token0: token0, token1: token1, feeLevel: feeLevel});
        IERC20(poolInfo.token0).safeApprove(
            NONFUNGIBLEPOSITIONMANAGER,
            cellarParams.amount0Desired
        );
        IERC20(poolInfo.token1).safeApprove(
            NONFUNGIBLEPOSITIONMANAGER,
            cellarParams.amount0Desired
        );
        uint256 weightSum0;
        uint256 weightSum1;
        uint256 liquidityBefore;
        uint256[] memory weight0 = new uint256[](_cellarTickInfo.length);
        uint256[] memory weight1 = new uint256[](_cellarTickInfo.length);

        (
            weightSum0,
            weightSum1,
            liquidityBefore,
            weight0,
            weight1
        ) = _getWeightInfo(poolInfo, _cellarTickInfo);

        for (uint16 i = 0; i < _cellarTickInfo.length; i++) {
            INonfungiblePositionManager.MintParams memory mintParams =
                INonfungiblePositionManager.MintParams({
                    token0: poolInfo.token0,
                    token1: poolInfo.token1,
                    fee: poolInfo.feeLevel,
                    tickLower: _cellarTickInfo[i].tickLower,
                    tickUpper: _cellarTickInfo[i].tickUpper,
                    amount0Desired: 0,
                    amount1Desired: 0,
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: address(this),
                    deadline: cellarParams.deadline
                });


                INonfungiblePositionManager.IncreaseLiquidityParams
                    memory increaseLiquidityParams
             =
                INonfungiblePositionManager.IncreaseLiquidityParams({
                    tokenId: _cellarTickInfo[i].tokenId,
                    amount0Desired: 0,
                    amount1Desired: 0,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: cellarParams.deadline
                });
            if (weightSum0 > 0) {
                mintParams.amount0Desired = FullMath.mulDiv(
                    cellarParams.amount0Desired,
                    weight0[i],
                    weightSum0
                );
                increaseLiquidityParams.amount0Desired = mintParams
                    .amount0Desired;
                mintParams.amount0Min = FullMath.mulDiv(
                    cellarParams.amount0Min,
                    weight0[i],
                    weightSum0
                );
                increaseLiquidityParams.amount0Min = mintParams.amount0Min;
            }
            if (weightSum1 > 0) {
                mintParams.amount1Desired = FullMath.mulDiv(
                    cellarParams.amount1Desired,
                    weight1[i],
                    weightSum1
                );
                increaseLiquidityParams.amount1Desired = mintParams
                    .amount1Desired;
                mintParams.amount1Min = FullMath.mulDiv(
                    cellarParams.amount1Min,
                    weight1[i],
                    weightSum1
                );
                increaseLiquidityParams.amount1Min = mintParams.amount1Min;
            }
            MintResult memory mintResult;
            if (_cellarTickInfo[i].tokenId == 0) {
                (
                    mintResult.tokenId,
                    mintResult.liquidity,
                    mintResult.amount0,
                    mintResult.amount1
                ) =
                    INonfungiblePositionManager(NONFUNGIBLEPOSITIONMANAGER)
                        .mint(mintParams);
                cellarTickInfo[i].tokenId = uint184(mintResult.tokenId);
                inAmount0 += mintResult.amount0;
                inAmount1 += mintResult.amount1;
                liquiditySum += mintResult.liquidity;
            } else {
                (mintResult.liquidity, mintResult.amount0, mintResult.amount1) =
                    INonfungiblePositionManager(NONFUNGIBLEPOSITIONMANAGER)
                        .increaseLiquidity(increaseLiquidityParams);
                inAmount0 += mintResult.amount0;
                inAmount1 += mintResult.amount1;
                liquiditySum += mintResult.liquidity;
            }
        }

        if (liquidityBefore == 0) {
            _mint(
                msg.sender,
                liquiditySum
            );
        }
        else {
            _mint(
                msg.sender,
                FullMath.mulDiv(liquiditySum, _totalSupply, liquidityBefore)
            );
        }
        IERC20(poolInfo.token0).safeApprove(NONFUNGIBLEPOSITIONMANAGER, 0);
        IERC20(poolInfo.token1).safeApprove(NONFUNGIBLEPOSITIONMANAGER, 0);
    }

    function _removeLiquidity(CellarRemoveParams memory cellarParams)
        internal
        returns (
            uint256 outAmount0,
            uint256 outAmount1,
            uint128 liquiditySum
        )
    {
        CellarTickInfo[] memory _cellarTickInfo = cellarTickInfo;
        for (uint16 i = 0; i < _cellarTickInfo.length; i++) {
            (, , , , , , , uint128 liquidity, , , , ) = INonfungiblePositionManager(
                NONFUNGIBLEPOSITIONMANAGER
            )
                .positions(_cellarTickInfo[i].tokenId);
            uint128 outLiquidity = uint128(FullMath.mulDiv(liquidity, cellarParams.tokenAmount, _totalSupply));
            INonfungiblePositionManager.DecreaseLiquidityParams
                memory decreaseLiquidityParams
             =
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: _cellarTickInfo[i].tokenId,
                    liquidity: outLiquidity,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: cellarParams.deadline
                });
            (uint256 amount0, uint256 amount1) =
                INonfungiblePositionManager(NONFUNGIBLEPOSITIONMANAGER)
                    .decreaseLiquidity(decreaseLiquidityParams);
            INonfungiblePositionManager(NONFUNGIBLEPOSITIONMANAGER).collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: _cellarTickInfo[i].tokenId,
                    recipient: address(this),
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            );
            outAmount0 += amount0;
            outAmount1 += amount1;
            liquiditySum += outLiquidity;
        }

        _burn(msg.sender, cellarParams.tokenAmount);
    }

    function _getWeights(
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint160 sqrtPriceX96,
        uint24 weight
    ) internal pure returns (uint256 weight0, uint256 weight1) {
        weight0 =
            FullMath.mulDiv(
                FullMath.mulDiv(
                    FullMath.mulDiv(
                        sqrtPriceAX96,
                        (sqrtPriceBX96 - sqrtPriceX96),
                        FixedPoint96.Q96
                    ),
                    FixedPoint96.Q96,
                    sqrtPriceX96
                ),
                FixedPoint96.Q96,
                (sqrtPriceBX96 - sqrtPriceAX96)
            ) *
            weight;
        weight1 =
            FullMath.mulDiv(
                (sqrtPriceX96 - sqrtPriceAX96),
                FixedPoint96.Q96,
                (sqrtPriceBX96 - sqrtPriceAX96)
            ) *
            weight;
    }

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual {}

    receive() external payable {
    }
}
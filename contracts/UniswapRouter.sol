pragma solidity >=0.6.6;

import './interfaces/IUniswapFactory.sol';
import './libraries/TransferHelper.sol';
import './libraries/UniswapLibrary.sol';
import './interfaces/IUniswapRouter.sol';
import './interfaces/IERC20.sol';
import './interfaces/IWETH.sol';

contract UniswapRouter is IUniswapRouter {
    using SafeMath for uint;

    address public immutable override factory;
    address public immutable override WETH;

    //交易期限
    //因为有些交易可能迟迟不能完成，所以需要给定一个期限
    modifier ensure(uint deadline) {
        require(deadline >= block.timestamp, 'UniswapRouter: EXPIRED');
        _;
    }
    //初始化操作
    constructor(address _factory, address _WETH) public {
        factory = _factory;
        WETH = _WETH;
    }
    //接收代币
    receive() external payable {
        assert(msg.sender == WETH);
    }

    //添加流动性（内部函数）
    function _addLiquidity(
        //两个代币的地址
        address tokenA,
        address tokenB,
        //期望的数额
        uint amountADesired,
        uint amountBDesired,
        //最小期望数额
        uint amountAMin,
        uint amountBMin
    ) private returns (
        //返回成功添加的数额
        uint amountA, uint amountB ) {

        // 检验这两个代币是否有对应的pair合约，没有则创建
        if (IUniswapFactory(factory).getPair(tokenA, tokenB) == address(0)) {
            IUniswapFactory(factory).createPair(tokenA, tokenB);
        }
        //获取存储量
        (uint reserveA, uint reserveB) = UniswapLibrary.getReserves(factory, tokenA, tokenB);
        //存储量为0，即池子为空，则返回期望值
        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            //对价计算
            //最优数量B = 期望A * 存储量B / 存储量A
            uint amountBOptimal = UniswapLibrary.quote(amountADesired, reserveA, reserveB);
            //如果 最小期望B <= 最优数量B <= 期望B，则返回最优数量B
            if (amountBOptimal <= amountBDesired) {
                require(amountBOptimal >= amountBMin, 'UniswapRouter: INSUFFICIENT_B_AMOUNT');
                (amountA, amountB) = (amountADesired, amountBOptimal);
            //反之 最小期望A <= 最优数量A <= 期望A，则返回最优数量A
            } else {
                uint amountAOptimal = UniswapLibrary.quote(amountBDesired, reserveB, reserveA);
                assert(amountAOptimal <= amountADesired);
                require(amountAOptimal >= amountAMin, 'UniswapRouter: INSUFFICIENT_A_AMOUNT');
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }
    //添加流动性（外部函数）
    function addLiquidity(
        //两个代币的地址
        address tokenA,
        address tokenB,
        //期望的数额
        uint amountADesired,
        uint amountBDesired,
        //最小期望数额
        uint amountAMin,
        uint amountBMin,
        //铸造流动性代币给to地址
        address to,
        //期限
        uint deadline
    ) external override ensure(deadline) returns (uint amountA, uint amountB, uint liquidity) {
        //获取代币交换AB的数值
        (amountA, amountB) = _addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin);
        //获取其pair合约地址
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
        //把用户的两个token发给pair合约
        TransferHelper.safeTransferFrom(tokenA, msg.sender, pair, amountA);
        TransferHelper.safeTransferFrom(tokenB, msg.sender, pair, amountB);
        //铸造流动性代币给用户
        liquidity = IUniswapV2Pair(pair).mint(to);
    }

    //添加ETH相关的流动性
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external override payable ensure(deadline) returns (uint amountToken, uint amountETH, uint liquidity) {
        //获取代币交换的数值
        (amountToken, amountETH) = _addLiquidity(
            token,
            WETH,
            amountTokenDesired,
            msg.value,
            amountTokenMin,
            amountETHMin
        );
        //获取其pair合约地址
        address pair = UniswapV2Library.pairFor(factory, token, WETH);
        //把用户的token发给pair合约，ETH发给WETH
        TransferHelper.safeTransferFrom(token, msg.sender, pair, amountToken);
        IWETH(WETH).deposit{value: amountETH}();
        assert(IWETH(WETH).transfer(pair, amountETH));
        //铸造流动性代币给用户
        liquidity = IUniswapV2Pair(pair).mint(to);
        //多余的ETH退还
        if (msg.value > amountETH) TransferHelper.safeTransferETH(msg.sender, msg.value - amountETH); // refund dust eth, if any
    }

    //移除流动性
    function removeLiquidity(
        address tokenA,
        address tokenB,
        //要销毁的流动性数量
        uint liquidity,
        //希望取出的最小token数
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) public override ensure(deadline) returns (uint amountA, uint amountB) {
        //计算TokenA，TokenB的Create2地址
        address pair = UniswapLibrary.pairFor(factory, tokenA, tokenB);
        //将流动性代币从用户发送给pair合约，需要提前approval批准
        IUniswapPair(pair).transferFrom(msg.sender, pair, liquidity); 
        //销毁，取出token
        (uint amount0, uint amount1) = IUniswapV2Pair(pair).burn(to);
        //排序
        (address token0,) = UniswapV2Library.sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
        //是否大于等于期望
        require(amountA >= amountAMin, 'UniswapV2Router: INSUFFICIENT_A_AMOUNT');
        require(amountB >= amountBMin, 'UniswapV2Router: INSUFFICIENT_B_AMOUNT');
    }
    //移除ETH相关的流动性
    function removeLiquidityETH(
        address token,
        //要销毁的流动性数量
        uint liquidity,
        //希望取出的最小token数
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) public override ensure(deadline) returns (uint amountToken, uint amountETH) {
        //调用基础的移除流动性方法
        (amountToken, amountETH) = removeLiquidity(
            token,
            WETH,
            liquidity,
            amountTokenMin,
            amountETHMin,
            address(this),
            deadline
        );
        //转账token和ETH
        TransferHelper.safeTransfer(token, to, amountToken);
        //将WETH转换为ETH
        IWETH(WETH).withdraw(amountETH);
        TransferHelper.safeTransferETH(to, amountETH);
    }
    //移除流动性带签名，因为需要批准操作
    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        //流动性
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline,
        //签名
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external override returns (uint amountA, uint amountB) {
        //获取pair合约地址
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
        uint value = approveMax ? uint(-1) : liquidity;
        //批准msg.sender的value个流动性代币给当前合约
        IUniswapPair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        (amountA, amountB) = removeLiquidity(tokenA, tokenB, liquidity, amountAMin, amountBMin, to, deadline);
    }
    //移除ETH相关的流动性带签名
    function removeLiquidityETHWithPermit(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external override returns (uint amountToken, uint amountETH) {
        address pair = UniswapV2Library.pairFor(factory, token, WETH);
        uint value = approveMax ? uint(-1) : liquidity;
        //批准msg.sender的value个流动性代币给当前合约
        IUniswapV2Pair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        (amountToken, amountETH) = removeLiquidityETH(token, liquidity, amountTokenMin, amountETHMin, to, deadline);
    }

    //移除流动性，支持转账收费代币
    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) public virtual override ensure(deadline) returns (uint amountETH) {
        (, amountETH) = removeLiquidity(
            token,
            WETH,
            liquidity,
            amountTokenMin,
            amountETHMin,
            address(this),
            deadline
        );
        TransferHelper.safeTransfer(token, to, IERC20(token).balanceOf(address(this)));
        IWETH(WETH).withdraw(amountETH);
        TransferHelper.safeTransferETH(to, amountETH);
    }

    //交换方法（内部方法）
    //代币交换可能经过多个路径，所以参数是数组
    function _swap(
        uint[] memory amounts, //数额数组
        address[] memory path, //路径数组
        address _to ) private {
        //遍历路径数组
        for (uint i; i < path.length - 1; i++) {
            //取出当前路径对应的两个代币地址
            (address input, address output) = (path[i], path[i + 1]);
            //排序
            (address token0,) = UniswapV2Library.sortTokens(input, output);
            //获取输出金额
            uint amountOut = amounts[i + 1];
            //两个输入的金额需要有一个是0
            (uint amount0Out, uint amount1Out) =  input == token0 ? 
                    (uint(0), amountOut) : 
                    (amountOut, uint(0));
            //修改to地址为下一个路径的合约地址
            address to = i < path.length - 2 ? 
                UniswapLibrary.pairFor(factory, output, path[i + 2]) : 
                _to;
            IUniswapPair(UniswapLibrary.pairFor(factory, input, output)).swap(amount0Out, amount1Out, to, new bytes(0));
        }
    }
    //给一个token看最多能交换多少的另一个token
    function swapExactTokensForTokens(
        uint amountIn,//输入金额
        uint amountOutMin,//最小输出金额
        address[] calldata path,//地址路径
        address to,
        uint deadline
    ) external override ensure(deadline) returns (
        //路径上每一步计算出来的数值
        uint[] memory amounts) {
        //遍历路径数组计算出每一步的数额
        //（amountIn * 997 * 存储量out）/（存储量in * 1000 + amountIn * 997）
        amounts = UniswapLibrary.getAmountsOut(factory, amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, 'UniswapRouter: INSUFFICIENT_OUTPUT_AMOUNT');
        //将用户的钱转入第一个pair合约
        TransferHelper.safeTransferFrom(path[0], msg.sender, UniswapLibrary.pairFor(factory, path[0], path[1]), amounts[0]);
        //执行路径后的交换
        _swap(amounts, path, to);
    }
    //给一个token想要的数量看需要多少个另一个token数量
    function swapTokensForExactTokens(
        uint amountOut,//输出金额
        uint amountInMax,//最大输入金额
        address[] calldata path,
        address to,
        uint deadline
    ) external override ensure(deadline) returns (uint[] memory amounts) {
        //（（存储量in * 存储量out * 1000）/（存储量out - 输出数额 * 997））+ 1
        amounts = UniswapLibrary.getAmountsIn(factory, amountOut, path);
        require(amounts[0] <= amountInMax, 'UniswapRouter: EXCESSIVE_INPUT_AMOUNT');
        //将用户的钱转入第一个pair合约
        TransferHelper.safeTransferFrom(path[0], msg.sender, UniswapLibrary.pairFor(factory, path[0], path[1]), amounts[0]);
        _swap(amounts, path, to);
    }
    //给ETH的数量看能交换多少的另一个token
    function swapExactETHForTokens(uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        override
        payable
        ensure(deadline)
        returns (uint[] memory amounts)
    {
        require(path[0] == WETH, 'UniswapV2Router: INVALID_PATH');
        amounts = UniswapV2Library.getAmountsOut(factory, msg.value, path);
        require(amounts[amounts.length - 1] >= amountOutMin, 'UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT');
        IWETH(WETH).deposit{value: amounts[0]}();
        assert(IWETH(WETH).transfer(UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]));
        _swap(amounts, path, to);
    }
    //给想要ETH的数量看需要多少个另一个token数量
    function swapTokensForExactETH(uint amountOut, uint amountInMax, address[] calldata path, address to, uint deadline)
        external
        override
        ensure(deadline)
        returns (uint[] memory amounts)
    {
        require(path[path.length - 1] == WETH, 'UniswapV2Router: INVALID_PATH');
        amounts = UniswapV2Library.getAmountsIn(factory, amountOut, path);
        require(amounts[0] <= amountInMax, 'UniswapV2Router: EXCESSIVE_INPUT_AMOUNT');
        TransferHelper.safeTransferFrom(path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]);
        _swap(amounts, path, address(this));
        IWETH(WETH).withdraw(amounts[amounts.length - 1]);
        TransferHelper.safeTransferETH(to, amounts[amounts.length - 1]);
    }
    //给一个token看能交换多少的ETH
    function swapExactTokensForETH(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        override
        ensure(deadline)
        returns (uint[] memory amounts)
    {
        require(path[path.length - 1] == WETH, 'UniswapV2Router: INVALID_PATH');
        amounts = UniswapV2Library.getAmountsOut(factory, amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, 'UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT');
        TransferHelper.safeTransferFrom(path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]);
        _swap(amounts, path, address(this));
        IWETH(WETH).withdraw(amounts[amounts.length - 1]);
        TransferHelper.safeTransferETH(to, amounts[amounts.length - 1]);
    }
    //给一个token想要的数量看需要多少个ETH
    function swapETHForExactTokens(uint amountOut, address[] calldata path, address to, uint deadline)
        external
        override
        payable
        ensure(deadline)
        returns (uint[] memory amounts)
    {
        require(path[0] == WETH, 'UniswapV2Router: INVALID_PATH');
        amounts = UniswapV2Library.getAmountsIn(factory, amountOut, path);
        require(amounts[0] <= msg.value, 'UniswapV2Router: EXCESSIVE_INPUT_AMOUNT');
        IWETH(WETH).deposit{value: amounts[0]}();
        assert(IWETH(WETH).transfer(UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]));
        _swap(amounts, path, to);
        if (msg.value > amounts[0]) TransferHelper.safeTransferETH(msg.sender, msg.value - amounts[0]); // refund dust eth, if any
    }

    // **** SWAP (supporting fee-on-transfer tokens) ****
    // requires the initial amount to have already been sent to the first pair
    function _swapSupportingFeeOnTransferTokens(address[] memory path, address _to) internal virtual {
        for (uint i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0,) = UniswapV2Library.sortTokens(input, output);
            IUniswapV2Pair pair = IUniswapV2Pair(UniswapV2Library.pairFor(factory, input, output));
            uint amountInput;
            uint amountOutput;
            { // scope to avoid stack too deep errors
            (uint reserve0, uint reserve1,) = pair.getReserves();
            (uint reserveInput, uint reserveOutput) = input == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
            amountInput = IERC20(input).balanceOf(address(pair)).sub(reserveInput);
            amountOutput = UniswapV2Library.getAmountOut(amountInput, reserveInput, reserveOutput);
            }
            (uint amount0Out, uint amount1Out) = input == token0 ? (uint(0), amountOutput) : (amountOutput, uint(0));
            address to = i < path.length - 2 ? UniswapV2Library.pairFor(factory, output, path[i + 2]) : _to;
            pair.swap(amount0Out, amount1Out, to, new bytes(0));
        }
    }
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external virtual override ensure(deadline) {
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amountIn
        );
        uint balanceBefore = IERC20(path[path.length - 1]).balanceOf(to);
        _swapSupportingFeeOnTransferTokens(path, to);
        require(
            IERC20(path[path.length - 1]).balanceOf(to).sub(balanceBefore) >= amountOutMin,
            'UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT'
        );
    }
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    )
        external
        virtual
        override
        payable
        ensure(deadline)
    {
        require(path[0] == WETH, 'UniswapV2Router: INVALID_PATH');
        uint amountIn = msg.value;
        IWETH(WETH).deposit{value: amountIn}();
        assert(IWETH(WETH).transfer(UniswapV2Library.pairFor(factory, path[0], path[1]), amountIn));
        uint balanceBefore = IERC20(path[path.length - 1]).balanceOf(to);
        _swapSupportingFeeOnTransferTokens(path, to);
        require(
            IERC20(path[path.length - 1]).balanceOf(to).sub(balanceBefore) >= amountOutMin,
            'UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT'
        );
    }
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    )
        external
        virtual
        override
        ensure(deadline)
    {
        require(path[path.length - 1] == WETH, 'UniswapV2Router: INVALID_PATH');
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amountIn
        );
        _swapSupportingFeeOnTransferTokens(path, address(this));
        uint amountOut = IERC20(WETH).balanceOf(address(this));
        require(amountOut >= amountOutMin, 'UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT');
        IWETH(WETH).withdraw(amountOut);
        TransferHelper.safeTransferETH(to, amountOut);
    }

    /**    重写UniswapLibrary中的方法      **/

    function quote(uint amountA, uint reserveA, uint reserveB) public pure override returns (uint amountB) {
        return UniswapV2Library.quote(amountA, reserveA, reserveB);
    }

    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) public pure override returns (uint amountOut) {
        return UniswapV2Library.getAmountOut(amountIn, reserveIn, reserveOut);
    }

    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut) public pure override returns (uint amountIn) {
        return UniswapV2Library.getAmountOut(amountOut, reserveIn, reserveOut);
    }

    function getAmountsOut(uint amountIn, address[] memory path) public view override returns (uint[] memory amounts) {
        return UniswapV2Library.getAmountsOut(factory, amountIn, path);
    }

    function getAmountsIn(uint amountOut, address[] memory path) public view override returns (uint[] memory amounts) {
        return UniswapV2Library.getAmountsIn(factory, amountOut, path);
    }
}

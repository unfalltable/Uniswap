pragma solidity >=0.5.0;

import '../interfaces/IUniswapPair.sol';
import "./SafeMath.sol";

library UniswapLibrary {
    using SafeMath for uint;

    //给两个token排序
    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        require(tokenA != tokenB, 'UniswapV2Library: IDENTICAL_ADDRESSES');
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'UniswapV2Library: ZERO_ADDRESS');
    }

    //通过两个token地址去找pair地址
    function pairFor(address factory, address tokenA, address tokenB) internal pure returns (address pair) {
        //排序
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        //create2方法获取pair合约地址
        pair = address(uint(keccak256(abi.encodePacked(
                hex'ff',
                factory,
                keccak256(abi.encodePacked(token0, token1)),
                hex'96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f' // init code hash
            ))));
    }

    //获取存储量
    function getReserves(address factory, address tokenA, address tokenB) internal view returns (uint reserveA, uint reserveB) {
        //排序
        (address token0,) = sortTokens(tokenA, tokenB);
        //调用pair合约中的获取储备量的方法
        (uint reserve0, uint reserve1,) = IUniswapPair(pairFor(factory, tokenA, tokenB)).getReserves();
        (reserveA, reserveB) = tokenA == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    //对价计算
    //给一个token数额求另一个token数额
    //amountB * reserveA = amountA * reserveB
    function quote(uint amountA, uint reserveA, uint reserveB) internal pure returns (uint amountB) {
        require(amountA > 0, 'UniswapLibrary: INSUFFICIENT_AMOUNT');
        require(reserveA > 0 && reserveB > 0, 'UniswapLibrary: INSUFFICIENT_LIQUIDITY');
        amountB = amountA.mul(reserveB) / reserveA;
    }

    //获取单个输出数额
    //输入1个token数额，2个token的存储量，求另一个token的数额
    //扣除了千分之三的手续费
    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) internal pure returns (uint amountOut) {
        require(amountIn > 0, 'UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT');
        require(reserveIn > 0 && reserveOut > 0, 'UniswapV2Library: INSUFFICIENT_LIQUIDITY');
        //税后输入数额 = 输入数额 * 997
        uint amountInWithFee = amountIn.mul(997);
        //分子 = 税后输入数额 * 存储量out
        uint numerator = amountInWithFee.mul(reserveOut);
        //分母 = 存储量in * 1000 + 税后输入数额
        uint denominator = reserveIn.mul(1000).add(amountInWithFee);
        //输出数额 = 分子 / 分母
        amountOut = numerator / denominator;
    }

    //获取单个输入数额
    //输入2个token数额，1个token的存储量，求另一个token的存储量
    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut) internal pure returns (uint amountIn) {
        require(amountOut > 0, 'UniswapV2Library: INSUFFICIENT_OUTPUT_AMOUNT');
        require(reserveIn > 0 && reserveOut > 0, 'UniswapV2Library: INSUFFICIENT_LIQUIDITY');
        //分子 = 存储量in * 存储量out * 1000
        uint numerator = reserveIn.mul(amountOut).mul(1000);
        //分母 = 存储量out - 输出数额 * 997
        uint denominator = reserveOut.sub(amountOut).mul(997);
        //输入数额 = （分子 / 分母）+ 1
        amountIn = (numerator / denominator).add(1);
    }

    //根据输入获取输出，计算路径中每一步交换的数值
    function getAmountsOut(
        address factory, 
        uint amountIn, //输入的数额
        address[] memory path //交换路径数组，存的是代币地址
            ) internal view returns (uint[] memory amounts) {
        require(path.length >= 2, 'UniswapLibrary: INVALID_PATH');
        amounts = new uint[](path.length);
        amounts[0] = amountIn;
        //遍历交换路径数组
        for (uint i; i < path.length - 1; i++) {
            //获取存储量
            (uint reserveIn, uint reserveOut) = getReserves(factory, path[i], path[i + 1]);
            amounts[i + 1] = getAmountOut(amounts[i], reserveIn, reserveOut);
        }
    }

    //根据输出获取输入，计算路径中每一步交换的数值
    //相当于路径倒推输入
    function getAmountsIn(address factory, uint amountOut, address[] memory path) internal view returns (uint[] memory amounts) {
        require(path.length >= 2, 'UniswapLibrary: INVALID_PATH');
        amounts = new uint[](path.length);
        amounts[amounts.length - 1] = amountOut;
        //从后往前循环
        for (uint i = path.length - 1; i > 0; i--) {
            //获取存储量
            (uint reserveIn, uint reserveOut) = getReserves(factory, path[i - 1], path[i]);
            amounts[i - 1] = getAmountIn(amounts[i], reserveIn, reserveOut);
        }
    }
}

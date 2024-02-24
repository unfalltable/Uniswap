pragma solidity >=0.5.16;

import './interfaces/IUniswapPair.sol';
import './UniswapERC20.sol';
import './libraries/Math.sol';
import './libraries/UQ112x112.sol';
import './interfaces/IERC20.sol';
import './interfaces/IUniswapFactory.sol';
import './interfaces/IUniswapCallee.sol';

//pair合约
contract UniswapPair is IUniswapPair, UniswapERC20 {
    using SafeMath  for uint;
    using UQ112x112 for uint224;

    //最小流动性
    uint public constant MINIMUM_LIQUIDITY = 10**3;
    //transfer函数签名/选择器
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)')));

    address public factory;             //工厂地址
    address public token0;              
    address public token1;

    uint112 private reserve0;           //代币A总存储量
    uint112 private reserve1;           //代币B总存储量
    uint32  private blockTimestampLast; //更新存储量后的时间戳

    //在价格预言机中使用
    uint public price0CumulativeLast;
    uint public price1CumulativeLast;

    uint public kLast;

    //重入锁
    uint private unlocked = 1;
    modifier lock() {
        require(unlocked == 1, 'Uniswap: LOCKED');
        unlocked = 0;
        _;
        unlocked = 1;
    }

    //获取代币存储量
    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    //安全转账
    function _safeTransfer(address token, address to, uint value) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'Uniswap: TRANSFER_FAILED');
    }

    //事件
    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    //由工厂合约部署，部署时记录了工厂合约的地址
    constructor() public {
        factory = msg.sender;
    }

    //只能通过工厂合约调用
    function initialize(address _token0, address _token1) external {
        require(msg.sender == factory, 'Uniswap: FORBIDDEN'); // sufficient check
        token0 = _token0;
        token1 = _token1;
    }

    //更新代币存储量
    function _update(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) private {
        require(balance0 <= uint112(-1) && balance1 <= uint112(-1), 'Uniswap: OVERFLOW');
        //32位的当前区块时间戳
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        //时间流逝 = 当前区块时间戳 - 上一次更新存储量后的时间戳
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; 
        //为价格预言机做准备
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            //price0 += B存储量 * 2^112 / A存储量 * 时间流逝
            price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            //price1 += A存储量 * 2^112 / B存储量 * 时间流逝
            price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
        }
        //更新存储量
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        //更新时间戳
        blockTimestampLast = blockTimestamp;
        emit Sync(reserve0, reserve1);
    }

    //查询创建/销毁流动性需要的费用 0.05%
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        //检查是否设置了收费人
        address feeTo = IUniswapFactory(factory).feeTo();
        feeOn = feeTo != address(0);
        uint _kLast = kLast; 
        //收费公式
        //liquidity = 流动性代币总量 * (rootK - rootKLast) / 5*rootK + rootKLast 
        if (feeOn) {
            if (_kLast != 0) {
                //rootK = sqrt(a存储量 * b存储量)
                uint rootK = Math.sqrt(uint(_reserve0).mul(_reserve1));
                //rootKLast = sqrt(_kLast)
                uint rootKLast = Math.sqrt(_kLast);
                if (rootK > rootKLast) {
                    uint numerator = totalSupply.mul(rootK.sub(rootKLast));
                    uint denominator = rootK.mul(5).add(rootKLast);
                    uint liquidity = numerator / denominator;
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
        }
    }

    //添加token，铸造流动性代币，用于记录池中占比
    function mint(address to) external lock returns (uint liquidity) {
        //获取代币存储量
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        //查询该pair合约两个代币的数量
        uint balance0 = IERC20(token0).balanceOf(address(this));
        uint balance1 = IERC20(token1).balanceOf(address(this));
        //计算出本次传入函数的代币值
        uint amount0 = balance0.sub(_reserve0);
        uint amount1 = balance1.sub(_reserve1);

        //检查是否开启铸造费
        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint _totalSupply = totalSupply; 
        if (_totalSupply == 0) {
            liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
            //永久锁定一个最小流动性
           _mint(address(0), MINIMUM_LIQUIDITY); 
        } else {
            liquidity = Math.min(amount0.mul(_totalSupply) / _reserve0, 
                                 amount1.mul(_totalSupply) / _reserve1);
        }
        require(liquidity > 0, 'Uniswap: INSUFFICIENT_LIQUIDITY_MINTED');
        //给to地址增加流动性代币
        _mint(to, liquidity);
        //更新代币存储量
        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint(reserve0).mul(reserve1);
        emit Mint(msg.sender, amount0, amount1);
    }

    //取出代币+手续费，销毁流动性代币
    function burn(address to) external lock returns (uint amount0, uint amount1) {
        //获取存储量
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); 
        //获取代币地址
        address _token0 = token0;                                
        address _token1 = token1;       
        //获取当前合约对应的代币余额                         
        uint balance0 = IERC20(_token0).balanceOf(address(this));
        uint balance1 = IERC20(_token1).balanceOf(address(this));
        //获取流动性代币数量
        uint liquidity = balanceOf[address(this)];

        //获取铸造费，如有
        bool feeOn = _mintFee(_reserve0, _reserve1);
        //当前合约流动性代币总量
        uint _totalSupply = totalSupply; 
        //获取可以取出的代币总量
        amount0 = liquidity.mul(balance0) / _totalSupply; 
        amount1 = liquidity.mul(balance1) / _totalSupply; 
        require(amount0 > 0 && amount1 > 0, 'Uniswap: INSUFFICIENT_LIQUIDITY_BURNED');
        //销毁流动性代币
        _burn(address(this), liquidity);
        //将代币转给to地址
        _safeTransfer(_token0, to, amount0);
        _safeTransfer(_token1, to, amount1);
        //更新代币存储量
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));
        _update(balance0, balance1, _reserve0, _reserve1);
        //更新k值
        if (feeOn) kLast = uint(reserve0).mul(reserve1); 
        emit Burn(msg.sender, amount0, amount1, to);
    }

    //用户交易，依据合约中的储备量，计算token置换的数额
    //amount0Out和amount1Out需要经过路由合约扣取费用
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external lock {
        require(amount0Out > 0 || amount1Out > 0, 'Uniswap: INSUFFICIENT_OUTPUT_AMOUNT');
        //获取代币存储量
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); 
        require(amount0Out < _reserve0 && amount1Out < _reserve1, 'Uniswap: INSUFFICIENT_LIQUIDITY');

        uint balance0;
        uint balance1;
        {
            //获取代币地址
            address _token0 = token0;
            address _token1 = token1;
            require(to != _token0 && to != _token1, 'Uniswap: INVALID_TO');
            //转账
            if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); 
            if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out);
            //有data则是合约地址 
            //闪电贷
            if (data.length > 0) IUniswapCallee(to).UniswapCall(msg.sender, amount0Out, amount1Out, data);
            //更新余额
            balance0 = IERC20(_token0).balanceOf(address(this));
            balance1 = IERC20(_token1).balanceOf(address(this));
        }
        //输入一个数获取另一个数的余量
        uint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, 'Uniswap: INSUFFICIENT_INPUT_AMOUNT');
        { 
            //确认是否收取过费用
            uint balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3));
            uint balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));
            require(balance0Adjusted.mul(balance1Adjusted) >= uint(_reserve0).mul(_reserve1).mul(1000**2), 'Uniswap: K');
        }
        //更新存储量
        _update(balance0, balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    //强制平衡以匹配储备
    function skim(address to) external lock {
        address _token0 = token0; 
        address _token1 = token1; 
        _safeTransfer(_token0, to, IERC20(_token0).balanceOf(address(this)).sub(reserve0));
        _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this)).sub(reserve1));
    }

    //强制准备金和余额匹配
    function sync() external lock {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
    }
}

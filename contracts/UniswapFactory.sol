pragma solidity >=0.5.16;

import './interfaces/IUniswapFactory.sol';
import './UniswapPair.sol';

//工厂合约
contract UniswapFactory is IUniswapFactory {
    address public feeTo;       //收费人
    address public feeToSetter;//收费人设置者

    //pair对映射
    //TokenA -> TokenB -> pair合约
    mapping(address => mapping(address => address)) public getPair;

    //所有的pair合约，数组下标即pair合约的序号
    address[] public allPairs;

    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    //构造函数，合约部署时确定收费人设置者
    constructor(address _feeToSetter) public {
        feeToSetter = _feeToSetter;
    }
    //获取pair合约数组长度
    function allPairsLength() external view returns (uint) {
        return allPairs.length;
    }

    //创建pair合约
    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, 'Uniswap: IDENTICAL_ADDRESSES');
        //排序，使A < B
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'Uniswap: ZERO_ADDRESS');
        //确保配对合约没有创建过
        require(getPair[token0][token1] == address(0), 'Uniswap: PAIR_EXISTS');
        //获取pair合约源代码
        bytes memory bytecode = type(UniswapPair).creationCode;
        //使用TokenA和TokenB取哈希作为部署pair合约的盐值
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        //通过内联汇编使用create2部署pair合约
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        //调用pair合约的初始化方法
        IUniswapPair(pair).initialize(token0, token1);
        //加入两个方向的pair对
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; 
        //加入部署后的pair合约
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    //设置收费人
    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, 'Uniswap: FORBIDDEN');
        feeTo = _feeTo;
    }

    //修改收费人设置者
    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, 'Uniswap: FORBIDDEN');
        feeToSetter = _feeToSetter;
    }
}

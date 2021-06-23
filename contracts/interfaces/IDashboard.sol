// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

interface IPriceCalculator {
    function getAmountsOut(uint256 amount, address[] memory path) external view returns (uint256);
    function pricesInUSD(address[] memory assets) external view returns (uint256[] memory);
    function valueOfAsset(address asset, uint256 amount) external view returns (uint256 valueInBNB, uint256 valueInUSD);
    function priceOfBNB() external view returns (uint256);
    function priceOfCake() external view returns (uint256);
    function priceOfPct() external view returns (uint256);
    function priceOfToken(address token) external view returns(uint256);
}

interface IAlpacaCalculator {
    function balanceOf(address vault, uint256 pid, address account) external view returns(uint256);
    function balanceOfib(address vault, uint256 pid, address account) external view returns(uint256);
    function vaultApr(address vault, uint256 pid) external view returns(uint256 _apr, uint256 _alpacaApr);
}

interface IWexCalculator {
    function wexPoolDailyApr() external view returns(uint256);
}

import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts } = hre;
  const { deployer } = await getNamedAccounts();

  console.log({ deployer });

  const ubeV3Factory = '0x67FEa58D5a5a4162cED847E13c2c81c73bf8aeC4';
  const ubeV3NonfungiblePositionManager = '0x897387c7B996485c3AAa85c94272Cd6C506f8c8F';

  const ONE_DAY = 24 * 60 * 60; // 86400

  await deployments.deploy('UbeswapV3Farming', {
    contract: 'UbeswapV3Farming',
    from: deployer,
    args: [
      ubeV3Factory, // _factory
      ubeV3NonfungiblePositionManager, // _nonfungiblePositionManager
      7 * ONE_DAY, // _maxIncentiveStartLeadTime
      90 * ONE_DAY, // _maxIncentivePeriodDuration
      90 * ONE_DAY, // _maxLockTime
    ],
    log: true,
    autoMine: true,
  });
};

export default func;
func.id = 'deploy_ube_v3_farming'; // id required to prevent reexecution
func.tags = ['UbeV3Farming'];

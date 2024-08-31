import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts } = hre;
  const { deployer } = await getNamedAccounts();

  console.log({ deployer });

  const farm = await hre.ethers.getContract('UbeswapV3Farming', deployer);
  const quoterV2 = '0xA8864a18Fab1ED233Ce1921F329A6A92DBccA56f';

  await deployments.deploy('OffChainCalculationHelper', {
    contract: 'OffChainCalculationHelper',
    from: deployer,
    args: [
      deployer, // address initialOwner,
      farm.address, // IUbeswapV3Farming _farm,
      quoterV2, // IQuoterV2 _quoter
    ],
    log: true,
    autoMine: true,
  });
};

export default func;
func.id = 'deploy_offchain_calculation_helper'; // id required to prevent reexecution
func.tags = ['OffChainCalculationHelper'];

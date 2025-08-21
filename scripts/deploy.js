async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with account:", deployer.address);

  const MockUSD = await ethers.getContractFactory("MockUSD");
  const mockUSD = await MockUSD.deploy();
  await mockUSD.deployed();
  console.log("MockUSD deployed to:", mockUSD.address);

  const ETHUSDAMM = await ethers.getContractFactory("ETHUSDAMM");
  const amm = await ETHUSDAMM.deploy(mockUSD.address);
  await amm.deployed();
  console.log("ETHUSDAMM deployed to:", amm.address);

  const Lock = await ethers.getContractFactory("Lock");
  const lock = await Lock.deploy({ value: ethers.utils.parseEther("1") });
  await lock.deployed();
  console.log("Lock deployed to:", lock.address);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

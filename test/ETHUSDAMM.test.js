const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("ETHUSDAMM", function () {
  let owner, addr1, addr2, usd, amm;

  beforeEach(async function () {
    [owner, addr1, addr2] = await ethers.getSigners();

    // Deploy Mock USD token
    const MockUSD = await ethers.getContractFactory("MockUSD");
    usd = await MockUSD.deploy("Mock USD", "mUSDC", 6);
    await usd.waitForDeployment();

    // Deploy AMM contract
    const ETHUSDAMM = await ethers.getContractFactory("ETHUSDAMM");
    amm = await ETHUSDAMM.deploy(
      await usd.getAddress(),
      owner.address,     // feeRecipient
      owner.address      // initialOwner
    );
    await amm.waitForDeployment();

    // Mint USD to addr1
    await usd.mint(addr1.address, ethers.parseUnits("1000000", 6));
  });

  it("should allow adding liquidity", async function () {
    const usdAmount = ethers.parseUnits("1000", 6);
    const ethAmount = ethers.parseEther("1");

    await usd.connect(addr1).approve(await amm.getAddress(), usdAmount);
    const deadline = (await time.latest()) + 3600;

    await expect(
      amm.connect(addr1).addLiquidity(
        usdAmount,
        0,
        0,
        deadline,
        { value: ethAmount }
      )
    ).to.emit(amm, "LiquidityAdded");
  });

  it("should allow removing liquidity", async function () {
    const usdAmount = ethers.parseUnits("1000", 6);
    const ethAmount = ethers.parseEther("1");
    const deadline = (await time.latest()) + 3600;

    await usd.connect(addr1).approve(await amm.getAddress(), usdAmount);
    await amm.connect(addr1).addLiquidity(
      usdAmount,
      0,
      0,
      deadline,
      { value: ethAmount }
    );

    const lpBalance = await amm.balanceOf(addr1.address);

    await expect(
      amm.connect(addr1).removeLiquidity(lpBalance, 0, 0, deadline)
    ).to.emit(amm, "LiquidityRemoved");
  });

  it("should swap ETH for USD", async function () {
    const usdAmount = ethers.parseUnits("1000", 6);
    const ethAmount = ethers.parseEther("1");
    let deadline = (await time.latest()) + 3600;

    await usd.connect(addr1).approve(await amm.getAddress(), usdAmount);
    await amm.connect(addr1).addLiquidity(
      usdAmount,
      0,
      0,
      deadline,
      { value: ethAmount }
    );

    deadline = (await time.latest()) + 3600;

    await expect(
      amm.connect(addr2).swapETHForUSD(0, deadline, { value: ethers.parseEther("0.1") })
    ).to.emit(amm, "Swap");
  });

  it("should swap USD for ETH", async function () {
    const usdAmount = ethers.parseUnits("1000", 6);
    const ethAmount = ethers.parseEther("1");
    let deadline = (await time.latest()) + 3600;

    await usd.connect(addr1).approve(await amm.getAddress(), usdAmount);
    await amm.connect(addr1).addLiquidity(
      usdAmount,
      0,
      0,
      deadline,
      { value: ethAmount }
    );

    deadline = (await time.latest()) + 3600;

    await usd.connect(addr1).approve(await amm.getAddress(), ethers.parseUnits("100", 6));

    await expect(
      amm.connect(addr1).swapUSDForETH(ethers.parseUnits("100", 6), 0, deadline)
    ).to.emit(amm, "Swap");
  });
});

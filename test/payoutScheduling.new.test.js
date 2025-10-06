const { expect } = require("chai");
const { ethers } = require("hardhat");

async function increaseTime(seconds) {
	await ethers.provider.send("evm_increaseTime", [seconds]);
	await ethers.provider.send("evm_mine", []);
}

describe("Payout scheduling (Security enforced via Router)", function () {
	let owner, user, donor;
	let core, router, security;

	beforeEach(async () => {
		[owner, user, donor] = await ethers.getSigners();

		// Core mock (paused=false). Constructor requires a storage address; pass any address.
		const Core = await ethers.getContractFactory("MockCore");
		core = await Core.deploy(owner.address);
		await core.waitForDeployment();

		// Use fully qualified router name to avoid HH701
		const Router = await ethers.getContractFactory("contracts/router/PoliDaoRouter.sol:PoliDaoRouter");
		router = await Router.deploy(await core.getAddress());
		await router.waitForDeployment();

		const Security = await ethers.getContractFactory("PoliDaoSecurity");
		security = await Security.deploy(await core.getAddress());
		await security.waitForDeployment();

		await (await router.connect(owner).setSecurity(await security.getAddress())).wait();

		const defaultLimit = await security.payoutLimitUSDC();
		expect(defaultLimit).to.equal(1_100_000n);
	});

	it("withdraw within limit executes immediately without schedule", async () => {
		const limit = await security.payoutLimitUSDC();
		const amt = limit - 1n;

		// v6: use staticCall
		const [allowedNow, nextAt, remaining] = await router.connect(user).withdrawWithSchedule.staticCall(1, amt);
		expect(allowedNow).to.equal(amt);
		expect(nextAt).to.equal(0n);
		expect(remaining).to.equal(0n);

		await (await router.connect(user).withdrawWithSchedule(1, amt)).wait();

		const sched = await security.withdrawSchedules(1, user.address);
		expect(sched.remaining).to.equal(0n);
		expect(sched.nextClaimAt).to.equal(0n);
	});

	it("withdraw over limit creates schedule, pays first tranche now, next after 1h (non-stacking)", async () => {
		const limit = await security.payoutLimitUSDC();
		const total = limit * 3n + (limit / 2n); // 3.5x limit

		const [allowed1, nextAt1, rem1] = await router.connect(user).withdrawWithSchedule.staticCall(7, total);
		expect(allowed1).to.equal(limit);
		expect(nextAt1).to.be.gt(0n);
		expect(rem1).to.equal(total - limit);
		await (await router.connect(user).withdrawWithSchedule(7, total)).wait();

		// Before 1h -> revert
		await expect(router.connect(user).withdrawWithSchedule(7, total)).to.be.revertedWith(
			"Security: payout tranche not available yet"
		);

		// After 1h -> second tranche
		await increaseTime(3600);
		const [allowed2, nextAt2, rem2] = await router.connect(user).withdrawWithSchedule.staticCall(7, total);
		expect(allowed2).to.equal(limit);
		expect(nextAt2).to.be.gt(0n);
		expect(rem2).to.equal(total - 2n * limit);
		await (await router.connect(user).withdrawWithSchedule(7, total)).wait();

		// After another 1h -> third tranche (limit)
		await increaseTime(3600);
		const [allowed3, nextAt3, rem3] = await router.connect(user).withdrawWithSchedule.staticCall(7, total);
		expect(allowed3).to.equal(limit);
		expect(nextAt3).to.be.gt(0n);
		expect(rem3).to.equal(total - 3n * limit);
		await (await router.connect(user).withdrawWithSchedule(7, total)).wait();

		// After another 1h -> last (remainder < limit), schedule cleared after
		await increaseTime(3600);
		const [allowed4, nextAt4, rem4] = await router.connect(user).withdrawWithSchedule.staticCall(7, total);
		expect(allowed4).to.equal(total - 3n * limit);
		expect(nextAt4).to.equal(0n);
		expect(rem4).to.equal(0n);
		await (await router.connect(user).withdrawWithSchedule(7, total)).wait();

		const sched = await security.withdrawSchedules(7, user.address);
		expect(sched.remaining).to.equal(0n);
		expect(sched.nextClaimAt).to.equal(0n);
	});

	it("admin can change payout limit and setting to 0 disables scheduling", async () => {
		await (await security.connect(owner).setPayoutLimitUSDC(2_000_000)).wait();
		const newLimit = await security.payoutLimitUSDC();
		expect(newLimit).to.equal(2_000_000n);

		const total = newLimit * 2n + (newLimit / 2n);

		const [a1, n1, r1] = await router.connect(user).withdrawWithSchedule.staticCall(9, total);
		expect(a1).to.equal(newLimit);
		expect(n1).to.be.gt(0n);
		expect(r1).to.equal(total - newLimit);
		await (await router.connect(user).withdrawWithSchedule(9, total)).wait();

		// Disable scheduling
		await (await security.connect(owner).setPayoutLimitUSDC(0)).wait();
		const zeroLimit = await security.payoutLimitUSDC();
		expect(zeroLimit).to.equal(0n);

		// Request only the remaining amount now that scheduling is disabled
		const [a2, n2, r2] = await router.connect(user).withdrawWithSchedule.staticCall(9, r1);
		expect(a2).to.equal(r1);
		expect(n2).to.equal(0n);
		expect(r2).to.equal(0n);
		await (await router.connect(user).withdrawWithSchedule(9, r1)).wait();

		const sched = await security.withdrawSchedules(9, user.address);
		expect(sched.remaining).to.equal(0n);
		expect(sched.nextClaimAt).to.equal(0n);
	});

	it("refund path mirrors withdraw scheduling", async () => {
		const limit = await security.payoutLimitUSDC();
		const total = limit + (limit / 3n);

		const [r1a, r1n, r1r] = await router.connect(donor).refundWithSchedule.staticCall(5, total);
		expect(r1a).to.equal(limit);
		expect(r1n).to.be.gt(0n);
		expect(r1r).to.equal(total - limit);
		await (await router.connect(donor).refundWithSchedule(5, total)).wait();

		await expect(router.connect(donor).refundWithSchedule(5, total)).to.be.revertedWith(
			"Security: payout tranche not available yet"
		);

		await increaseTime(3600);
		const [r2a, r2n, r2r] = await router.connect(donor).refundWithSchedule.staticCall(5, total);
		expect(r2a).to.equal(total - limit);
		expect(r2n).to.equal(0n);
		expect(r2r).to.equal(0n);
		await (await router.connect(donor).refundWithSchedule(5, total)).wait();

		const sched = await security.refundSchedules(5, donor.address);
		expect(sched.remaining).to.equal(0n);
		expect(sched.nextClaimAt).to.equal(0n);
	});
});


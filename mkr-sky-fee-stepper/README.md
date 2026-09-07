# MkrSky Fee Stepper

Steps up the MKR → SKY **Delayed Upgrade Penalty** by a fixed amount every period (1 percentage
point per quarter) without a spell for every step.

The penalty is the `fee` of the [`MkrSky`](https://github.com/sky-ecosystem/sky/blob/master/src/MkrSky.sol)
converter. Governance decided in 2025 that the fee starts at 1% and grows by 1 percentage point every
three months until it reaches 100%. So far every increase has been a line in an executive spell:

| Spell        | Fee | Spell code                                              |
|--------------|-----|---------------------------------------------------------|
| 2025-09-18   | 1%  | `DssExecLib.setValue(MKR_SKY, "fee", 1 * WAD / 100);`   |
| 2025-12-11   | 2%  | `DssExecLib.setValue(MKR_SKY, "fee", 2 * WAD / 100);`   |
| 2026-03-12   | 3%  | `DssExecLib.setValue(MKR_SKY, "fee", 3_00 * WAD / 100_00);` |
| 2026-06-04   | 4%  | `DssExecLib.setValue(MKR_SKY, "fee", 4 * WAD / 100);`   |
| 2026-09-10   | 5%  | scheduled: [Delayed Migration Penalty Update - September 10th Spell](https://forum.skyeco.com/t/delayed-migration-penalty-update-september-10th-spell/28218) |

This module replaces those recurring spell items with an on-chain schedule that anyone (in practice
the Sky keeper network) can poke.

## Contracts

| Contract                     | Purpose |
|------------------------------|---------|
| `src/MkrSkyFeeStepper.sol`   | The schedule. Permissionless `tick()` files the next fee on `MkrSky`. Must be a ward of `MkrSky`. |
| `src/MkrSkyFeeStepperMom.sol`| Lets the hat halt the stepper immediately, bypassing the GSM delay (same pattern as `SplitterMom` / `SPBEAMMom`). |
| `src/MkrSkyFeeStepperJob.sol`| [dss-cron](https://github.com/makerdao/dss-cron) `IJob` so the keeper networks call `tick()` as soon as a period elapses. |
| `deploy/MkrSkyFeeStepperDeploy.sol` | Deploys the three contracts and hands ownership to the pause proxy. |
| `deploy/MkrSkyFeeStepperInit.sol`   | Spell library: sanity checks, files the schedule, wires permissions, adds the job to the sequencer and registers chainlog keys. |

### MkrSkyFeeStepper

```
step  [wad]        Fee increase applied per period (1% == 0.01 * WAD)
cap   [wad]        Max fee this contract will ever file (<= WAD)
tau   [seconds]    Period length
rho   [timestamp]  Time of the last step (start of the current period)
bad   [flag]       Circuit breaker (1 == halted)
```

`tick()`:

1. reverts if halted (`bad == 1`), if `tau` is not set, or if less than `tau` has passed since `rho`;
2. computes `n = (block.timestamp - rho) / tau`, the number of whole periods elapsed;
3. files `min(cap, MkrSky.fee() + n * step)` on `MkrSky`, reverting if that would not raise the fee;
4. moves `rho` forward by exactly `n * tau`.

Properties that follow (all covered by the unit, fuzz and invariant tests):

* **The fee only ever goes up**, and never above `cap` (which itself is capped at `WAD`, the bound
  `MkrSky` enforces). The stepper cannot lower a fee that governance set above `cap`.
* **Missed periods are caught up**, not lost: if nobody pokes the contract for two quarters, the next
  `tick()` applies two steps at once. This is the same "accumulate what is owed for the elapsed time"
  behaviour as `jug.drip()` / `pot.drip()`, discretised to whole periods.
* **The schedule never drifts.** `rho` snaps to the grid `rho0 + k * tau`, whether the poke is early
  by a second or late by a week. Fee changes always land at the same time of day, every `tau`.
* **Governance keeps direct control.** The increment is applied on top of whatever `MkrSky.fee()` is at
  the time, so a spell can still file the fee directly (up or down) and the stepper carries on from
  the new value. The parameters can be re-filed at any time, and the stepper can simply be `deny`ed on
  `MkrSky` to retire it.
* **Anyone can call `tick()`.** There is nothing to gain by front-running it: the outcome is a pure
  function of the schedule and the clock.

### MkrSkyFeeStepperMom

`halt()` files `bad = 1` on the stepper. It is callable by the Mom `owner` (the pause proxy) or by
anyone the `authority` (`MCD_ADM`, i.e. the hat) allows, so it does not wait for the GSM delay. Resuming
is a normal governance action: `stepper.file("bad", 0)`.

While halted `rho` does not advance, so resuming after two missed periods catches both up at the
next `tick()`. If that is not what governance wants, the resuming spell should also re-anchor the
schedule with `stepper.file("rho", <timestamp>)` (the next step is then due at `rho + tau`).

### MkrSkyFeeStepperJob

`workable(network)` mirrors the checks in `tick()` and never reverts; `work(network, args)` calls
`tick()` when the calling keeper network is the sequencer master. The invariant test checks that
`work()` reverts if and only if `workable()` returns `false`.

## Relationship to existing modules

* [`dss-lerp`](https://github.com/makerdao/dss-lerp) — the Maker module for stepwise/gradual parameter
  changes. Like `Lerp`, the stepper is a ward of the target contract, exposes a permissionless
  `tick()` and calls `target.file(what, value)`. Unlike `Lerp` it is not limited to one year and does
  not compute a linear interpolation but a step function that keeps going until `cap`.
* `jug` / `pot` / `sUSDS` `drip()` — time based accumulation anchored at `rho`, applied to the current
  value, catching up all elapsed time in one call.
* [`Splitter`](https://github.com/sky-ecosystem/dss-flappers) (`hop` / `zzz`) and its `SplitterMom`,
  and [`SP-BEAM`](https://github.com/sky-ecosystem/sp-beam) (`bad` flag + `SPBEAMMom.halt`) — timing
  and emergency-halt conventions reused here.
* [`dss-cron`](https://github.com/makerdao/dss-cron) — the `IJob` interface implemented by the job.

## Governance operations

### Deploy

```bash
export ETH_RPC_URL=... ETH_FROM=...
make deploy   # forge script script/Deploy.s.sol:DeployScript --broadcast --verify
```

The script reads `MKR_SKY`, `CRON_SEQUENCER` and `MCD_PAUSE_PROXY` from the chainlog, deploys the
three contracts owned by the pause proxy and writes the addresses to `script/output/<chainid>/`.

### Init (in a spell)

```solidity
import { MkrSkyFeeStepperInit, MkrSkyFeeStepperConfig } from "mkr-sky-fee-stepper/deploy/MkrSkyFeeStepperInit.sol";
import { MkrSkyFeeStepperInstance } from "mkr-sky-fee-stepper/deploy/MkrSkyFeeStepperInstance.sol";

// ---------- Automate the Delayed Upgrade Penalty ----------
DssInstance memory dss = MCD.loadFromChainlog(DssExecLib.LOG);
MkrSkyFeeStepperInit.init(
    dss,
    MkrSkyFeeStepperInstance({
        stepper: MKR_SKY_FEE_STEPPER,
        mom:     MKR_SKY_FEE_STEPPER_MOM,
        job:     CRON_MKR_SKY_FEE_STEPPER_JOB
    }),
    MkrSkyFeeStepperConfig({
        step: 1 * WAD / 100, // +1 percentage point per period
        cap:  WAD,           // until the fee reaches 100%
        tau:  91 days,       // one period == 13 weeks
        rho:  1_789_000_000  // example: cast time of the last manual increase; first automatic step at rho + tau
    })
);
```

`init` checks the instance against the chainlog and the config for sanity (`0 < step <= WAD`,
`fee <= cap <= WAD`, `tau > 0`, `0 < rho <= now + tau`), files the schedule, relies the Mom on the
stepper, sets `MCD_ADM` as the Mom authority, relies the stepper on `MKR_SKY`, adds the job to
`CRON_SEQUENCER` and sets the chainlog keys `MKR_SKY_FEE_STEPPER`, `MKR_SKY_FEE_STEPPER_MOM` and
`CRON_MKR_SKY_FEE_STEPPER_JOB`. Bumping the chainlog version is left to the spell.

Once the module is live the quarterly `DssExecLib.setValue(MKR_SKY, "fee", ...)` spell items are no
longer needed; if a spell does file the fee directly, the stepper simply continues from the new value.

### Suggested mainnet parameters

| Parameter | Value                      | Note |
|-----------|----------------------------|------|
| `step`    | `1 * WAD / 100`            | 1 percentage point, as in every spell so far |
| `cap`     | `WAD`                      | 100%, the end of the governance-approved schedule |
| `tau`     | `91 days`                  | 13 weeks. `7_889_400` (365.25 / 4 days) is the alternative if calendar-year alignment over 25 years matters more than whole weeks |
| `rho`     | cast time of the last manual step | e.g. the 2026-09-10 spell that set 5%; the first automatic step then lands 91 days later |

From 5% and 91-day periods the fee reaches 100% after 95 steps, in mid-2050 — in line with the
"1% every three months until 100%" schedule announced in 2025.

### Emergency and retirement

* Halt without delay: hat calls `MkrSkyFeeStepperMom.halt()`.
* Resume: spell files `bad = 0` (and optionally a new `rho`, see above).
* Change the schedule: spell files `step` / `cap` / `tau` / `rho`. A `tau` change takes effect from the
  last step: the next step is due at `rho + newTau`.
* Retire: spell calls `MkrSky.deny(stepper)` and `Sequencer.removeJob(job)`.

## Development

```bash
forge build
forge test                       # unit, fuzz and invariant tests
ETH_RPC_URL=... forge test       # additionally runs the mainnet fork tests in test/Integration.t.sol
```

Dependencies (git submodules): [`forge-std`](https://github.com/foundry-rs/forge-std),
[`dss-test`](https://github.com/makerdao/dss-test) and [`sky`](https://github.com/sky-ecosystem/sky)
(the real `MkrSky` and `Sky` contracts are used in the tests).

### Bootstrapping this as a standalone repository

```bash
git init mkr-sky-fee-stepper && cd mkr-sky-fee-stepper
# copy everything from this directory except lib/
git submodule add https://github.com/foundry-rs/forge-std lib/forge-std
git submodule add https://github.com/makerdao/dss-test lib/dss-test
git submodule add https://github.com/sky-ecosystem/sky lib/sky
git submodule update --init --recursive
forge test
```

## License

AGPL-3.0-or-later. See [LICENSE](LICENSE).

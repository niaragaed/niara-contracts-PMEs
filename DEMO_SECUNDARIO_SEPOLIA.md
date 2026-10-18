# Public demo — Sepolia (Phase 4: secondary settlement)

> **Notice.** This is a demonstration on the **Sepolia testnet**. `MockBRL` is a test
> mock (unbacked, valueless, mintable at will) and **does not represent real money**.
> This code has **no published external audit** (full test coverage + fuzzing
> invariants, WITHOUT an external audit). **No mainnet deploy has been made or is
> planned in this phase.** `LiquidacaoSecundaria` **is not an order book**: it is a
> bilateral assignment matched by the platform, embodying the intermediation CVM
> Resolution 88 requires for the secondary market of securities offered under a
> registration exemption; there is no book of offers, no matching engine and no
> unrestricted P2P trading. The secondary market in this demo is restricted by
> `RestrictedTransferPolicy` (lock-up + allowlist + release flag, see `CLAUDE.md`); having
> opened it here only demonstrates the governance flow, not a real market opening.

> 🔴 **These addresses are no longer operable.** The deployer key below was lost, and with
> it `DEFAULT_ADMIN_ROLE` on every contract in this deploy. The infrastructure was
> redeployed on 2026-08-15; see "Phase 4 deployer key lost" in `CLAUDE.md` for the current
> addresses. This file is kept as the historical record of that deploy.

## Deployed contracts

Deployed and verified via `script/DemoSecundarioSetup.s.sol` (the deployer acting as
admin/agent). A fresh deploy on purpose: the previous demo's token (`DEMO_SEPOLIA.md`,
Phase 2) points to `DenyAllTransferPolicy` and came from an implementation older than the
Phase 3 policy setter, so it cannot be migrated.

| Contract | Address | Etherscan |
|---|---|---|
| MockBRL | `0xDF052B4147Fdd8876d84767CB9F5477E4feC0559` | [view](https://sepolia.etherscan.io/address/0xDF052B4147Fdd8876d84767CB9F5477E4feC0559) |
| DenyAllTransferPolicy | `0x8e5A71D005E08002aF1eA697D543ac3825c43F82` | [view](https://sepolia.etherscan.io/address/0x8e5A71D005E08002aF1eA697D543ac3825c43F82) |
| RestrictedTransferPolicy | `0x8E1E7407D3771386c3fE7BF9E823e1A0E83B621E` | [view](https://sepolia.etherscan.io/address/0x8E1E7407D3771386c3fE7BF9E823e1A0E83B621E) |
| ParticipacaoToken (implementation) | `0xF20a786fa64329c3b162a2D45cB290978c76fB64` | [view](https://sepolia.etherscan.io/address/0xF20a786fa64329c3b162a2D45cB290978c76fB64) |
| EmissaoGateway | `0xcb01a240a73784Bc3B3B28Dbd77e01FcA4c8bb40` | [view](https://sepolia.etherscan.io/address/0xcb01a240a73784Bc3B3B28Dbd77e01FcA4c8bb40) |
| ParticipacaoTokenFactory | `0x0aD8Bbf0793BD81160526522D6cF7aC0E2C4705C` | [view](https://sepolia.etherscan.io/address/0x0aD8Bbf0793BD81160526522D6cF7aC0E2C4705C) |
| RegistroInvestidorQualificado | `0x1FFb81796B588D0E519E9e6BFD3F5B35607c813a` | [view](https://sepolia.etherscan.io/address/0x1FFb81796B588D0E519E9e6BFD3F5B35607c813a) |
| OfertaCaptacao (implementation) | `0x778C62B8Bb651D13479D4faf6a6b70F17721e7C4` | [view](https://sepolia.etherscan.io/address/0x778C62B8Bb651D13479D4faf6a6b70F17721e7C4) |
| OfertaCaptacaoFactory | `0x2aC536554b8c7733F11bf38f0d8BC272950a1d4f` | [view](https://sepolia.etherscan.io/address/0x2aC536554b8c7733F11bf38f0d8BC272950a1d4f) |
| LiquidacaoSecundaria | `0xE96649DEf1B2df25AAaEb68BC8F412be05e11107` | [view](https://sepolia.etherscan.io/address/0xE96649DEf1B2df25AAaEb68BC8F412be05e11107) |

All 10 contracts above were verified on Sepolia Etherscan (`forge script --verify`,
"Pass - Verified" or "Already Verified" confirmed for each one in the broadcast log).

EIP-1167 clone created via `script/DemoSecundarioPreparar.s.sol` (a minimal proxy;
Etherscan recognizes it automatically as a proxy of the corresponding implementation above;
the real code lives in the implementation, already verified):

| Clone | Address | Points to | Etherscan |
|---|---|---|---|
| Token (ParticipacaoToken, "Oferta Demo Secundario" / nSEC) | `0x1277fF28a14616366b824db3Df9312B9a3C03603` | ParticipacaoToken (implementation) | [view](https://sepolia.etherscan.io/address/0x1277fF28a14616366b824db3Df9312B9a3C03603) |

Wallets (not contracts, listed only for completeness; **all new burners, generated in this
run, with no real value**; the previous demo's keys were exposed in a transcript and are
burned, not reused here):

| Role | Address |
|---|---|
| Deployer / admin / agent | `0x101e8ad58F2D2A923553FeFE558a7bEf5566871E` |
| Seller (held the shares) | `0x4665a641e73e2A70183d2bb1172eB579db622A36` |
| Buyer (eligible, paid for the assignment) | `0x0312a3a8F09af4485106a82078fACF9eA231dcBa` |
| Protocol (dormant fee = 0 in this demo) | `0x2D05772D847742648DE4c1935e3468E30307ADf0` |

## Timeline with the timelock

The 1h timelock hits two independent points: (a) granting `AGENTE_ROLE` and (b) migrating
the token's policy to `RestrictedTransferPolicy` + turning on `secundarioLiberado`. Since
the token only exists after the AGENT role is granted, the two moments do not fit in the
same window; hence three scripts, with two real 1h waits between them.

## Transaction timeline

### Part 1 — `DemoSecundarioSetup.s.sol` (deploy + propose `AGENTE_ROLE`)

| # | Action | Tx hash |
|---|---|---|
| 1 | Deploy MockBRL | [`0x8e0aa326…355028f1`](https://sepolia.etherscan.io/tx/0x8e0aa326051761d6af829dc0cdfe7001e270b7abdc8172739df1ef32355028f1) |
| 2 | Deploy DenyAllTransferPolicy | [`0x13ff5751…972104ea0`](https://sepolia.etherscan.io/tx/0x13ff5751472b189faa9004449235acb1b16b7c438178799e34570ae972104ea0) |
| 3 | Deploy RestrictedTransferPolicy | [`0x03adf86e…4dc15b289`](https://sepolia.etherscan.io/tx/0x03adf86efc2b5a52a84a5b95cc2374607811d615cb0ee883d60ee984dc15b289) |
| 4 | Deploy ParticipacaoToken (implementation) | [`0xfa79cac1…d83fbc5f5`](https://sepolia.etherscan.io/tx/0xfa79cac17f86e0b03d6cff52d8540b7824f7fbc9b09c1c9be95d5bdc83fbc5f5) |
| 5 | Deploy EmissaoGateway | [`0x8a9726cc…3fb154fd0`](https://sepolia.etherscan.io/tx/0x8a9726ccb82069de1ef3a04681629819a2fe1880755d88ff1969c233fb154fd0) |
| 6 | Deploy ParticipacaoTokenFactory | [`0x72743a96…be87de049`](https://sepolia.etherscan.io/tx/0x72743a96e244167408a49877f0df767c6e95067d753db52fc41f4b6be87de049) |
| 7 | Deploy RegistroInvestidorQualificado | [`0xaf428d62…f1a6673af`](https://sepolia.etherscan.io/tx/0xaf428d62a89a54bf9d0e648c9a2bb02d931750e5b92978ebd681763f1a6673af) |
| 8 | Deploy OfertaCaptacao (implementation) | [`0x3b23b9aa…28dea7110`](https://sepolia.etherscan.io/tx/0x3b23b9aa2a5b90e50298d6daef6fb9a50a5532ec1d01cdb92aaf8ae28dea7110) |
| 9 | Deploy OfertaCaptacaoFactory | [`0x7ded3199…e20a933ec`](https://sepolia.etherscan.io/tx/0x7ded3199091f2b47945a0d2dd9f11360b46f40b7a1a28622cffde60e20a933ec) |
| 10 | Deploy LiquidacaoSecundaria | [`0xd7ff4db5…8bd62295d`](https://sepolia.etherscan.io/tx/0xd7ff4db5a7d4c9a1b985f6d9bfd09a7e6e021be4c2640c1425c7f628bd62295d) |
| 11 | `EmissaoGateway.proposeGrantRole(AGENTE_ROLE, deployer)` | [`0x13dc9ca3…c3e265e3015`](https://sepolia.etherscan.io/tx/0x13dc9ca3abd132e6ed6b98821103db81a40fec3de5ebe2406d1f2c3e265e3015) |
| 12 | `ParticipacaoTokenFactory.proposeGrantRole(AGENTE_ROLE, deployer)` | [`0x39f41ad7…7b111980849aaef5a7bdb6bf2`](https://sepolia.etherscan.io/tx/0x39f41ad73042f0ac80bfd8f6e5eec11b04f814a7b111980849aaef5a7bdb6bf2) |
| 13 | `RegistroInvestidorQualificado.proposeGrantRole(AGENTE_ROLE, deployer)` | [`0xd4521259…719deaed78fd`](https://sepolia.etherscan.io/tx/0xd45212596507a846475b8411b5d8d2050742179abb531f5556ab719deaed78fd) |
| 14 | `OfertaCaptacaoFactory.proposeGrantRole(AGENTE_ROLE, deployer)` | [`0x24e10c5c…858d740edd70`](https://sepolia.etherscan.io/tx/0x24e10c5c47347531f4552ec9750d0b6cf7784e0d26c01e02b371858d740edd70) |
| 15 | `RestrictedTransferPolicy.proposeGrantRole(AGENTE_ROLE, deployer)` | [`0xd66e22b6…c398effe2b325faafb6`](https://sepolia.etherscan.io/tx/0xd66e22b6955cd50f1effdd7a07ed043e9408283ca59d8c398effe2b325faafb6) |
| 16 | `LiquidacaoSecundaria.proposeGrantRole(AGENTE_ROLE, deployer)` | [`0xdcc76d0f…987ec30ceefda2e74ccf`](https://sepolia.etherscan.io/tx/0xdcc76d0f9150b8a49a5dd1faa0ef4870f58809a250ef987ec30ceefda2e74ccf) |

**Real timelock wait no. 1**: the `AGENTE_ROLE` proposals above stayed pending for
`MIN_TIMELOCK_DELAY = 1 hours`. Proposed at `1785709356` (2026-08-02 22:22:36 UTC),
`executeAfter = 1785712956` (2026-08-02 23:22:36 UTC): real wall-clock time elapsed on the
chain before part 2, which cannot be simulated in a real broadcast.

### Part 2 — `DemoSecundarioPreparar.s.sol` (execute `AGENTE_ROLE`, issue shares, configure the policy, propose migration + opening)

| # | Action | Tx hash |
|---|---|---|
| 1 | `EmissaoGateway.executeGrantRole(AGENTE_ROLE, deployer)` | [`0x2f095d43…b561db3243`](https://sepolia.etherscan.io/tx/0x2f095d4381cd6a46be8d3e0a50b3eddd4a8229f950eec7b8147805b561db3243) |
| 2 | `ParticipacaoTokenFactory.executeGrantRole(AGENTE_ROLE, deployer)` | [`0x99368065…9278c953a45cf32a6daf7`](https://sepolia.etherscan.io/tx/0x99368065c2be3b770453e0f836de5c2eda22873b4590278c953a45cf32a6daf7) |
| 3 | `RegistroInvestidorQualificado.executeGrantRole(AGENTE_ROLE, deployer)` | [`0x55e1e4c9…52d74971f9fe50771`](https://sepolia.etherscan.io/tx/0x55e1e4c91160b21c49e362e12d469230a77ace5bbf87df252d74971f9fe50771) |
| 4 | `OfertaCaptacaoFactory.executeGrantRole(AGENTE_ROLE, deployer)` | [`0xe9a73ad3…cad2221315d43912baa9`](https://sepolia.etherscan.io/tx/0xe9a73ad38ea5a24df99061daacc1ba0fee0554a96f17cad2221315d43912baa9) |
| 5 | `RestrictedTransferPolicy.executeGrantRole(AGENTE_ROLE, deployer)` | [`0xdebf42d6…525ebf9f7591f2a0a31`](https://sepolia.etherscan.io/tx/0xdebf42d633ec08bf0678ebcdb37f153398fcbab76c948525ebf9f7591f2a0a31) |
| 6 | `LiquidacaoSecundaria.executeGrantRole(AGENTE_ROLE, deployer)` | [`0xbc8e799d…c99625f73aad43dd5`](https://sepolia.etherscan.io/tx/0xbc8e799db68a01b1f0d912d5866e27b5e1fc04acf4c6b2b300d0431ba2e4c7c9) |
| 7 | `ParticipacaoTokenFactory.criarOferta(...)` → token | [`0xb22c3d1a…c99625f73aad43dd5`](https://sepolia.etherscan.io/tx/0xb22c3d1aa2aabd9d7da302842db426b0c7481ecfd10c9cec99625f73aad43dd5) |
| 8 | `EmissaoGateway.atestarCotas(token, 1,000,000 shares)` | [`0x54b75b00…caef3ce`](https://sepolia.etherscan.io/tx/0x54b75b007efc7731f4d08e32cf416e0eb8d538562eea4cbffdef79442caef3ce) |
| 9 | **`EmissaoGateway.emitir(token, vendedor, 50 shares)`** | [`0xa24a2d28…8f93041a`](https://sepolia.etherscan.io/tx/0xa24a2d2878d45fa7370afb5d202392cf55b11658dbfa3b98b18138fe8f93041a) |
| 10 | `RestrictedTransferPolicy.definirElegivel(token, vendedor, true)` | [`0x8b164b05…9deb0fcd`](https://sepolia.etherscan.io/tx/0x8b164b0517edcb8757ef182953e78b223afadbc8babb71d0adb360329deb0fcd) |
| 11 | `RestrictedTransferPolicy.definirElegivel(token, comprador, true)` | [`0x47f3a2b7…5762187e0`](https://sepolia.etherscan.io/tx/0x47f3a2b7c7eefa43e2622770b6a5078921280b6de65928d7fe7a1175762187e0) |
| 12 | `RestrictedTransferPolicy.definirLockup(token, +10 min)` | [`0x316cfb82…f196fc89`](https://sepolia.etherscan.io/tx/0x316cfb8222030a95e6f0a07dd610a3ae50dce2e8e92afc460c5bdf26f196fc89) |
| 13 | `EmissaoGateway.proposeSetTransferPolicy(token, restricted)` | [`0x14a8514e…b62626498`](https://sepolia.etherscan.io/tx/0x14a8514edede27f2422c40ef9e8a303097b7d7abc9bd5ecbce26973b62626498) |
| 14 | `RestrictedTransferPolicy.proposeSetSecundarioLiberado(token, true)` | [`0x2584c442…743cf6a2e5cce8a03e5`](https://sepolia.etherscan.io/tx/0x2584c4429e6c9fec7e58dfcbfd09ca176375384abd917743cf6a2e5cce8a03e5) |

**Restriction artifact (public proof, optional)**: between part 2 and part 3, with the
token still pointing to `DenyAllTransferPolicy`, an attempted `ParticipacaoToken.transfer`
from the seller to the buyer was submitted via `cast send` (published even though it
reverts): a **deliberate failure**, recorded on-chain:
[`0x121ac5a2…970239ec3`](https://sepolia.etherscan.io/tx/0x121ac5a21abadb6243aafec423aa9a7bc3a0fbff64ebd787973d9f8970239ec3)
(`status: 0 (failed)`, revert `TransferenciaNaoPermitida`).

**Real timelock wait no. 2**: policy migration + secondary opening proposed at
`1785713676` (implied, `executeAfter - 3600`), `executeAfter = 1785717276` (2026-08-03
00:34:36 UTC). The 10-minute lock-up set in action 12 had already expired well before that
moment, so part 3 found the assignment already releasable as soon as the timelock passed.

### Part 3 — `DemoSecundario.s.sol` (execute migration + opening, settle the assignment)

| # | Action | Tx hash |
|---|---|---|
| 1 | `EmissaoGateway.executeSetTransferPolicy(token, restricted)` | [`0x16a133e3…82f7f449f`](https://sepolia.etherscan.io/tx/0x16a133e34b1e9cda69b2c7b78f532b21c5e61baa0b17a769c57244182f7f449f) |
| 2 | `RestrictedTransferPolicy.executeSetSecundarioLiberado(token, true)` | [`0x9295e42b…1ac11a531f`](https://sepolia.etherscan.io/tx/0x9295e42b15e745b3e0d3fb4e74bf2433fe71e024abfd7a552542fc1ac11a531f) |
| 3 | `MockBRL.mint(comprador, 2,000 mBRL)` | [`0xf89813cd…9c59b69f42c7604a`](https://sepolia.etherscan.io/tx/0xf89813cd123ab464d807fda03005a47a947b1d59ae8e67209c59b69f42c7604a) |
| 4 | `MockBRL.approve(settlement, 2,000 mBRL)`: buyer | [`0x985a1e38…fccd548d48371ab8c8`](https://sepolia.etherscan.io/tx/0x985a1e384ec4bf291ab6bfe7f4893e449c32ac0057a882fccd548d48371ab8c8) |
| 5 | `ParticipacaoToken.approve(settlement, 20 shares)`: seller | [`0x524793d9…8673da367441636fe5892e2e8f73945`](https://sepolia.etherscan.io/tx/0x524793d90eae50c5718eb0677140c679d8673da367441636fe5892e2e8f73945) |
| 6 | **`LiquidacaoSecundaria.liquidarCessao(token, vendedor, comprador, 20 shares, 100 mBRL)`** | [`0xe338d6be…894c9fa3396bbadc26b`](https://sepolia.etherscan.io/tx/0xe338d6be53893a045370c7ecc9d50bac213a3ee9138f9894c9fa3396bbadc26b) |

## Assignment math

- `quantidade = 20 shares` × `precoPorCota = 100 mBRL` = **`2,000 mBRL`**.
- `taxaSecundarioBps = 0` (dormant) → `fee charged = 0`, `protocol receives 0`.
- Seller: `50 → 30 shares` (`-20`), `MockBRL: 0 → 2,000` (`+2,000`, the full amount, zero
  fee).
- Buyer: `0 → 20 shares` (`+20`), `MockBRL: 2,000 → 0` (`-2,000`, paid in full).
- Atomic swap via `allowance`: `LiquidacaoSecundaria` never held either asset;
  `moeda.transferFrom`/`token.transferFrom` moved funds directly between the parties in the
  same transaction.

Every value above (the seller's/buyer's share balance, the seller's/buyer's/protocol's
`MockBRL` balance, the token's current `transferPolicy()`, `secundarioLiberado`) was read
directly from the chain via `cast call`, not only from the script's console log, before this
document was written:

```
seller shares:    30000000000000000000 (30 shares)
buyer shares:     20000000000000000000 (20 shares)
seller MockBRL:   2000000000000000000000 (2,000 mBRL)
buyer MockBRL:    0
protocol MockBRL: 0
token transferPolicy: 0x8E1E7407D3771386c3fE7BF9E823e1A0E83B621E (RestrictedTransferPolicy)
secundarioLiberado: true
```

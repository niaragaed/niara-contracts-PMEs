# Public demo — Sepolia (Phase 2: fundraising with escrow)

> **Notice.** This is a demonstration on the **Sepolia testnet**. `MockBRL` is a test
> mock (unbacked, valueless, mintable at will) and **does not represent real money**.
> This code has **no published external audit** (full test coverage + fuzzing
> invariants, WITHOUT an external audit). **No mainnet deploy has been made or is
> planned in this phase.** The on-chain cap table here is a complementary evidentiary
> record: it does not replace the corporate books of Law 6,404/76 nor registration with a
> notary/commercial registry. The per-investor cap seen in this demo is only that
> offering's limit; CVM Resolution 88's annual cap across platforms is off-chain and
> self-declared.

## Deployed contracts

Deployed and verified via `script/DemoSepolia_Setup.s.sol` (the deployer acting as
admin/agent).

| Contract | Address | Etherscan |
|---|---|---|
| MockBRL | `0x9065C2cfaC52BbC3C452DAA7c51d8c2ec1698238` | [view](https://sepolia.etherscan.io/address/0x9065C2cfaC52BbC3C452DAA7c51d8c2ec1698238) |
| DenyAllTransferPolicy | `0x3c0AD53e2C76590d206674F58a4684643a33F09A` | [view](https://sepolia.etherscan.io/address/0x3c0AD53e2C76590d206674F58a4684643a33F09A) |
| ParticipacaoToken (implementation) | `0xA5fDb726CdE2dF76CD14128c642e200ae2fb42aA` | [view](https://sepolia.etherscan.io/address/0xA5fDb726CdE2dF76CD14128c642e200ae2fb42aA) |
| EmissaoGateway | `0x9C04980f37c5C6a2c1cec7BD5195cCA97c01B032` | [view](https://sepolia.etherscan.io/address/0x9C04980f37c5C6a2c1cec7BD5195cCA97c01B032) |
| ParticipacaoTokenFactory | `0x8c2385EDd6B15E98819043dFbd7D758096D0f42B` | [view](https://sepolia.etherscan.io/address/0x8c2385EDd6B15E98819043dFbd7D758096D0f42B) |
| RegistroInvestidorQualificado | `0x4F9c6E52D28c3d62FCF281dee78C6881967Cacbb` | [view](https://sepolia.etherscan.io/address/0x4F9c6E52D28c3d62FCF281dee78C6881967Cacbb) |
| OfertaCaptacao (implementation) | `0x6205a0641a9977fd262e32419C1B1938296A45D0` | [view](https://sepolia.etherscan.io/address/0x6205a0641a9977fd262e32419C1B1938296A45D0) |
| OfertaCaptacaoFactory | `0xAed0f51854c5EAF361b832F97948Cca1DFC4600C` | [view](https://sepolia.etherscan.io/address/0xAed0f51854c5EAF361b832F97948Cca1DFC4600C) |

EIP-1167 clones created via `script/DemoSepolia.s.sol` (minimal proxies; Etherscan
recognizes them automatically as proxies of the corresponding implementation above; the
real code lives in the implementations, already verified):

| Clone | Address | Points to | Etherscan |
|---|---|---|---|
| Token (ParticipacaoToken, "Oferta Demo Sepolia" / nCAP) | `0xa84259BCe4d35147f3E6dd7b9e9306410B9d2221` | ParticipacaoToken (implementation) | [view](https://sepolia.etherscan.io/address/0xa84259BCe4d35147f3E6dd7b9e9306410B9d2221) |
| Offering (OfertaCaptacao, escrow) | `0x452f271DBAF1140200Fd15fA38B99304D8F583Da` | OfertaCaptacao (implementation) | [view](https://sepolia.etherscan.io/address/0x452f271DBAF1140200Fd15fA38B99304D8F583Da) |

Wallets (not contracts, listed only for completeness; all burner, no real value):

| Role | Address |
|---|---|
| Deployer / admin / agent | `0xa26A9B4C4E9C176E76c785Ad25F699734488622C` |
| Investor 1 | `0xc04d8dF601340455ACFE442abCBa43c9C081270d` |
| Investor 2 | `0x75Ce20d974057Ab3c009e311938E557210bF88AA` |
| Issuer (receives the released funds) | `0xf1F6192A7DFE50cc888241Bc59902484d626c9aD` |
| Protocol (dormant fee = 0 in this demo) | `0xa26A9B4C4E9C176E76c785Ad25F699734488622C` (the same wallet as the deployer in this demo) |

## Transaction timeline

### Part 1 — `DemoSepolia_Setup.s.sol` (deploy + propose `AGENTE_ROLE`)

| # | Action | Tx hash |
|---|---|---|
| 1 | Deploy MockBRL | [`0xdee7c680…4465ae9`](https://sepolia.etherscan.io/tx/0xdee7c680d045ae433f71d061fba89fe68ce6cea79f3ece4af08561ddf4465ae9) |
| 2 | Deploy DenyAllTransferPolicy | [`0x85b62dce…980f8105`](https://sepolia.etherscan.io/tx/0x85b62dce589ffcc37a1cfe56c2bf9ef50cb9299e6da959bbfd6de2fc980f8105) |
| 3 | Deploy ParticipacaoToken (implementation) | [`0x1869bd1d…f81dddb`](https://sepolia.etherscan.io/tx/0x1869bd1d6137fbbf2ebaa6443547ef3f8b12ae2f4e6c88827428f0eedf81dddb) |
| 4 | Deploy EmissaoGateway | [`0x458c7696…3fdf7633…`](https://sepolia.etherscan.io/tx/0x458c769675fedc1ef353a525f4bd788d0df6f4f648b13d43fdf76339085f7141) |
| 5 | Deploy ParticipacaoTokenFactory | [`0xde7f4520…7a88b0`](https://sepolia.etherscan.io/tx/0xde7f4520044c9c306c89eb6649c396601ffbeaf85b4fb2112924b79c987a88b0) |
| 6 | Deploy RegistroInvestidorQualificado | [`0xa1694af7…7a7f0e`](https://sepolia.etherscan.io/tx/0xa1694af709763cdc5bf7bdcfa7d154de016fa4e6275394ab0cb169d8017a7f0e) |
| 7 | Deploy OfertaCaptacao (implementation) | [`0x83e21151…540962`](https://sepolia.etherscan.io/tx/0x83e2115186955592981651b522feb6c3943163c28d612c6ae5ec5206f0540962) |
| 8 | Deploy OfertaCaptacaoFactory | [`0x9b48a468…338519`](https://sepolia.etherscan.io/tx/0x9b48a4680a0d39784f44544cdcbb0c7c0d33c354dc2d8446210c10d290338519) |
| 9 | `EmissaoGateway.proposeGrantRole(AGENTE_ROLE, deployer)` | [`0xdc20d096…69ee6f2`](https://sepolia.etherscan.io/tx/0xdc20d09650fedae514bd76235754604abc12a6cd12a9389633b51b41469ee6f2) |
| 10 | `ParticipacaoTokenFactory.proposeGrantRole(AGENTE_ROLE, deployer)` | [`0x4db46b17…10d6940`](https://sepolia.etherscan.io/tx/0x4db46b17b08c2d9fa090b3aa17e637458a4a8953c7244a34816158eaf10d6940) |
| 11 | `RegistroInvestidorQualificado.proposeGrantRole(AGENTE_ROLE, deployer)` | [`0x78ed475c…0de331d`](https://sepolia.etherscan.io/tx/0x78ed475ca08a5c8cb6e7ba9a3a2f02e1d50a3661b3e9b21c07c4a27d80de331d) |
| 12 | `OfertaCaptacaoFactory.proposeGrantRole(AGENTE_ROLE, deployer)` | [`0xc7f49c0b…33db3b5`](https://sepolia.etherscan.io/tx/0xc7f49c0b051e6399c5e9215d9bbb9eb589cb2f836e61e1999ff937be033db3b5) |

All 8 contracts in rows 1–8 were verified on Sepolia Etherscan (`forge script --verify`).

**Real timelock wait**: the `AGENTE_ROLE` proposals above stayed pending for
`MIN_TIMELOCK_DELAY = 1 hours` (`TimelockedAccessControl`), real wall-clock time on the
chain, which cannot be simulated in a real broadcast. On-chain `executeAfter`:
`1785535620` (2026-07-31 22:07:00 UTC), confirmed by reading
`EmissaoGateway.pendingActions` directly before moving on to part 2.

### Part 2 — `DemoSepolia.s.sol` (execute `AGENTE_ROLE` + full cycle)

| # | Action | Tx hash |
|---|---|---|
| 1 | `EmissaoGateway.executeGrantRole(AGENTE_ROLE, deployer)` | [`0xc46aeabb…5bf000177`](https://sepolia.etherscan.io/tx/0xc46aeabbd6e8f5189a220007d2702ce62c6894d175b6d5b53c7be6f5bf000177) |
| 2 | `ParticipacaoTokenFactory.executeGrantRole(AGENTE_ROLE, deployer)` | [`0x40545fbf…60bbd8955`](https://sepolia.etherscan.io/tx/0x40545fbf44b4632b85d1526540d4ee74b6bb5a56886e246bf81e0d660bbd8955) |
| 3 | `OfertaCaptacaoFactory.executeGrantRole(AGENTE_ROLE, deployer)` | [`0xe20a7b37…8d2ba56e8`](https://sepolia.etherscan.io/tx/0xe20a7b374748770174ff0d1c022daed6007c234964b2b60fbd418d68d2ba56e8) |
| 4 | `ParticipacaoTokenFactory.criarOferta(...)` → token | [`0xbe9767e8…10d696b64`](https://sepolia.etherscan.io/tx/0xbe9767e8adb86a9d942a839617d376a8682548c72bcb3c283b1abd510d696b64) |
| 5 | `EmissaoGateway.atestarCotas(token, 50 shares)` | [`0xd7386c07…eb2205cb3`](https://sepolia.etherscan.io/tx/0xd7386c07ce2a62cc43940d73c1fc5822e49166a1fea34ef57b6c01eeb2205cb3) |
| 6 | `OfertaCaptacaoFactory.criarCaptacao(...)` → offering | [`0xd4fb493b…dc47a6ff76`](https://sepolia.etherscan.io/tx/0xd4fb493b834484e041f0c14a4425bbbff6fbfc99217e0a160ef3cddc47a6ff76) |
| 7 | `EmissaoGateway.registrarCaptacao(token, oferta)` | [`0x5fae0557…731ac4dbee8cf3d83f`](https://sepolia.etherscan.io/tx/0x5fae0557179187c3f03fd805b60efbe17baaacb625680b731ac4dbee8cf3d83f) |
| 8 | `MockBRL.mint(investor1, 3000 mBRL)` | [`0x89ee237c…8bf4d902a9283`](https://sepolia.etherscan.io/tx/0x89ee237c2e6fe2347ff6482bb031889d08aed5d61945bffdc8e8bf4d902a9283) |
| 9 | `MockBRL.mint(investor2, 2000 mBRL)` | [`0xa14ce17c…7325bdf456`](https://sepolia.etherscan.io/tx/0xa14ce17c70ca2cd4ec31da9e3b7d041f46231d2d4ea8221c50c7607325bdf456) |
| 10 | `MockBRL.approve(oferta, 3000 mBRL)`: investor 1 | [`0x049667b8…9745cad8a8be`](https://sepolia.etherscan.io/tx/0x049667b83146f724d57a035a9cb5c3a6421847674c3a0247d6f09745cad8a8be) |
| 11 | **`OfertaCaptacao.aportar(3000 mBRL)`**: investor 1 | [`0x6491ae4d…d0279e2370554c80`](https://sepolia.etherscan.io/tx/0x6491ae4dc53e9d24f8f1f0166a2d45f99da55b08d3492324d0279e2370554c80) |
| 12 | `MockBRL.approve(oferta, 2000 mBRL)`: investor 2 | [`0x9bf065fc…1c2272473`](https://sepolia.etherscan.io/tx/0x9bf065fcb7a0d16ec8e246396c1ce84ce852ad1c9156f35eb9c4f5c1c2272473) |
| 13 | **`OfertaCaptacao.aportar(2000 mBRL)`**: investor 2 | [`0xbe5c70ca…d1829eb4e295e1572`](https://sepolia.etherscan.io/tx/0xbe5c70ca86e1ade2a373b40e0adb2f5b062bbc260a6d520d1829eb4e295e1572) |
| 14 | **`OfertaCaptacao.encerrar()`** → EncerradaSucesso | [`0x0d1e5a14…0179e9322692d`](https://sepolia.etherscan.io/tx/0x0d1e5a144804c9a43af5d69873db5c698dc80863aa6285c0dd00179e9322692d) |
| 15 | **`OfertaCaptacao.resgatarCotas()`**: investor 1 (30 shares) | [`0x7e7bea6a…6d508f8e4b630eef3`](https://sepolia.etherscan.io/tx/0x7e7bea6aeb9bf8a38094c7a8633ba4ebff66d587dedda3a6d508f8e4b630eef3) |
| 16 | **`OfertaCaptacao.resgatarCotas()`**: investor 2 (20 shares) | [`0x274cd295…99ff49a4d675a1f4b`](https://sepolia.etherscan.io/tx/0x274cd29565bd760e0056a9e3a0dde13bc90260babf5502d99ff49a4d675a1f4b) |
| 17 | **`OfertaCaptacao.liberarParaEmissor()`** | [`0x212b95cd…dfa495715291`](https://sepolia.etherscan.io/tx/0x212b95cd6ce9e2eba913423bf951b8bcd376b38b34ffd7baf831dfa495715291) |

## Closing math

- Investments: `3,000 mBRL` (investor 1) + `2,000 mBRL` (investor 2) = **`5,000 mBRL`
  raised** = exactly `metaMaxima` → early close from full subscription (without waiting
  for the 1-day deadline).
- `precoPorCota = 100 mBRL` → **50 shares issued** on redemption: `30` to investor 1
  (`3,000 / 100`), `20` to investor 2 (`2,000 / 100`). `token.totalSupply() = 50 ether`
  (50 shares on the ERC-20's 18-decimal scale, confirmed on-chain).
- `taxaBps = 0` (dormant) → on release, **the full `5,000 mBRL` went to the issuer's
  wallet**, `0` to the protocol wallet.
- The escrow (`OfertaCaptacao`) closed with a **`0 mBRL`** balance, confirmed by reading
  on-chain directly (`MockBRL.balanceOf(oferta)`) after `liberarParaEmissor()`, not only
  from the script log.

Every value above (`totalSupply`, each investor's share balance, the issuer's mBRL balance,
the escrow's residual balance, the offering's final state) was read directly from the chain
via `cast call`, not only from the script's console log, before this document was written.

## Self-service deploy (`OfertaOrquestrador`) — `DeployFase2Sepolia` + `DeployFase2SepoliaExecute`

A newer flow, separate from the demo above: instead of the AGENT creating each offering
manually (`ParticipacaoTokenFactory.criarOferta` → `atestarCotas` → `criarCaptacao` →
`registrarCaptacao`), the issuing company itself (previously authorized) creates its
offering in a single transaction, via `OfertaOrquestrador.criarOfertaCompleta`. Two scripts,
with no private key in an environment variable anywhere: the single signer of each one is
resolved by `--account` on the command line:

1. **`script/DeployFase2Sepolia.s.sol`**: deploys the 8 Phase 2 contracts +
   `OfertaOrquestrador`, and PROPOSES (does not execute) `AGENTE_ROLE` in 5 relationships:
   the orchestrator on `tokenFactory`/`gateway`/`captacaoFactory`, the admin on the
   orchestrator itself, and the admin on `RegistroInvestidorQualificado` (a prerequisite for
   `definirQualificado`, needed for any investor who must invest above an offering's
   `tetoPorInvestidor`; grouped here because it goes through the same 1h timelock as the
   other four grants). It persists the 9 addresses in `./script/output/fase2-sepolia.json`.
   Env: `PROTOCOLO_WALLET_ADDRESS`, `TAXA_BPS_ORQUESTRADOR` (required, 1–100; see the
   warning below), `TETO_POR_INVESTIDOR_ORQUESTRADOR` (required). None has a fallback.
2. A real wait of >= 1h (the timelock cannot be skipped on a real network: `vm.warp` does
   not affect the clock of a real chain receiving transactions).
3. **`script/DeployFase2SepoliaExecute.s.sol`**: reads the 9 addresses from the JSON above
   (never typed in via env, so as not to risk pointing at the wrong contract), executes the
   5 pending grants, and authorizes the first issuer (`EMISSOR_WALLET_ADDRESS`) to operate the
   self-service channel. Idempotent: it can be run more than once without breaking.
4. After that, the **authorized issuer signs its own transaction** (`cast send
   <OfertaOrquestrador> "criarOfertaCompleta(...)" ... --account <issuer account>`) to
   create its offering; it does not go through any script in this repository. The same
   goes for the investors who invest in it afterwards: each actor signs with their own
   wallet, proof that they are distinct parties with no privilege over each other.

> ⚠️ **`taxaBps` cannot be `0` in this flow, and it is stored immutably per offering.**
> `OfertaOrquestrador.taxaBps` (a platform parameter, swappable via timelock) is copied
> into `OfertaCaptacao.taxaBps` at the exact moment of `criarOfertaCompleta`, and
> `OfertaCaptacao.sol` **has no setter** for that field after `initialize()` (checked in the
> source code: it is assigned exactly once, in `initialize`, and never reassigned). Once
> created, an offering with the wrong `taxaBps` **cannot be corrected**: the only remedy is
> to fix `OfertaOrquestrador.taxaBps` via `proposeSetTaxaBps`/`executeSetTaxaBps` (which only
> affects **future** offerings) and create a new offering. That is why
> `DeployFase2Sepolia.s.sol` rejects `TAXA_BPS_ORQUESTRADOR == 0`: with a dormant fee,
> `OfertaCaptacao.liberarParaEmissor` skips the transfer leg to the protocol entirely
> (`if (taxa > 0)`), and the revenue split would never show up on Etherscan; the whole point
> of this phase is to prove that split on-chain.

## Results — first real self-service offering ("Padaria Silva")

Run on 2026-09-24. Infrastructure deployed by `DeployFase2Sepolia.s.sol` +
`DeployFase2SepoliaExecute.s.sol` (deployer/admin signing); the offering itself was created
and operated by wallets **distinct** from the deployer: the issuer and the investors signed
their own transactions, none of them with any privileged role on the contracts.

### Deployed infrastructure (addresses from `script/output/fase2-sepolia.json`)

`script/output/fase2-sepolia.json` is gitignored (regenerated on each deploy, see "Local
commit" in `CLAUDE.md`); the addresses below are the permanent copy, checked line by line
against `broadcast/DeployFase2Sepolia.s.sol/11155111/run-latest.json`.

| Contract | Address | Etherscan |
|---|---|---|
| MockBRL | `0xEC377e00e022675B67Da6ab1966Bc0764bF792A4` | [view](https://sepolia.etherscan.io/address/0xEC377e00e022675B67Da6ab1966Bc0764bF792A4) |
| DenyAllTransferPolicy | `0xC763cd522B8D4632ccd1adE698BAD09Be22f6a69` | [view](https://sepolia.etherscan.io/address/0xC763cd522B8D4632ccd1adE698BAD09Be22f6a69) |
| ParticipacaoToken (implementation) | `0x367D71E1A578a1Ac061991aCa8f302f9119dB603` | [view](https://sepolia.etherscan.io/address/0x367D71E1A578a1Ac061991aCa8f302f9119dB603) |
| EmissaoGateway | `0xeaedcAea403F793AFf6c345a5321c05eE55Cb1FE` | [view](https://sepolia.etherscan.io/address/0xeaedcAea403F793AFf6c345a5321c05eE55Cb1FE) |
| ParticipacaoTokenFactory | `0xA116Aeb034633ef58AF68A387778C59f99FE9539` | [view](https://sepolia.etherscan.io/address/0xA116Aeb034633ef58AF68A387778C59f99FE9539) |
| RegistroInvestidorQualificado | `0x5BE2cF3f1aeA02987Bea87a635FC9ba7BdF04732` | [view](https://sepolia.etherscan.io/address/0x5BE2cF3f1aeA02987Bea87a635FC9ba7BdF04732) |
| OfertaCaptacao (implementation) | `0x46c6690Db2Ad39AF5Fa29581Ed01172a65949656` | [view](https://sepolia.etherscan.io/address/0x46c6690Db2Ad39AF5Fa29581Ed01172a65949656) |
| OfertaCaptacaoFactory | `0x5E248656516140360ADEFB66c1095ef0951e45cB` | [view](https://sepolia.etherscan.io/address/0x5E248656516140360ADEFB66c1095ef0951e45cB) |
| **OfertaOrquestrador** | `0xde9cC84d1300b57F640f2d1862900393b82796e5` | [view](https://sepolia.etherscan.io/address/0xde9cC84d1300b57F640f2d1862900393b82796e5) |

`OfertaOrquestrador` was deployed with
`protocoloWallet = 0x9780270d42FD834872C80E57024221A33d3ACd08`, `taxaBps = 100` (1%, the
hard cap `TAXA_BPS_MAXIMA`), `tetoPorInvestidor = 20_000 ether` (the same value as CVM
Resolution 88's annual retail cap: a deliberate parameter coincidence, not a real
cross-check; see "Limitations" below) and `timelockDelay = 3600` seconds (1h; see the note on
`TIMELOCK_DELAY` in `CLAUDE.md`).

Wallets (all burner, no real value):

| Role | Address |
|---|---|
| Deployer / admin / orchestrator agent | `0x9e3d33E905a87FC86A6b84d13176240A22C8FBF8` |
| Issuer ("Padaria Silva", authorized via `autorizarEmissor`) | `0x47d9de93F15E1ebfbEFD5F32c0076cf3090C63c6` |
| Protocol (receives the 1% fee) | `0x9780270d42FD834872C80E57024221A33d3ACd08` |
| Investor 1 (qualified via `definirQualificado`) | `0x21443ADa1d36e5DCAadD62896Ca2c21aDFE396E1` |
| Investor 2 (qualified via `definirQualificado`) | `0x5a71bA5a602791add4722Aa485b1b68f7BB4ae10` |

### Timeline — Part 1: `DeployFase2Sepolia.s.sol` (deploy + propose 5 roles)

| # | Action | Tx hash |
|---|---|---|
| 1 | Deploy MockBRL | [`0xc6f273c2…618466`](https://sepolia.etherscan.io/tx/0xc6f273c24d5ab141e3b903b34bfd67e4b18af85901fa497500442d72fd618466) |
| 2 | Deploy DenyAllTransferPolicy | [`0x7951655b…c3715b`](https://sepolia.etherscan.io/tx/0x7951655b195606c0ac8427d402f5792ec1c05880a218e3402804eaa2d8c3715b) |
| 3 | Deploy ParticipacaoToken (implementation) | [`0x94956781…3ec478`](https://sepolia.etherscan.io/tx/0x949567812ab42d2daf4349f97fe26aa21fb32c65e560981342031691973ec478) |
| 4 | Deploy EmissaoGateway | [`0x7248016e…e34657`](https://sepolia.etherscan.io/tx/0x7248016e1525f7706f1c6ab7b8f213d463289a79c08e2eeab9f0271025e34657) |
| 5 | Deploy ParticipacaoTokenFactory | [`0xd1cff5b5…c9b55e`](https://sepolia.etherscan.io/tx/0xd1cff5b50a893eb99a355fcb0d9541d32064eb2f1862984d191892c11cc9b55e) |
| 6 | Deploy RegistroInvestidorQualificado | [`0xae2d4133…78057e`](https://sepolia.etherscan.io/tx/0xae2d413354060d0fcbba6adaadfc7c08749a0a5f11a0397684bb47b6bd78057e) |
| 7 | Deploy OfertaCaptacao (implementation) | [`0x23d40e9f…feb224`](https://sepolia.etherscan.io/tx/0x23d40e9ff77eab27ef8355a5265e145af5d013b94392a0b19033c9f64efeb224) |
| 8 | Deploy OfertaCaptacaoFactory | [`0xe7c62301…3112ad`](https://sepolia.etherscan.io/tx/0xe7c62301b524e7f462925aba167f7bf46411feb2078e43a7ba91b2087a3112ad) |
| 9 | Deploy OfertaOrquestrador | [`0x87e4ab0e…e282ed`](https://sepolia.etherscan.io/tx/0x87e4ab0ee73dd189fc311e98cf95a38f20a3488e6139e8d3dd8c932859e282ed) |
| 10 | `ParticipacaoTokenFactory.proposeGrantRole(AGENTE_ROLE, orchestrator)` | [`0x3508a9b3…741831`](https://sepolia.etherscan.io/tx/0x3508a9b3ad6d3d4d44a3e35836cde929fd429cdff8fdd8d1d710941407741831) |
| 11 | `EmissaoGateway.proposeGrantRole(AGENTE_ROLE, orchestrator)` | [`0xab2a75cb…d0fa00`](https://sepolia.etherscan.io/tx/0xab2a75cbe4358670bfaa3091b91a9d1fbdd7d1faaa08022cdbf9d0c99bd0fa00) |
| 12 | `OfertaCaptacaoFactory.proposeGrantRole(AGENTE_ROLE, orchestrator)` | [`0xc77b1b87…50a470`](https://sepolia.etherscan.io/tx/0xc77b1b87b61eb52492d22b94e8b2818fd437cb2b255d12c26e9743da6150a470) |
| 13 | `OfertaOrquestrador.proposeGrantRole(AGENTE_ROLE, admin)` | [`0x20c93273…ba70c5`](https://sepolia.etherscan.io/tx/0x20c932734bafb5de48a3a11aec7902014aed9eb043637aa4a11d726c13ba70c5) |
| 14 | `RegistroInvestidorQualificado.proposeGrantRole(AGENTE_ROLE, admin)` | [`0x37df452e…b991cd`](https://sepolia.etherscan.io/tx/0x37df452e02092630d772ca6c3f9943fa41c5be9c6dd223555347aff19fb991cd) |

**Real timelock wait**: the 5 proposals above stayed pending for 1h of real wall-clock time
(the same mechanics already used in the earlier phases: `vm.warp` does not exist outside
`forge test`).

### Timeline — Part 2: `DeployFase2SepoliaExecute.s.sol` (execute the 5 roles + authorize the issuer)

| # | Action | Tx hash |
|---|---|---|
| 1 | `ParticipacaoTokenFactory.executeGrantRole(AGENTE_ROLE, orchestrator)` | [`0x8b7c4bed…a2388a`](https://sepolia.etherscan.io/tx/0x8b7c4bed9ec43b084cdbe59c499486f13fac979bc5f18dd5a72a9e2ab3a2388a) |
| 2 | `EmissaoGateway.executeGrantRole(AGENTE_ROLE, orchestrator)` | [`0x33a0965f…34bd8f`](https://sepolia.etherscan.io/tx/0x33a0965f35954e3a4b2fef87411bd4fd9268ca1cc69848551b8acbd28634bd8f) |
| 3 | `OfertaCaptacaoFactory.executeGrantRole(AGENTE_ROLE, orchestrator)` | [`0xe753dc1d…ed1f44`](https://sepolia.etherscan.io/tx/0xe753dc1dc7f5a6013d37624ae322a0109f573da8d52b606e76ea909c01ed1f44) |
| 4 | `OfertaOrquestrador.executeGrantRole(AGENTE_ROLE, admin)` | [`0x84560fe1…f9a13b`](https://sepolia.etherscan.io/tx/0x84560fe1796c84c81b92a6bb76488667f002bd5971abadc775a175bffef9a13b) |
| 5 | `RegistroInvestidorQualificado.executeGrantRole(AGENTE_ROLE, admin)` | [`0xf773d86a…edbcaa`](https://sepolia.etherscan.io/tx/0xf773d86af3af5b179b53c5ca6e1619b50f308a4486585d97d642d09b84edbcaa) |
| 6 | `OfertaOrquestrador.autorizarEmissor(emissor)` | [`0x05686377…99e212`](https://sepolia.etherscan.io/tx/0x056863778275553d47e211d35e54d2b4709cd75d6954bfdd3ff121499099e212) |

### Timeline — Part 3: actions signed outside the scripts (issuer and investors)

None of the transactions below goes through this repository: each actor signed with their
own wallet, directly via `cast send`/their own wallet, exactly as described in the previous
section. Only the two central transactions have their hash recorded here; investments,
closing and redemptions were checked by reading state (`cast call`), not listed
individually.

| Action | Who signs | Tx hash |
|---|---|---|
| **`OfertaOrquestrador.criarOfertaCompleta(...)`**: creates the PSILVA token + the "Padaria Silva" offering in a single transaction | issuer (`0x47d9…C63c6`) | [`0xcbe401ab…ded8dd`](https://sepolia.etherscan.io/tx/0xcbe401ab61de636816b8c009e0ecfec389b9b3b35ac11d72b0aaf8e792ded8dd) |
| `RegistroInvestidorQualificado.definirQualificado` (2x, one per investor) | admin | not listed; only the effect (`ehQualificado == true`) was checked via `cast call` |
| `MockBRL.mint` + `.approve` + `OfertaCaptacao.aportar` (2x, one per investor) | investor 1, investor 2 | not listed; only the final `totalArrecadado` was checked via `cast call` |
| `OfertaCaptacao.encerrar()` → `EncerradaSucesso` | any account (permissionless) | not listed; only the final `estado()` was checked via `cast call` |
| `OfertaCaptacao.resgatarCotas()` (2x, one per investor) | investor 1, investor 2 | not listed; only `token.balanceOf`/`totalSupply` were checked via `cast call` |
| **`OfertaCaptacao.liberarParaEmissor()`**: splits the amount raised between protocol and issuer | any account (permissionless) | [`0xe4efcb14…de4baf`](https://sepolia.etherscan.io/tx/0xe4efcb14198eabfc87ae59e8f99e55099b6e04786f26e40788eed27cc6de4baf) |

Contracts created at runtime by the central transaction (clone addresses, not deployed by
any script; they come from `Clones.clone` inside `criarOfertaCompleta`):

| | Address | Etherscan |
|---|---|---|
| Token (ParticipacaoToken, "PSILVA") | `0x76d8e88fe48Bfab2f2EEd7196321B2886750298D` | [view](https://sepolia.etherscan.io/address/0x76d8e88fe48Bfab2f2EEd7196321B2886750298D) |
| Offering (OfertaCaptacao, "Padaria Silva" escrow) | `0x6587265f971Aa555106D64e3422Ee901A0D20546` | [view](https://sepolia.etherscan.io/address/0x6587265f971Aa555106D64e3422Ee901A0D20546) |

Offering terms: minimum target R$ 500,000, maximum target R$ 600,000 (an additional lot of
exactly 20% over the minimum, within CVM Resolution 88's 25% limit), price per share
R$ 1,000, a 90-day deadline (within the 180-day limit).

### Results verified on-chain (`cast call`, not only the script logs)

- `hasRole(AGENTE_ROLE, emissor)` → **`false`** on `ParticipacaoTokenFactory`,
  `EmissaoGateway` and `OfertaCaptacaoFactory`: the issuer never held, at any moment, the
  privileged role that creating the offering requires; only `OfertaOrquestrador` holds it,
  and it acted on the issuer's behalf within a single atomic transaction signed by the
  issuer.
- `totalArrecadado = R$ 600,000` (exactly `metaMaxima`) → early close from full
  subscription, the same pattern already seen in the manual demo above.
- After `liberarParaEmissor()`: the protocol wallet with **R$ 6,000** (1% of R$ 600,000,
  `taxaBps = 100`) and the issuer's wallet with **R$ 594,000** (the remaining 99%): the first
  time, in this line of demos, that the fee split shows a non-zero value on-chain (the
  manual Phase 2 demo above used `taxaBps = 0` on purpose).
- `token.totalSupply() = 600 ether` (600 shares on the 18-decimal scale), exactly equal to
  the token's `cotasAutorizadas()`: no share "left over" or "missing" relative to what the
  `EmissaoGateway` attested at creation time.

## Demo script

Suggested order of links to open (all on Sepolia Etherscan), with what to say at each:

1. **Verified `OfertaOrquestrador`** (address in the table above). "This is the new
   contract: before, only the platform (the AGENT) could create an offering, by calling 4
   functions on 3 different contracts. Now an authorized company does it on its own, in a
   single transaction."
2. **The central transaction** (`criarOfertaCompleta`, hash above). Point to the **From**
   field: it is the issuer's wallet, not the deployer/admin's. "Whoever signs this
   transaction is Padaria Silva itself; the 'From' field is not the platform."
3. In the **"Internal Txns"** tab of that same transaction: show the 4 subcalls
   (`criarOferta` → `atestarCotas` → `criarCaptacao` → `registrarCaptacao`) happening
   inside the same transaction. "All of this is atomic: if any of them had failed, nothing
   would have been created, neither the token nor the offering" (see the two atomicity
   tests in `test/OfertaOrquestrador.t.sol`, reinforced in this phase).
4. **Read Contract** on `ParticipacaoTokenFactory`/`EmissaoGateway`/`OfertaCaptacaoFactory`,
   calling `hasRole` with `AGENTE_ROLE` and the issuer's address → shows `false` live. "The
   issuer never had this role; only the orchestrator did, and it used it on the issuer's
   behalf."
5. **PSILVA token** and **"Padaria Silva" offering** (addresses above): both recognized by
   Etherscan as proxies (EIP-1167) of the same implementations already verified in the
   manual demo. "Same code, a different creation path."
6. **`liberarParaEmissor()`** (hash above) → the **"ERC-20 Token Txns"** or **"Internal
   Txns"** tab: show the two `MockBRL` transfers leaving the escrow: R$ 6,000 to the
   protocol wallet, R$ 594,000 to the issuer's wallet. "This is the first time this fee
   split shows a non-zero value on-chain: 1%, the maximum cap the contract itself allows."
7. Close with `token.totalSupply()` in **Read Contract** = 600 shares, matching
   `metaMaxima / precoPorCota`.

## Limitations of this demo

- **Unbacked testnet.** Sepolia ETH and `MockBRL` have no real value; no real security was
  offered.
- **Annual caps are off-chain.** Neither the R$ 20,000/year retail investor cap nor the
  issuer's aggregate cap across platforms (CVM Resolution 88) is checked by this contract
  across platforms: `tetoPorInvestidor` is only **this offering's** limit, and
  `OfertaOrquestrador` documents explicitly in its NatSpec that it does not and cannot have
  visibility into what an issuer has already raised on another platform (see
  `src/orquestracao/OfertaOrquestrador.sol`, the contract NatSpec).
- **`taxaBps` is immutable per clone.** Once created, a specific offering's fee can no
  longer be changed; only future offerings inherit a new `taxaBps` (see the warning above).
- **No external audit.** Test coverage + invariant fuzzing, with no third-party review.
- **Both investors were qualified manually.** `definirQualificado` was called for both
  investor wallets specifically to allow investments above the R$ 20,000 cap per
  non-qualified investor (`tetoPorInvestidor`); without it, neither could have invested the
  R$ 300,000 they did. In production, investor qualification is a real regulatory process
  (CVM Resolution 30), not a demo button.

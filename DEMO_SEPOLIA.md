# Demo pública — Sepolia (Fase 2: captação com escrow)

> **Aviso.** Isto é uma demonstração em **testnet Sepolia**. `MockBRL` é um mock de
> teste — sem lastro, sem valor, mintável à vontade — e **não representa dinheiro
> real**. Este código **não tem auditoria externa publicada** (cobertura total de
> testes + invariantes por fuzzing, SEM auditoria externa). **Nenhum deploy em
> mainnet foi feito ou está planejado nesta fase.** O cap table on-chain aqui é
> registro probatório complementar — não substitui os livros societários da Lei
> 6.404/76 nem o registro em cartório/junta comercial. O teto por investidor
> observado nesta demo é só o limite daquela oferta; o teto anual cruzado entre
> plataformas da Resolução CVM 88 é off-chain e auto-declaratório.

## Contratos implantados

Implantados e verificados via `script/DemoSepolia_Setup.s.sol` (deployer atuando
como admin/agente).

| Contrato | Endereço | Etherscan |
|---|---|---|
| MockBRL | `0x9065C2cfaC52BbC3C452DAA7c51d8c2ec1698238` | [ver](https://sepolia.etherscan.io/address/0x9065C2cfaC52BbC3C452DAA7c51d8c2ec1698238) |
| DenyAllTransferPolicy | `0x3c0AD53e2C76590d206674F58a4684643a33F09A` | [ver](https://sepolia.etherscan.io/address/0x3c0AD53e2C76590d206674F58a4684643a33F09A) |
| ParticipacaoToken (implementação) | `0xA5fDb726CdE2dF76CD14128c642e200ae2fb42aA` | [ver](https://sepolia.etherscan.io/address/0xA5fDb726CdE2dF76CD14128c642e200ae2fb42aA) |
| EmissaoGateway | `0x9C04980f37c5C6a2c1cec7BD5195cCA97c01B032` | [ver](https://sepolia.etherscan.io/address/0x9C04980f37c5C6a2c1cec7BD5195cCA97c01B032) |
| ParticipacaoTokenFactory | `0x8c2385EDd6B15E98819043dFbd7D758096D0f42B` | [ver](https://sepolia.etherscan.io/address/0x8c2385EDd6B15E98819043dFbd7D758096D0f42B) |
| RegistroInvestidorQualificado | `0x4F9c6E52D28c3d62FCF281dee78C6881967Cacbb` | [ver](https://sepolia.etherscan.io/address/0x4F9c6E52D28c3d62FCF281dee78C6881967Cacbb) |
| OfertaCaptacao (implementação) | `0x6205a0641a9977fd262e32419C1B1938296A45D0` | [ver](https://sepolia.etherscan.io/address/0x6205a0641a9977fd262e32419C1B1938296A45D0) |
| OfertaCaptacaoFactory | `0xAed0f51854c5EAF361b832F97948Cca1DFC4600C` | [ver](https://sepolia.etherscan.io/address/0xAed0f51854c5EAF361b832F97948Cca1DFC4600C) |

Clones EIP-1167 criados via `script/DemoSepolia.s.sol` (minimal proxies — Etherscan
os reconhece automaticamente como proxy da implementação correspondente acima; código
de verdade fica nas implementações, já verificadas):

| Clone | Endereço | Aponta para | Etherscan |
|---|---|---|---|
| Token (ParticipacaoToken, "Oferta Demo Sepolia" / nCAP) | `0xa84259BCe4d35147f3E6dd7b9e9306410B9d2221` | ParticipacaoToken (implementação) | [ver](https://sepolia.etherscan.io/address/0xa84259BCe4d35147f3E6dd7b9e9306410B9d2221) |
| Oferta (OfertaCaptacao, escrow) | `0x452f271DBAF1140200Fd15fA38B99304D8F583Da` | OfertaCaptacao (implementação) | [ver](https://sepolia.etherscan.io/address/0x452f271DBAF1140200Fd15fA38B99304D8F583Da) |

Carteiras (não são contratos, listadas só por completude — todas burner, sem valor
real):

| Papel | Endereço |
|---|---|
| Deployer / admin / agente | `0xa26A9B4C4E9C176E76c785Ad25F699734488622C` |
| Investidor 1 | `0xc04d8dF601340455ACFE442abCBa43c9C081270d` |
| Investidor 2 | `0x75Ce20d974057Ab3c009e311938E557210bF88AA` |
| Emissor (recebe recursos liberados) | `0xf1F6192A7DFE50cc888241Bc59902484d626c9aD` |
| Protocolo (taxa dormente = 0 nesta demo) | `0xa26A9B4C4E9C176E76c785Ad25F699734488622C` (mesma carteira do deployer nesta demo) |

## Cronologia de transações

### Parte 1 — `DemoSepolia_Setup.s.sol` (deploy + propõe `AGENTE_ROLE`)

| # | Ação | Tx hash |
|---|---|---|
| 1 | Deploy MockBRL | [`0xdee7c680…4465ae9`](https://sepolia.etherscan.io/tx/0xdee7c680d045ae433f71d061fba89fe68ce6cea79f3ece4af08561ddf4465ae9) |
| 2 | Deploy DenyAllTransferPolicy | [`0x85b62dce…980f8105`](https://sepolia.etherscan.io/tx/0x85b62dce589ffcc37a1cfe56c2bf9ef50cb9299e6da959bbfd6de2fc980f8105) |
| 3 | Deploy ParticipacaoToken (implementação) | [`0x1869bd1d…f81dddb`](https://sepolia.etherscan.io/tx/0x1869bd1d6137fbbf2ebaa6443547ef3f8b12ae2f4e6c88827428f0eedf81dddb) |
| 4 | Deploy EmissaoGateway | [`0x458c7696…3fdf7633…`](https://sepolia.etherscan.io/tx/0x458c769675fedc1ef353a525f4bd788d0df6f4f648b13d43fdf76339085f7141) |
| 5 | Deploy ParticipacaoTokenFactory | [`0xde7f4520…7a88b0`](https://sepolia.etherscan.io/tx/0xde7f4520044c9c306c89eb6649c396601ffbeaf85b4fb2112924b79c987a88b0) |
| 6 | Deploy RegistroInvestidorQualificado | [`0xa1694af7…7a7f0e`](https://sepolia.etherscan.io/tx/0xa1694af709763cdc5bf7bdcfa7d154de016fa4e6275394ab0cb169d8017a7f0e) |
| 7 | Deploy OfertaCaptacao (implementação) | [`0x83e21151…540962`](https://sepolia.etherscan.io/tx/0x83e2115186955592981651b522feb6c3943163c28d612c6ae5ec5206f0540962) |
| 8 | Deploy OfertaCaptacaoFactory | [`0x9b48a468…338519`](https://sepolia.etherscan.io/tx/0x9b48a4680a0d39784f44544cdcbb0c7c0d33c354dc2d8446210c10d290338519) |
| 9 | `EmissaoGateway.proposeGrantRole(AGENTE_ROLE, deployer)` | [`0xdc20d096…69ee6f2`](https://sepolia.etherscan.io/tx/0xdc20d09650fedae514bd76235754604abc12a6cd12a9389633b51b41469ee6f2) |
| 10 | `ParticipacaoTokenFactory.proposeGrantRole(AGENTE_ROLE, deployer)` | [`0x4db46b17…10d6940`](https://sepolia.etherscan.io/tx/0x4db46b17b08c2d9fa090b3aa17e637458a4a8953c7244a34816158eaf10d6940) |
| 11 | `RegistroInvestidorQualificado.proposeGrantRole(AGENTE_ROLE, deployer)` | [`0x78ed475c…0de331d`](https://sepolia.etherscan.io/tx/0x78ed475ca08a5c8cb6e7ba9a3a2f02e1d50a3661b3e9b21c07c4a27d80de331d) |
| 12 | `OfertaCaptacaoFactory.proposeGrantRole(AGENTE_ROLE, deployer)` | [`0xc7f49c0b…33db3b5`](https://sepolia.etherscan.io/tx/0xc7f49c0b051e6399c5e9215d9bbb9eb589cb2f836e61e1999ff937be033db3b5) |

Todos os 8 contratos das linhas 1–8 foram verificados no Sepolia Etherscan
(`forge script --verify`).

**Espera real do timelock**: as propostas de `AGENTE_ROLE` acima ficaram pendentes
por `MIN_TIMELOCK_DELAY = 1 hours` (`TimelockedAccessControl`) — tempo de relógio
real na chain, não simulável em broadcast de verdade. `executeAfter` on-chain:
`1785535620` (2026-07-31 22:07:00 UTC), confirmado via leitura direta de
`EmissaoGateway.pendingActions` antes de prosseguir para a parte 2.

### Parte 2 — `DemoSepolia.s.sol` (executa `AGENTE_ROLE` + ciclo completo)

| # | Ação | Tx hash |
|---|---|---|
| 1 | `EmissaoGateway.executeGrantRole(AGENTE_ROLE, deployer)` | [`0xc46aeabb…5bf000177`](https://sepolia.etherscan.io/tx/0xc46aeabbd6e8f5189a220007d2702ce62c6894d175b6d5b53c7be6f5bf000177) |
| 2 | `ParticipacaoTokenFactory.executeGrantRole(AGENTE_ROLE, deployer)` | [`0x40545fbf…60bbd8955`](https://sepolia.etherscan.io/tx/0x40545fbf44b4632b85d1526540d4ee74b6bb5a56886e246bf81e0d660bbd8955) |
| 3 | `OfertaCaptacaoFactory.executeGrantRole(AGENTE_ROLE, deployer)` | [`0xe20a7b37…8d2ba56e8`](https://sepolia.etherscan.io/tx/0xe20a7b374748770174ff0d1c022daed6007c234964b2b60fbd418d68d2ba56e8) |
| 4 | `ParticipacaoTokenFactory.criarOferta(...)` → token | [`0xbe9767e8…10d696b64`](https://sepolia.etherscan.io/tx/0xbe9767e8adb86a9d942a839617d376a8682548c72bcb3c283b1abd510d696b64) |
| 5 | `EmissaoGateway.atestarCotas(token, 50 cotas)` | [`0xd7386c07…eb2205cb3`](https://sepolia.etherscan.io/tx/0xd7386c07ce2a62cc43940d73c1fc5822e49166a1fea34ef57b6c01eeb2205cb3) |
| 6 | `OfertaCaptacaoFactory.criarCaptacao(...)` → oferta | [`0xd4fb493b…dc47a6ff76`](https://sepolia.etherscan.io/tx/0xd4fb493b834484e041f0c14a4425bbbff6fbfc99217e0a160ef3cddc47a6ff76) |
| 7 | `EmissaoGateway.registrarCaptacao(token, oferta)` | [`0x5fae0557…731ac4dbee8cf3d83f`](https://sepolia.etherscan.io/tx/0x5fae0557179187c3f03fd805b60efbe17baaacb625680b731ac4dbee8cf3d83f) |
| 8 | `MockBRL.mint(investidor1, 3000 mBRL)` | [`0x89ee237c…8bf4d902a9283`](https://sepolia.etherscan.io/tx/0x89ee237c2e6fe2347ff6482bb031889d08aed5d61945bffdc8e8bf4d902a9283) |
| 9 | `MockBRL.mint(investidor2, 2000 mBRL)` | [`0xa14ce17c…7325bdf456`](https://sepolia.etherscan.io/tx/0xa14ce17c70ca2cd4ec31da9e3b7d041f46231d2d4ea8221c50c7607325bdf456) |
| 10 | `MockBRL.approve(oferta, 3000 mBRL)` — investidor1 | [`0x049667b8…9745cad8a8be`](https://sepolia.etherscan.io/tx/0x049667b83146f724d57a035a9cb5c3a6421847674c3a0247d6f09745cad8a8be) |
| 11 | **`OfertaCaptacao.aportar(3000 mBRL)`** — investidor1 | [`0x6491ae4d…d0279e2370554c80`](https://sepolia.etherscan.io/tx/0x6491ae4dc53e9d24f8f1f0166a2d45f99da55b08d3492324d0279e2370554c80) |
| 12 | `MockBRL.approve(oferta, 2000 mBRL)` — investidor2 | [`0x9bf065fc…1c2272473`](https://sepolia.etherscan.io/tx/0x9bf065fcb7a0d16ec8e246396c1ce84ce852ad1c9156f35eb9c4f5c1c2272473) |
| 13 | **`OfertaCaptacao.aportar(2000 mBRL)`** — investidor2 | [`0xbe5c70ca…d1829eb4e295e1572`](https://sepolia.etherscan.io/tx/0xbe5c70ca86e1ade2a373b40e0adb2f5b062bbc260a6d520d1829eb4e295e1572) |
| 14 | **`OfertaCaptacao.encerrar()`** → EncerradaSucesso | [`0x0d1e5a14…0179e9322692d`](https://sepolia.etherscan.io/tx/0x0d1e5a144804c9a43af5d69873db5c698dc80863aa6285c0dd00179e9322692d) |
| 15 | **`OfertaCaptacao.resgatarCotas()`** — investidor1 (30 cotas) | [`0x7e7bea6a…6d508f8e4b630eef3`](https://sepolia.etherscan.io/tx/0x7e7bea6aeb9bf8a38094c7a8633ba4ebff66d587dedda3a6d508f8e4b630eef3) |
| 16 | **`OfertaCaptacao.resgatarCotas()`** — investidor2 (20 cotas) | [`0x274cd295…99ff49a4d675a1f4b`](https://sepolia.etherscan.io/tx/0x274cd29565bd760e0056a9e3a0dde13bc90260babf5502d99ff49a4d675a1f4b) |
| 17 | **`OfertaCaptacao.liberarParaEmissor()`** | [`0x212b95cd…dfa495715291`](https://sepolia.etherscan.io/tx/0x212b95cd6ce9e2eba913423bf951b8bcd376b38b34ffd7baf831dfa495715291) |

## Matemática do fechamento

- Aportes: `3.000 mBRL` (investidor 1) + `2.000 mBRL` (investidor 2) = **`5.000 mBRL`
  arrecadados** = `metaMaxima` exata → fechamento antecipado por subscrição cheia
  (sem esperar o prazo de 1 dia).
- `precoPorCota = 100 mBRL` → **50 cotas emitidas** no resgate: `30` para o
  investidor 1 (`3.000 / 100`), `20` para o investidor 2 (`2.000 / 100`).
  `token.totalSupply() = 50 ether` (50 cotas na escala de 18 casas do ERC-20,
  confirmado on-chain).
- `taxaBps = 0` (dormente) → na liberação, **`5.000 mBRL` inteiros foram para a
  carteira do emissor**, `0` para a carteira de protocolo.
- Escrow (`OfertaCaptacao`) fechou com **`0 mBRL`** de saldo — confirmado por
  leitura direta on-chain (`MockBRL.balanceOf(oferta)`) após `liberarParaEmissor()`,
  não só pelo log do script.

Todos os valores acima (`totalSupply`, saldo de cotas de cada investidor, saldo de
mBRL do emissor, saldo residual do escrow, estado final da oferta) foram lidos
diretamente da chain via `cast call` — não apenas do console log do script — antes
deste documento ser escrito.

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

## Deploy self-service (`OfertaOrquestrador`) — `DeployFase2Sepolia` + `DeployFase2SepoliaExecute`

Fluxo mais novo, separado da demo acima: em vez do AGENTE criar cada oferta manualmente
(`ParticipacaoTokenFactory.criarOferta` → `atestarCotas` → `criarCaptacao` →
`registrarCaptacao`), a própria empresa emissora (previamente autorizada) cria a sua oferta
numa única transação, via `OfertaOrquestrador.criarOfertaCompleta`. Dois scripts, sem
nenhuma chave privada em variável de ambiente em lugar nenhum — o único signatário de cada
um é resolvido por `--account` na linha de comando:

1. **`script/DeployFase2Sepolia.s.sol`** — implanta os 8 contratos da Fase 2 +
   `OfertaOrquestrador`, e PROPÕE (não executa) `AGENTE_ROLE` em 5 relações: o orquestrador
   em `tokenFactory`/`gateway`/`captacaoFactory`, o admin no próprio orquestrador, e o admin
   em `RegistroInvestidorQualificado` (pré-requisito de `definirQualificado` — necessário
   para qualquer investidor que precise aportar acima do `tetoPorInvestidor` de uma oferta;
   agrupado aqui porque passa pelo mesmo timelock de 1h das outras quatro concessões).
   Persiste os 9 endereços em `./script/output/fase2-sepolia.json`. Env:
   `PROTOCOLO_WALLET_ADDRESS`, `TAXA_BPS_ORQUESTRADOR` (obrigatório, 1–100 — ver aviso
   abaixo), `TETO_POR_INVESTIDOR_ORQUESTRADOR` (obrigatório). Todos sem fallback.
2. Espera real de >= 1h (o timelock não pode ser pulado em rede real — `vm.warp` não afeta
   o relógio de uma chain de verdade recebendo transações).
3. **`script/DeployFase2SepoliaExecute.s.sol`** — lê os 9 endereços do JSON acima (nunca
   digitados via env, para não arriscar apontar para o contrato errado), executa as 5
   concessões pendentes, e autoriza o primeiro emissor (`EMISSOR_WALLET_ADDRESS`) a operar
   o canal self-service. Idempotente: pode ser rodado mais de uma vez sem quebrar.
4. Depois disso, o **emissor autorizado assina a própria transação** (`cast send
   <OfertaOrquestrador> "criarOfertaCompleta(...)" ... --account <conta do emissor>`) para
   criar sua oferta — não passa por nenhum script deste repositório. O mesmo vale para os
   investidores que aportam nela depois: cada ator assina com a própria carteira, prova de
   que são partes distintas e sem privilégio uns sobre os outros.

> ⚠️ **`taxaBps` não pode ser `0` neste fluxo, e é gravado imutavelmente por oferta.**
> `OfertaOrquestrador.taxaBps` (parâmetro de plataforma, trocável via timelock) é copiado
> para `OfertaCaptacao.taxaBps` no exato momento de `criarOfertaCompleta` — e
> `OfertaCaptacao.sol` **não tem nenhum setter** para esse campo depois de `initialize()`
> (conferido no código-fonte: é atribuído uma única vez, em `initialize`, e nunca mais
> reatribuído). Uma vez criada, uma oferta com `taxaBps` errado **não tem correção
> possível** — o único remédio é corrigir `OfertaOrquestrador.taxaBps` via
> `proposeSetTaxaBps`/`executeSetTaxaBps` (o que só afeta ofertas **futuras**) e criar uma
> oferta nova. Por isso `DeployFase2Sepolia.s.sol` rejeita `TAXA_BPS_ORQUESTRADOR == 0`: com
> taxa dormente, `OfertaCaptacao.liberarParaEmissor` pula inteiramente a perna de
> transferência ao protocolo (`if (taxa > 0)`), e o split de receita nunca apareceria no
> Etherscan — o objetivo desta fase é justamente provar esse split on-chain.

## Resultados — primeira oferta self-service real ("Padaria Silva")

Executado em 2026-09-24. Infraestrutura implantada por `DeployFase2Sepolia.s.sol` +
`DeployFase2SepoliaExecute.s.sol` (deployer/admin assinando); a oferta em si foi criada e
operada por carteiras **distintas** do deployer — emissor e investidores assinaram as
próprias transações, nenhuma delas com qualquer papel privilegiado nos contratos.

### Infraestrutura implantada (endereços de `script/output/fase2-sepolia.json`)

`script/output/fase2-sepolia.json` é gitignored (regenerado a cada deploy, ver "Commit
local" no `CLAUDE.md`) — os endereços abaixo são a cópia permanente, conferidos linha a
linha contra `broadcast/DeployFase2Sepolia.s.sol/11155111/run-latest.json`.

| Contrato | Endereço | Etherscan |
|---|---|---|
| MockBRL | `0xEC377e00e022675B67Da6ab1966Bc0764bF792A4` | [ver](https://sepolia.etherscan.io/address/0xEC377e00e022675B67Da6ab1966Bc0764bF792A4) |
| DenyAllTransferPolicy | `0xC763cd522B8D4632ccd1adE698BAD09Be22f6a69` | [ver](https://sepolia.etherscan.io/address/0xC763cd522B8D4632ccd1adE698BAD09Be22f6a69) |
| ParticipacaoToken (implementação) | `0x367D71E1A578a1Ac061991aCa8f302f9119dB603` | [ver](https://sepolia.etherscan.io/address/0x367D71E1A578a1Ac061991aCa8f302f9119dB603) |
| EmissaoGateway | `0xeaedcAea403F793AFf6c345a5321c05eE55Cb1FE` | [ver](https://sepolia.etherscan.io/address/0xeaedcAea403F793AFf6c345a5321c05eE55Cb1FE) |
| ParticipacaoTokenFactory | `0xA116Aeb034633ef58AF68A387778C59f99FE9539` | [ver](https://sepolia.etherscan.io/address/0xA116Aeb034633ef58AF68A387778C59f99FE9539) |
| RegistroInvestidorQualificado | `0x5BE2cF3f1aeA02987Bea87a635FC9ba7BdF04732` | [ver](https://sepolia.etherscan.io/address/0x5BE2cF3f1aeA02987Bea87a635FC9ba7BdF04732) |
| OfertaCaptacao (implementação) | `0x46c6690Db2Ad39AF5Fa29581Ed01172a65949656` | [ver](https://sepolia.etherscan.io/address/0x46c6690Db2Ad39AF5Fa29581Ed01172a65949656) |
| OfertaCaptacaoFactory | `0x5E248656516140360ADEFB66c1095ef0951e45cB` | [ver](https://sepolia.etherscan.io/address/0x5E248656516140360ADEFB66c1095ef0951e45cB) |
| **OfertaOrquestrador** | `0xde9cC84d1300b57F640f2d1862900393b82796e5` | [ver](https://sepolia.etherscan.io/address/0xde9cC84d1300b57F640f2d1862900393b82796e5) |

`OfertaOrquestrador` foi implantado com `protocoloWallet = 0x9780270d42FD834872C80E57024221A33d3ACd08`,
`taxaBps = 100` (1%, o teto rígido `TAXA_BPS_MAXIMA`), `tetoPorInvestidor = 20_000 ether`
(mesmo valor do teto de varejo anual da Res. CVM 88 — coincidência deliberada de parâmetro,
não uma verificação cruzada real, ver "Limitações" abaixo) e `timelockDelay = 3600`
segundos (1h — ver nota sobre `TIMELOCK_DELAY` no `CLAUDE.md`).

Carteiras (todas burner, sem valor real):

| Papel | Endereço |
|---|---|
| Deployer / admin / agente do orquestrador | `0x9e3d33E905a87FC86A6b84d13176240A22C8FBF8` |
| Emissor ("Padaria Silva", autorizado via `autorizarEmissor`) | `0x47d9de93F15E1ebfbEFD5F32c0076cf3090C63c6` |
| Protocolo (recebe a taxa de 1%) | `0x9780270d42FD834872C80E57024221A33d3ACd08` |
| Investidor 1 (qualificado via `definirQualificado`) | `0x21443ADa1d36e5DCAadD62896Ca2c21aDFE396E1` |
| Investidor 2 (qualificado via `definirQualificado`) | `0x5a71bA5a602791add4722Aa485b1b68f7BB4ae10` |

### Cronologia — Parte 1: `DeployFase2Sepolia.s.sol` (deploy + propõe 5 papéis)

| # | Ação | Tx hash |
|---|---|---|
| 1 | Deploy MockBRL | [`0xc6f273c2…618466`](https://sepolia.etherscan.io/tx/0xc6f273c24d5ab141e3b903b34bfd67e4b18af85901fa497500442d72fd618466) |
| 2 | Deploy DenyAllTransferPolicy | [`0x7951655b…c3715b`](https://sepolia.etherscan.io/tx/0x7951655b195606c0ac8427d402f5792ec1c05880a218e3402804eaa2d8c3715b) |
| 3 | Deploy ParticipacaoToken (implementação) | [`0x94956781…3ec478`](https://sepolia.etherscan.io/tx/0x949567812ab42d2daf4349f97fe26aa21fb32c65e560981342031691973ec478) |
| 4 | Deploy EmissaoGateway | [`0x7248016e…e34657`](https://sepolia.etherscan.io/tx/0x7248016e1525f7706f1c6ab7b8f213d463289a79c08e2eeab9f0271025e34657) |
| 5 | Deploy ParticipacaoTokenFactory | [`0xd1cff5b5…c9b55e`](https://sepolia.etherscan.io/tx/0xd1cff5b50a893eb99a355fcb0d9541d32064eb2f1862984d191892c11cc9b55e) |
| 6 | Deploy RegistroInvestidorQualificado | [`0xae2d4133…78057e`](https://sepolia.etherscan.io/tx/0xae2d413354060d0fcbba6adaadfc7c08749a0a5f11a0397684bb47b6bd78057e) |
| 7 | Deploy OfertaCaptacao (implementação) | [`0x23d40e9f…feb224`](https://sepolia.etherscan.io/tx/0x23d40e9ff77eab27ef8355a5265e145af5d013b94392a0b19033c9f64efeb224) |
| 8 | Deploy OfertaCaptacaoFactory | [`0xe7c62301…3112ad`](https://sepolia.etherscan.io/tx/0xe7c62301b524e7f462925aba167f7bf46411feb2078e43a7ba91b2087a3112ad) |
| 9 | Deploy OfertaOrquestrador | [`0x87e4ab0e…e282ed`](https://sepolia.etherscan.io/tx/0x87e4ab0ee73dd189fc311e98cf95a38f20a3488e6139e8d3dd8c932859e282ed) |
| 10 | `ParticipacaoTokenFactory.proposeGrantRole(AGENTE_ROLE, orquestrador)` | [`0x3508a9b3…741831`](https://sepolia.etherscan.io/tx/0x3508a9b3ad6d3d4d44a3e35836cde929fd429cdff8fdd8d1d710941407741831) |
| 11 | `EmissaoGateway.proposeGrantRole(AGENTE_ROLE, orquestrador)` | [`0xab2a75cb…d0fa00`](https://sepolia.etherscan.io/tx/0xab2a75cbe4358670bfaa3091b91a9d1fbdd7d1faaa08022cdbf9d0c99bd0fa00) |
| 12 | `OfertaCaptacaoFactory.proposeGrantRole(AGENTE_ROLE, orquestrador)` | [`0xc77b1b87…50a470`](https://sepolia.etherscan.io/tx/0xc77b1b87b61eb52492d22b94e8b2818fd437cb2b255d12c26e9743da6150a470) |
| 13 | `OfertaOrquestrador.proposeGrantRole(AGENTE_ROLE, admin)` | [`0x20c93273…ba70c5`](https://sepolia.etherscan.io/tx/0x20c932734bafb5de48a3a11aec7902014aed9eb043637aa4a11d726c13ba70c5) |
| 14 | `RegistroInvestidorQualificado.proposeGrantRole(AGENTE_ROLE, admin)` | [`0x37df452e…b991cd`](https://sepolia.etherscan.io/tx/0x37df452e02092630d772ca6c3f9943fa41c5be9c6dd223555347aff19fb991cd) |

**Espera real do timelock**: as 5 propostas acima ficaram pendentes por 1h de relógio real
(mesma mecânica já usada nas fases anteriores — `vm.warp` não existe fora do `forge test`).

### Cronologia — Parte 2: `DeployFase2SepoliaExecute.s.sol` (executa os 5 papéis + autoriza o emissor)

| # | Ação | Tx hash |
|---|---|---|
| 1 | `ParticipacaoTokenFactory.executeGrantRole(AGENTE_ROLE, orquestrador)` | [`0x8b7c4bed…a2388a`](https://sepolia.etherscan.io/tx/0x8b7c4bed9ec43b084cdbe59c499486f13fac979bc5f18dd5a72a9e2ab3a2388a) |
| 2 | `EmissaoGateway.executeGrantRole(AGENTE_ROLE, orquestrador)` | [`0x33a0965f…34bd8f`](https://sepolia.etherscan.io/tx/0x33a0965f35954e3a4b2fef87411bd4fd9268ca1cc69848551b8acbd28634bd8f) |
| 3 | `OfertaCaptacaoFactory.executeGrantRole(AGENTE_ROLE, orquestrador)` | [`0xe753dc1d…ed1f44`](https://sepolia.etherscan.io/tx/0xe753dc1dc7f5a6013d37624ae322a0109f573da8d52b606e76ea909c01ed1f44) |
| 4 | `OfertaOrquestrador.executeGrantRole(AGENTE_ROLE, admin)` | [`0x84560fe1…f9a13b`](https://sepolia.etherscan.io/tx/0x84560fe1796c84c81b92a6bb76488667f002bd5971abadc775a175bffef9a13b) |
| 5 | `RegistroInvestidorQualificado.executeGrantRole(AGENTE_ROLE, admin)` | [`0xf773d86a…edbcaa`](https://sepolia.etherscan.io/tx/0xf773d86af3af5b179b53c5ca6e1619b50f308a4486585d97d642d09b84edbcaa) |
| 6 | `OfertaOrquestrador.autorizarEmissor(emissor)` | [`0x05686377…99e212`](https://sepolia.etherscan.io/tx/0x056863778275553d47e211d35e54d2b4709cd75d6954bfdd3ff121499099e212) |

### Cronologia — Parte 3: ações assinadas fora dos scripts (emissor e investidores)

Nenhuma das transações abaixo passa por este repositório — cada ator assinou com a própria
carteira, direto via `cast send`/carteira própria, exatamente como descrito na seção
anterior. Só as duas transações centrais têm hash registrado aqui; aportes, encerramento e
resgates foram conferidos por leitura de estado (`cast call`), não listados individualmente.

| Ação | Quem assina | Tx hash |
|---|---|---|
| **`OfertaOrquestrador.criarOfertaCompleta(...)`** — cria token PSILVA + oferta "Padaria Silva" numa única transação | emissor (`0x47d9…C63c6`) | [`0xcbe401ab…ded8dd`](https://sepolia.etherscan.io/tx/0xcbe401ab61de636816b8c009e0ecfec389b9b3b35ac11d72b0aaf8e792ded8dd) |
| `RegistroInvestidorQualificado.definirQualificado` (2x, um por investidor) | admin | não listado — só o efeito (`ehQualificado == true`) foi conferido via `cast call` |
| `MockBRL.mint` + `.approve` + `OfertaCaptacao.aportar` (2x, um por investidor) | investidor 1, investidor 2 | não listados — só `totalArrecadado` final foi conferido via `cast call` |
| `OfertaCaptacao.encerrar()` → `EncerradaSucesso` | qualquer conta (permissionless) | não listado — só `estado()` final foi conferido via `cast call` |
| `OfertaCaptacao.resgatarCotas()` (2x, um por investidor) | investidor 1, investidor 2 | não listados — só `token.balanceOf`/`totalSupply` foram conferidos via `cast call` |
| **`OfertaCaptacao.liberarParaEmissor()`** — divide a arrecadação entre protocolo e emissor | qualquer conta (permissionless) | [`0xe4efcb14…de4baf`](https://sepolia.etherscan.io/tx/0xe4efcb14198eabfc87ae59e8f99e55099b6e04786f26e40788eed27cc6de4baf) |

Contratos criados em runtime pela transação central (endereços do clone, não implantados
por nenhum script — vêm de `Clones.clone` dentro de `criarOfertaCompleta`):

| | Endereço | Etherscan |
|---|---|---|
| Token (ParticipacaoToken, "PSILVA") | `0x76d8e88fe48Bfab2f2EEd7196321B2886750298D` | [ver](https://sepolia.etherscan.io/address/0x76d8e88fe48Bfab2f2EEd7196321B2886750298D) |
| Oferta (OfertaCaptacao, escrow "Padaria Silva") | `0x6587265f971Aa555106D64e3422Ee901A0D20546` | [ver](https://sepolia.etherscan.io/address/0x6587265f971Aa555106D64e3422Ee901A0D20546) |

Termos da oferta: meta mínima R$ 500.000, meta máxima R$ 600.000 (lote adicional de exatos
20% sobre a mínima, dentro do limite de 25% da Res. CVM 88), preço por cota R$ 1.000, prazo
de 90 dias (dentro do limite de 180 dias).

### Resultados verificados on-chain (`cast call`, não só o log dos scripts)

- `hasRole(AGENTE_ROLE, emissor)` → **`false`** em `ParticipacaoTokenFactory`,
  `EmissaoGateway` e `OfertaCaptacaoFactory` — o emissor nunca deteve, em nenhum momento, o
  papel privilegiado que a criação da oferta exige; só o `OfertaOrquestrador` o detém, e
  atuou em nome do emissor dentro de uma única transação atômica assinada por ele.
- `totalArrecadado = R$ 600.000` (`metaMaxima` exata) → fechamento antecipado por
  subscrição cheia, mesmo padrão já visto na demo manual acima.
- Após `liberarParaEmissor()`: carteira do protocolo com **R$ 6.000** (1% de R$ 600.000,
  `taxaBps = 100`) e carteira do emissor com **R$ 594.000** (99% restante) — primeira vez,
  nesta linha de demos, que o split de taxa aparece com um valor diferente de zero
  on-chain (a demo manual da Fase 2 acima usou `taxaBps = 0` deliberadamente).
- `token.totalSupply() = 600 ether` (600 cotas na escala de 18 casas), exatamente igual a
  `cotasAutorizadas()` do token — nenhuma cota "sobrando" nem "faltando" em relação ao
  atestado pelo `EmissaoGateway` no momento da criação.

## Roteiro de demonstração

Ordem sugerida de links a abrir (todos no Sepolia Etherscan), com o que dizer em cada um:

1. **`OfertaOrquestrador` verificado** (endereço na tabela acima). "Este é o contrato novo:
   antes, só a plataforma (o AGENTE) podia criar uma oferta, chamando 4 funções em 3
   contratos diferentes. Agora uma empresa autorizada faz isso sozinha, numa única
   transação."
2. **A transação central** (`criarOfertaCompleta`, hash acima). Apontar o campo **From**:
   é a carteira do emissor, não a do deployer/admin. "Quem assina esta transação é a própria
   Padaria Silva — o botão 'From' não é a plataforma."
3. Na aba **"Internal Txns"** dessa mesma transação: mostrar as 4 subchamadas
   (`criarOferta` → `atestarCotas` → `criarCaptacao` → `registrarCaptacao`) acontecendo
   dentro da mesma transação — "isso tudo é atômico: se qualquer uma falhasse, nada teria
   sido criado, nem o token nem a oferta" (ver os dois testes de atomicidade em
   `test/OfertaOrquestrador.t.sol`, reforçados nesta fase).
4. **Read Contract** de `ParticipacaoTokenFactory`/`EmissaoGateway`/`OfertaCaptacaoFactory`,
   chamando `hasRole` com `AGENTE_ROLE` e o endereço do emissor → mostra `false` ao vivo.
   "O emissor nunca teve esse papel — só o orquestrador teve, e usou em nome dele."
5. **Token PSILVA** e **oferta "Padaria Silva"** (endereços acima) — ambos reconhecidos pelo
   Etherscan como proxy (EIP-1167) das mesmas implementações já verificadas na demo manual.
   "Mesmo código, caminho de criação diferente."
6. **`liberarParaEmissor()`** (hash acima) → aba **"ERC-20 Token Txns"** ou **"Internal
   Txns"**: mostrar as duas transferências de `MockBRL` saindo do escrow — R$ 6.000 para a
   carteira de protocolo, R$ 594.000 para a carteira do emissor. "Esta é a primeira vez que
   esse split de taxa aparece com valor diferente de zero on-chain — 1%, o teto máximo
   permitido pelo próprio contrato."
7. Fechar com `token.totalSupply()` em **Read Contract** = 600 cotas, batendo com
   `metaMaxima / precoPorCota`.

## Limitações desta demonstração

- **Testnet sem lastro.** Sepolia ETH e `MockBRL` não têm valor real; nenhum valor
  mobiliário de verdade foi ofertado.
- **Tetos anuais são off-chain.** Nem o teto de R$ 20 mil/ano do investidor de varejo, nem
  o teto agregado do emissor entre plataformas (Res. CVM 88), são verificados por este
  contrato de forma cross-plataforma — `tetoPorInvestidor` é só o limite **desta oferta**,
  e o `OfertaOrquestrador` documenta em NatSpec, explicitamente, que não tem e não pode ter
  visibilidade sobre o que um emissor já captou em outra plataforma (ver
  `src/orquestracao/OfertaOrquestrador.sol`, NatSpec do contrato).
- **`taxaBps` é imutável por clone.** Uma vez criada, a taxa de uma oferta específica não
  pode mais ser alterada — só ofertas futuras herdam um `taxaBps` novo (ver aviso acima).
- **Sem auditoria externa.** Cobertura de testes + fuzzing de invariantes, sem revisão de
  terceiros.
- **Os dois investidores foram qualificados manualmente.** `definirQualificado` foi chamado
  para as duas carteiras de investidor especificamente para permitir aportes acima do teto
  de R$ 20 mil por investidor não qualificado (`tetoPorInvestidor`) — sem isso, nenhuma das
  duas conseguiria aportar os R$ 300 mil que aportou. Em produção, qualificação de
  investidor é um processo regulatório real (Res. CVM 30), não um botão de demonstração.

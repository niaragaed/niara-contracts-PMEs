# CLAUDE.md — niara-contracts-PMEs

Instruções permanentes para o Claude Code neste repositório. Leia antes de escrever
qualquer código.

Este repositório é **separado** de:
- `niara-contracts` — a exchange (mercado secundário), referência somente-leitura (ver
  seção "Linhagem"). Nunca editar nem copiar arquivos de lá.
- `niara-PMEs` — o site institucional. Não procure nem referencie arquivos daquele
  projeto a partir daqui.

---

## Visão do produto

Plataforma de tokenização de cotas de participação para pequenas e médias empresas
(PMEs) brasileiras, enquadrada na **Resolução CVM 88** (oferta de valores mobiliários
por dispensa de registro). Uma empresa cria uma oferta; investidores aportam e recebem
tokens que representam a cota emitida.

**Tudo aqui é protótipo em testnet (Sepolia), demonstração, sem auditoria externa
publicada.** Formulação honesta a usar sempre: *"cobertura total de testes +
invariantes por fuzzing, SEM auditoria externa"*. Nunca descrever qualquer contrato
deste repositório como "seguro" ou "auditado". Nunca fazer deploy em mainnet nesta
fase.

Diferença central em relação à exchange (`niara-contracts`): lá é mercado secundário
(troca P2P de um ativo que já existe, lastreado por atestação de custódia). Aqui é
**mercado primário / captação**: a empresa emite cotas, o investidor aporta. Por isso
este repositório tem coisas que a exchange não tinha — factory com clones (um token por
oferta) e política de transferência plugável (secundário desligado por padrão).

## Regulatório — limites do que este código é

- **Cap table on-chain é registro probatório complementar, NÃO substitui os livros
  societários da Lei 6.404/76 nem o registro em cartório/junta comercial.** Isso está
  também no NatSpec de `ParticipacaoToken`. Nenhuma automação deste repositório deve
  sugerir o contrário.
- `MockBRL` é mock de teste — sem lastro, sem valor, rotulado como tal em NatSpec.
- Sem números de taxa nesta fase — modelo de receita das PMEs está **a definir**. Não
  há `CashbackDistributor` neste repo (diferente da exchange).

---

## Decisões travadas

- **Arquitetura do token**: factory-por-oferta, ERC-20 clonável via EIP-1167
  (`Clones` da OpenZeppelin). Um clone por oferta, implementação única auditável.
- **Atestado = cotas autorizadas** nos atos societários da empresa. Invariante
  central, válida para todo token: `totalSupply() <= cotasAutorizadas`.
- **Categoria inicial**: apenas participação (cotas). Dívida/recebível ficam para fase
  futura — a base (`ITransferPolicy`, gateway, factory) é desenhada para ser
  extensível a outras categorias sem reescrever o já existente.
- **Política de transferência plugável** via `ITransferPolicy`. A Fase 1 entrega
  `DenyAllTransferPolicy` (secundário totalmente desligado). A política sofisticada
  (lock-up + allowlist + flag de liberação) é Fase 3 — trocável por governança, sem
  tocar no token.
- **Governança com timelock desde o início** (delay mínimo 1h, padrão
  propose→execute, portado de `niara-contracts`). Papéis `AGENTE_ROLE`
  (agente/plataforma, atestador/emissor autorizado) e `EMISSOR_ROLE` (reservado para
  ações futuras específicas da empresa emissora) são declarados em `EmissaoGateway` e
  `ParticipacaoTokenFactory` — `TimelockedAccessControl` em si é agnóstico a papéis
  concretos (só conhece `DEFAULT_ADMIN_ROLE`, herdado do `AccessControl` da OZ).
- **Sem `CashbackDistributor`.** Taxa fica dormente/ausente nesta fase — não inserir
  nenhum número de bps de taxa até instrução explícita.
- **Unidade on-chain para aportes**: `MockBRL` (mock, 18 casas decimais) na testnet.
  Não era load-bearing nas Fases 0/1; passa a ser load-bearing no escrow da Fase 2
  (`OfertaCaptacao`).

### Decisões travadas — Fase 2 (captação com escrow)

- **Fechamento parcial.** A oferta tem `metaMinima` (piso) e `metaMaxima` (teto). No
  encerramento (`OfertaCaptacao.encerrar`): `totalArrecadado >= metaMinima` ⇒ sucesso
  (mesmo abaixo da máxima); abaixo do piso ⇒ fracasso ⇒ reembolso. Encerramento é
  permissionless, válido ao atingir o prazo OU a meta máxima antes dele (subscrição
  cheia encerra cedo).
- **Mint só no sucesso.** Durante a captação nenhuma cota é cunhada — o dinheiro fica
  retido no escrow (`OfertaCaptacao`). Cotas só são mintadas na liquidação do sucesso
  (`resgatarCotas`), proporcionalmente ao arrecadado por cada investidor, via pull
  individual (nunca um loop sobre todos os investidores — risco de gas/DoS).
- **Teto por investidor on-chain, por oferta**, com flag de qualificado/sem-limite
  atestada pelo AGENTE em `RegistroInvestidorQualificado`. **O teto ANUAL CRUZADO ENTRE
  PLATAFORMAS previsto na Resolução CVM 88 é OFF-CHAIN e AUTO-DECLARATÓRIO** — nenhum
  contrato deste repositório tem, ou pode ter, visibilidade de aportes do mesmo
  investidor em outras plataformas, e nenhuma automação deve prometer o contrário. A
  flag de qualificação é só a forma on-chain de uma verificação de suitability que a
  plataforma já é obrigada a fazer off-chain.
- **Unidade dos aportes**: `MockBRL` (18 casas), sem conversão de câmbio — "R$ 20 mil"
  é valor de face em `MockBRL`. USDT/WBTC como moeda de aporte ficam fora desta fase
  (exigiriam oráculo de câmbio; sob revisão jurídica).
- **Taxa dormente com teto rígido**: `taxaBps` por captação, validado `<= 100` (1%) em
  `OfertaCaptacao.initialize` e em `OfertaCaptacaoFactory.criarCaptacao`, sem valor
  final definido — quem cria a captação escolhe (inclusive `0`, caso em que o emissor
  recebe 100% do arrecadado). Não hardcodar um número final até instrução explícita.
- **Regra de arredondamento**: `aportar` exige que o valor seja múltiplo exato de
  `precoPorCota`, para que `cotas = aporte / precoPorCota` seja sempre exato (sem
  poeira). Simplificação deliberada desta fase — aceitar valor livre e devolver o
  resto fica registrado como evolução futura possível.
- **Escala das cotas mintadas**: `ParticipacaoToken` é um ERC-20 padrão de 18 casas
  (sem override de `decimals()`), então "1 cota inteira" corresponde a `1 ether` em
  unidade bruta do token — mesma convenção já usada na Fase 1
  (`gateway.emitir(token, investidor, 100 ether)` == 100 cotas). `OfertaCaptacao`
  calcula a CONTAGEM de cotas como `aportado / precoPorCota` e então reescala por
  `UNIDADE_COTA` (`1 ether`) antes de mintar — dividir sem reescalar de volta mintaria
  uma fração ínfima da cota (bug já pego e corrigido durante o desenvolvimento desta
  fase). Qualquer atestação de teto (`atestarCotas`) para um token usado em captação
  também precisa estar na mesma escala: `(metaMaxima / precoPorCota) * 1 ether`.
- **`OfertaCaptacao` não tem `AccessControl` próprio** (mesmo raciocínio do
  `ParticipacaoToken` na Fase 1: é um clone leve replicado por oferta). A única ação
  restrita do escrow (`cancelar`) reaproveita o `AGENTE_ROLE`, já timelocked, do
  `EmissaoGateway` apontado por `gateway`, consultado via `IAccessControl.hasRole` —
  não duplica gestão de papel por clone.

---

## Linhagem (o que veio de `niara-contracts`)

`niara-contracts` (a exchange) é referência **somente-leitura** — nunca editada nem
copiada literalmente, mas os seguintes padrões foram estudados e adaptados:

- **Estilo de invariante estrutural**: `AssetToken.mint` da exchange trava
  `totalSupply() + amount <= totalAtestado`, verificado dentro do próprio contrato do
  token (não apenas por controle de acesso de quem chama). `ParticipacaoToken.mint`
  segue o mesmo princípio: `totalSupply() + amount <= cotasAutorizadas`, checado no
  token, independentemente de quem tenha o papel autorizado a chamar.
- **Padrão atestar → mintar**: `BackingGateway` da exchange registra pedido, um papel
  custodiante atesta, só então libera a cunhagem. `EmissaoGateway` replica o padrão:
  `atestarCotas` (eleva o teto) antes de `emitir` (cunha), ambos restritos ao papel
  `AGENTE_ROLE`.
- **`governance/TimelockedAccessControl.sol`**: portado quase literalmente — atraso
  mínimo de 1h, `grantRole`/`revokeRole` padrão desabilitados em favor de
  `proposeX`/`executeX`, `renounceRole` livre. Adaptado apenas nos papéis concretos
  (`AGENTE_ROLE`/`EMISSOR_ROLE` em vez de `MINTER_ROLE`/`CUSTODIAN_ROLE`/etc.).
- **Estrutura de `test/` e harness de fuzzing**: `test/invariant/Handler.sol` +
  `test/Invariant.t.sol` seguem o mesmo desenho — um `Handler` (ator único, uma função
  pública por ação de protocolo) que o motor de invariantes do Foundry explora com
  `targetContract`/`targetSelector`, com uma fração das chamadas tomando
  deliberadamente o caminho inválido (`_chaos`, ~1 em 5) para exercitar os `revert`s.
  Escala de fuzzing (`runs=256 * depth=100` = 25.600 chamadas por rodada de
  invariante) escolhida para espelhar deliberadamente a da exchange.
- **`MockUSDT.sol`** → modelo direto para `src/mocks/MockBRL.sol` (ERC-20 simples,
  `mint` público irrestrito, rotulado como mock em NatSpec).

O que **não** veio da exchange (específico deste repositório): factory com clones
EIP-1167, `ITransferPolicy` plugável, e o modelo de "cotas autorizadas" em vez de
"lastro custodiado" — a exchange nunca precisou de clonagem porque cada `AssetToken`
era implantado uma vez por ativo.

---

## Plano de fases

- **Fase 0** (concluída) — fundação: projeto Foundry, convenções, `MockBRL`,
  `CLAUDE.md`.
- **Fase 1** (concluída) — `ParticipacaoToken` clonável +
  `ITransferPolicy`/`DenyAllTransferPolicy` + `EmissaoGateway` +
  `ParticipacaoTokenFactory` + `TimelockedAccessControl` + testes unitários e de
  invariante. Ver "Arquitetura da Fase 1" e "Resultados de teste (Fase 1)" abaixo.
- **Fase 2** (concluída) — captação primária CVM 88 com escrow: `OfertaCaptacao`
  clonável + `OfertaCaptacaoFactory` + `RegistroInvestidorQualificado` + extensão de
  `EmissaoGateway` (mint escopado por captação) + testes unitários e de invariante de
  dinheiro/reentrância. Ver "Arquitetura da Fase 2" e "Resultados de teste (Fase 2)"
  abaixo.
- **Fase 3** (futura) — política de transferência sofisticada (lock-up + allowlist +
  flag de liberação de secundário), trocável por governança.
- **Fase 4** (futura) — categorias adicionais (dívida/recebível).
- **Fase 5** (futura) — a definir; possivelmente integração com o site (`niara-PMEs`)
  e/ou modelo de receita.

---

## Arquitetura da Fase 1

```
ParticipacaoTokenFactory (TimelockedAccessControl, Pausable)
  ├─ implementacao (template ParticipacaoToken, trocável via timelock)
  ├─ gateway (EmissaoGateway, fixo na construção)
  ├─ transferPolicyPadrao (trocável via timelock)
  └─ criarOferta(...) [AGENTE_ROLE] → Clones.clone(implementacao) → initialize(...)

EmissaoGateway (TimelockedAccessControl)
  ├─ AGENTE_ROLE — atestarCotas / emitir / pausarToken / despausarToken
  └─ EMISSOR_ROLE — reservado, sem uso funcional nesta fase

ParticipacaoToken (Initializable, ERC20Upgradeable, PausableUpgradeable)
  ├─ gateway — único endereço autorizado a chamar setCotasAutorizadas/mint/pause/unpause
  ├─ cotasAutorizadas — teto, só sobe (setCotasAutorizadas reverte se novoTeto < atual)
  ├─ transferPolicy (ITransferPolicy) — consultado em toda transferência titular→titular
  └─ invariante: totalSupply() <= cotasAutorizadas, sempre

DenyAllTransferPolicy (ITransferPolicy) — canTransfer sempre false (Fase 1)
```

Autorização é por endereço único (`gateway`) no token — não por `AccessControl` — porque
o token é um clone leve replicado por oferta; a governança por papéis fica concentrada em
`EmissaoGateway`/`ParticipacaoTokenFactory`, que não são clonados.

Troca de `implementacao`/`transferPolicyPadrao` na factory (via timelock) só afeta
ofertas **futuras** — clones já criados mantêm a lógica/política vigente no momento em
que foram clonados (testado em
`test_SetImplementacao_OnlyAffectsFutureOffers`).

---

## Arquitetura da Fase 2

```
RegistroInvestidorQualificado (TimelockedAccessControl)
  └─ AGENTE_ROLE — definirQualificado(investidor, bool) [imediato, sem timelock na ação]

OfertaCaptacaoFactory (TimelockedAccessControl, Pausable)
  ├─ implementacao (template OfertaCaptacao, trocável via timelock)
  ├─ gateway, registro, moeda (fixos na construção, sem setter nesta fase)
  └─ criarCaptacao(...) [AGENTE_ROLE] → Clones.clone(implementacao) → initialize(...)

EmissaoGateway (TimelockedAccessControl) — ESTENDIDO na Fase 2
  ├─ AGENTE_ROLE — atestarCotas / emitir / pausarToken / despausarToken (Fase 1)
  ├─ registrarCaptacao(token, oferta) [AGENTE_ROLE] — define o escrow autorizado
  └─ emitirParaCaptacao(token, to, cotas) — só a `oferta` registrada p/ aquele token;
     chama token.mint(to, cotas), mesmo invariante da Fase 1 continua valendo

OfertaCaptacao (Initializable, PausableUpgradeable, ReentrancyGuard)
  ├─ token, gateway, registro, moeda, emissorWallet, protocoloWallet (via initialize)
  ├─ metaMinima, metaMaxima, precoPorCota, prazo, tetoPorInvestidor, taxaBps (<= 100)
  ├─ estado: Aberta → EncerradaSucesso | EncerradaFalha (nunca volta)
  ├─ aportar (nonReentrant, whenNotPaused) — escrow, CEI, múltiplo de precoPorCota
  ├─ encerrar (permissionless) — prazo OU metaMaxima atingida
  ├─ cancelar — só AGENTE (via gateway.hasRole), poder protetivo (Aberta → Falha)
  ├─ resgatarCotas / reembolsar / liberarParaEmissor — pull, nonReentrant, uma vez
  └─ pausar/despausar — só bloqueia `aportar`; saques nunca ficam congelados
```

`ReentrancyGuard` usado é o **não-upgradeable** de
`@openzeppelin/contracts/utils/ReentrancyGuard.sol` — nesta versão da OZ (`v5.6.1`) ele
já é stateless/namespaced (slot fixo via `keccak256`, marcado `@custom:stateless` no
próprio contrato da OZ), então funciona corretamente em um clone EIP-1167 sem precisar
de uma variante "Upgradeable" (que não existe mais no pacote, substituída por esse
design). Não existe `ReentrancyGuardUpgradeable.sol` em
`lib/openzeppelin-contracts-upgradeable` — não procurar por ele.

### Cadeia de autorização do mint (sequência operacional do AGENTE)

Para colocar uma oferta de captação no ar, nesta ordem:

1. `ParticipacaoTokenFactory.criarOferta(...)` → `token`.
2. `EmissaoGateway.atestarCotas(token, N)` — `N >= metaMaxima / precoPorCota`, **na
   escala de `1 ether` por cota** (ver "Decisões travadas — Fase 2").
3. `OfertaCaptacaoFactory.criarCaptacao(token, ...)` → `oferta`.
4. `EmissaoGateway.registrarCaptacao(token, oferta)` — só depois disso a `oferta`
   consegue, no sucesso, mintar via `emitirParaCaptacao`.

### Separação timelock × operacional (Fase 2)

O timelock (1h) não pode ser exigido em toda ação de uma captação ao vivo — investidor
não espera 1h para aportar. Classificação:

| Ação | Categoria |
|---|---|
| `criarOferta`, `atestarCotas`, `criarCaptacao`, `registrarCaptacao`, `definirQualificado`, `cancelar` | Operacional (AGENTE, imediato) |
| `aportar`, `encerrar`, `reembolsar`, `resgatarCotas`, `liberarParaEmissor` | Investidor/permissionless, imediato |
| Conceder/revogar `AGENTE_ROLE` (em qualquer um dos 4 contratos que o exigem), trocar `implementacao`/`taxaBps`-padrão/parâmetros sensíveis de protocolo | Timelock (1h, propose→execute) |

`AGENTE_ROLE` precisa ser concedido **em 4 contratos independentes** para operação
completa: `EmissaoGateway`, `ParticipacaoTokenFactory`, `RegistroInvestidorQualificado`
e `OfertaCaptacaoFactory` — cada um com seu próprio `TimelockedAccessControl` (mesmo
padrão da Fase 1, estendido). `OfertaCaptacao` (clone) não tem papel próprio: seu
`cancelar` reaproveita o `AGENTE_ROLE` do `EmissaoGateway` via `hasRole`.

---

## Resultados de teste (Fase 1)

- `forge build`: sem erros.
- `forge test`: 76/76 passando (unitários + 6 invariantes).
- `forge coverage` nos contratos principais (`src/`, exceto script de deploy):
  `EmissaoGateway`, `TimelockedAccessControl`, `ParticipacaoToken`,
  `ParticipacaoTokenFactory` e `MockBRL` — **100% linha/statement/branch/função**.
  `DenyAllTransferPolicy` mostra 50%/0% na única linha (`return false`) por uma
  limitação conhecida do instrumentador de cobertura do Foundry com funções `pure` de
  retorno literal — a contagem de hits da própria função (2336, via fuzz test +
  handler) confirma que ela é exercitada extensivamente; não é uma lacuna real de
  teste. `script/DeployFase1.s.sol` fica em 0% de propósito — scripts de deploy não
  são cobertos pela suíte de testes, só validados por execução manual (ver abaixo).
- Invariantes (`forge test --match-contract InvariantTest`) rodam na escala
  configurada — `runs=256 * depth=100` = 25.600 chamadas por invariante — sem nenhuma
  violação, com ~35-40% das chamadas revertendo de propósito (caminhos "caóticos"
  exercitando os `revert`s). As 6 invariantes verificadas:
  1. `totalSupply() <= cotasAutorizadas`, para todo token criado.
  2. `sum(saldos) == totalSupply()`, para todo token criado.
  3. Nenhuma chamada não autorizada a `mint`/`setCotasAutorizadas`/`pause`/`unpause`
     do token (fora do `gateway`) jamais teve sucesso.
  4. Nenhuma chamada sem `AGENTE_ROLE` a `atestarCotas`/`emitir`/`pausarToken`/
     `despausarToken`/`criarOferta` jamais teve sucesso.
  5. Nenhuma transferência titular→titular (`transfer`/`transferFrom`) jamais teve
     sucesso (política nega-tudo).
  6. Nenhum clone já inicializado pôde ser reinicializado.
- `script/DeployFase1.s.sol` foi validado de duas formas:
  - **Dry-run** (`forge script script/DeployFase1.s.sol`, sem `--rpc-url` nem
    `--broadcast`): fluxo completo (deploy → conceder `AGENTE_ROLE` via
    propose/`vm.warp`/execute → criar oferta → atestar → emitir) roda com sucesso,
    pois `vm.warp` é honrado na simulação local.
  - **Broadcast contra `anvil` local** (nunca Sepolia): falha, de propósito, em
    `executeGrantRole` com `TimelockNotElapsed` — porque, ao transmitir de verdade,
    o tempo do timelock precisa decorrer no relógio real da chain, e `vm.warp` não
    afeta um nó já em execução recebendo transações reais. Comportamento correto e
    esperado, documentado no NatSpec do script — não é um bug. Para um demo real
    contra `anvil` ao vivo, seria necessário ou esperar `TIMELOCK_DELAY` segundos de
    verdade entre duas transmissões, ou avançar o relógio do `anvil` via
    `evm_increaseTime`/`evm_mine` (não implementado nesta fase).

---

## Resultados de teste (Fase 2)

- `forge build`: sem erros (mesma suíte da Fase 1 + Fase 2).
- `forge test`: **183/183 passando** — 165 unitários + 18 invariantes (6 da Fase 1 +
  12 novos da Fase 2), sem nenhuma regressão na suíte da Fase 1 após estender
  `EmissaoGateway`.
- `forge coverage` nos contratos principais da Fase 2 (`OfertaCaptacao`,
  `OfertaCaptacaoFactory`, `RegistroInvestidorQualificado`, e a extensão de
  `EmissaoGateway`) — **100% linha/statement/branch/função**, mesma barra da Fase 1.
  `DenyAllTransferPolicy` mantém a mesma limitação conhecida do instrumentador da Fase
  1 (não é lacuna real). `script/DeployFase1.s.sol` e `script/DeployFase2.s.sol` ficam
  em 0% de propósito (scripts de deploy não são cobertos pela suíte, só validados por
  execução manual).
- Teste de reentrância dedicado (`test/OfertaCaptacaoReentrancy.t.sol`): uma moeda
  maliciosa (`ReentrantMockBRL`) tenta reentrar `aportar`/`reembolsar`/
  `liberarParaEmissor` a partir do próprio `transfer`/`transferFrom` — as 3 tentativas
  são bloqueadas pelo `nonReentrant`, e cada função externa completa com sucesso
  exatamente uma vez (sem duplo pagamento/duplo aporte).
- Invariantes de dinheiro (`forge test --match-contract InvariantCaptacaoTest`), na
  mesma escala configurada (`runs=256 * depth=100` = 25.600 chamadas por invariante),
  **zero violações**, ~10% das chamadas revertendo de propósito (`tentar*`). As 12
  invariantes verificadas:
  1. `moeda.balanceOf(oferta) == totalArrecadado - sumReembolsado` (ou `0` se
     `recursosLiberados`), para toda captação — a contabilidade central do escrow.
  2. `sum(reembolsos) <= totalArrecadado`, para toda captação.
  3. Nenhum duplo reembolso jamais teve sucesso.
  4. `sum(cotas mintadas via resgate) <= totalArrecadado / precoPorCota`, para toda
     captação.
  5. Nenhum duplo resgate de cotas jamais teve sucesso.
  6. `totalArrecadado <= metaMaxima`, sempre, para toda captação.
  7. Nenhum investidor não-qualificado conseguiu, numa única chamada de `aportar`,
     ultrapassar `tetoPorInvestidor` (checado no momento da chamada — não como
     snapshot retroativo, já que qualificação é uma flag mutável: um investidor pode
     legitimamente ficar acima do teto vigente se foi qualificado no aporte e
     desqualificado depois; isso não é bug, é ausência de confisco retroativo).
  8. Nunca houve reembolso E mint/liberação para a mesma captação (exclusão
     sucesso/fracasso).
  9. Nenhuma chamada sem `AGENTE_ROLE` a `cancelar`/`definirQualificado`/
     `criarCaptacao` jamais teve sucesso.
  10. Nenhuma dupla liberação ao emissor (`liberarParaEmissor`) jamais teve sucesso.
  11. Nenhum `aportar` fora do estado `Aberta` ou após o prazo jamais teve sucesso.
  12. Nenhum `encerrar` prematuro (antes do prazo e antes da meta máxima) jamais teve
      sucesso.
- Durante o desenvolvimento, a rodada de invariantes pegou um bug genuíno de escala:
  `resgatarCotas` mintava `aportado / precoPorCota` (uma contagem adimensional, ex.
  `60`) diretamente, sem reescalar para a unidade bruta de 18 casas do
  `ParticipacaoToken` (deveria ser `60 ether`) — corrigido com a constante
  `UNIDADE_COTA` (ver "Decisões travadas — Fase 2"). Vale como exemplo do valor do
  fuzzing stateful nesta fase: o teste unitário isolado não pegou porque comparava
  contra o mesmo cálculo (não escalado) usado no próprio teste; só o dry-run do
  `DeployFase2` (mostrando "60" em vez de "60000000000000000000" cotas) tornou o
  problema óbvio.
- `script/DeployFase2.s.sol` foi validado de duas formas, mesmo padrão do
  `DeployFase1.s.sol`:
  - **Dry-run**: os dois cenários rodam com sucesso — (A) sucesso parcial: dois
    investidores aportam somando entre a meta mínima e a máxima, encerramento em
    sucesso, um investidor resgata cotas (recebe `60 ether` = 60 cotas), liberação
    para o emissor (líquido da taxa) e para o protocolo (a taxa); (B) fracasso: aporte
    fica abaixo da meta mínima, encerramento em fracasso, os dois investidores
    reembolsam e recuperam o valor exato aportado.
  - **Broadcast contra `anvil` local**: falha, de propósito, no mesmo ponto que
    `DeployFase1` — `executeGrantRole` com `TimelockNotElapsed`, pela mesma razão
    (tempo real não decorrido no nó). Comportamento esperado, não é bug.

---

## Regras inegociáveis

### Honestidade / regulatório
- Protótipo em testnet, sem mainnet, sem auditoria publicada. Formulação honesta:
  "cobertura total + invariantes por fuzzing, SEM auditoria externa".
- `MockBRL` é mock de teste, sempre rotulado como tal.
- Cap table on-chain não substitui Lei 6.404 nem cartório — sempre no NatSpec do
  token.
- Sem número de taxa **final** definido — `taxaBps` (Fase 2) tem teto rígido de 100 bps
  e default `0`, mas o valor de fato usado por captação é escolha de quem a cria; não
  apresentar nenhum bps como "a taxa da plataforma" até instrução explícita.
- O teto por investidor de `OfertaCaptacao` é só o limite daquela oferta — o teto ANUAL
  CRUZADO ENTRE PLATAFORMAS da Resolução CVM 88 é OFF-CHAIN/AUTO-DECLARATÓRIO. Nunca
  descrever o teto on-chain como cumprindo, sozinho, essa exigência agregada.

### Git / GitHub
- Commits em português, prefixo `feat:`/`fix:`/`refactor:`/`chore:`/`docs:`/`test:`.
- Sem `git push` sem instrução explícita. Sem `--force`. Sem reescrever histórico já
  publicado.
- Identidade do repo: `niara <niaragaed@gmail.com>` (configurada localmente via
  `git config user.name`/`user.email`, sem `--global`). Sem trailer
  `Co-Authored-By: Claude`, sem "Generated with Claude Code".
- Repositório público: sem segredos versionados. `.gitignore` cobre `out/`, `cache/`,
  `broadcast/` (exceto dry-run/local), `.env`.
- Sem deploy em Sepolia (`--broadcast`) sem instrução explícita. Scripts de deploy
  podem ser escritos e rodados só localmente (`anvil`/dry-run) nesta etapa.

### Barra de testes
- Foundry: unitários + invariantes por fuzzing stateful (handlers).
- Meta de cobertura total (linha/branch/função) nos contratos principais; branch
  genuinamente inatingível deve ser documentado honestamente, nunca inflar o número.
- Fuzzing configurado para ~25.600+ chamadas por rodada de invariante
  (`runs=256 * depth=100`), espelhando a escala da exchange.

---

## Stack

- Solidity `0.8.24` (compatível com OpenZeppelin v5).
- `lib/openzeppelin-contracts` e `lib/openzeppelin-contracts-upgradeable`, instaladas
  via `forge install` (submódulos git), ambas na tag `v5.6.1`.
- Remappings e perfis de fuzz/invariant em `foundry.toml`.

## Como rodar

```bash
forge build
forge test -vv
forge coverage
forge test --match-contract Invariant -vv   # roda InvariantTest (Fase 1) e InvariantCaptacaoTest (Fase 2)
```

## Convenções

- Comentários e NatSpec em português.
- Erros customizados (`error X()` + `revert X()`), não `require(cond, "string")`,
  exceto onde já usado por bibliotecas externas (OpenZeppelin).
- Padrão de timelock idêntico ao da exchange: `proposeX(...)` agenda
  (`_scheduleAction`), `executeX(...)` consome (`_consumeAction`) e aplica. O
  `actionId` é `keccak256(abi.encode("NOME_DA_ACAO", ...parâmetros))`.
- Clones EIP-1167 não rodam construtor — `ParticipacaoToken` herda de
  `ERC20Upgradeable`/`Initializable`, define nome/símbolo/metadados dentro de
  `initialize()`, e a implementação-template chama `_disableInitializers()` no
  construtor para não poder ser inicializada diretamente.

## Fluxo de trabalho

1. Antes de codar, ler os arquivos envolvidos — não presumir.
2. `forge build` e `forge test -vv` ao final de cada mudança; corrigir o que aparecer.
3. Commit local ao final de cada bloco de tarefa, mensagem em português.
4. Nunca `--force`, nunca reescrever histórico, nunca push sem ser pedido.
5. Se algo quebrar ou ficar ambíguo: parar e explicar, não improvisar.

---

## Pendências conhecidas

- `EMISSOR_ROLE` está definido em `EmissaoGateway` mas ainda sem uso funcional em
  nenhum contrato da Fase 1 — reservado para ações específicas da empresa emissora em
  fases futuras (ex.: propor a própria oferta).
- `ParticipacaoTokenFactory.gateway` é fixado na construção — não há setter
  timelocked para trocá-lo nesta fase (só `implementacao` e `transferPolicyPadrao`
  são trocáveis). Se uma fase futura precisar substituir o `EmissaoGateway`, isso
  exigirá adicionar esse setter então.
- Nenhum deploy em Sepolia foi feito ainda. `script/DeployFase1.s.sol` e
  `script/DeployFase2.s.sol` só rodam local (`anvil`) ou em dry-run.
- Nenhuma auditoria externa foi feita. Não descrever este código como auditado em
  nenhuma documentação futura.
- `OfertaCaptacaoFactory.gateway`/`registro`/`moeda` são fixados na construção
  (`immutable`) — sem setter, nem timelocked, nesta fase. Só `implementacao` é
  trocável. Mesma decisão já registrada acima para
  `ParticipacaoTokenFactory.gateway`.
- Regra de arredondamento de `aportar` (múltiplo exato de `precoPorCota`) significa que
  um investidor não consegue aportar um valor "quebrado" — UX real precisaria
  calcular/sugerir o múltiplo mais próximo no frontend; não implementado nesta fase.
- `OfertaCaptacao.pausar()` só bloqueia `aportar` — não existe um "pausar tudo" de
  emergência que também trave `resgatarCotas`/`reembolsar`/`liberarParaEmissor` (decisão
  deliberada: saques nunca devem poder ser congelados pela plataforma).

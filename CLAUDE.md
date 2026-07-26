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
  propose→execute, portado de `niara-contracts`). Papéis: `AGENTE_ROLE`
  (agente/plataforma, atestador/emissor autorizado) e `EMISSOR_ROLE` (reservado para
  ações futuras específicas da empresa emissora; ver `TimelockedAccessControl`).
- **Sem `CashbackDistributor`.** Taxa fica dormente/ausente nesta fase — não inserir
  nenhum número de bps de taxa até instrução explícita.
- **Unidade on-chain para aportes**: `MockBRL` (mock, 18 casas decimais) na testnet.
  Não é load-bearing nas Fases 0/1 — só entra em uso real no escrow da Fase 2.

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
- **Fase 1** (em andamento) — `ParticipacaoToken` clonável +
  `ITransferPolicy`/`DenyAllTransferPolicy` + `EmissaoGateway` +
  `ParticipacaoTokenFactory` + `TimelockedAccessControl` + testes unitários e de
  invariante.
- **Fase 2** (futura) — escrow de aportes em `MockBRL`, ciclo de vida da oferta
  (captação → liquidação → devolução se meta não atingida).
- **Fase 3** (futura) — política de transferência sofisticada (lock-up + allowlist +
  flag de liberação de secundário), trocável por governança.
- **Fase 4** (futura) — categorias adicionais (dívida/recebível).
- **Fase 5** (futura) — a definir; possivelmente integração com o site (`niara-PMEs`)
  e/ou modelo de receita.

---

## Regras inegociáveis

### Honestidade / regulatório
- Protótipo em testnet, sem mainnet, sem auditoria publicada. Formulação honesta:
  "cobertura total + invariantes por fuzzing, SEM auditoria externa".
- `MockBRL` é mock de teste, sempre rotulado como tal.
- Cap table on-chain não substitui Lei 6.404 nem cartório — sempre no NatSpec do
  token.
- Sem números de taxa nesta fase.

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
forge test --match-contract Invariant -vv   # rodada de invariantes na escala configurada
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

- `EMISSOR_ROLE` está definido em `TimelockedAccessControl` mas ainda sem uso
  funcional em nenhum contrato da Fase 1 — reservado para ações específicas da
  empresa emissora em fases futuras (ex.: propor a própria oferta).
- Nenhum deploy em Sepolia foi feito ainda. `script/DeployFase1.s.sol` só roda local
  (`anvil`) ou em dry-run.
- Nenhuma auditoria externa foi feita. Não descrever este código como auditado em
  nenhuma documentação futura.

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

A partir da Fase 4 este repositório também tem um secundário — mas **não** é um
order book P2P como o da exchange: é cessão bilateral pareada pela plataforma (ver
`LiquidacaoSecundaria`/"Arquitetura da Fase 4"), sempre atrás da restrição de
transferência da Fase 3. Continua não sendo o desenho da exchange.

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
  (lock-up + allowlist + flag de liberação) é a `RestrictedTransferPolicy` da Fase 3 —
  trocável por governança (ver "Decisões travadas — Fase 3" sobre o setter governado
  que isso exigiu adicionar no token).
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

### Decisões travadas — Fase 3 (política de transferência restrita)

- **Desvio do plano original: `ParticipacaoToken` ganhou um setter de política
  governado.** O plano da Fase 1 previa que a troca de política ficaria só na
  `transferPolicyPadrao` da factory — mas essa troca só afeta ofertas **futuras**
  (clones já criados congelam a política vigente no momento em que foram clonados, ver
  "Arquitetura da Fase 1"). Migrar uma oferta já viva de `DenyAllTransferPolicy` para
  `RestrictedTransferPolicy` — o próprio ponto da Fase 3 — exige tocar o clone
  existente. Por isso `ParticipacaoToken.setTransferPolicy(address)` foi adicionado,
  seguindo o mesmo padrão de autorização único (`onlyGateway`) das demais funções
  restritas do token (`mint`, `setCotasAutorizadas`, `pause`/`unpause`) — não um
  `AccessControl` novo no clone. A decisão de *quando* trocar é sensível (mesma
  categoria de trocar a implementação na factory), então fica atrás de timelock em
  `EmissaoGateway.proposeSetTransferPolicy`/`executeSetTransferPolicy`
  (`DEFAULT_ADMIN_ROLE`, mesmo padrão de `SET_IMPLEMENTACAO`/
  `SET_TRANSFER_POLICY_PADRAO`), não `AGENTE_ROLE` — o token só expõe o setter cru ao
  `gateway`.
- **`RestrictedTransferPolicy` é compartilhada, não clonada** — a assinatura de
  `ITransferPolicy.canTransfer(token, from, to, amount)` já recebe o endereço do token,
  então uma única instância serve qualquer número de ofertas, com todo o estado (lock-up,
  allowlist, flag mestre) keyed por `token`. Menos contratos para implantar/verificar do
  que um clone por oferta.
- **Tabela-verdade de `canTransfer`**, nesta ordem, todas necessárias: (1)
  `secundarioLiberado[token]` (flag mestre, default `false`); (2)
  `block.timestamp >= lockupAte[token]` (carência); (3) `elegivel[token][to]`
  (allowlist do destinatário). O `from` não entra na checagem — quem já detém o token é
  titular por construção (só chegou lá via mint), então a exigência da CVM 88 de
  "comprador é investidor ativo" recai só sobre `to`.
- **Separação timelock × operacional idêntica ao padrão das fases anteriores**:
  `definirElegivel`/`definirLockup` são operacionais (`AGENTE_ROLE`, imediato —
  onboarding ágil); `setSecundarioLiberado` é a única alavanca atrás de timelock nesta
  política, porque é a decisão que de fato abre negociação secundária. Ver tabela
  completa em "Arquitetura da Fase 3".
- **`definirLockup` é set-once via flag dedicada (`lockupDefinido[token]`), não
  sentinela em `lockupAte == 0`.** Um lock-up de `0` segundos ("sem carência") é uma
  configuração legítima — se o "já definido" fosse inferido do próprio valor ser
  diferente de zero, definir lock-up `0` deixaria o campo permanentemente redefinível,
  quebrando a garantia de "prazo gravado na oferta, para valer". A flag separada evita
  essa ambiguidade.
- **Honestidade regulatória**: `setSecundarioLiberado(token, true)` é a alavanca
  on-chain, mas ligá-la de verdade depende de duas condições que o contrato não
  verifica e não pode verificar — o lock-up já ter decorrido (isso sim é checado on-chain,
  em `canTransfer`) **e** a autorização de negócio/jurídica da plataforma para abrir
  aquele secundário (isso é inteiramente externo ao código, uma decisão de governança
  que antecede a chamada). Nenhuma automação deve descrever `setSecundarioLiberado`
  como, sozinho, uma aprovação regulatória.

### Decisões travadas — Fase 4 (liquidação secundária)

- **Cessão bilateral pareada, não order book.** `LiquidacaoSecundaria.liquidarCessao`
  recebe uma cessão já casada (`token`, `vendedor`, `comprador`, `quantidade`,
  `precoPorCota`) — não existe livro de ofertas, matching engine, nem função de "criar
  ordem aberta". A plataforma (AGENTE) pareia as partes off-chain; ambas pré-aprovam as
  allowances necessárias antes da submissão. Esse desenho materializa a intermediação
  que a Resolução CVM 88 exige do secundário de valores mobiliários ofertados por
  dispensa de registro, e evita a semântica de marketplace P2P irrestrito que a exchange
  (`niara-contracts`) tem.
- **Não custodia nada — opera por `allowance`, adaptado do `NiaraSettlement` da
  exchange.** `LiquidacaoSecundaria` nunca mantém saldo de `MockBRL` nem de cotas; toda
  cessão move fundos diretamente entre `vendedor`/`comprador`/`protocoloWallet` via
  `transferFrom`, atomicamente. Mesmo padrão three-party (comprador/vendedor/protocolo)
  do `NiaraSettlement`. **Conferido contra o código-fonte `NiaraSettlement.sol`** — em
  duas rodadas: primeiro contra as propriedades extraídas de `NiaraSettlement.t.sol`
  (testes), depois contra um trecho do próprio `settle` (a guarda anti-evasão de taxa,
  ver abaixo) — ver "Conferência contra `NiaraSettlement`" logo abaixo para o resultado
  completo, incluindo a confirmação de `SafeERC20` em todas as pernas e da ordem das
  transferências. `niara-contracts` como repositório completo (clone local, checkout)
  continua fora de alcance neste ambiente, mas o código relevante de `NiaraSettlement`
  já foi conferido trecho a trecho ao longo das sessões desta fase — não há mais
  pendência de "arquivo não lido" em aberto.
- **O token continua sendo a única fonte de verdade da elegibilidade.** Quando
  `liquidarCessao` chama `IERC20(token).transferFrom(vendedor, comprador, quantidade)`,
  o `_update` do `ParticipacaoToken` já consulta a `RestrictedTransferPolicy` vigente com
  `from=vendedor, to=comprador` — a mesma checagem de secundário liberado/lock-up/
  allowlist da Fase 3, sem duplicação de lógica. `LiquidacaoSecundaria` faz apenas um
  **pre-flight** (`ITransferPolicy.canTransfer`, `view`, sem efeito) antes de mover
  qualquer fundo, só para reverter cedo com um erro claro
  (`CessaoNaoPermitidaPelaPolitica`) em vez de deixar o revert acontecer no meio da
  troca. Se o pre-flight e o `_update` algum dia divergissem (não deveriam, é a mesma
  chamada de view function), a garantia que vale é sempre a do token.
- **Escala de `quantidade`/`precoPorCota`, mesma disciplina de `UNIDADE_COTA` da Fase
  2.** `quantidade` é a quantia de cotas na unidade bruta do token (18 casas, a mesma
  passada direto a `transferFrom` — sem exigir que quem chama rescale nada à parte);
  `precoPorCota` é o preço de UMA cota inteira em `MockBRL` (mesmo significado de
  `OfertaCaptacao.precoPorCota`). `valor = (quantidade * precoPorCota) / UNIDADE_COTA`
  reescala de volta antes de multiplicar pelo preço — omitir essa reescala inflaria o
  valor por `1e18`, o mesmo bug de escala já pego e corrigido em
  `OfertaCaptacao.resgatarCotas` na Fase 2. Decisão deliberada: o texto original da
  tarefa desta fase descrevia `valor = quantidade * precoPorCota` sem reescala visível —
  seguir isso literalmente teria reintroduzido exatamente aquele bug de escala; a
  reescala foi adicionada de propósito e travada por teste
  (`test_LiquidarCessao_MovesCotasAndMoeda_SemTaxa`, que verifica o valor exato).
- **Taxa do secundário é independente da taxa da primária.** `taxaSecundarioBps` (Fase
  4) e `OfertaCaptacao.taxaBps` (Fase 2) são parâmetros distintos, cada um com seu
  próprio teto rígido de 100 bps e default `0` — nada impede alíquotas diferentes entre
  primário e secundário; não hardcodar nenhum dos dois até instrução explícita.
- **`LiquidacaoSecundaria` reutiliza `AGENTE_ROLE`/`TimelockedAccessControl`, não
  reinventa governança.** É um contrato único (não clonado, como `RestrictedTransferPolicy`
  — não como `OfertaCaptacao`), então declara seu próprio `AGENTE_ROLE` e herda
  `TimelockedAccessControl` diretamente, no mesmo padrão de `EmissaoGateway`/
  `RegistroInvestidorQualificado`/`RestrictedTransferPolicy`. `AGENTE_ROLE` precisa ser
  concedido nela separadamente — ver "Arquitetura da Fase 4" para a contagem atualizada
  de contratos que exigem o papel.
- **Validação de token conhecido via `IParticipacaoTokenFactory.isOferta`.**
  `liquidarCessao` reverte cedo (`TokenDesconhecido`) se `token` não foi criado pela
  `ParticipacaoTokenFactory` apontada na construção — evita liquidar cessões sobre um
  endereço arbitrário que não seja sequer um `ParticipacaoToken` desta plataforma.

### Conferência contra `NiaraSettlement`

Em duas rodadas, o comportamento de `NiaraSettlement` foi conferido item a item contra
`LiquidacaoSecundaria`: primeiro contra as propriedades extraídas de
`NiaraSettlement.t.sol` (testes), depois contra um trecho do código-fonte do próprio
`settle` (a guarda anti-evasão de taxa). Resultado:

| Propriedade | Situação antes | O que mudou |
|---|---|---|
| Troca atômica por `allowance`, sem custódia | Já conforme (desde a implementação inicial) | — |
| `SafeERC20.safeTransferFrom` nas três pernas (pagamento ao vendedor, taxa ao protocolo, cota ao comprador) | Já conforme (`using SafeERC20 for IERC20` cobre `moeda` e `token`) | Confirmado, nenhuma mudança necessária |
| Taxa com teto rígido via timelock | Já conforme (`TAXA_BPS_MAXIMA = 100`, `propose`/`execute`) | — |
| Reentrância bloqueada (lado do pagamento) | Já conforme (`nonReentrant`, testado com `ReentrantMockBRL`) | — |
| `BuyerEqualsSeller` | Ausente | Adicionado: `VendedorIgualComprador()`, checado antes de qualquer outra validação |
| `ZeroAmount` (quantidade) | Já conforme (`QuantidadeInvalida`) | — |
| `ZeroAmount` (valor de pagamento) | Ausente (gap real: `quantidade`/`precoPorCota` != 0 não impedia o `valor` derivado arredondar para `0` por divisão inteira) | Adicionado: `ValorInvalido()`, checado após calcular `valor` |
| **Anti-evasão por fracionamento** (`PaymentAmountTooSmallForFeePrecision` na referência) | Ausente (gap real: com taxa ativa, um `valor` pequeno o bastante fazia `taxa` truncar a `0` por divisão inteira — fracionar uma cessão grande em muitas minúsculas escaparia da taxa) | Adicionado: `ValorInsuficienteParaPrecisaoDaTaxa()`, `if (taxaSecundarioBps > 0 && taxa == 0) revert ...`, logo após calcular `taxa`. Inócuo com a taxa dormente (`0`), mas fecha a brecha antes dela ser ativada |
| `ZeroAddress` (token/comprador/vendedor) | Ausente em `liquidarCessao` (só existia no construtor/setters) | Adicionado: reaproveita o `ZeroAddress()` já existente, checado primeiro na função |
| `Pausable` com papel de pausa | Ausente | Adicionado: `pause()`/`unpause()` — **decisão deliberada**: reaproveita `AGENTE_ROLE` (mesmo papel operacional único usado para pausa em `ParticipacaoTokenFactory`/`OfertaCaptacaoFactory`), não um `PAUSER_ROLE` novo como na referência — este repositório nunca fragmentou pausa em um papel à parte, e criar um agora só para este contrato quebraria essa consistência sem necessidade |
| Reentrância pelo lado do ATIVO | Não aplicável — ver justificativa abaixo | Documentado em vez de forçado um teste artificial |
| `settle` retorna a taxa cobrada | Ausente (`liquidarCessao` não retornava nada) | Adicionado: `returns (uint256 taxa)` |
| Guarda de teto repetida no `execute` | Ausente (`executeSetTaxaSecundarioBps` só confiava na validação do `propose`) | Adicionado: mesma checagem de `TAXA_BPS_MAXIMA` repetida no `execute`, coberta por teste que chama `execute` diretamente sem `propose` |
| Ordem das transferências (ativo → pagamento → taxa na referência) | `LiquidacaoSecundaria` faz pagamento → taxa → ativo, ordem invertida | **Divergência deliberada, documentada em vez de alterada** — ver abaixo |

**Ordem das transferências — por que a divergência foi mantida**: no `NiaraSettlement` a
ordem é ativo primeiro, pagamento depois. Em `LiquidacaoSecundaria` é o inverso: as duas
pernas de `MockBRL` primeiro, o `transferFrom` do token por último. Sendo tudo atômico
(`nonReentrant`, um único `liquidarCessao`), a ordem não muda o resultado final em caso de
sucesso ou revert — mas manter o `transferFrom` do TOKEN como a última chamada reforça, no
próprio código, o tema já documentado no NatSpec do contrato: o pre-flight de
`canTransfer` serve só para reverter cedo com um erro claro; a checagem que de fato
autoriza a cessão é o `_update` do token, disparado por essa última chamada — ela fica
posicionada como o gate final da sequência, não uma perna qualquer no meio. Comentado
inline no código (`liquidarCessao`).

**Reentrância pelo lado do ativo — por que não se aplica aqui**: no `NiaraSettlement` o
ativo negociado é um ERC-20 arbitrário (qualquer par pode ser listado na exchange), então
precisa ser tratado como potencialmente malicioso — daí o teste de reentrada também pelo
lado do ativo. Em `LiquidacaoSecundaria`, `token` já passou pelo pre-flight
`factory.isOferta(token)`: é sempre um `ParticipacaoToken` clonado da implementação única
desta plataforma, nunca um ERC-20 arbitrário. O caminho de `transferFrom` desse token
(`_update` → `ITransferPolicy.canTransfer`, uma `view` sem efeito colateral, →
`super._update` padrão da OZ) não tem nenhum hook externo com código controlável por
terceiro. Forçar um teste de reentrada nesse lado exigiria forjar um "ParticipacaoToken"
malicioso que nunca existiria em produção (a implementação é fixa e auditável, clonada via
EIP-1167) — o teste seria artificial, não uma prova de nada que possa acontecer de
verdade. Registrado como justificativa, não como lacuna.

**Divergência intencional — destino da taxa**: `NiaraSettlement` envia a taxa para um
`CashbackDistributor`. `LiquidacaoSecundaria` envia direto para `protocoloWallet`. Isto é
deliberado, não uma omissão: este repositório nunca teve `CashbackDistributor` (ver
"Visão do produto" e "Decisões travadas" no topo deste arquivo) — cashback por volume de
negociação é um mecanismo da exchange que não se aplica ao modelo primário/secundário
restrito das PMEs, onde a intermediação já é a plataforma, não um mercado aberto a
incentivar com cashback. Não reintroduzir `CashbackDistributor` nesta ou em fases
futuras sem instrução explícita.

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
- **`NiaraSettlement.sol`** → padrão adaptado para `src/secundario/LiquidacaoSecundaria.sol`
  (Fase 4): liquidação atômica three-party (comprador/vendedor/protocolo) operando por
  `allowance`, sem custodiar fundos, `SafeERC20` nas três pernas, taxa de teto rígido de
  100 bps e a mesma guarda anti-evasão por fracionamento
  (`PaymentAmountTooSmallForFeePrecision` na referência,
  `ValorInsuficienteParaPrecisaoDaTaxa` aqui). O repositório `niara-contracts` completo
  nunca esteve acessível nas sessões em que a Fase 4 foi implementada e conferida (não
  está no disco, não é público no GitHub, sem `gh` CLI/credenciais no ambiente) — a
  implementação partiu da descrição funcional do padrão e a conferência, em duas
  rodadas, das propriedades de `NiaraSettlement.t.sol` e depois de um trecho do
  código-fonte de `settle` fornecidos na instrução. Ver "Conferência contra
  `NiaraSettlement`" (dentro de "Decisões travadas — Fase 4") para o resultado item a
  item.

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
- **Fase 3** (concluída) — política de transferência sofisticada:
  `RestrictedTransferPolicy` (lock-up + allowlist + flag de liberação de secundário) +
  setter de política governado em `ParticipacaoToken` (desvio do plano original, ver
  "Decisões travadas — Fase 3") + extensão de `EmissaoGateway` (troca de política via
  timelock) + testes unitários e de invariante da tabela-verdade. Ver "Arquitetura da
  Fase 3" e "Resultados de teste (Fase 3)" abaixo.
- **Fase 4** (concluída) — liquidação secundária: `LiquidacaoSecundaria` (cessão
  bilateral pareada pela plataforma, gated pela `RestrictedTransferPolicy` da Fase 3,
  padrão adaptado do `NiaraSettlement` da exchange) + testes unitários, de reentrância e
  de invariante de conservação/atomicidade. Ver "Arquitetura da Fase 4" e "Resultados de
  teste (Fase 4)" abaixo.
- **Fase 5** (futura) — categorias adicionais (dívida/recebível).
- **Fase 6** (em andamento) — integração com o site (`niara-PMEs`): o frontend passou a
  ler/escrever de verdade contra a infraestrutura já implantada em Sepolia (Fase 4), via
  `script/DemoNiaraPMEsOnChain.s.sol` (ver abaixo) + `src/lib/web3/` naquele repositório.
  Nenhum contrato novo foi implantado para isso — só uma nova chamada de escrita
  (`criarOferta`/`atestarCotas`/`criarCaptacao`/`registrarCaptacao`) usando os factories já
  verificados e o `AGENTE_ROLE` já concedido ao deployer.
- **`OfertaOrquestrador`** (concluída — implementação e deploy real em Sepolia) — canal
  self-service aditivo: a própria empresa emissora, previamente autorizada, cria sua oferta
  (token + captação) numa única transação atômica, sem ganhar poder sobre parâmetros de
  plataforma. Não substitui nem altera nenhuma fase anterior — é um segundo caminho para o
  mesmo resultado (a criação manual pelo AGENTE continua funcionando sem mudança). Ver
  `PLANO_OFERTA_ORQUESTRADOR.md` (desenho) e "`OfertaOrquestrador` — canal self-service"
  abaixo (deploy real e resultados).

### 🔴 Chave do deployer da Fase 4 perdida — infraestrutura redeployada em 2026-08-15

A chave do deployer original da Fase 4 (`0x101e8ad58F2D2A923553FeFE558a7bEf5566871E`,
documentada em `DEMO_SECUNDARIO_SEPOLIA.md`) foi perdida (não encontrada em nenhuma
carteira MetaMask). Como `admin_` desse deployer foi o único endereço a receber
`DEFAULT_ADMIN_ROLE` em todos os 6 contratos que o exigem (conferido em
`_deployInfra(admin, protocoloWallet)`, `script/DemoSecundarioSetup.s.sol:74-95` — o mesmo
`admin` é passado a todos os construtores) e `grantRole`/`revokeRole` padrão estão
desabilitados (`TimelockedAccessControl.sol:102-110`), não havia caminho on-chain para
recuperar acesso — os 10 contratos originais da Fase 4 (ver tabela em
`DEMO_SECUNDARIO_SEPOLIA.md`) ficaram permanentemente órfãos. `DEMO_SECUNDARIO_SEPOLIA.md`
**não foi apagado** (continua documentando aquele deploy histórico), mas os endereços de
lá não são mais operáveis — usar sempre os endereços novos abaixo.

`script/DemoSecundarioSetup.s.sol` foi rodado de novo, com uma carteira burner nova
(`0x0D41059eBde70a46EB5207af0837921594CAFC05`), confirmando os 10 deploys + as 6 propostas
de `AGENTE_ROLE` on-chain (nonce 0→16, saldo debitado — verificado via `cast`, não só pelo
log do script). Depois de esperar a 1h real do timelock, `AGENTE_ROLE` foi executado e a
oferta de demo criada (ver seção seguinte) — tudo lido de volta da chain via `cast call`
antes de ser considerado confirmado.

| Contrato | Endereço novo (2026-08-15) |
|---|---|
| MockBRL | `0xb99dda4e4d89f40324A7831970b8f37dBc35668F` |
| DenyAllTransferPolicy | `0x28020B9370E140b5a542443a767F2f016b9a461A` |
| RestrictedTransferPolicy | `0x0Ea184A5A02f2104D250ff7fA2F97d26FcceFb42` |
| ParticipacaoToken (implementação) | `0xf603fc5dEb042053567ebEB0cEc1CCe646B63346` |
| EmissaoGateway | `0x3082981ceE0068c0B9d6144edB1B0CEE14931a6E` |
| ParticipacaoTokenFactory | `0xD12808283E953E975f46799B1Eac0ad88BfbA697` |
| RegistroInvestidorQualificado | `0xd5608D6FAAAC715eE9edeB2c47fe1f2De86F64F5` |
| OfertaCaptacao (implementação) | `0x53a7C7F8a5E88DD9db8Ee8109f44aA7BCB08552B` |
| OfertaCaptacaoFactory | `0x28BE1a83189CA6Bc8A163dC7bf659FAF09621dA7` |
| LiquidacaoSecundaria | `0x156aa697739eCa43ED0916D58C4913b4863629ac` |

Deployer/admin/agente novo: `0x0D41059eBde70a46EB5207af0837921594CAFC05` — chave privada
só em `.env` local (gitignored), nunca impressa em log/console/chat.

### `script/DemoNiaraPMEsOnChain.s.sol` (Fase 6 — oferta para o frontend real)

Cria UMA nova oferta de captação por execução, reaproveitando por completo a infra acima
(nenhum contrato novo) — pensada para ser consumida pelo fluxo real de `/investir/onchain`
do `niara-PMEs`. Também executa (não só propõe) o `AGENTE_ROLE` pendente nos 3 contratos
que usa, de forma **idempotente** (`_executarAgente` faz `hasRole` antes de chamar
`executeGrantRole` — pula se já concedido, em vez de reverter com `ActionNotPending`) —
substitui, só para este caso, o `DemoSecundarioPreparar.s.sol` original (que também prepara
vendedor/comprador/lockup do secundário, fora de escopo aqui). Essa idempotência é o que
permite **rodar o script várias vezes seguidas para criar várias ofertas**, não só uma —
ver "10 ofertas de reserva" abaixo. Parâmetros pequenos de propósito (`metaMinima=100
mBRL`, `metaMaxima=200 mBRL`, `precoPorCota=10 mBRL`, `tetoPorInvestidor=200 mBRL` — igual
à meta máxima, para uma única carteira conseguir fechar a oferta sozinha) — ver NatSpec do
próprio script para o raciocínio completo, incluindo por que `encerrar()` consegue fechar
antes do prazo de 180 dias (atingindo `metaMaxima` exatamente).

**Primeira oferta, rodada em 2026-08-15** (`--broadcast`, confirmado via `cast call` contra
o estado real, não só o log do script) — testada ponta a ponta pela UI de verdade no mesmo
dia (mint → aportar 2x → encerrar → resgatar), **já encerrada**:

| | Endereço |
|---|---|
| Token (ParticipacaoToken da oferta) | `0xAD141F009160789A50C93f116a41635a31EbEE3A` |
| Oferta (escrow OfertaCaptacao) | `0x8390a7dCD1a379B99b67E3876c1bf200A27C57c6` |

### 10 ofertas de reserva para o Startup Summit (2026-08-15)

Criadas rodando o script 10x em sequência, todas confirmadas `estado=Aberta` via `cast
call` antes de considerar prontas. Pensadas para uma demo presencial (apresentador guia um
visitante por vez, troca de oferta entre uma demo e outra pelo seletor da UI — ver
`niara-PMEs/CLAUDE.md`, "Uma ou várias ofertas") — nenhuma delas foi tocada pela UI ainda,
todas com `totalArrecadado=0`. Já carregadas em `NEXT_PUBLIC_OFERTAS_ONCHAIN` no
`.env.local`/deploy do `niara-PMEs`.

| # | Token (ParticipacaoToken) | Oferta (OfertaCaptacao) |
|---|---|---|
| 1 | `0x4DDDD5DeF833f9Ad3F6f714661a55fDC0D71d18D` | `0xd4AC69a4c7Bfdc5E85c0e0da76ce12a1552b2704` |
| 2 | `0x42B054aA3A6b4Eb4fDEd2E81E145C4C30268494b` | `0xcB5B8D945996114F781DD729F229638192d18258` |
| 3 | `0xdb7c0A4059384b6Dd36354b6897419d968B739be` | `0xDd9a14c221C6d9E2Cf33c56d8A4bF7C8BDfAF938` |
| 4 | `0x4f92299B02A677b4b9888da16096763c2D60f1d8` | `0x29f10569644871BcD57e442E8802434D963688d9` |
| 5 | `0xA1a2C9F3877ddAE6eC5dcedE9Cf00c3e4cD1A1F6` | `0xfAa7946221F4a1D66c1B172bed79cF37ca003261` |
| 6 | `0x2fA50be34DF5C123B4f12B1f12A79C3bc12F4B9D` | `0xa60119428905fDf66BF967DE90A2F892985d99b2` |
| 7 | `0x076f06668F04cF5Bf7fB33a2aAaFe58e72881DD9` | `0xE4E7c347823f648aBba73B31855E2Fc1D7fE2fb1` |
| 8 | `0x757534f9A0bfEF76C1f8532a3561670F481dcCc5` | `0x4378E93588603385B1A51b74c06c0a9FCfc66A16` |
| 9 | `0x944ad3048F9940F53eA68d6546FB7029afe70601` | `0xd720e3E0f53B7BA278A2beE99Da7F0Edd1F14B9c` |
| 10 | `0x466e066d155724b62e75De340ceF7097D3996176` | `0xaef8C045cAaBe0F283bD92893031F4f2644d534F` |

🔴 Cada uma consome parte do saldo de Sepolia ETH do deployer
(`0x0D41059eBde70a46EB5207af0837921594CAFC05`, ~0.0025 ETH por oferta) — se o evento exigir
mais de 10 demonstrações completas, rodar o script de novo (idempotente, sem timelock,
`AGENTE_ROLE` já ativo) e verificar o saldo antes via `cast balance`.

Estado on-chain conferido: `estado=0` (Aberta), `metaMinima=100 ether`,
`metaMaxima=200 ether`, `precoPorCota=10 ether`, `tetoPorInvestidor=200 ether`,
`token.cotasAutorizadas=20 ether` (20 cotas, reescalado certo). Esses 3 endereços (token +
oferta + `MockBRL` fixo da tabela acima) já estão em `niara-PMEs/.env.local`
(`NEXT_PUBLIC_MOCKBRL_ADDRESS`/`NEXT_PUBLIC_PARTICIPACAO_TOKEN_ADDRESS`/
`NEXT_PUBLIC_OFERTA_CAPTACAO_ADDRESS`) — `/investir/onchain` já lê a oferta real.

### `OfertaOrquestrador` — canal self-service (implementação + deploy real em Sepolia)

Contrato aditivo (`src/orquestracao/OfertaOrquestrador.sol`, commit `0216eb0`) que permite a
própria empresa emissora, previamente autorizada, criar sua oferta (token + captação) numa
única transação atômica (`criarOfertaCompleta`), sem ganhar poder sobre `cotasAutorizadas`,
`taxaBps`, `protocoloWallet` ou `tetoPorInvestidor` — ver `PLANO_OFERTA_ORQUESTRADOR.md`
para o desenho completo e `test/OfertaOrquestrador.t.sol` + `test/InvariantOrquestrador.t.sol`
para a suíte (43 testes unitários + 6 invariantes de fuzzing stateful, 100% de cobertura
linha/statement/branch/função no contrato novo). Nenhum contrato existente mudou de
comportamento.

Deploy real em Sepolia (`script/DeployFase2Sepolia.s.sol` + `script/
DeployFase2SepoliaExecute.s.sol`, 2026-09-24) e primeira oferta self-service de verdade
("Padaria Silva", R$ 600.000 captados, taxa de 1% dividida on-chain entre protocolo e
emissor) — cronologia completa de transações, roteiro de demonstração e limitações em
`DEMO_SEPOLIA.md`, seção "Resultados — primeira oferta self-service real".

🔴 **`TIMELOCK_DELAY = 1 hora` usado neste deploy é valor de protótipo, não de produção.**
`TimelockedAccessControl.MIN_TIMELOCK_DELAY` (1h) é o **mínimo** permitido pelo contrato
(`MAX_TIMELOCK_DELAY` é 30 dias) — o deploy real usou exatamente esse mínimo, escolhido para
não segurar a demonstração por dias, não porque 1h seja um delay de governança adequado. Um
deploy de produção deveria usar um delay bem maior (ordem de grandeza recomendada: ~48h),
para dar tempo real de alguém reagir a uma proposta de troca de papel/parâmetro incorreta ou
maliciosa antes que ela possa ser executada. Nada no código impede um delay maior — é uma
escolha de parâmetro no momento do deploy (`timelockDelay_` do construtor), não uma
limitação do contrato.

🔴 **Gás na Sepolia variou de forma acentuada dentro da MESMA sessão de deploy/demo** —
de ~1 gwei a dezenas de gwei — com uma única chamada de `aportar` custando ~0.018 ETH numa
dessas janelas de pico. Qualquer demonstração ao vivo em Sepolia precisa (a) de uma folga de
saldo bem acima do custo estimado a partir de um gás baixo observado anteriormente, e (b)
ser preparada com **dias de antecedência**, não na mesma sessão em que vai ser apresentada —
Sepolia ETH de faucet é limitado, e um pico de gás inesperado pode consumir saldo mais
rápido do que o planejado no meio de uma demo.

Endereços da infraestrutura implantada para este canal (nova infra de referência —
**não substitui** a tabela de endereços da Fase 4/Fase 6 acima, que serve o fluxo
`/investir/onchain` do frontend via AGENTE manual; esta serve o canal self-service do
emissor):

| Contrato | Endereço |
|---|---|
| MockBRL | `0xEC377e00e022675B67Da6ab1966Bc0764bF792A4` |
| DenyAllTransferPolicy | `0xC763cd522B8D4632ccd1adE698BAD09Be22f6a69` |
| ParticipacaoToken (implementação) | `0x367D71E1A578a1Ac061991aCa8f302f9119dB603` |
| EmissaoGateway | `0xeaedcAea403F793AFf6c345a5321c05eE55Cb1FE` |
| ParticipacaoTokenFactory | `0xA116Aeb034633ef58AF68A387778C59f99FE9539` |
| RegistroInvestidorQualificado | `0x5BE2cF3f1aeA02987Bea87a635FC9ba7BdF04732` |
| OfertaCaptacao (implementação) | `0x46c6690Db2Ad39AF5Fa29581Ed01172a65949656` |
| OfertaCaptacaoFactory | `0x5E248656516140360ADEFB66c1095ef0951e45cB` |
| OfertaOrquestrador | `0xde9cC84d1300b57F640f2d1862900393b82796e5` |

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

## Arquitetura da Fase 3

```
RestrictedTransferPolicy (TimelockedAccessControl, ITransferPolicy)
  ├─ AGENTE_ROLE — definirElegivel(token, investidor, bool) [imediato]
  │              — definirLockup(token, lockupAte) [imediato, set-once por token]
  ├─ DEFAULT_ADMIN_ROLE (timelock) — proposeSetSecundarioLiberado/executeSetSecundarioLiberado
  └─ canTransfer(token, from, to, amount):
       secundarioLiberado[token] && block.timestamp >= lockupAte[token] && elegivel[token][to]

ParticipacaoToken — ESTENDIDO na Fase 3
  └─ setTransferPolicy(novaPolitica) [onlyGateway] — troca transferPolicy de um clone já vivo

EmissaoGateway (TimelockedAccessControl) — ESTENDIDO na Fase 3
  └─ proposeSetTransferPolicy/executeSetTransferPolicy(token, novaPolitica)
     [DEFAULT_ADMIN_ROLE, timelock] → chama token.setTransferPolicy(novaPolitica)
```

Uma única `RestrictedTransferPolicy` serve qualquer número de ofertas — todo o estado
(lock-up, allowlist, flag mestre) é keyed por `token`, aproveitando que
`ITransferPolicy.canTransfer` já recebe o endereço do token na assinatura (ver
"Decisões travadas — Fase 3"). `from` nunca é checado: quem detém o token é titular por
construção (só mint concede saldo), então a exigência de "comprador é investidor ativo"
da CVM 88 recai só sobre `to`.

### Separação timelock × operacional (Fase 3)

| Ação | Categoria |
|---|---|
| `definirElegivel`, `definirLockup` | Operacional (AGENTE, imediato — onboarding ágil) |
| `setSecundarioLiberado` (a alavanca que de fato abre negociação) | Timelock (1h, propose→execute, `DEFAULT_ADMIN_ROLE`) |
| `setTransferPolicy` do token (trocar a política de uma oferta já viva) | Timelock (1h, propose→execute, via `EmissaoGateway`, `DEFAULT_ADMIN_ROLE`) |

Apontar um token para a `RestrictedTransferPolicy` antes de configurar lock-up/allowlist
é seguro: enquanto `secundarioLiberado[token] == false` (o default), `canTransfer`
continua negando tudo — a mesma garantia de "estado inicial travado" que
`DenyAllTransferPolicy` dava, só que agora reversível por governança em vez de fixa.

---

## Arquitetura da Fase 4

```
LiquidacaoSecundaria (TimelockedAccessControl, ReentrancyGuard, Pausable)
  ├─ moeda, factory (immutable, fixos na construção — mesma decisão já registrada para
  │  OfertaCaptacaoFactory.gateway/registro/moeda em "Pendências conhecidas")
  ├─ protocoloWallet, taxaSecundarioBps (<= 100, default 0) — trocáveis via timelock
  ├─ pause()/unpause() [AGENTE_ROLE] — emergência, mesmo padrão de pausa das factories
  └─ liquidarCessao(token, vendedor, comprador, quantidade, precoPorCota)
       [AGENTE_ROLE, whenNotPaused] returns (uint256 taxa)
       0. guardas defensivas: token/vendedor/comprador != address(0);
          vendedor != comprador                              — conferidas contra NiaraSettlement
       1. factory.isOferta(token)                          — token conhecido
       2. policy.canTransfer(token, vendedor, comprador, quantidade)  — pre-flight (view)
       3. valor = (quantidade * precoPorCota) / UNIDADE_COTA; reverte se valor == 0
          taxa = valor * bps / 10_000
       4. moeda.transferFrom(comprador, vendedor, valor - taxa)
       5. se taxa > 0: moeda.transferFrom(comprador, protocoloWallet, taxa)
       6. token.transferFrom(vendedor, comprador, quantidade)  — dispara _update do
          token, que consulta a RestrictedTransferPolicy de novo; é essa chamada,
          não o pre-flight do passo 2, que efetivamente vale
```

Requisitos de allowance (a plataforma nunca custodia nada — ver "Decisões travadas —
Fase 4"): o **vendedor** aprova `LiquidacaoSecundaria` para mover suas cotas
(`ParticipacaoToken.approve`); o **comprador** aprova para mover seu `MockBRL`
(`MockBRL.approve`). Sem as duas aprovações pré-existentes, `liquidarCessao` reverte
limpo (erro padrão de allowance insuficiente do ERC-20 da OZ), sem estado parcial —
qualquer perna que falhe desfaz as pernas já executadas antes dela na mesma transação.

### Separação timelock × operacional (Fase 4)

| Ação | Categoria |
|---|---|
| `liquidarCessao` | Operacional (AGENTE, imediato — é por-negociação, não pode esperar 1h) |
| `pause`/`unpause` | Operacional (AGENTE, imediato — emergência não pode esperar 1h, mesmo padrão de `ParticipacaoTokenFactory`/`OfertaCaptacaoFactory`) |
| `setTaxaSecundarioBps`, `setProtocoloWallet` | Timelock (1h, propose→execute, `DEFAULT_ADMIN_ROLE`) |

Com a Fase 4, `AGENTE_ROLE` passa a precisar ser concedido **em 6 contratos
independentes** para operação completa da plataforma (primário + secundário):
`EmissaoGateway`, `ParticipacaoTokenFactory`, `RegistroInvestidorQualificado`,
`OfertaCaptacaoFactory` (Fases 1/2), `RestrictedTransferPolicy` (Fase 3) e
`LiquidacaoSecundaria` (Fase 4) — cada um com seu próprio `TimelockedAccessControl`.

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

## Resultados de teste (Fase 3)

- `forge build`: sem erros (mesma suíte da Fase 1 + Fase 2 + Fase 3).
- `forge test`: **220/220 passando** — 196 unitários + 24 invariantes (6 da Fase 1 + 12
  da Fase 2 + 6 novos da Fase 3), sem nenhuma regressão nas suítes das Fases 1/2 após
  estender `ParticipacaoToken`/`EmissaoGateway`. Contribuição da Fase 3: 19 testes em
  `test/RestrictedTransferPolicy.t.sol` (tabela-verdade, acesso, set-once, isolamento
  por token) + 3 em `test/RestrictedTransferPolicyIntegration.t.sol` (mint/resgate
  continuam funcionando com a Restricted anexada + ciclo completo de abertura) + 4 novos
  em `test/ParticipacaoToken.t.sol` (`setTransferPolicy`) + 6 novos em
  `test/EmissaoGateway.t.sol` (`proposeSetTransferPolicy`/`executeSetTransferPolicy`) +
  6 invariantes novas em `test/InvariantPolitica.t.sol`.
- `forge coverage` nos contratos principais da Fase 3 (`RestrictedTransferPolicy`, e as
  extensões de `ParticipacaoToken`/`EmissaoGateway`) — **100%
  linha/statement/branch/função**, mesma barra das Fases 1/2. `DenyAllTransferPolicy`
  mantém a mesma limitação conhecida do instrumentador (não é lacuna real, ver
  "Resultados de teste (Fase 1)"). Scripts de deploy/demo ficam em 0% de propósito.
- Invariantes da política restrita (`forge test --match-contract InvariantPoliticaTest`),
  mesma escala configurada (`runs=256 * depth=100` = 25.600 chamadas por invariante),
  **zero violações**, ~5,5% das chamadas revertendo de propósito (`tentarLockupDuplicado`
  — a única ação "caótica" desta suíte, já que a maior parte das demais ações não tem
  um caminho inválido natural a explorar além do que já é coberto por
  `NoUnauthorizedOperationalCallEverSucceeded`/`NoUnauthorizedSecundarioToggleEverSucceeded`).
  As 6 invariantes verificadas:
  1. Nenhuma transferência titular→titular teve um resultado (sucesso/revert)
     diferente do previsto pela tabela-verdade
     (`secundarioLiberado && !lockup && elegivel[to]`) — a prova central da Fase 3.
  2. `gateway.emitir` (mint, dentro do teto atestado) nunca falhou por causa do estado
     da `RestrictedTransferPolicy` anexada — mint nunca consulta a política (ver
     `ParticipacaoToken._update`, `from == address(0)`).
  3. Nenhuma chamada sem `AGENTE_ROLE` a `definirElegivel`/`definirLockup` jamais teve
     sucesso.
  4. Nenhuma chamada sem `DEFAULT_ADMIN_ROLE` a `proposeSetSecundarioLiberado` jamais
     teve sucesso.
  5. Nenhum segundo `definirLockup` no mesmo token jamais teve sucesso ("set-once").
  6. Nenhum vazamento de estado entre tokens: o espelho mantido pelo handler
     (`ghost_*Esperado`, atualizado a cada escrita bem-sucedida) bate com os getters
     reais da política para todo token e todo investidor rastreado, em toda chamada da
     sequência — prova de isolamento por token "de graça", já que uma escrita vazando
     de `tokenA` para `tokenB` divergiria o espelho de `tokenB`.
- `script/DemoFase3.s.sol` foi validado de duas formas, mesmo padrão dos scripts
  anteriores:
  - **Dry-run**: mostra os 4 passos em sequência — (1) secundário desligado
    (`DenyAllTransferPolicy`): transferência reverte; (2) token já aponta para a
    `RestrictedTransferPolicy`, mas ainda travado (`secundarioLiberado == false`,
    dentro do lock-up): transferência continua revertendo, provando que "apontar cedo
    é seguro"; (3) secundário liberado e após o lock-up, mas destinatário fora da
    allowlist: reverte; (4) secundário liberado, após o lock-up, destinatário
    elegível: passa. Log final mostra saldos e o estado completo da política.
  - **Broadcast contra `anvil` local**: falha, de propósito, no mesmo ponto que
    `DeployFase1`/`DeployFase2` — `executeGrantRole` com `TimelockNotElapsed`.
    Comportamento esperado, não é bug.

---

## Resultados de teste (Fase 4)

- `forge build`: sem erros (mesma suíte da Fase 1 + Fase 2 + Fase 3 + Fase 4).
- `forge test`: **266/266 passando** — 236 unitários + 30 invariantes (6 da Fase 1 + 12
  da Fase 2 + 6 da Fase 3 + 6 da Fase 4), sem nenhuma regressão nas suítes anteriores.
  Contribuição da Fase 4 original: 24 testes em `test/LiquidacaoSecundaria.t.sol` +
  1 em `test/LiquidacaoSecundariaReentrancy.t.sol` + 6 invariantes em
  `test/InvariantSecundario.t.sol`. Duas rodadas de conferência contra `NiaraSettlement`
  depois (ver "Decisões travadas — Fase 4"): **+12 testes** contra as propriedades de
  `NiaraSettlement.t.sol` (um revert por guarda nova — `VendedorIgualComprador`,
  `ValorInvalido`, `ZeroAddress` em `token`/`vendedor`/`comprador` —, dois para o
  retorno de `taxa`, quatro para `pause`/`unpause`, um para a guarda defensiva de teto
  no `execute` chamado sem `propose`) e **+3 testes** contra o trecho de código-fonte de
  `settle` (a guarda anti-evasão: reverte quando a taxa trunca a zero, passa quando o
  valor é suficiente, e confirma que a guarda não dispara com a taxa dormente).
- `forge coverage` nos contratos principais da Fase 4 (`LiquidacaoSecundaria`, e as
  pequenas extensões de `IParticipacaoToken`/nova `IParticipacaoTokenFactory`) — **100%
  linha/statement/branch/função**, mesma barra das fases anteriores. As guardas
  acumuladas nas duas rodadas de conferência elevaram `LiquidacaoSecundaria` de 44/44
  para 53/53 linhas e de 8/8 para 13/13 branches, todas cobertas. `DenyAllTransferPolicy`
  mantém a mesma limitação conhecida do instrumentador (não é lacuna real, ver
  "Resultados de teste (Fase 1)"). Scripts de deploy/demo ficam em 0% de propósito.
- Teste de reentrância dedicado (`test/LiquidacaoSecundariaReentrancy.t.sol`), mesmo
  padrão de `OfertaCaptacaoReentrancy.t.sol` (Fase 2): `ReentrantMockBRL` tenta reentrar
  `liquidarCessao` a partir do próprio `transferFrom` — bloqueada pelo `nonReentrant`, e
  a cessão original completa com sucesso exatamente uma vez (sem duplo movimento de
  cotas nem de moeda).
- Invariantes de conservação/atomicidade (`forge test --match-contract
  InvariantSecundarioTest`), mesma escala configurada (`runs=256 * depth=100` = 25.600
  chamadas por invariante), **zero violações**. Todas as ações do handler usam
  `try/catch` (a mesma prática de `HandlerCaptacao`), então o quadro de reverts por
  seletor fica zerado por desenho — o que importa é a ausência de violação nas 6
  invariantes abaixo, não a taxa de revert bruta:
  1. `moeda.balanceOf(ator) == ghost_moedaEsperada(ator)`, para todo ator rastreado e o
     `protocoloWallet` — conservação de `MockBRL`, provada por um espelho atualizado com
     a MESMA aritmética que `liquidarCessao` deveria aplicar a cada entrada de saldo
     (mint) e a cada cessão bem-sucedida.
  2. `token.balanceOf(ator) == ghost_cotasEsperadas(token, ator)`, para todo token e
     ator rastreado — conservação de cotas, mesmo mecanismo de espelho. Como só há duas
     vias mirroradas de saldo (mint via gateway, cessão bem-sucedida), qualquer bug de
     conservação (perder poeira, duplicar uma perna, aplicar taxa errada) ou qualquer
     cessão bloqueada que mesmo assim movesse fundos apareceria como divergência —
     provando conservação E atomicidade na mesma checagem.
  3. Nenhuma `liquidarCessao` bem-sucedida ocorreu com
     `policy.canTransfer(token, vendedor, comprador, quantidade) == false` no momento da
     chamada — o gate Fase 3 ↔ Fase 4 nunca é contornado.
  4. Nenhuma chamada sem `AGENTE_ROLE` a `liquidarCessao` jamais teve sucesso.
  5. Nenhuma chamada sem `DEFAULT_ADMIN_ROLE` a `proposeSetTaxaSecundarioBps`/
     `proposeSetProtocoloWallet` (nem a `RestrictedTransferPolicy.
     proposeSetSecundarioLiberado`, verificado aqui em profundidade defensiva) jamais
     teve sucesso.
  6. `taxaSecundarioBps` nunca excedeu `TAXA_BPS_MAXIMA` (100), em nenhum momento da
     sequência.
- Decisão de escala tomada durante o desenvolvimento desta fase (não um bug pego DEPOIS,
  desta vez pego ANTES de escrever o código, por reconhecer o padrão do bug já
  documentado na Fase 2): o texto da tarefa descrevia `valor = quantidade * precoPorCota`
  sem reescala visível: seguir isso literalmente teria multiplicado o valor por `1e18`
  seguindo a mesma convenção de unidade bruta de `quantidade`. `LiquidacaoSecundaria`
  reescala por `UNIDADE_COTA` de propósito (ver "Decisões travadas — Fase 4"), travado
  por teste com valores exatos.
- `script/DemoFase4.s.sol` foi validado de duas formas, mesmo padrão dos scripts
  anteriores:
  - **Dry-run**: mini-ciclo de emissão (vendedor recebe 1.000 cotas) → migração de
    `DenyAllTransferPolicy` para `RestrictedTransferPolicy` (timelock) → contra-exemplo 1
    (cessão antes do lock-up, com secundário já liberado, reverte) → avanço de tempo →
    contra-exemplo 2 (cessão para comprador fora da allowlist reverte) → cessão válida
    de 50 cotas a 100 `MockBRL` cada: vendedor `950 ether` cotas restantes, comprador
    `50 ether` cotas recebidas, vendedor `5.000 ether` `MockBRL` recebidos (taxa `0`),
    comprador `995.000 ether` `MockBRL` restantes, protocolo `0` (taxa dormente) —
    valores conferidos exatamente no log.
  - **Broadcast contra `anvil` local**: falha, de propósito, no mesmo ponto que os
    scripts anteriores — `executeGrantRole` com `TimelockNotElapsed`. Comportamento
    esperado, não é bug.

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
- `RestrictedTransferPolicy.setSecundarioLiberado` liga a flag que abre negociação
  secundária, mas ligá-la de verdade depende do lock-up ter decorrido (checado
  on-chain) **e** de autorização de negócio/jurídica da plataforma (inteiramente fora
  do código). Nunca descrever essa chamada, sozinha, como uma aprovação regulatória.
- `LiquidacaoSecundaria` **não é um order book** — não descrever como marketplace,
  bolsa, nem "negociação livre entre investidores". É cessão bilateral pareada pela
  plataforma; a intermediação da CVM 88 é justamente a plataforma submeter a cessão já
  casada, não os investidores negociarem diretamente entre si on-chain.
- Sem número de taxa **final** para o secundário — `taxaSecundarioBps` (Fase 4) tem teto
  rígido de 100 bps e default `0`, independente de `OfertaCaptacao.taxaBps` (primária);
  não apresentar nenhum bps como "a taxa do secundário" até instrução explícita.

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
forge test --match-contract Invariant -vv   # roda InvariantTest (Fase 1), InvariantCaptacaoTest (Fase 2), InvariantPoliticaTest (Fase 3) e InvariantSecundarioTest (Fase 4)
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

- 🔴 Nota atualizada nesta revisão: o self-service de criação de oferta pela própria
  empresa emissora — o caso de uso para o qual `EMISSOR_ROLE` fora reservado ("propor a
  própria oferta") — já existe e está em produção real na Sepolia, mas **não** via
  `EMISSOR_ROLE`. `OfertaOrquestrador.emissoresAutorizados` (allowlist própria do
  orquestrador, gerida por `autorizarEmissor`/`revogarEmissor`) é quem resolve isso — ver
  "`OfertaOrquestrador` — canal self-service" acima. `EMISSOR_ROLE` continua definido em
  `EmissaoGateway`, constante morta, sem nenhum uso funcional em nenhuma fase. A decisão de
  não reaproveitá-lo foi deliberada, não esquecimento: `EMISSOR_ROLE` é concedido/revogado
  via `EmissaoGateway.proposeGrantRole`/`executeGrantRole`, herdado de
  `TimelockedAccessControl` — logo passa pelo timelock de 1h do contrato. Autorizar um
  emissor a criar a própria oferta precisava ser **imediato** (é só a capacidade de criar a
  própria oferta com parâmetros fixados pela plataforma, nunca poder sobre fundos de
  terceiros) — incompatível com o delay do `EMISSOR_ROLE` reaproveitado. A allowlist nova,
  num contrato novo, resolve o mesmo caso de uso sem essa incompatibilidade (ver
  `PLANO_OFERTA_ORQUESTRADOR.md`, §1.4, "`EMISSOR_ROLE` do `EmissaoGateway`").
- `ParticipacaoTokenFactory.gateway` é fixado na construção — não há setter
  timelocked para trocá-lo nesta fase (só `implementacao` e `transferPolicyPadrao`
  são trocáveis). Se uma fase futura precisar substituir o `EmissaoGateway`, isso
  exigirá adicionar esse setter então.
- 🔴 Nota desatualizada corrigida nesta revisão: Sepolia já recebeu múltiplos deploys reais
  (ver `DEMO_SEPOLIA.md`, `DEMO_SECUNDARIO_SEPOLIA.md` e as seções "Fase 6"/
  "`OfertaOrquestrador`" acima). `script/DeployFase1.s.sol`, `script/DemoFase3.s.sol` e
  `script/DemoFase4.s.sol` continuam rodando só local (`anvil`) ou em dry-run;
  `script/DeployFase2.s.sol` foi removido, substituído por `script/DeployFase2Sepolia.s.sol`
  + `script/DeployFase2SepoliaExecute.s.sol` (que já rodaram de verdade em Sepolia).
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
- `LiquidacaoSecundaria.moeda`/`factory` são fixados na construção (`immutable`) — sem
  setter, nem timelocked, nesta fase. Só `protocoloWallet` e `taxaSecundarioBps` são
  trocáveis. Mesma decisão já registrada para `OfertaCaptacaoFactory.gateway`/
  `ParticipacaoTokenFactory.gateway`.
- `LiquidacaoSecundaria` não tem um "pausar" próprio — diferente de
  `OfertaCaptacao`/`ParticipacaoToken`, que têm `pausar`/`pause` para emergência. Uma
  emergência no secundário hoje precisaria passar por `RestrictedTransferPolicy`
  (desligar `secundarioLiberado` via timelock, o que leva 1h) ou por não conceder mais
  `AGENTE_ROLE` a ninguém capaz de chamar `liquidarCessao` — não implementado como um
  botão único nesta fase.
- `niara-contracts` (a exchange) como repositório completo (clone local, checkout)
  nunca esteve acessível nesta linha de sessões (não está no disco, não é público no
  GitHub, sem `gh` CLI/credenciais no ambiente) — mas isso não ficou como pendência
  aberta: `LiquidacaoSecundaria` foi conferida item a item contra `NiaraSettlement`,
  primeiro via as propriedades de `NiaraSettlement.t.sol`, depois via um trecho do
  próprio `settle` (a guarda anti-evasão de taxa), ambos fornecidos na instrução — ver
  "Conferência contra `NiaraSettlement`" em "Decisões travadas — Fase 4".

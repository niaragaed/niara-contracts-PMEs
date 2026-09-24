# Plano — `OfertaOrquestrador` (Fase 0: inspeção + plano, sem código)

Documento produzido sem alterar nenhum `.sol`, sem commit. Confirma as decisões travadas
contra o código-fonte real (lido nesta sessão) e detalha o contrato antes da implementação.

**Veredito geral: nenhuma decisão travada é inviável.** Todas as assinaturas usadas pelas
decisões travadas batem exatamente com o código existente — a orquestração encaixa sem
adaptar nenhum contrato atual. Há dois pontos que não são decisões travadas erradas, mas
lacunas que as decisões travadas não cobriram — sinalizados em "Observações abertas" no
final, para sua decisão antes da implementação.

---

## 1. Inspeção solicitada

### 1.1 Assinaturas confirmadas (lidas de `src/`, não de memória)

```solidity
// src/token/ParticipacaoTokenFactory.sol
function criarOferta(
    string memory nome,
    string memory simbolo,
    string memory empresa,
    bytes32 cnpjRef,
    string memory serie
) external onlyRole(AGENTE_ROLE) whenNotPaused returns (address token);

// src/emissao/EmissaoGateway.sol
function atestarCotas(address token, uint256 novoTeto) external onlyRole(AGENTE_ROLE);
// sem retorno

function registrarCaptacao(address token, address oferta) external onlyRole(AGENTE_ROLE);
// sem retorno

// src/captacao/OfertaCaptacaoFactory.sol
function criarCaptacao(
    address token,
    uint256 metaMinima,
    uint256 metaMaxima,
    uint256 precoPorCota,
    uint256 prazo,
    uint256 tetoPorInvestidor,
    uint256 taxaBps,
    address emissorWallet,
    address protocoloWallet
) external onlyRole(AGENTE_ROLE) whenNotPaused returns (address oferta);
```

As quatro encaixam sem adaptação na sequência descrita nas decisões travadas — confirmado
também contra `script/DemoNiaraPMEsOnChain.s.sol` (`_criarOfertaECaptacao`), que já executa
essa exata sequência hoje (só que com o AGENTE humano assinando, não um contrato).

Único ponto de atenção: `criarCaptacao` recebe `taxaBps` na 7ª posição e `emissorWallet`/
`protocoloWallet` nas posições 8/9 — o orquestrador precisa montar essa chamada com
`emissorWallet = msg.sender` (forçado) e `taxaBps`/`protocoloWallet` vindos do seu próprio
storage, nunca de parâmetro externo (ver §3).

### 1.2 `decimals()` do `MockBRL`

`MockBRL` herda `ERC20` da OpenZeppelin sem sobrescrever `decimals()` → **18 casas**, igual ao
`ParticipacaoToken`. Confirmado em `src/mocks/MockBRL.sol` (NatSpec já documenta "18 casas
decimais, não as 2 casas usuais do BRL fiat").

Logo, `TETO_OFERTA` (limite de R$ 15.000.000 por oferta) deve ser:

```solidity
uint256 public constant TETO_OFERTA = 15_000_000 ether; // 15_000_000 * 1e18
```

### 1.3 Concessão de `AGENTE_ROLE` ao orquestrador

`AGENTE_ROLE` (mesmo valor de hash — `keccak256("AGENTE_ROLE")` — em `ParticipacaoTokenFactory`,
`EmissaoGateway` e `OfertaCaptacaoFactory`, mas três instâncias de `AccessControl`
**independentes**: conceder num contrato não afeta os outros dois). `getRoleAdmin(AGENTE_ROLE)`
não é sobrescrito em nenhum dos três → o admin é sempre `DEFAULT_ADMIN_ROLE`, hoje detido pelo
admin da plataforma (`0x0D41059eBde70a46EB5207af0837921594CAFC05`, por `CLAUDE.md`).

Sequência exata (assumindo a infra já implantada, como em Sepolia hoje):

1. Deploy do `OfertaOrquestrador` → endereço `orquestrador`.
2. `ParticipacaoTokenFactory.proposeGrantRole(AGENTE_ROLE, orquestrador)` — admin.
3. `EmissaoGateway.proposeGrantRole(AGENTE_ROLE, orquestrador)` — admin.
4. `OfertaCaptacaoFactory.proposeGrantRole(AGENTE_ROLE, orquestrador)` — admin.
   (2–4 são transações independentes, em contratos diferentes — ordem entre elas não importa,
   podem até ir no mesmo bloco.)
5. Esperar o `timelockDelay()` vigente em **cada um** dos três contratos decorrer (hoje 1h nos
   três, mas checar antes — nada impede que um deles tenha tido o próprio delay alterado por
   `proposeSetTimelockDelay`/`executeSetTimelockDelay` desde o deploy original).
6. `executeGrantRole(AGENTE_ROLE, orquestrador)` nos três contratos.
7. `AGENTE_ROLE` do **próprio** orquestrador (para quem vai operar `autorizarEmissor`) também
   passa pelo timelock do próprio orquestrador — `TimelockedAccessControl` não abre exceção
   para o próprio contrato: mais um `propose` + espera + `execute`.
8. Só a partir daqui `autorizarEmissor(empresa)` funciona (imediato, sem timelock — decisão
   travada).

**Se o orquestrador for implantado antes de ter os papéis** (ou antes do timelock decorrer):
`criarOfertaCompleta` reverte limpo, de forma atômica, na primeira subchamada
(`ParticipacaoTokenFactory.criarOferta`) com o erro padrão do `AccessControl` da OZ
(`AccessControlUnauthorizedAccount(orquestrador, AGENTE_ROLE)`), propagado (bubbled) até quem
chamou. Nenhum estado é criado, nenhum evento emitido. O mesmo vale se só 2 dos 3 papéis já
tiverem sido concedidos: a sequência chega a criar o token e atestar o teto, mas reverte na
falta do terceiro papel — e a EVM desfaz **também** as duas subchamadas anteriores
automaticamente, porque tudo está dentro de uma única transação externa. É esse desfazimento
atômico nativo da EVM — não uma lógica de rollback escrita à mão — que resolve o Obstáculo 1
do problema original. Total de transações fixas até a primeira oferta self-service: 1 deploy +
3 propose + 3 execute (papéis nas factories/gateway) + 1 propose + 1 execute (papel do próprio
orquestrador) = **9**, mais uma por emissor autorizado.

### 1.4 `EMISSOR_ROLE` do `EmissaoGateway`

**Recomendação: manter exatamente como está — não tocar em `EmissaoGateway.sol`.**

Isso não é só a opção mais segura: é a única compatível com duas decisões já travadas ao mesmo
tempo —

- "Nenhum contrato existente muda de comportamento" (topo do prompt da Fase 0).
- "Autorização por allowlist, **sem timelock**" para o emissor (o ponto central do desenho).

Reaproveitar `EMISSOR_ROLE` significaria conceder/revogar via
`EmissaoGateway.proposeGrantRole`/`executeGrantRole` — que **é** timelocked (herdado de
`TimelockedAccessControl`). Isso contradiria a decisão de autorização imediata. A allowlist
nova (`emissoresAutorizados` no próprio `OfertaOrquestrador`) já resolve exatamente o caso de
uso para o qual `EMISSOR_ROLE` foi reservado ("ações futuras específicas da empresa
emissora") — só que num contrato novo, com semântica de timelock diferente da que o papel
teria se reaproveitado. `EMISSOR_ROLE` continua morta, e agora há uma razão explícita e
documentável para isso (incompatibilidade de timelock), não apenas "não tinha uso ainda".

Consequência para testes: zero — nada muda em `EmissaoGateway.t.sol`. Consequência para
`CLAUDE.md`: atualizar a nota em "Pendências conhecidas" para registrar essa razão, em vez de
"reservado, sem uso funcional" genérico.

### 1.5 Impacto na suíte atual

`forge test` na branch limpa (rodado nesta sessão, `~/.foundry/bin/forge.exe test --summary`):

```
266 testes passando, 0 falhando, 0 pulados
```

(Bate exatamente com "Resultados de teste (Fase 4)" do `CLAUDE.md`.)

**Quais testes existentes tendem a quebrar quando o orquestrador ganhar `AGENTE_ROLE`:
nenhum.** Conferido lendo `test/ParticipacaoTokenFactory.t.sol` (representativo do padrão):
cada arquivo de teste faz `new ParticipacaoTokenFactory(...)`/`new EmissaoGateway(...)`/
`new OfertaCaptacaoFactory(...)` do zero no próprio `setUp()`, e concede `AGENTE_ROLE` **só**
ao endereço `agente` local daquele arquivo (`makeAddr("agente")`). Não há fixture
compartilhado entre arquivos de teste, e nenhum deles jamais vai instanciar o
`OfertaOrquestrador` a menos que um teste novo, escrito para ele, decida fazer isso
deliberadamente. Ou seja: a introdução do orquestrador é puramente aditiva do ponto de vista
da suíte — 266/266 continua passando sem tocar em nada, e os novos testes vivem isolados em
`test/OfertaOrquestrador.t.sol` (+ handler de invariante novo), com seu próprio deploy de
`ParticipacaoTokenFactory`/`EmissaoGateway`/`OfertaCaptacaoFactory` local. Isso só deixaria de
valer se, no futuro, alguém decidisse compartilhar um fixture entre o orquestrador e outro
teste — não é o caso aqui.

### 1.6 Gás

Estimativa (sem instrumentação real ainda — só o desenho conhecido dos 3 contratos):

| Etapa | Custo aproximado |
|---|---|
| `Clones.clone(implementacaoToken)` + `ParticipacaoToken.initialize(...)` (7 SSTORE cold: `gateway`, `transferPolicy`, `empresa`, `cnpjRef`, `serie`, mais nome/símbolo do ERC20) | ~230k–300k gas |
| `EmissaoGateway.atestarCotas` (1 SSTORE cold + overhead de chamada externa) | ~35k–45k gas |
| `Clones.clone(implementacaoOferta)` + `OfertaCaptacao.initialize(...)` (12 campos do `InitParams`, a maioria SSTORE cold) | ~300k–380k gas |
| `EmissaoGateway.registrarCaptacao` (1 SSTORE em mapping + overhead) | ~35k–45k gas |
| Overhead do próprio `OfertaOrquestrador` (checagens de limite CVM 88, 4 `CALL`s externas cold, 1 evento) | ~30k–50k gas |
| **Total estimado `criarOfertaCompleta`** | **~650k–820k gas** |

Sepolia tem o mesmo limite de bloco que a mainnet atual (30.000.000 gas) — 820k gas é ~2,7%
de um bloco. **Não há risco de estourar o limite de bloco.** O único risco prático é
subestimação de gás por parte de carteiras (MetaMask) ao simular uma transação com múltiplos
`CREATE` internos — recomendação para a integração com `niara-PMEs`: fixar um `gasLimit`
explícito generoso (ex.: 1.2M) na chamada do frontend em vez de confiar 100% na estimativa
automática da wallet, para não arriscar "out of gas" por estimativa curta. Confirmar o número
real com `forge test --gas-report` assim que o contrato existir — este é só um teto de
planejamento.

### 1.7 Superfície de risco — vetores que a suíte precisa cobrir

O orquestrador concentra o caminho de criação de qualquer oferta self-service — um bug nele
afeta todo mint futuro desse canal. Vetores concretos, cada um mapeado para um teste no §5/§6:

1. **Bypass de allowlist** — qualquer das 4 subchamadas só deve ser alcançável por um endereço
   em `emissoresAutorizados`. Testar diretamente (não só a função pública) que não há caminho
   alternativo.
2. **Manipulação de `emissorWallet`** — não é parâmetro da função; testar que o valor gravado
   em `OfertaCaptacao.emissorWallet()` é sempre `msg.sender`, nunca outro endereço, mesmo que
   o "emissor" seja um contrato tentando repassar a chamada.
3. **Manipulação de `taxaBps`/`protocoloWallet`/`tetoPorInvestidor`** — também não são
   parâmetros; testar que os valores gravados na captação resultante são sempre os do storage
   do orquestrador **no momento da chamada**, nunca influenciáveis por calldata do emissor (não
   há superfície de ataque possível aqui além de confirmar por teste, já que a ABI da função
   nem aceita esses valores).
4. **`cotasAutorizadas` como consequência aritmética, não atestação livre** — testar que
   `token.cotasAutorizadas()` é sempre exatamente `(metaMaxima/precoPorCota) * 1 ether`, e que
   não existe nenhuma função exposta pelo orquestrador que permita a um emissor chamar
   `atestarCotas` com um valor arbitrário.
5. **Limites CVM 88 nos boundaries exatos** — 180 dias, R$ 15.000.000, 25% de lote adicional
   (ver casos de teste em §5).
6. **`metaMaxima % precoPorCota != 0`** — deve reverter no orquestrador, antes de qualquer
   subchamada (ver observação sobre divisão por zero em "Observações abertas").
7. **Atomicidade sob falha forçada** — nenhuma combinação de sucesso parcial pode persistir.
   Testável forçando revert na 4ª subchamada (ex.: mock de `EmissaoGateway` que reverte só em
   `registrarCaptacao`) e verificando que nem `isOferta(token)` nem `isCaptacao(oferta)` ficam
   `true`.
8. **Papéis ainda não concedidos** — `criarOfertaCompleta` reverte limpo (erro padrão do
   `AccessControl`) se o orquestrador ainda não tiver `AGENTE_ROLE` em algum dos 3 contratos
   (ver §1.3).
9. **Reentrância — analisada e descartada, não forçada artificialmente.** Nenhuma das 4
   subchamadas transfere valor nem invoca qualquer hook no `msg.sender` (nem ERC-20, nem
   ERC-721/1155 `onReceived`, nem `.call` de valor) — `Clones.clone` é `CREATE` sobre a
   implementação fixa da própria plataforma, não código controlado pelo emissor. Não existe
   vetor de reentrância real nesta função; documentar essa análise em vez de forçar um mock
   artificial, no mesmo padrão já usado na Fase 4 para "reentrância pelo lado do ativo" em
   `LiquidacaoSecundaria` (ver `CLAUDE.md`).
10. **Paridade com o caminho manual** — uma oferta criada pelo orquestrador precisa se
    comportar de forma idêntica, ponta a ponta (aportar → encerrar → resgatar), a uma criada
    manualmente pelo AGENTE — o orquestrador só automatiza a mesma sequência, não deveria
    introduzir nenhuma diferença de estado observável.
11. **Front-running — analisado e descartado.** O endereço do clone (`Clones.clone`) não é
    escolhido pelo emissor nem previsível de forma explorável antes da transação minerar; não
    há parâmetro sensível a MEV (sem preço/slippage). Não requer teste dedicado, só
    documentação da análise.

---

## 2. Assinatura completa do contrato

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TimelockedAccessControl} from "../governance/TimelockedAccessControl.sol";
import {ParticipacaoTokenFactory} from "../token/ParticipacaoTokenFactory.sol";
import {EmissaoGateway} from "../emissao/EmissaoGateway.sol";
import {OfertaCaptacaoFactory} from "../captacao/OfertaCaptacaoFactory.sol";

contract OfertaOrquestrador is TimelockedAccessControl {
    // ── Papel operacional ──────────────────────────────────────────────────────────
    bytes32 public constant AGENTE_ROLE = keccak256("AGENTE_ROLE");

    // ── Constantes regulatórias (Res. CVM 88) ─────────────────────────────────────
    uint256 public constant TETO_OFERTA = 15_000_000 ether;   // teto de captação por oferta
    uint256 public constant PRAZO_MAXIMO = 180 days;          // prazo máximo da captação
    uint256 public constant LOTE_ADICIONAL_NUMERADOR = 125;   // metaMaxima*100 <= metaMinima*125
    uint256 public constant LOTE_ADICIONAL_DENOMINADOR = 100; // (lote adicional <= 25%)

    // ── Constantes de escala/taxa (mesma disciplina das fases anteriores) ─────────
    uint256 public constant UNIDADE_COTA = 1 ether;
    uint256 internal constant TAXA_BPS_MAXIMA = 100;

    // ── Endereços fixos na construção (mesmo padrão de OfertaCaptacaoFactory.gateway
    // /registro/moeda — sem setter nesta fase, ver "Pendências conhecidas") ────────
    ParticipacaoTokenFactory public immutable tokenFactory;
    EmissaoGateway public immutable emissaoGateway;
    OfertaCaptacaoFactory public immutable captacaoFactory;

    // ── Parâmetros de plataforma, trocáveis via timelock, invisíveis ao emissor ───
    address public protocoloWallet;
    uint256 public taxaBps;
    uint256 public tetoPorInvestidor;

    // ── Allowlist de emissores, gerida por AGENTE_ROLE, sem timelock ──────────────
    mapping(address => bool) public emissoresAutorizados;

    // ── Eventos ────────────────────────────────────────────────────────────────────
    event EmissorAutorizado(address indexed emissor);
    event EmissorRevogado(address indexed emissor);
    event OfertaCompletaCriada(
        address indexed emissor,
        address indexed token,
        address indexed oferta,
        uint256 metaMinima,
        uint256 metaMaxima,
        uint256 precoPorCota,
        uint256 prazo
    );
    event ProtocoloWalletChangeProposed(address indexed novoProtocoloWallet, uint256 executeAfter);
    event ProtocoloWalletChanged(address indexed antigo, address indexed novo);
    event TaxaBpsChangeProposed(uint256 novaTaxaBps, uint256 executeAfter);
    event TaxaBpsChanged(uint256 antiga, uint256 nova);
    event TetoPorInvestidorChangeProposed(uint256 novoTeto, uint256 executeAfter);
    event TetoPorInvestidorChanged(uint256 antigo, uint256 novo);

    // ── Erros ──────────────────────────────────────────────────────────────────────
    error ZeroAddress();
    error EmissorNaoAutorizado(address emissor);
    error PrecoInvalido();
    error PrazoInvalido(uint256 prazo);
    error PrazoExcedeLimite(uint256 prazo, uint256 limite);
    error MetaMaximaExcedeTeto(uint256 metaMaxima, uint256 teto);
    error LoteAdicionalExcedeLimite(uint256 metaMaxima, uint256 metaMinima);
    error PrecoNaoDivideMetaMaxima(uint256 metaMaxima, uint256 precoPorCota);
    error TaxaExcedeMaximo(uint256 taxaBps, uint256 maximo);

    constructor(
        address admin_,
        address tokenFactory_,
        address emissaoGateway_,
        address captacaoFactory_,
        address protocoloWallet_,
        uint256 taxaBps_,
        uint256 tetoPorInvestidor_,
        uint256 timelockDelay_
    ) TimelockedAccessControl(timelockDelay_) {
        if (
            admin_ == address(0) || tokenFactory_ == address(0) || emissaoGateway_ == address(0)
                || captacaoFactory_ == address(0) || protocoloWallet_ == address(0)
        ) revert ZeroAddress();
        if (taxaBps_ > TAXA_BPS_MAXIMA) revert TaxaExcedeMaximo(taxaBps_, TAXA_BPS_MAXIMA);

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        tokenFactory = ParticipacaoTokenFactory(tokenFactory_);
        emissaoGateway = EmissaoGateway(emissaoGateway_);
        captacaoFactory = OfertaCaptacaoFactory(captacaoFactory_);
        protocoloWallet = protocoloWallet_;
        taxaBps = taxaBps_;
        tetoPorInvestidor = tetoPorInvestidor_;
    }

    // ── Allowlist (AGENTE_ROLE, imediato — ver decisão travada) ────────────────────
    function autorizarEmissor(address emissor) external onlyRole(AGENTE_ROLE) {
        if (emissor == address(0)) revert ZeroAddress();
        emissoresAutorizados[emissor] = true;
        emit EmissorAutorizado(emissor);
    }

    function revogarEmissor(address emissor) external onlyRole(AGENTE_ROLE) {
        emissoresAutorizados[emissor] = false;
        emit EmissorRevogado(emissor);
    }

    // ── Criação atômica ─────────────────────────────────────────────────────────────
    function criarOfertaCompleta(
        string memory nome,
        string memory simbolo,
        string memory empresa,
        bytes32 cnpjRef,
        string memory serie,
        uint256 metaMinima,
        uint256 metaMaxima,
        uint256 precoPorCota,
        uint256 prazo
    ) external returns (address token, address oferta) {
        if (!emissoresAutorizados[msg.sender]) revert EmissorNaoAutorizado(msg.sender);
        if (precoPorCota == 0) revert PrecoInvalido();
        if (prazo <= block.timestamp) revert PrazoInvalido(prazo);
        if (prazo - block.timestamp > PRAZO_MAXIMO) revert PrazoExcedeLimite(prazo, PRAZO_MAXIMO);
        if (metaMaxima > TETO_OFERTA) revert MetaMaximaExcedeTeto(metaMaxima, TETO_OFERTA);
        if (metaMaxima * LOTE_ADICIONAL_DENOMINADOR > metaMinima * LOTE_ADICIONAL_NUMERADOR) {
            revert LoteAdicionalExcedeLimite(metaMaxima, metaMinima);
        }
        if (metaMaxima % precoPorCota != 0) revert PrecoNaoDivideMetaMaxima(metaMaxima, precoPorCota);

        token = tokenFactory.criarOferta(nome, simbolo, empresa, cnpjRef, serie);

        uint256 cotasAutorizadas = (metaMaxima / precoPorCota) * UNIDADE_COTA;
        emissaoGateway.atestarCotas(token, cotasAutorizadas);

        oferta = captacaoFactory.criarCaptacao(
            token, metaMinima, metaMaxima, precoPorCota, prazo, tetoPorInvestidor, taxaBps, msg.sender, protocoloWallet
        );

        emissaoGateway.registrarCaptacao(token, oferta);

        emit OfertaCompletaCriada(msg.sender, token, oferta, metaMinima, metaMaxima, precoPorCota, prazo);
    }

    // ── Parâmetros de plataforma (DEFAULT_ADMIN_ROLE, timelock) ────────────────────
    function proposeSetProtocoloWallet(address novo) external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256);
    function executeSetProtocoloWallet(address novo) external onlyRole(DEFAULT_ADMIN_ROLE);

    function proposeSetTaxaBps(uint256 novaTaxaBps) external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256);
    // valida TAXA_BPS_MAXIMA tanto no propose quanto no execute (lição já aplicada em
    // LiquidacaoSecundaria.executeSetTaxaSecundarioBps, ver CLAUDE.md — repetir aqui)
    function executeSetTaxaBps(uint256 novaTaxaBps) external onlyRole(DEFAULT_ADMIN_ROLE);

    function proposeSetTetoPorInvestidor(uint256 novoTeto) external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256);
    function executeSetTetoPorInvestidor(uint256 novoTeto) external onlyRole(DEFAULT_ADMIN_ROLE);
}
```

Cada par `proposeX`/`executeX` segue exatamente o padrão já usado em todo o repositório:
`actionId = keccak256(abi.encode("NOME_DA_ACAO", ...parâmetros))`, `_scheduleAction`/
`_consumeAction` herdados de `TimelockedAccessControl`.

### 2.1 Lista completa de reverts

| Revert | Condição | Onde |
|---|---|---|
| `ZeroAddress()` | qualquer endereço obrigatório do construtor é `address(0)`; `autorizarEmissor(address(0))` | construtor, `autorizarEmissor` |
| `TaxaExcedeMaximo(taxaBps_, 100)` | `taxaBps` inicial (construtor) ou proposto (`proposeSetTaxaBps`/`executeSetTaxaBps`) excede 100 bps | construtor, `proposeSetTaxaBps`, `executeSetTaxaBps` |
| `EmissorNaoAutorizado(msg.sender)` | `criarOfertaCompleta` chamado por endereço fora de `emissoresAutorizados` | `criarOfertaCompleta` |
| `PrecoInvalido()` | `precoPorCota == 0` | `criarOfertaCompleta` |
| `PrazoInvalido(prazo)` | `prazo <= block.timestamp` | `criarOfertaCompleta` |
| `PrazoExcedeLimite(prazo, 180 days)` | `prazo - block.timestamp > 180 dias` | `criarOfertaCompleta` |
| `MetaMaximaExcedeTeto(metaMaxima, 15_000_000 ether)` | `metaMaxima > TETO_OFERTA` | `criarOfertaCompleta` |
| `LoteAdicionalExcedeLimite(metaMaxima, metaMinima)` | `metaMaxima*100 > metaMinima*125` | `criarOfertaCompleta` |
| `PrecoNaoDivideMetaMaxima(metaMaxima, precoPorCota)` | `metaMaxima % precoPorCota != 0` | `criarOfertaCompleta` |
| *(bubbled)* `AccessControlUnauthorizedAccount` | orquestrador ainda sem `AGENTE_ROLE` em algum dos 3 contratos-alvo | subchamadas dentro de `criarOfertaCompleta` |
| *(bubbled)* `MetasInvalidas`/`PrecoInvalido`/`PrazoInvalido`/`TaxaExcedeMaximo` de `OfertaCaptacaoFactory` | `metaMinima == 0`/`metaMinima > metaMaxima` — **deliberadamente não duplicado** no orquestrador, já garantido a jusante | `criarCaptacao`, chamado de dentro de `criarOfertaCompleta` |
| `ActionAlreadyPending`/`ActionNotPending`/`TimelockNotElapsed`/`InvalidTimelockDelay`/`RoleChangeRequiresTimelock` | herdados de `TimelockedAccessControl`, sem mudança | qualquer `proposeX`/`executeX`, `grantRole`/`revokeRole` |

---

## 3. Sequência de deploy — resumo

Ver detalhamento completo em §1.3. Resumo em passos:

1. Deploy de `OfertaOrquestrador` (após a infra atual já existir).
2. `propose`/espera 1h/`execute` de `AGENTE_ROLE` em `ParticipacaoTokenFactory`,
   `EmissaoGateway` e `OfertaCaptacaoFactory` (3 propose + 3 execute, independentes entre si).
3. `propose`/espera 1h/`execute` de `AGENTE_ROLE` no **próprio** orquestrador, para o operador
   que vai gerir a allowlist.
4. `autorizarEmissor(empresa)` por empresa aprovada off-chain — imediato.
5. Empresa chama `criarOfertaCompleta(...)` da própria carteira.

---

## 4. Plano de testes

Arquivo novo: `test/OfertaOrquestrador.t.sol`. Cobrindo, no mínimo:

**Acesso/allowlist**
- `criarOfertaCompleta` por emissor não autorizado reverte com `EmissorNaoAutorizado`.
- `autorizarEmissor`/`revogarEmissor` só por `AGENTE_ROLE` (do orquestrador); qualquer outro
  chamador reverte com o erro padrão do `AccessControl`.
- Emissor revogado não consegue mais criar ofertas depois da revogação (mesmo tendo criado
  uma antes).

**Limites Res. CVM 88 — boundary exato**
- `prazo - block.timestamp == 180 days` passa; `== 180 days + 1` reverte com
  `PrazoExcedeLimite`.
- `metaMaxima == TETO_OFERTA` passa; `== TETO_OFERTA + 1` reverte com `MetaMaximaExcedeTeto`.
- `metaMaxima * 100 == metaMinima * 125` (exatamente 25% de lote adicional) passa;
  `metaMaxima * 100 == metaMinima * 125 + 1` reverte com `LoteAdicionalExcedeLimite`.
- `prazo <= block.timestamp` reverte com `PrazoInvalido` (não com `PrazoExcedeLimite`).

**Aritmética/derivação**
- `metaMaxima % precoPorCota != 0` reverte com `PrecoNaoDivideMetaMaxima` (inclusive
  `precoPorCota == 0`, que deve reverter com `PrecoInvalido` **antes** de qualquer módulo —
  ver "Observações abertas").
- Token resultante tem `cotasAutorizadas() == (metaMaxima/precoPorCota) * 1 ether` exatamente.

**Anti-manipulação**
- `OfertaCaptacao.emissorWallet() == msg.sender`, sempre — mesmo simulando o "emissor" como um
  contrato intermediário chamando por conta própria (o valor gravado é sempre quem chamou
  `criarOfertaCompleta` por último, nunca repassável).
- `OfertaCaptacao.taxaBps()`, `.protocoloWallet()`, `.tetoPorInvestidor()` batem exatamente com
  o storage do orquestrador **no momento da chamada**, inclusive quando esses valores tiverem
  sido alterados por `executeSetX` entre duas criações consecutivas (a segunda oferta reflete
  o valor novo, a primeira mantém o valor antigo — mesmo padrão de "trocas só afetam o
  futuro" já usado em `ParticipacaoTokenFactory.implementacao`).

**Atomicidade**
- Forçar falha na 4ª subchamada (`registrarCaptacao`) — via um `EmissaoGateway` de teste que
  reverte só nessa função — e confirmar que nem `tokenFactory.isOferta(token)` nem
  `captacaoFactory.isCaptacao(oferta)` ficam `true`, e que nenhum evento
  `OfertaCompletaCriada`/`OfertaCriada`/`CaptacaoCriada` é emitido.
- `criarOfertaCompleta` chamado antes de o orquestrador ter `AGENTE_ROLE` nos 3 contratos
  reverte limpo (erro padrão do `AccessControl`), sem estado parcial.

**Ciclo completo (integração)**
- Emissor autorizado cria oferta → investidor aporta (até `metaMaxima`) → `encerrar()` →
  `resgatarCotas()` → cotas mintadas batem com o aportado, exatamente como no fluxo manual já
  testado em `OfertaCaptacao.t.sol`.

**Governança dos parâmetros de plataforma**
- `proposeSetTaxaBps`/`executeSetTaxaBps` só por `DEFAULT_ADMIN_ROLE`; ambos revertem se
  `> TAXA_BPS_MAXIMA` (teste chamando `executeSetTaxaBps` diretamente, sem `propose`, com valor
  acima do teto — mesma lição já registrada no `CLAUDE.md` para
  `LiquidacaoSecundaria.executeSetTaxaSecundarioBps`).
- Mesma cobertura para `proposeSetProtocoloWallet`/`executeSetProtocoloWallet` (rejeita
  `address(0)`) e `proposeSetTetoPorInvestidor`/`executeSetTetoPorInvestidor`.

---

## 5. Plano de fuzzing stateful

Arquivo novo: `test/invariant/HandlerOrquestrador.sol` + `test/InvariantOrquestrador.t.sol`,
mesmo desenho dos handlers existentes (`actors` = mistura de emissores autorizados e não
autorizados; `agente` = titular de `AGENTE_ROLE` no orquestrador; `_chaos` ~1 em 5 toma o
caminho inválido). Ações do handler:

- `autorizarEmissor`/`revogarEmissor` (chaos: chamador sem `AGENTE_ROLE`).
- `criarOfertaCompleta` com parâmetros `bound()`ados dentro dos limites válidos na maior parte
  das chamadas; no caminho `_chaos`, um dos seguintes é violado de propósito: prazo > 180 dias,
  `metaMaxima` > teto, lote adicional > 25%, `metaMaxima` não múltiplo de `precoPorCota`, ou
  chamador não autorizado.
- `proposeSetTaxaBps`/`executeSetTaxaBps`, `proposeSetProtocoloWallet`/
  `executeSetProtocoloWallet`, `proposeSetTetoPorInvestidor`/`executeSetTetoPorInvestidor`
  (chaos: chamador sem `DEFAULT_ADMIN_ROLE`; `taxaBps` acima do teto).

Não há ação de handler para "tentar influenciar `taxaBps`/`protocoloWallet`/`emissorWallet`
via `criarOfertaCompleta`" — a ABI da função nem aceita esses parâmetros, então essa invariante
vale por construção, não por teste dinâmico; mencionado explicitamente no relatório de
cobertura em vez de forçar uma ação de handler artificial.

**Invariantes (texto)**:

1. Para toda oferta criada via orquestrador: `token.totalSupply() <= token.cotasAutorizadas()`
   (a invariante geral da Fase 1, verificada especificamente no caminho novo).
2. Para toda oferta criada via orquestrador: `metaMaxima <= TETO_OFERTA`,
   `prazo - <timestamp de criação, no espelho do handler> <= 180 dias`, e
   `metaMaxima*100 <= metaMinima*125` — nenhuma oferta viva viola os limites CVM 88 codificados
   no orquestrador.
3. Para toda oferta criada via orquestrador: `oferta.emissorWallet()` é sempre o endereço que
   chamou `criarOfertaCompleta` para aquela oferta específica (espelhado pelo handler).
4. Para toda oferta criada via orquestrador: `oferta.taxaBps()`, `.protocoloWallet()` e
   `.tetoPorInvestidor()` batem com o valor do storage do orquestrador no instante exato da
   criação (espelho `ghost_*` atualizado a cada `executeSetX` bem-sucedido) — nunca divergem.
5. Nenhuma chamada de `criarOfertaCompleta` por um endereço fora de `emissoresAutorizados` (no
   momento da chamada) jamais teve sucesso.
6. Nenhuma chamada sem `AGENTE_ROLE` (do orquestrador) a `autorizarEmissor`/`revogarEmissor`,
   nem sem `DEFAULT_ADMIN_ROLE` a `proposeSetTaxaBps`/`proposeSetProtocoloWallet`/
   `proposeSetTetoPorInvestidor`, jamais teve sucesso.
7. `taxaBps` do orquestrador nunca excedeu `TAXA_BPS_MAXIMA` (100) em nenhum momento da
   sequência (mesmo padrão da invariante 6 da Fase 4, aplicada aqui a um segundo contrato com
   teto de taxa independente).

Escala: mesma configuração do `foundry.toml` já em uso (`runs=256 * depth=100` = 25.600
chamadas por rodada), sem necessidade de mudar o perfil global.

---

## 6. Cobertura

Meta: **100% linha/statement/branch/função** em `OfertaOrquestrador.sol`, mesma barra das
Fases 1–4. Nenhuma branch nova deveria cair na mesma categoria de "limitação conhecida do
instrumentador" documentada para `DenyAllTransferPolicy` — todas as branches aqui são
condicionais normais (`if`/`revert`), não funções `pure` de retorno literal.

---

## 7. Atualizações necessárias no `CLAUDE.md` (quando a implementação for liberada)

- Nova seção "Arquitetura da Fase N — `OfertaOrquestrador`" (numeração a definir — hoje Fase 5
  é "categorias adicionais" e Fase 6 está em andamento; este trabalho provavelmente vira uma
  Fase 7, mas isso é só rotulagem, não decisão técnica).
- Nova entrada em "Decisões travadas" registrando: allowlist sem timelock (com o racional já
  dado no prompt), `cotasAutorizadas` derivada, e a decisão de **não** tocar `EMISSOR_ROLE`
  (com a razão de incompatibilidade de timelock, ver §1.4).
- Nova linha na tabela de "Separação timelock × operacional": `criarOfertaCompleta` e
  `autorizarEmissor`/`revogarEmissor` → operacional/imediato; `setTaxaBps`/
  `setProtocoloWallet`/`setTetoPorInvestidor` → timelock.
- Nota explícita, honesta, no NatSpec do contrato e no `CLAUDE.md`: o teto anual cruzado entre
  plataformas da Res. CVM 88 (R$ 20 mil por investidor de varejo) continua **inteiramente
  off-chain e autodeclaratório** — `OfertaOrquestrador` não adiciona nenhuma garantia nova
  sobre isso, só automatiza a criação da oferta em si.
- Atualizar "Pendências conhecidas": `OfertaOrquestrador.tokenFactory`/`emissaoGateway`/
  `captacaoFactory` são `immutable`, sem setter nesta fase (mesmo padrão já registrado para
  `OfertaCaptacaoFactory.gateway`/`registro`/`moeda`).

---

## 8. Observações abertas (não são decisões travadas quebradas — são lacunas a preencher)

1. **`precoPorCota == 0` antes do módulo.** As decisões travadas descrevem
   `metaMaxima % precoPorCota != 0` como revert, mas não mencionam o caso `precoPorCota == 0`
   explicitamente. Em Solidity puro isso seria `Panic(0x12)` (divisão/módulo por zero) em vez
   de um erro customizado — quebra a convenção deste repositório de nunca deixar um revert
   "cru" acontecer. O plano acima já inclui `if (precoPorCota == 0) revert PrecoInvalido();`
   antes do módulo, reaproveitando o mesmo nome de erro já usado em `OfertaCaptacaoFactory`.
   Confirmar se concorda com essa adição antes da implementação.
2. **Pausa de emergência do orquestrador.** Diferente de `ParticipacaoTokenFactory`/
   `OfertaCaptacaoFactory` (ambas `Pausable`, `AGENTE_ROLE`), o desenho travado não menciona
   um `pause()` no `OfertaOrquestrador`. Vale notar que uma pausa **transitiva** já existe: se
   `ParticipacaoTokenFactory.pause()` ou `OfertaCaptacaoFactory.pause()` forem acionadas (já
   `AGENTE_ROLE`, imediatas, hoje), `criarOfertaCompleta` reverte automaticamente na
   subchamada correspondente — então uma emergência já tem um botão, só que "emprestado" de
   contratos que também afetam o caminho manual do AGENTE. Perguntar se isso é suficiente ou
   se você quer um `pause()` dedicado só para o canal self-service (não incluído no desenho
   acima, para não expandir escopo silenciosamente).
3. **Um emissor pode criar múltiplas ofertas.** `emissoresAutorizados` é uma permissão
   booleana, não um contador nem um limite de "uma oferta por vez" — uma empresa autorizada
   pode chamar `criarOfertaCompleta` quantas vezes quiser enquanto estiver na allowlist. As
   decisões travadas não impõem restrição alguma aqui; sinalizando só para confirmar que é
   comportamento pretendido (parece razoável — uma empresa pode legitimamente ter mais de uma
   série/rodada — mas registro a suposição).

Nenhuma dessas três observações contradiz uma decisão travada; são pontos que o texto do
problema simplesmente não especificou. Recomendo decidir os três antes de eu escrever
qualquer `.sol`.

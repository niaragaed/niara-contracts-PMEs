# niara-contracts-PMEs

Contratos Solidity da captação tokenizada de pequenas e médias empresas
(PMEs) brasileiras, enquadrada na **Resolução CVM 88** — uma empresa cria
uma oferta, investidores aportam e recebem tokens que representam a cota
emitida. Repositório irmão de `niara-PMEs` (o site institucional, que lê/
escreve de verdade contra esta infraestrutura em `/investir/onchain`) e
separado da exchange `niara-contracts` (mercado secundário do grupo,
usada aqui só como referência somente-leitura).

**Protótipo em testnet (Sepolia), sem auditoria externa publicada.**
Formulação honesta: cobertura total de testes + invariantes por fuzzing,
**sem** auditoria externa — nenhum contrato deste repositório deve ser
descrito como "seguro" ou "auditado", e não há deploy em mainnet nesta
fase. `MockBRL`, a moeda usada nos aportes, é um mock de teste sem lastro.

## Estágio atual

Quatro fases de contrato concluídas — **266/266 testes passando**
(unitários + invariantes por fuzzing stateful), 100% de cobertura
linha/branch/função nos contratos principais:

- **Fase 1** — token de participação clonável (`ParticipacaoToken`, via
  EIP-1167) com política de transferência plugável, secundário desligado
  por padrão.
- **Fase 2** — captação primária com escrow (`OfertaCaptacao`): meta
  mínima/máxima, teto por investidor, cotas só são mintadas no sucesso da
  captação.
- **Fase 3** — política de transferência restrita
  (`RestrictedTransferPolicy`): lock-up + allowlist + flag de liberação de
  secundário.
- **Fase 4** — liquidação secundária (`LiquidacaoSecundaria`): cessão
  bilateral pareada pela plataforma — não um order book aberto.

A infraestrutura já está implantada em Sepolia e conectada de verdade ao
frontend de `niara-PMEs` (`/investir/onchain`), incluindo um conjunto de
ofertas de demonstração prontas para uso em pitch presencial.

Ver [`CLAUDE.md`](./CLAUDE.md) para o histórico completo de decisões,
arquitetura de cada fase, endereços implantados e pendências conhecidas —
é a fonte de verdade deste repositório.

## Como rodar

```bash
forge build
forge test -vv
forge coverage
```

## Foundry

Kit de ferramentas Ethereum usado neste projeto — Forge para build/testes,
Cast para interagir com contratos e a chain, Anvil para nó local. Docs:
https://book.getfoundry.sh/

```bash
forge fmt         # formata o código
forge snapshot    # gas snapshots
anvil             # nó local
cast <subcommand> # interage com contratos/chain
```

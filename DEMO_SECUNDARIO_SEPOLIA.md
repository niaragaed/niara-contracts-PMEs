# Demo pública — Sepolia (Fase 4: liquidação secundária)

> **Aviso.** Isto é uma demonstração em **testnet Sepolia**. `MockBRL` é um mock de
> teste — sem lastro, sem valor, mintável à vontade — e **não representa dinheiro
> real**. Este código **não tem auditoria externa publicada** (cobertura total de
> testes + invariantes por fuzzing, SEM auditoria externa). **Nenhum deploy em
> mainnet foi feito ou está planejado nesta fase.** `LiquidacaoSecundaria` **não é
> um order book** — é cessão bilateral pareada pela plataforma, materializando a
> intermediação exigida pela Resolução CVM 88 para o secundário de valores
> mobiliários ofertados por dispensa de registro; não há livro de ofertas, matching
> engine nem negociação P2P irrestrita. O secundário desta demo está restrito por
> `RestrictedTransferPolicy` (lock-up + allowlist + flag de liberação, ver
> `CLAUDE.md`) — o fato de tê-lo aberto aqui é só a demonstração do fluxo de
> governança, não uma abertura real de mercado.

## Contratos implantados

Implantados e verificados via `script/DemoSecundarioSetup.s.sol` (deployer atuando
como admin/agente). Fresh deploy de propósito — o token da demo anterior
(`DEMO_SEPOLIA.md`, Fase 2) aponta para `DenyAllTransferPolicy` e veio de uma
implementação anterior ao setter de política da Fase 3; não dá para migrá-lo.

| Contrato | Endereço | Etherscan |
|---|---|---|
| MockBRL | `0xDF052B4147Fdd8876d84767CB9F5477E4feC0559` | [ver](https://sepolia.etherscan.io/address/0xDF052B4147Fdd8876d84767CB9F5477E4feC0559) |
| DenyAllTransferPolicy | `0x8e5A71D005E08002aF1eA697D543ac3825c43F82` | [ver](https://sepolia.etherscan.io/address/0x8e5A71D005E08002aF1eA697D543ac3825c43F82) |
| RestrictedTransferPolicy | `0x8E1E7407D3771386c3fE7BF9E823e1A0E83B621E` | [ver](https://sepolia.etherscan.io/address/0x8E1E7407D3771386c3fE7BF9E823e1A0E83B621E) |
| ParticipacaoToken (implementação) | `0xF20a786fa64329c3b162a2D45cB290978c76fB64` | [ver](https://sepolia.etherscan.io/address/0xF20a786fa64329c3b162a2D45cB290978c76fB64) |
| EmissaoGateway | `0xcb01a240a73784Bc3B3B28Dbd77e01FcA4c8bb40` | [ver](https://sepolia.etherscan.io/address/0xcb01a240a73784Bc3B3B28Dbd77e01FcA4c8bb40) |
| ParticipacaoTokenFactory | `0x0aD8Bbf0793BD81160526522D6cF7aC0E2C4705C` | [ver](https://sepolia.etherscan.io/address/0x0aD8Bbf0793BD81160526522D6cF7aC0E2C4705C) |
| RegistroInvestidorQualificado | `0x1FFb81796B588D0E519E9e6BFD3F5B35607c813a` | [ver](https://sepolia.etherscan.io/address/0x1FFb81796B588D0E519E9e6BFD3F5B35607c813a) |
| OfertaCaptacao (implementação) | `0x778C62B8Bb651D13479D4faf6a6b70F17721e7C4` | [ver](https://sepolia.etherscan.io/address/0x778C62B8Bb651D13479D4faf6a6b70F17721e7C4) |
| OfertaCaptacaoFactory | `0x2aC536554b8c7733F11bf38f0d8BC272950a1d4f` | [ver](https://sepolia.etherscan.io/address/0x2aC536554b8c7733F11bf38f0d8BC272950a1d4f) |
| LiquidacaoSecundaria | `0xE96649DEf1B2df25AAaEb68BC8F412be05e11107` | [ver](https://sepolia.etherscan.io/address/0xE96649DEf1B2df25AAaEb68BC8F412be05e11107) |

Todos os 10 contratos acima foram verificados no Sepolia Etherscan
(`forge script --verify`, confirmado "Pass - Verified" ou "Already Verified" para
cada um no log do broadcast).

Clone EIP-1167 criado via `script/DemoSecundarioPreparar.s.sol` (minimal proxy —
Etherscan o reconhece automaticamente como proxy da implementação correspondente
acima; código de verdade fica na implementação, já verificada):

| Clone | Endereço | Aponta para | Etherscan |
|---|---|---|---|
| Token (ParticipacaoToken, "Oferta Demo Secundario" / nSEC) | `0x1277fF28a14616366b824db3Df9312B9a3C03603` | ParticipacaoToken (implementação) | [ver](https://sepolia.etherscan.io/address/0x1277fF28a14616366b824db3Df9312B9a3C03603) |

Carteiras (não são contratos, listadas só por completude — **todas burner novas,
geradas nesta rodada, sem valor real**; as chaves da demo anterior foram expostas em
transcript e estão queimadas, não reaproveitadas aqui):

| Papel | Endereço |
|---|---|
| Deployer / admin / agente | `0x101e8ad58F2D2A923553FeFE558a7bEf5566871E` |
| Vendedor (detinha as cotas) | `0x4665a641e73e2A70183d2bb1172eB579db622A36` |
| Comprador (elegível, pagou pela cessão) | `0x0312a3a8F09af4485106a82078fACF9eA231dcBa` |
| Protocolo (taxa dormente = 0 nesta demo) | `0x2D05772D847742648DE4c1935e3468E30307ADf0` |

## Cronologia com o timelock

O timelock de 1h atinge dois pontos independentes: (a) conceder `AGENTE_ROLE` e (b)
migrar a política do token para `RestrictedTransferPolicy` + ligar
`secundarioLiberado`. Como o token só existe depois do AGENTE ser concedido, os dois
momentos não cabem na mesma janela — daí três scripts, com duas esperas reais de 1h
entre eles.

## Cronologia de transações

### Parte 1 — `DemoSecundarioSetup.s.sol` (deploy + propõe `AGENTE_ROLE`)

| # | Ação | Tx hash |
|---|---|---|
| 1 | Deploy MockBRL | [`0x8e0aa326…355028f1`](https://sepolia.etherscan.io/tx/0x8e0aa326051761d6af829dc0cdfe7001e270b7abdc8172739df1ef32355028f1) |
| 2 | Deploy DenyAllTransferPolicy | [`0x13ff5751…972104ea0`](https://sepolia.etherscan.io/tx/0x13ff5751472b189faa9004449235acb1b16b7c438178799e34570ae972104ea0) |
| 3 | Deploy RestrictedTransferPolicy | [`0x03adf86e…4dc15b289`](https://sepolia.etherscan.io/tx/0x03adf86efc2b5a52a84a5b95cc2374607811d615cb0ee883d60ee984dc15b289) |
| 4 | Deploy ParticipacaoToken (implementação) | [`0xfa79cac1…d83fbc5f5`](https://sepolia.etherscan.io/tx/0xfa79cac17f86e0b03d6cff52d8540b7824f7fbc9b09c1c9be95d5bdc83fbc5f5) |
| 5 | Deploy EmissaoGateway | [`0x8a9726cc…3fb154fd0`](https://sepolia.etherscan.io/tx/0x8a9726ccb82069de1ef3a04681629819a2fe1880755d88ff1969c233fb154fd0) |
| 6 | Deploy ParticipacaoTokenFactory | [`0x72743a96…be87de049`](https://sepolia.etherscan.io/tx/0x72743a96e244167408a49877f0df767c6e95067d753db52fc41f4b6be87de049) |
| 7 | Deploy RegistroInvestidorQualificado | [`0xaf428d62…f1a6673af`](https://sepolia.etherscan.io/tx/0xaf428d62a89a54bf9d0e648c9a2bb02d931750e5b92978ebd681763f1a6673af) |
| 8 | Deploy OfertaCaptacao (implementação) | [`0x3b23b9aa…28dea7110`](https://sepolia.etherscan.io/tx/0x3b23b9aa2a5b90e50298d6daef6fb9a50a5532ec1d01cdb92aaf8ae28dea7110) |
| 9 | Deploy OfertaCaptacaoFactory | [`0x7ded3199…e20a933ec`](https://sepolia.etherscan.io/tx/0x7ded3199091f2b47945a0d2dd9f11360b46f40b7a1a28622cffde60e20a933ec) |
| 10 | Deploy LiquidacaoSecundaria | [`0xd7ff4db5…8bd62295d`](https://sepolia.etherscan.io/tx/0xd7ff4db5a7d4c9a1b985f6d9bfd09a7e6e021be4c2640c1425c7f628bd62295d) |
| 11 | `EmissaoGateway.proposeGrantRole(AGENTE_ROLE, deployer)` | [`0x13dc9ca3…c3e265e3015`](https://sepolia.etherscan.io/tx/0x13dc9ca3abd132e6ed6b98821103db81a40fec3de5ebe2406d1f2c3e265e3015) |
| 12 | `ParticipacaoTokenFactory.proposeGrantRole(AGENTE_ROLE, deployer)` | [`0x39f41ad7…7b111980849aaef5a7bdb6bf2`](https://sepolia.etherscan.io/tx/0x39f41ad73042f0ac80bfd8f6e5eec11b04f814a7b111980849aaef5a7bdb6bf2) |
| 13 | `RegistroInvestidorQualificado.proposeGrantRole(AGENTE_ROLE, deployer)` | [`0xd4521259…719deaed78fd`](https://sepolia.etherscan.io/tx/0xd45212596507a846475b8411b5d8d2050742179abb531f5556ab719deaed78fd) |
| 14 | `OfertaCaptacaoFactory.proposeGrantRole(AGENTE_ROLE, deployer)` | [`0x24e10c5c…858d740edd70`](https://sepolia.etherscan.io/tx/0x24e10c5c47347531f4552ec9750d0b6cf7784e0d26c01e02b371858d740edd70) |
| 15 | `RestrictedTransferPolicy.proposeGrantRole(AGENTE_ROLE, deployer)` | [`0xd66e22b6…c398effe2b325faafb6`](https://sepolia.etherscan.io/tx/0xd66e22b6955cd50f1effdd7a07ed043e9408283ca59d8c398effe2b325faafb6) |
| 16 | `LiquidacaoSecundaria.proposeGrantRole(AGENTE_ROLE, deployer)` | [`0xdcc76d0f…987ec30ceefda2e74ccf`](https://sepolia.etherscan.io/tx/0xdcc76d0f9150b8a49a5dd1faa0ef4870f58809a250ef987ec30ceefda2e74ccf) |

**Espera real do timelock nº 1**: as propostas de `AGENTE_ROLE` acima ficaram
pendentes por `MIN_TIMELOCK_DELAY = 1 hours`. Proposta em `1785709356`
(2026-08-02 22:22:36 UTC), `executeAfter = 1785712956` (2026-08-02 23:22:36 UTC) —
tempo de relógio real decorrido na chain antes da parte 2, não simulável em
broadcast de verdade.

### Parte 2 — `DemoSecundarioPreparar.s.sol` (executa `AGENTE_ROLE`, emite cotas, configura política, propõe migração + abertura)

| # | Ação | Tx hash |
|---|---|---|
| 1 | `EmissaoGateway.executeGrantRole(AGENTE_ROLE, deployer)` | [`0x2f095d43…b561db3243`](https://sepolia.etherscan.io/tx/0x2f095d4381cd6a46be8d3e0a50b3eddd4a8229f950eec7b8147805b561db3243) |
| 2 | `ParticipacaoTokenFactory.executeGrantRole(AGENTE_ROLE, deployer)` | [`0x99368065…9278c953a45cf32a6daf7`](https://sepolia.etherscan.io/tx/0x99368065c2be3b770453e0f836de5c2eda22873b4590278c953a45cf32a6daf7) |
| 3 | `RegistroInvestidorQualificado.executeGrantRole(AGENTE_ROLE, deployer)` | [`0x55e1e4c9…52d74971f9fe50771`](https://sepolia.etherscan.io/tx/0x55e1e4c91160b21c49e362e12d469230a77ace5bbf87df252d74971f9fe50771) |
| 4 | `OfertaCaptacaoFactory.executeGrantRole(AGENTE_ROLE, deployer)` | [`0xe9a73ad3…cad2221315d43912baa9`](https://sepolia.etherscan.io/tx/0xe9a73ad38ea5a24df99061daacc1ba0fee0554a96f17cad2221315d43912baa9) |
| 5 | `RestrictedTransferPolicy.executeGrantRole(AGENTE_ROLE, deployer)` | [`0xdebf42d6…525ebf9f7591f2a0a31`](https://sepolia.etherscan.io/tx/0xdebf42d633ec08bf0678ebcdb37f153398fcbab76c948525ebf9f7591f2a0a31) |
| 6 | `LiquidacaoSecundaria.executeGrantRole(AGENTE_ROLE, deployer)` | [`0xbc8e799d…c99625f73aad43dd5`](https://sepolia.etherscan.io/tx/0xbc8e799db68a01b1f0d912d5866e27b5e1fc04acf4c6b2b300d0431ba2e4c7c9) |
| 7 | `ParticipacaoTokenFactory.criarOferta(...)` → token | [`0xb22c3d1a…c99625f73aad43dd5`](https://sepolia.etherscan.io/tx/0xb22c3d1aa2aabd9d7da302842db426b0c7481ecfd10c9cec99625f73aad43dd5) |
| 8 | `EmissaoGateway.atestarCotas(token, 1.000.000 cotas)` | [`0x54b75b00…caef3ce`](https://sepolia.etherscan.io/tx/0x54b75b007efc7731f4d08e32cf416e0eb8d538562eea4cbffdef79442caef3ce) |
| 9 | **`EmissaoGateway.emitir(token, vendedor, 50 cotas)`** | [`0xa24a2d28…8f93041a`](https://sepolia.etherscan.io/tx/0xa24a2d2878d45fa7370afb5d202392cf55b11658dbfa3b98b18138fe8f93041a) |
| 10 | `RestrictedTransferPolicy.definirElegivel(token, vendedor, true)` | [`0x8b164b05…9deb0fcd`](https://sepolia.etherscan.io/tx/0x8b164b0517edcb8757ef182953e78b223afadbc8babb71d0adb360329deb0fcd) |
| 11 | `RestrictedTransferPolicy.definirElegivel(token, comprador, true)` | [`0x47f3a2b7…5762187e0`](https://sepolia.etherscan.io/tx/0x47f3a2b7c7eefa43e2622770b6a5078921280b6de65928d7fe7a1175762187e0) |
| 12 | `RestrictedTransferPolicy.definirLockup(token, +10 min)` | [`0x316cfb82…f196fc89`](https://sepolia.etherscan.io/tx/0x316cfb8222030a95e6f0a07dd610a3ae50dce2e8e92afc460c5bdf26f196fc89) |
| 13 | `EmissaoGateway.proposeSetTransferPolicy(token, restricted)` | [`0x14a8514e…b62626498`](https://sepolia.etherscan.io/tx/0x14a8514edede27f2422c40ef9e8a303097b7d7abc9bd5ecbce26973b62626498) |
| 14 | `RestrictedTransferPolicy.proposeSetSecundarioLiberado(token, true)` | [`0x2584c442…743cf6a2e5cce8a03e5`](https://sepolia.etherscan.io/tx/0x2584c4429e6c9fec7e58dfcbfd09ca176375384abd917743cf6a2e5cce8a03e5) |

**Artefato de restrição (prova pública, opcional)**: entre a parte 2 e a parte 3, com
o token ainda apontando para `DenyAllTransferPolicy`, foi submetida via `cast send`
(publicado mesmo revertendo) uma tentativa de `ParticipacaoToken.transfer` do
vendedor para o comprador — **falha proposital**, registrada on-chain:
[`0x121ac5a2…970239ec3`](https://sepolia.etherscan.io/tx/0x121ac5a21abadb6243aafec423aa9a7bc3a0fbff64ebd787973d9f8970239ec3)
(`status: 0 (failed)`, revert `TransferenciaNaoPermitida`).

**Espera real do timelock nº 2**: migração de política + abertura do secundário
propostas em `1785713676` (implícito, `executeAfter - 3600`),
`executeAfter = 1785717276` (2026-08-03 00:34:36 UTC) — o lock-up de 10 minutos
definido na ação 12 já havia expirado bem antes desse instante, então a parte 3 já
encontrou a cessão liberável assim que o timelock passou.

### Parte 3 — `DemoSecundario.s.sol` (executa migração + abertura, fecha a cessão)

| # | Ação | Tx hash |
|---|---|---|
| 1 | `EmissaoGateway.executeSetTransferPolicy(token, restricted)` | [`0x16a133e3…82f7f449f`](https://sepolia.etherscan.io/tx/0x16a133e34b1e9cda69b2c7b78f532b21c5e61baa0b17a769c57244182f7f449f) |
| 2 | `RestrictedTransferPolicy.executeSetSecundarioLiberado(token, true)` | [`0x9295e42b…1ac11a531f`](https://sepolia.etherscan.io/tx/0x9295e42b15e745b3e0d3fb4e74bf2433fe71e024abfd7a552542fc1ac11a531f) |
| 3 | `MockBRL.mint(comprador, 2.000 mBRL)` | [`0xf89813cd…9c59b69f42c7604a`](https://sepolia.etherscan.io/tx/0xf89813cd123ab464d807fda03005a47a947b1d59ae8e67209c59b69f42c7604a) |
| 4 | `MockBRL.approve(liquidacao, 2.000 mBRL)` — comprador | [`0x985a1e38…fccd548d48371ab8c8`](https://sepolia.etherscan.io/tx/0x985a1e384ec4bf291ab6bfe7f4893e449c32ac0057a882fccd548d48371ab8c8) |
| 5 | `ParticipacaoToken.approve(liquidacao, 20 cotas)` — vendedor | [`0x524793d9…8673da367441636fe5892e2e8f73945`](https://sepolia.etherscan.io/tx/0x524793d90eae50c5718eb0677140c679d8673da367441636fe5892e2e8f73945) |
| 6 | **`LiquidacaoSecundaria.liquidarCessao(token, vendedor, comprador, 20 cotas, 100 mBRL)`** | [`0xe338d6be…894c9fa3396bbadc26b`](https://sepolia.etherscan.io/tx/0xe338d6be53893a045370c7ecc9d50bac213a3ee9138f9894c9fa3396bbadc26b) |

## Matemática da cessão

- `quantidade = 20 cotas` × `precoPorCota = 100 mBRL` = **`2.000 mBRL`**.
- `taxaSecundarioBps = 0` (dormente) → `taxa cobrada = 0`, `protocolo recebe 0`.
- Vendedor: `50 → 30 cotas` (`-20`), `MockBRL: 0 → 2.000` (`+2.000`, valor inteiro,
  taxa zero).
- Comprador: `0 → 20 cotas` (`+20`), `MockBRL: 2.000 → 0` (`-2.000`, pagou tudo).
- Troca atômica por `allowance` — `LiquidacaoSecundaria` nunca custodiou nenhum dos
  dois ativos; `moeda.transferFrom`/`token.transferFrom` moveram direto entre as
  partes na mesma transação.

Todos os valores acima (saldo de cotas do vendedor/comprador, saldo de `MockBRL` do
vendedor/comprador/protocolo, `transferPolicy()` vigente do token,
`secundarioLiberado`) foram lidos diretamente da chain via `cast call` — não apenas
do console log do script — antes deste documento ser escrito:

```
cotas vendedor:   30000000000000000000 (30 cotas)
cotas comprador:  20000000000000000000 (20 cotas)
MockBRL vendedor: 2000000000000000000000 (2.000 mBRL)
MockBRL comprador: 0
MockBRL protocolo: 0
transferPolicy do token: 0x8E1E7407D3771386c3fE7BF9E823e1A0E83B621E (RestrictedTransferPolicy)
secundarioLiberado: true
```

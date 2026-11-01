# Experimentos genéticos v2 — 2026-10-31

## Escopo e procedimento

Foram criados quatro experimentos isolados no schema `neural_doom_local_game_20261024`: referência `4→6→4`, além de `4→32→4`, `4→64→4` e `4→64→32→64→4`. Cada população inicial tem 8 genomas, seed genética `20261031`, mutação `0.05`, duas gerações planejadas e duas avaliações por genoma. As quatro entradas e saídas reais do engine foram mantidas.

As partidas usaram Freedoom 2 E1M1, skill 2, 20 segundos de controles fixos automatizados, Edge headless e um contexto Playwright isolado. O backend experimental foi reiniciado sequencialmente por arquitetura na porta 8001; o backend existente na porta 8000 não foi substituído. O runner salvou uma captura de tela e um JSON por partida em `%TEMP%\neural-doom-genetic-experiments-v2`.

A seed controla a população genética. O bundle atual não permite fixar a seed aleatória do Freedoom, então mapas, encontros e resultados de gerações não são plenamente controlados. As médias abaixo descrevem as partidas realizadas e **não comprovam melhora de aprendizado**.

As migrations 14 e 15 criam/isolam experimentos e evolução v2. A migration 16 ajusta a atribuição de genomas em sessões com roster menor que a população: genomas com menos avaliações ACK-confirmadas passam primeiro. O fluxo legado de seleção e seu fitness permanecem intactos. A fixture da migration 16 usou dados sintéticos apenas no schema SQL de testes; ela não compõe os resultados do jogo.

## Estado das gerações

Cada geração concluída tem 8 genomas e 16 avaliações usadas pelo agregador: duas por genoma, escolhidas em ordem de conclusão entre sessões registradas e com ACK confirmado. Sessões extras continuam preservadas no banco, mas não entram além das duas avaliações configuradas por genoma.

| Topologia | Geração | Estado | Média fitness | Melhor | Pior | Dano ao jogador | Dano recebido | Mortes de NPC | Sobrevivência somada (s) |
|---|---:|---|---:|---:|---:|---:|---:|---:|---:|
| 4→6→4 | 0 | EVOLVED | -9.5510 | 6.3000 | -56.1750 | 12 | 70 | 3 | 161 |
| 4→6→4 | 1 | COMPLETE | -12.1563 | 14.1250 | -47.0667 | 95 | 171 | 5 | 195 |
| 4→32→4 | 0 | EVOLVED | -18.5875 | 0.2334 | -56.1084 | 41 | 165 | 6 | 171 |
| 4→32→4 | 1 | COMPLETE | 0.0729 | 11.1917 | -17.8167 | 52 | 20 | 1 | 250 |
| 4→64→4 | 0 | EVOLVED | -15.2250 | 8.1250 | -56.0667 | 100 | 185 | 6 | 159 |
| 4→64→4 | 1 | COMPLETE | -29.6084 | 0.2250 | -71.3834 | 100 | 305 | 10 | 151 |
| 4→64→32→64→4 | 0 | EVALUATING | — | — | — | — | — | — | — |

As três primeiras topologias completaram as duas gerações. Para a rede profunda, 5 genomas ainda não tinham as duas avaliações exigidas; ela não foi evoluída. Nenhum `PLAYER_KILL` foi registrado nas gerações concluídas.

As mudanças entre gerações são mistas: a média subiu em `4→32→4`, caiu na referência e caiu em `4→64→4`. Com duas avaliações por genoma e seed do jogo não controlável, isso não é evidência suficiente de melhora genética.

Para orientar uma próxima avaliação, `4→32→4`, geração 1, é uma candidata provisória: teve a maior média observada e baixa latência, mas não é uma vencedora comprovada. O experimento dessa geração já está `COMPLETE`; esta rodada não preparou um modo de avaliação humana que registre novas sessões depois do fechamento. Nenhuma partida humana foi feita ou declarada pronta nesta entrega.

## Decisões e execução pelo engine

Os contadores abaixo somam a telemetria de todas as sessões de cada experimento/geração. `ATTACK SQL` é a quantidade de decisões ATTACK retornadas pelo MySQL; `ofertas engine` conta cada oferta ao longo dos ticks; `aplicadas/rejeitadas` são os resultados medidos pelo engine. Uma decisão SQL não equivale a um ataque executado.

| Topologia / geração | Decisões SQL (IDLE/CHASE/ATTACK/FLEE) | Ofertas ATTACK | ATTACK aplicado / rejeitado | Ações do engine aplicadas / rejeitadas | Fallback / oportunidades |
|---|---:|---:|---:|---:|---:|
| 4→6→4 / 0 | 833 (83/534/145/71) | 350 | 69 / 281 (19.7% aplicadas) | 1,986 / 359 | 52 / 2,397 (2.17%) |
| 4→6→4 / 1 | 441 (11/41/263/126) | 690 | 96 / 594 (13.9%) | 449 / 763 | 21 / 1,233 (1.70%) |
| 4→32→4 / 0 | 894 (125/273/75/421) | 188 | 33 / 155 (17.6%) | 1,873 / 709 | 52 / 2,634 (1.97%) |
| 4→32→4 / 1 | 736 (151/79/166/340) | 430 | 59 / 371 (13.7%) | 1,219 / 894 | 18 / 2,131 (0.84%) |
| 4→64→4 / 0 | 426 (85/156/125/60) | 285 | 67 / 218 (23.5%) | 879 / 283 | 44 / 1,206 (3.65%) |
| 4→64→4 / 1 | 464 (11/0/342/111) | 894 | 99 / 795 (11.1%) | 307 / 925 | 43 / 1,275 (3.37%) |
| 4→64→32→64→4 / 0 | 321 (9/128/32/152) | 91 | 21 / 70 (23.1%) | 1,015 / 367 | 268 / 1,650 (16.24%) |

Houve 0 resposta SQL inválida nas partidas registradas. A seleção de ATTACK foi efetivamente aceita pelo engine em parte das ofertas; estes contadores agregados não separam rejeições por cooldown, estado ou geometria. `4→64→4` geração 1 selecionou ATTACK em 342 decisões, sem CHASE, mas só 99 de 894 ofertas ATTACK foram aplicadas. Isso é comportamento observado, não prova de estratégia aprendida.

Foram registrados 36 sessions reais de navegador nos quatro experimentos; os 36 têm conclusão e ACK de frontend confirmados no MySQL. O roster oscilou entre poucos NPCs e populações completas, e o balanceamento v2 distribuiu avaliações de rosters curtos entre genomas ainda pouco avaliados. Algumas partidas não tiveram eventos de combate; continuam identificadas nos JSONs como sessões survival-only, e não como combates observados.

## Latência WebSocket

Os valores agregam tempos de ida e volta das respostas `npc_action` vistas pelo navegador, incluindo backend e banco. Fallbacks são contabilizados à parte; logo o percentil descreve respostas recebidas, não substitui a métrica de fallback.

| Topologia / geração | P95 agregado (ms) | Maior P95 de uma partida (ms) | Fallback |
|---|---:|---:|---:|
| 4→6→4 / 0 | 91.03 | 135.95 | 2.17% |
| 4→6→4 / 1 | 71.30 | 76.84 | 1.70% |
| 4→32→4 / 0 | 47.89 | 65.33 | 1.97% |
| 4→32→4 / 1 | 60.09 | 71.17 | 0.84% |
| 4→64→4 / 0 | 210.23 | 329.30 | 3.65% |
| 4→64→4 / 1 | 117.08 | 203.13 | 3.37% |
| 4→64→32→64→4 / 0 | 1,387.57 | 1,485.49 | 16.24% |

A rede profunda tem 4.772 parâmetros treináveis e excedeu o limite operacional de P95 de 800 ms, com fallback elevado. A evolução foi bloqueada; topologias maiores que ela não foram iniciadas. A referência, H32 e H64 ficaram abaixo do limite nas partidas observadas.

## Preparação e limites

Para reproduzir no Windows, com MySQL local e login-path de instalação já configurados, dependências frontend instaladas e `backend/.env` válido:

```powershell
cd C:\Users\victo\Rede-Neural-work\neural-doom-lab\frontend
node scripts/run-genetic-experiments-v2.mjs --prepare-only
node scripts/run-genetic-experiments-v2.mjs
```

O runner usa somente `neural_doom_local_game_20261024`, aplica a migration 16 apenas se a procedure ainda não contiver a lógica de balanceamento, e chama a preparação idempotente das quatro experiências. O MySQL installer path é usado somente por esse runner; FastAPI lê as credenciais locais de `backend/.env`. Ele não altera grants nem configurações globais do MySQL. A suíte sintética SQL deve continuar no schema `neural_doom_local_sql_test_20261024`.

Esta validação foi automatizada em Edge headless. Não houve partida humana nesta etapa. A versão ainda precisa de validação humana de movimentação, perseguição, combate e comportamento geral; os valores de fitness não justificam afirmar aprendizado.

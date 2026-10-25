# Experimentos de topologias — 25/10/2026

## Escopo e método

As partidas foram executadas no Freedoom 2, mapa E1M1, skill 2, por 75 s, em Microsoft Edge headless isolado. Um script controlou o jogador com uma sequência fixa de setas, Espaço, Ctrl e Shift; portanto foram partidas automatizadas, não partidas humanas nem agentes que aprenderam a jogar. O fluxo observado foi jogo → WebSocket → FastAPI temporário → procedures MySQL → resposta ao engine. As sessões foram fechadas pelo handshake e as avaliações vieram de eventos de combate persistidos pelo engine.

O schema utilizado foi somente `neural_doom_local_game_20261024`. O seed da população/evolução foi fixado por experimento; o seed aleatório interno do Freedoom não é configurável no bundle atual. A quantidade e a distribuição dos NPCs variaram entre 10 e 17 por sessão. Assim, gerações e arquiteturas têm a mesma configuração nominal, mas os confrontos não são perfeitamente pareados. Cada genoma da geração 0 e das gerações 1 completas recebeu duas avaliações reais; a arquitetura de referência `npc_teste_4_6_4` permaneceu intacta.

| Topologia | Seed | Parâmetros treináveis | Avaliações reais |
|---|---:|---:|---|
| 4 → 6 → 4 | 2026102501 | 58 | 2 partidas/genoma nas gerações 0 e 1 |
| 4 → 32 → 4 | 2026102502 | 292 | 2 partidas/genoma nas gerações 0 e 1 |
| 4 → 64 → 4 | 2026102503 | 580 | 2 partidas/genoma nas gerações 0 e 1 |
| 4 → 64 → 32 → 64 → 4 | 2026102504 | 4.772 | 2 partidas/genoma nas gerações 0 e 1 |
| 4 → 128 → 64 → 128 → 4 | 2026102505 | 17.732 | 1 partida/genoma na geração 0; interrompida por latência |
| 4 → 256 → 128 → 64 → 4 | 2026102506 | 42.692 | 1 partida/genoma na geração 0; interrompida por latência |
| 4 → 512 → 4 | 2026102507 | 4.612 | 2 partidas/genoma nas gerações 0 e 1 |

Todas usam população 4, ReLU oculta, mutação 5%, duas gerações planejadas e duas avaliações por genoma. Foram 22 partidas automatizadas no total: 20 nas cinco topologias completas e duas avaliações parciais das redes maiores.

## Resultados SQL por geração

Fitness e métricas de combate abaixo são agregados sobre as duas partidas de cada geração (ou sobre uma partida nas duas arquiteturas interrompidas). `Dano ao jogador`, `abates` e `dano recebido` são eventos registrados pelo engine; sobrevivência está em segundos agregados. Fitness não é uma medida independente: é calculado da telemetria segundo a fórmula documentada no README.

| Topologia | Geração | Fitness médio / melhor | Dano ao jogador | Abates | Dano recebido | Mortes NPC | Sobrevivência (s) |
|---|---:|---:|---:|---:|---:|---:|---:|
| 4 → 6 → 4 | 0 | -41,0396 / 52,9833 | 63 | 0 | 231 | 7 | 986 |
|  | 1 | -28,8146 / 100,0833 | 236 | 2 | 307 | 12 | 614 |
| 4 → 32 → 4 | 0 | -57,1688 / 154,6333 | 122 | 1 | 381 | 12 | 954 |
|  | 1 | -35,1292 / 36,3833 | 123 | 0 | 300 | 7 | 1.258 |
| 4 → 64 → 4 | 0 | -62,7833 / 129,8500 | 195 | 1 | 430 | 14 | 614 |
|  | 1 | 40,2750 / 113,4167 | 236 | 2 | 144 | 2 | 1.332 |
| 4 → 64 → 32 → 64 → 4 | 0 | -31,7021 / 137,7833 | 220 | 2 | 333 | 12 | 578 |
|  | 1 | -10,6542 / 153,0167 | 229 | 2 | 307 | 9 | 751 |
| 4 → 512 → 4 | 0 | -16,7042 / 92,9833 | 222 | 2 | 268 | 10 | 682 |
|  | 1 | -43,7708 / 132,8667 | 219 | 2 | 319 | 14 | 635 |
| 4 → 128 → 64 → 128 → 4 | 0 parcial | -18,3917 / 101,5167 | 110 | 1 | 159 | 5 | 371 |
| 4 → 256 → 128 → 64 → 4 | 0 parcial | -53,4292 / 139,5500 | 82 | 1 | 208 | 7 | 377 |

As quatro topologias prioritárias e `4 → 512 → 4` evoluíram uma geração usando a procedure SQL depois de completar a cobertura real da geração 0. Não houve avanço genético para `4 → 128 → 64 → 128 → 4` ou `4 → 256 → 128 → 64 → 4`: o limite de latência foi ultrapassado já na primeira partida. Não há evidência suficiente para declarar aprendizado ou superioridade: a amostra é pequena, a aleatoriedade do jogo não está fixada e os indicadores divergem entre gerações. Por exemplo, `4 → 64 → 4` melhorou várias medidas na geração 1, mas isso ainda é um sinal exploratório, não uma conclusão.

## Aplicação de ações, combate e desempenho

O ACK das 22 partidas indicou sessão encerrada; todas as partidas tiveram NPCs, ação neural aceita pelo engine e eventos de combate persistidos. Somando snapshots de ação: 46.651 oportunidades, 30.751 ações aplicadas (65,92%), 14.697 rejeitadas (31,51%) e 1.203 fallbacks para `ORIGINAL_AI` (2,58%). Rejeição significa que a decisão SQL chegou ao bridge do engine, mas não era aplicável naquele estado; não é contada como aplicada. Fallback é separado e cobre, por exemplo, ausência de resposta dentro do prazo. Isso comprova integração e controle neural efetivo, mas a taxa de rejeições ainda merece atenção.

Para `ATTACK`, houve 2.078 seleções pelo SQL e 5.727 ofertas ao engine ao longo dos ticks: 468 aceitas e 5.259 rejeitadas. Uma seleção pode resultar em várias ofertas repetidas, portanto seleção e oferta não têm relação 1:1. “Aplicada” confirma que o engine aceitou a ordem na condição válida, não que o golpe acertou. O evento posterior de dano/morte confirma combate real, mas o schema atual não vincula cada golpe a uma decisão ATTACK específica. Ações ATTACK aceitas foram observadas nas partidas de `4 → 6 → 4` (76), `4 → 32 → 4` (52), `4 → 64 → 4` (91), `4 → 64 → 32 → 64 → 4` (118), `4 → 512 → 4` (112) e `4 → 256 → 128 → 64 → 4` (19). A rede 128 profunda selecionou ATTACK 16 vezes, nenhuma aceita.

Latência medida pelo round-trip do pedido de decisão no navegador até a resposta WebSocket. Inclui engine/frontend, FastAPI e a inferência MySQL; não é uma medição isolada do tempo dentro do MySQL. O limite seguro usado pelo runner é P95 de 800 ms.

| Topologia | Média das médias por partida (ms) | Faixa de P95 entre partidas (ms) | Fallback |
|---|---:|---:|---:|
| 4 → 6 → 4 | 19,4 | 34,3–47,5 | 0,48% |
| 4 → 32 → 4 | 22,9 | 39,8–55,1 | 0,35% |
| 4 → 64 → 4 | 30,4 | 44,7–78,1 | 0,71% |
| 4 → 64 → 32 → 64 → 4 | 136,9 | 202,0–424,2 | 3,08% |
| 4 → 128 → 64 → 128 → 4 | 952,9 | 1.375,3 | 22,83% |
| 4 → 256 → 128 → 64 → 4 | 2.084,5 | 3.552,4 | 72,50% |
| 4 → 512 → 4 | 325,2 | 427,1–700,5 | 4,22% |

As redes 128 e 256 foram interrompidas corretamente: não completaram a segunda repetição da geração 0 nem foram evoluídas. A de 256 excedeu inclusive o prazo de resposta do bridge, produzindo fallback elevado. `4 → 512 → 4` ficou abaixo do corte neste host, porém bem mais lenta que as topologias pequenas e com fitness médio pior na geração 1.

## Integridade, ACK e reprodução

- 15.092 decisões SQL em 22 sessões foram comparadas com a sequência de saúde por sessão/NPC. Os 139 deltas não nulos coincidem com perdas reais de vida; todos os primeiros registros têm delta zero e nenhuma diferença entre sessões foi encontrada. A fórmula validada é `clamp((vida_anterior − vida_atual) / vida_máxima, -1, 1)`.
- Duas partidas da primeira leva tiveram ACK fechado mas o snapshot de ações ficou atrasado em relação à contagem MySQL em 3 e 1 decisões. O dreno de requisições pendentes antes do encerramento foi corrigido e validado numa partida real adicional: ACK=360, banco=360, 11 NPCs, 8 avaliações e sessão encerrada. As seis partidas da leva posterior (quatro de `4 → 512 → 4` e uma de cada rede grande) tiveram contagens ACK/SQL iguais.
- O runner atualizado só considera uma geração íntegra para evolução se ACK, arquitetura, fechamento, contagem de decisões, ação aplicada e evento de combate conferirem; tampouco evolui após P95 > 800 ms. O modo `--prepare-only` verifica a preparação idempotente no schema restrito sem iniciar jogo.
- Testes automatizados nesta finalização: backend 16/16; frontend 2/2; build Vite passou; preparação/autenticação MySQL com login-path passou; teste SQL `10_finish_session_requires_persisted_evaluation.sql` passou no schema SQL de testes.
- Relatórios brutos das partidas ficam fora do Git em `%TEMP%\neural-doom-automated-experiments`: `architecture-experiments-2026-10-25T04-41-55.681Z.json` e `architecture-experiments-2026-10-25T04-54-16.851Z.json` (incluem sessões, decisões, telemetria, latências e ACKs).

## Recomendação e pendências

`4 → 64 → 4`, geração 1, é a candidata provisória para a validação humana: foi a única com fitness médio positivo na pequena amostra da geração 1 e apresentou menos dano recebido/mortes de NPC e mais dano/abates no agregado, com P95 abaixo de 80 ms. Isso não comprova que a evolução melhorou a rede. `4 → 6 → 4` permanece a referência mais rápida e conservadora; use-a se a prioridade for previsibilidade/latência.

Ainda falta uma partida humana para validar sensação de perseguição, fuga, frequência e acerto de ataques, controles e responsividade. Também faltam repetições com seed do jogo controlável, avaliação mais longa e latência isolada por procedure MySQL. Até essas etapas, não apresentar a rede como treinada ou vencedora.

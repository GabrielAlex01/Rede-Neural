# Interface, modos e redes criadas no laboratório

Validação automatizada em 1/11/2026 com Edge headless, contexto Playwright isolado, Freedoom 2 MAP01/skill 2, backend FastAPI e MySQL local nos schemas Neural Doom. Não houve uso de mouse, teclado ou janela física. Os testes são automatizados; nenhuma partida humana foi realizada.

## Opções e critérios do painel

Os testes usam `EXTERNAL_AI` com `MySQL neural (via backend)` em Freedoom 2 MAP01, skill 2. O painel não calcula nem mostra um ranking de arquiteturas por desempenho. O catálogo seleciona apenas arquiteturas que a procedure SQL aceita para jogar. A H32 G1 e a referência 4→6→4 são atalhos explícitos para avaliação, não recomendações baseadas em fitness, comportamento, aceitação de ações ou latência. A seleção inicial respeita a arquitetura já escolhida, o padrão configurado no backend e, na falta deles, a ordem do catálogo SQL.

As evidências devem ser lidas como categorias distintas:

- **Maior fitness individual v2 observado (snapshot local em 1/11/2026):** 28,1667, empate entre H64 G0 genoma #79 e 4→6→4 G1 genoma #99, com duas avaliações cada. São registros históricos de experimentos encerrados e não aparecem como jogáveis no catálogo atual. O empate não estabelece uma arquitetura vencedora.
- **Baseline mais leve:** `auto_20261025_ref46`, 4→6→4, 58 parâmetros treináveis, geração 1 quando o catálogo SQL a mantém utilizável. É referência de custo, não de desempenho.
- **Combate demonstrado:** população local aleatória 4→8→4 `lab_new_mvx9gl5o_fada0840`, G0 genoma #113. Uma partida headless fixou o genoma, registrou 139 decisões ATTACK e aplicou 25 de 388 ofertas repetidas; os eventos da sessão registraram 23 de dano ao jogador, 20 recebidos e uma morte NPC (fitness -30,9833). Esses eventos demonstram combate naquela sessão, sem atribuir causalmente o dano a uma oferta ATTACK individual. Não é evidência de treinamento e esse registro está apenas no schema local do experimento.

O seletor mostra `fitness legado` e a quantidade de avaliações v2 registradas. O fitness legado não é o fitness calculado pelas avaliações v2. Latência por decisão e contagens de ações aplicadas, rejeitadas e fallback são observáveis na sessão/ACK, mas nenhuma delas alimenta um ranking ou altera a decisão SQL.

A regressão headless mais recente fixou `auto_20261025_h32`, G1, genoma #32. O painel mostrou `NPC 17 · genoma #32 · geração 1 · auto_20261025_h32`; a camada de saída exibiu quatro ativações do `run_id=40401`. Todas as linhas da API correspondiam ao mesmo run, genoma e arquitetura, e os valores renderizados coincidiram com a resposta da API/SQL. Na sessão `058484a0-1fff-4586-9a64-789b1f60e253`, dois NPCs usaram o genoma #32 e houve 58 decisões SQL (todas FLEE), 172 oportunidades, 170 ofertas ao engine, 119 aplicações, 51 rejeições e dois fallbacks `waiting_for_mysql`; não houve respostas SQL inválidas nem eventos de combate. A latência WebSocket média/P95 foi 67,85/85,28 ms. O ACK informou sessão fechada e avaliação completa, e o recibo foi confirmado. A consulta SQL read-only confirmou 58 runs, avaliação do genoma #32 com fitness 0,3333, dano recebido e ao jogador iguais a zero, nenhuma morte e 20 segundos de sobrevivência. A partida não demonstrou combate nem aprendizado.

Uma sessão H32 headless anterior, `a66a01c6-ef6d-448c-99b0-9286c26a232a`, registrou 64 decisões (63 FLEE, 1 IDLE), 183 oportunidades, 173 ofertas, 141 aplicações, 32 rejeições, 10 fallbacks e latência média/P95 de 42,78/106,91 ms. O jogador não recebeu dano; NPCs receberam 40 e um morreu; fitness -59,6333. Nessa sessão, o `run_id=40343` e as 40 ativações SQL de todas as camadas foram conferidos com o genoma #32; a interface exibiu as quatro ativações da saída. É evidência de aplicação da identidade selecionada e eventos da sessão, não de causalidade entre uma ação individual e o dano.

## Modos e cobertura

| Configuração | O que foi validado | Limite da evidência |
|---|---|---|
| ORIGINAL_AI | Smoke headless em MAP01/skill 2. Não abriu sessão neural, não fez inferência e não persistiu avaliação. Renderização observada: 144,24 FPS com painel fechado e 144,25 com painel aberto. | FPS é `requestAnimationFrame`, não contador interno do engine. O painel pode fazer consultas de leitura quando aberto. |
| EXTERNAL_AI + Local mock | Partida headless; ação mock observada. Zero WebSockets `/ws/ai`, decisões SQL e chamadas ao laboratório/MySQL. | Política JavaScript de desenvolvimento; não testa rede neural nem aprendizado. |
| EXTERNAL_AI + MySQL, H32 G1 (sessão anterior) | Partida headless com genoma #32; 194 decisões SQL FLEE, ACK, recibo e avaliação v2 persistidos. Latência WebSocket média/P95 78,18/160,89 ms; chamada MySQL 42,29/70,31 ms; round trip backend+banco 58,99/95,48 ms. | Sem eventos de combate; fitness 1,1667. A sessão mais recente está descrita acima. |
| EXTERNAL_AI + MySQL, rede criada na interface 4→8→4, genoma #113 | Criação de arquitetura/população, seleção exata e partida. 139 decisões ATTACK; 25 ofertas aplicadas, 363 rejeitadas e quatro esperas com fallback. Eventos: 7 `PLAYER_DAMAGE`, 1 `NPC_DAMAGE`, 1 `NPC_DEATH`. ACK, recibo e avaliação v2 presentes. Latência WebSocket média/P95 70,76/199,18 ms; chamada MySQL 39,26/87,54 ms; round trip backend+banco 58,39/113,67 ms. | Fitness -30,9833; dano ao jogador 23, dano recebido 20, uma morte NPC, 61 s de sobrevivência. Eventos são da sessão inteira, não atribuem causalmente cada evento a uma oferta individual. |
| EXTERNAL_AI + MySQL, segunda rede nova 4→8→4, genoma #115 | Segunda criação isolada e nova sessão: 136 decisões ATTACK; 24 ofertas aplicadas, 356 rejeitadas e três esperas com fallback. Eventos: 4 `PLAYER_DAMAGE`, 1 `NPC_DAMAGE`, 1 `NPC_DEATH`. ACK, recibo e avaliação v2 presentes. Latência WebSocket média/P95 48,47/116,87 ms; chamada MySQL 28,40/53,43 ms; round trip backend+banco 44,23/80,66 ms. | Fitness -39,0000; dano ao jogador 15, dano recebido 20, uma morte NPC, 60 s de sobrevivência. As duas avaliações H8 não são comparáveis como prova de evolução; são genomas aleatórios distintos. |

As ofertas do engine são repetidas por tick enquanto o NPC mantém a decisão. Rejeição por estado, geometria ou cooldown é diferente de falha de transporte: nas partidas H8 não houve respostas SQL inválidas; houve 3–4 fallbacks `waiting_for_mysql`, e as demais rejeições foram contadas explicitamente pelo engine antes do fallback à IA original. O ACK para a sessão #115 registrou 383 oportunidades, 136 decisões SQL, 380 envios ao engine, 24 aplicações, 356 rejeições e 3 fallbacks.

O painel, runner e engine registraram três NPCs em cada partida H8, mas todos eram `npc_type=1`. Não foi validada cobertura de outros tipos nesta rodada. Os logs confirmam `startmap: 1`, `startepisode: 1`, `startskill 2` com Freedoom 2: MAP01, skill 2. Outros mapas e dificuldades não foram testados.

O fallback com o MySQL intencionalmente desligado não foi testado numa partida, para não interromper nem alterar o serviço local. A regressão backend que simula falha de conexão confirma que o backend devolve uma decisão inválida para o fallback do engine; isso é teste automatizado de falha, não validação de indisponibilidade real. Também não foi testada a opção de reinício dentro do menu do Doom. Foram abertas partidas em sessões/instâncias headless novas, com IDs distintos e ACK confirmado em cada sessão. Para começar outra partida, encerre a sessão neural e aguarde ACK; então recarregue a página e inicie uma nova sessão. Trocar arquitetura ou genoma não altera uma sessão em andamento.

## Criar e selecionar uma rede

1. Abra o laboratório, informe um nome único e a topologia com 4 entradas/saídas, por exemplo `4, 8, 4`; confira neurônios, conexões e parâmetros antes de criar.
2. Em **População inicial isolada**, selecione a arquitetura vazia, escolha quantidade e semente e inicialize. Isso cria a geração 0 sem tocar em arquiteturas, populações ou avaliações anteriores.
3. Selecione a arquitetura no catálogo. A listagem só inclui redes com genomas/generation que a procedure de decisão aceita.
4. Escolha geração e genoma para inspecionar. Para fixar essa identidade no próximo jogo, use **Usar genoma selecionado na próxima partida**. O SQL valida o par arquitetura/genoma, fixa a associação por NPC e recusa mudança durante a sessão. Sem essa opção, o SQL distribui o roster utilizável.
5. Selecione `EXTERNAL_AI` + MySQL, inicie o jogo e confira no laboratório ações SQL, ativações MySQL, aplicação no engine e tempos. Encerre a sessão e confirme ACK/avaliação antes de recarregar para jogar com outra rede.

O runner `npm run test:match -- --create-new-network` automatiza um fluxo curto com nome único, 4→8→4, população 2, seed 20261101, genoma fixado, partida, ACK e persistência. Ele verifica que as contagens de genomas das arquiteturas anteriores não mudaram. JSON e screenshots ficam em `%TEMP%`, fora do Git.

## Testes executados

- SQL migration 18 instalada nos dois schemas isolados; fixture SQL 17 passou no schema de testes. A fixture é sintética e valida seleção/lock de genoma, não comportamento de combate.
- Backend: suíte de 31 testes passou, incluindo validação do genoma fixo, associação SQL antes da inferência, WebSocket e fallback de conexão indisponível.
- Frontend: 10 testes Node passaram; build Vite passou.
- UI Playwright: catálogo SQL real, candidata e alternativa verificadas, camadas/pesos consultados, genoma fixado salvo e recuperado, viewport de 390 px sem overflow.
- Modos Playwright: ORIGINAL_AI e Local mock executados headless, sem inferência MySQL.
- Partidas Playwright H32 G1 e duas populações H8 novas concluíram; cada sessão teve ACK fechado, recibo confirmado e avaliação v2 persistida.
- Teste de FPS headless passou. Nenhum teste de jogabilidade humana foi feito.

A consulta read-only após as regressões encontrou 14 arquiteturas, 116 genomas, 85 sessões e 40.401 runs de decisão no schema de jogo. Durante esta revisão, partidas acrescentaram sessões e avaliações próprias; não houve atualização, remoção ou substituição de arquiteturas e genomas existentes.

## Pendências para validação humana

- Jogar manualmente com H32 G1 para avaliar se a política só-FLEE é aceitável.
- Testar uma partida com mouse, outros mapas/dificuldades e mais tipos de NPC.
- Repetir partida após encerramento e ACK no mesmo navegador e validar fluxo do menu de reinício do Doom.
- Testar fallback durante indisponibilidade real de MySQL somente numa instância de teste descartável.
- Fazer comparações pareadas, com várias partidas e condições equivalentes, antes de afirmar evolução ou escolher uma rede vencedora.

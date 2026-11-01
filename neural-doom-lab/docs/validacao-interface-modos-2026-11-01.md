# Interface, modos e redes criadas no laboratório

Validação automatizada em 1/11/2026 com Edge headless, contexto Playwright isolado, Freedoom 2 MAP01/skill 2, backend FastAPI e MySQL local nos schemas Neural Doom. Não houve uso de mouse, teclado ou janela física. Os testes são automatizados; nenhuma partida humana foi realizada.

## Configuração recomendada

Use `EXTERNAL_AI` com `MySQL neural (via backend)`. Como configuração candidata, a interface procura no catálogo SQL uma arquitetura 4→32→4 com geração 1 utilizável; no schema validado ela é `auto_20261025_h32`. A opção de menor custo é a referência 4→6→4, `auto_20261025_ref46`, também condicionada à disponibilidade da geração 1 no catálogo. A referência de mapa é Freedoom 2 MAP01, skill 2.

“Candidata” descreve apenas uma configuração reproduzível para avaliação. A H32 G1 selecionou somente FLEE na partida mais recente e não causou dano nessa sessão. Não há demonstração de superioridade nem aprendizado consistente. A H8 recém-criada selecionou ATTACK, mas a maioria das ofertas repetidas foi rejeitada e as avaliações foram negativas. Nenhuma rede recém-inicializada deve ser chamada de treinada.

## Modos e cobertura

| Configuração | O que foi validado | Limite da evidência |
|---|---|---|
| ORIGINAL_AI | Smoke headless em MAP01/skill 2. Não abriu sessão neural, não fez inferência e não persistiu avaliação. Renderização observada: 144,24 FPS com painel fechado e 144,25 com painel aberto. | FPS é `requestAnimationFrame`, não contador interno do engine. O painel pode fazer consultas de leitura quando aberto. |
| EXTERNAL_AI + Local mock | Partida headless; ação mock observada. Zero WebSockets `/ws/ai`, decisões SQL e chamadas ao laboratório/MySQL. | Política JavaScript de desenvolvimento; não testa rede neural nem aprendizado. |
| EXTERNAL_AI + MySQL, H32 G1 | Partida real headless com três NPCs atribuídos ao genoma #32; 194 decisões SQL FLEE, 265 ofertas aplicadas, 303 rejeitadas e cinco esperas com fallback. ACK, recibo e avaliação v2 persistidos. Latência WebSocket média/P95 78,18/160,89 ms; chamada MySQL 42,29/70,31 ms; round trip backend+banco 58,99/95,48 ms. | Nenhum evento de combate na sessão; avaliação foi sobrevivência, fitness 1,1667. Não é evidência de combate ou aprendizado. |
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

Os resultados persistidos no schema de jogo ao final destas partidas foram 14 arquiteturas, 116 genomas, 81 sessões e 26.651 decisões. A mudança de contagem corresponde às duas redes H8 recém-criadas e às três sessões automatizadas desta validação; os scripts conferiram que os genomas das arquiteturas anteriores ficaram intactos.

## Pendências para validação humana

- Jogar manualmente com H32 G1 para avaliar se a política só-FLEE é aceitável.
- Testar uma partida com mouse, outros mapas/dificuldades e mais tipos de NPC.
- Repetir partida após encerramento e ACK no mesmo navegador e validar fluxo do menu de reinício do Doom.
- Testar fallback durante indisponibilidade real de MySQL somente numa instância de teste descartável.
- Fazer comparações pareadas, com várias partidas e condições equivalentes, antes de afirmar evolução ou escolher uma rede vencedora.

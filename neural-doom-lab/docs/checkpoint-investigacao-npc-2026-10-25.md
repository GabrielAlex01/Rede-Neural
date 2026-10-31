# Checkpoint — atribuição de combate e comportamento neural

Data: 25/10/2026  
Branch: `codex/mysql-neural-doom`  
Clone de trabalho: `C:\Users\victo\Rede-Neural-work`  
Workspace original `C:\Users\victo\doom-wasm`: preservado, sem alterações.

## Investigação concluída

As consultas foram feitas em modo de leitura no schema isolado `neural_doom_local_game_20261024`, pelo login-path instalador. A conta da aplicação conecta ao MySQL 8.0.46, mas tem privilégios de `EXECUTE` e não permite enumerar tabelas; nenhum privilégio ou credencial foi alterado. Nenhum schema recebeu escrita nesta etapa.

Arquivos e áreas examinados: `database/04_genome_initialization.sql`, `05_neural_inference.sql`, `06_combat_telemetry.sql`, `07_genetic_evolution.sql`, `08_configurable_architectures.sql`, `09_training_experiments.sql`, `11_prepare_autonomous_architecture_experiments.sql`; `backend/decision_service.py`, `backend/main.py`, `backend/action_metrics.py`; `engine/neural-ai-bridge.patch` e as cópias-fonte locais `p_enemy.c`, `p_inter.c`, `p_mobj.c`, `p_mobj.h`, `p_saveg.c`, `p_neural_ai.c/.h`; `frontend/src/main.js`, `frontend/src/ai-metrics.js`; os scripts de partida automatizada e o relatório de experimentos.

Achados dos dados existentes:

- A H64 geração 1 (`auto_20261025_h64`, genomas 33–36) tem 2.505 decisões SQL observadas, todas `FLEE`. Por genoma: 843, 693, 626 e 343 decisões. A ativação média da saída `FLEE` fica entre 0,9793 e 0,9940; `CHASE`, entre 0,0048 e 0,0478. A saída `FLEE` vence quando o jogador está visível e também quando não está. As entradas reais variam: saúde média por genoma de 0,805 a 0,985, distância normalizada média de 0,320 a 0,434 e visibilidade de 0,507 a 0,739. Não é uma saída explicada apenas por falta de variação nas entradas.
- Os biases `FLEE` dos genomas H64 geração 1 vieram dos pais 18/19: 0,7517 ou 0,6396, contra biases de `CHASE` de -0,8889 ou -0,5014. A geração 1 foi cruzada a partir dos dois melhores fitness legados da geração 0; houve população 4, elite 2, mutation rate 0,05 e mutações por parâmetro limitadas a ±0,25 com pesos/biases limitados a [-1,1]. A seleção propagou o viés de saída dos pais.
- A rede H32 geração 1 é mais diversa, mas o genoma 29 escolheu `ATTACK` 636 vezes quando a visibilidade era sempre 0 e `FLEE` 404 vezes, quase sempre com visibilidade 1. Isso sugere que diversidade por si só não comprova ataques válidos.
- Na referência 4→6→4 geração 1, os genomas 25 e 26 escolheram `ATTACK` 78 e 116 vezes; os genomas 27/28 escolheram `IDLE`. H64 geração 0 também era mais diversa, em particular o genoma 18 (`ATTACK` 324, `FLEE` 168). Os fitness legados dessas populações não são evidência independente de aprendizado.
- O forward pass SQL usa quatro entradas: `health_ratio`, `player_distance/2048` clampada a [0,1], `player_visible` e `health_delta` clampada a [-1,1]. A saída usa sigmoid por ação e escolhe a maior ativação. A taxa de 5% é mutação por parâmetro, não por genoma.
- A função de fitness atual é `dano ao jogador + 100×eliminações − 0,25×dano recebido − 50×mortes do NPC + sobrevivência/60`. Ela não usa contagem de ações aceitas/rejeitadas.

Suspeita concreta confirmada por inspeção do engine: `A_Chase` só marcava `neural_controlled` depois de uma ação aceita, mas mantinha a marca latched pelo restante da vida do NPC. Quando uma oferta neural era rejeitada, `A_Chase` continuava na IA original. `NAI_ReportCombatEvent` usava a marca latched para atribuir ao genoma dano e eliminações feitos pelo NPC. Como a H64 geração 1 só pediu `FLEE`, ela não podia causar dano por uma ação de ataque neural; o dano ao jogador atribuído a essa geração veio do caminho vanilla/fallback (ou de projéteis iniciados por esse caminho). Os eventos antigos não guardam proveniência suficiente para estimar a fração exata por origem. As avaliações e seus fitness não foram apagados nem recalculados.

## Correção em andamento — estado no checkpoint de 25/10 (depois concluída)

Foi editado o patch versionado e a árvore-fonte vendorizada ignorada dentro deste clone. A proposta adiciona proveniência de ataque no ator/projétil, marca como membro avaliado todo NPC que recebeu uma decisão SQL válida (mesmo que rejeitada), marca ataque neural somente depois dos gates originais do engine, e só credita `PLAYER_DAMAGE`/`PLAYER_KILL` quando o dano veio de melee neural ou de míssil originado por um ataque neural. O dano reportado passa a ser limitado ao dano efetivamente removido da vida do jogador. O cooldown `MF_JUSTATTACKED` é mantido. Nenhum gate de combate foi enfraquecido.

As mudanças estão em `neural-doom-lab/engine/neural-ai-bridge.patch` e, para build local, nos arquivos-fonte sob `neural-doom-lab/engine/vendor/chocolate-doom/src/doom/`. O patch foi regenerado e a checagem reversa contra a árvore-fonte passou, mas a correção ainda **não** foi compilada, testada em partida, aplicada ao MySQL, nem commitada. Não use ainda o WASM atual como validação desta correção.

## Continuação exata

1. Validar o diff regenerado e construir um toolchain temporário novo: a pasta `%TEMP%\neural-doom-final-review-toolchain` da revisão anterior ficou parcialmente removida e não contém mais `emsdk.bat`, `emcc`, CMake ou Ninja. Não tocar no `doom-wasm` original.
2. Adicionar uma migração não destrutiva e um campo de versão de atribuição/fitness. Registros existentes devem permanecer identificados como legado (`legacy_latched_v1`); avaliações futuras, feitas com o novo WASM, devem receber `neural_attack_provenance_v2`. Atualizar também o DDL base `database/06_combat_telemetry.sql`.
3. Testar a migração e a suíte SQL em um schema de testes novo e isolado; não limpar nem reutilizar destrutivamente `neural_doom_local_sql_test_20261024`.
4. Evitar misturar avaliações legadas e novas nas arquiteturas originais. Se necessário, criar aliases de avaliação somente para as topologias existentes 4→6→4, 4→32→4 e 4→64→4, copiando genomas identificados, sem mudar pesos de origem nem criar topologias maiores.
5. Recompilar o WASM, executar backend/frontend e partidas Edge automatizadas repetidas com os mesmos controles; conferir SQL escolhido, oferta/aplicação/rejeição do engine, ACK, eventos e métricas persistidas. Incluir H64 g1 como controle FLEE e genomas diversos existentes como comparação para observar ATTACK neural válido.
6. Rodar testes backend/frontend/SQL e revisar o diff. Só então fazer commits separados para engine/telemetria e documentação/experimentos; sem push/merge.

Não houve novo treinamento nem partidas nesta etapa. O build e as partidas automatizadas anteriores descritos em `docs/experimentos-2026-10-25.md` continuam sendo o baseline anterior à correção.

## Atualização de 31/10/2026

A proveniência foi corrigida, o patch foi aplicado a um checkout limpo do commit upstream fixado e o WASM compilou com 165/165 etapas. `neural_attack_active` só passa a verdadeiro quando o engine aceita ATTACK; termina no retorno a `A_Chase`, morte ou ressurreição. Projéteis guardam o ID do atacante no spawn, e impactos tardios são atribuídos pelo ID salvo, sem depender do ponteiro do NPC. Fallback/ORIGINAL_AI não gera crédito positivo de dano/eliminações.

A migration aditiva e os testes SQL v2 estão em `neural-doom-lab/database/`. Sessões novas são marcadas em tabela lateral após uma observação do engine que declara `neural_attack_provenance_v2`; avaliações v2 são isoladas e não atualizam fitness legados. A conta instaladora não tinha `ALTER`, e nenhuma permissão foi aumentada.

Quatro partidas automatizadas, duas com H64 geração 1 e duas com a referência 4→6→4 geração 1, foram encerradas por ACK e persistidas no schema de jogo. A referência produziu ATTACK aplicado, dano e uma eliminação por partida; H64 escolheu apenas FLEE. Resultados, sessões, ativações, métricas, limitações e a ausência de uma sessão humana estão detalhados em `neural-doom-lab/docs/avaliacao-proveniencia-v2-2026-10-31.md`. Nenhuma nova geração foi evoluída e não há afirmação de aprendizado.

### Continuação em 31/10/2026 — partida longa e auditoria final

O Git permaneceu limpo na branch `codex/mysql-neural-doom` em `aa15b5e` antes da atualização deste checkpoint. Foi iniciada uma nova instância do backend com `auto_20261025_ref46` e feita uma partida automatizada de 120 segundos após reinício. A sessão `7000cbcd-aa6a-4dab-bc71-5ceebedaec92` recebeu ACK `closed=true` e persistiu quatro avaliações v2 no schema isolado do jogo. O genoma 25 teve 188 de dano ao jogador e duas eliminações; o NPC 24, genoma 25, foi avaliado após sete seleções ATTACK e causou 74 de dano e uma eliminação sem morrer. O total do ACK foi 70 ATTACK aceitos, 5.416 ofertas rejeitadas (repetidas, não decisões SQL únicas) e 138 fallbacks `waiting_for_mysql`; RTT médio/P95 medido em carga foi 397,2/546,6 ms.

A busca por eventos v2 posteriores à morte do mesmo `engine_npc_id` não encontrou um impacto após `NPC_DEATH`, nem nas quatro partidas anteriores nem nesta. O caminho está inspecionado no C: o projétil guarda o ID estável do dono ao nascer durante ataque aceito; o estado de ataque do ator é limpo ao morrer e o projétil preserva sua origem. Fica pendente provocar e observar especificamente esse caso em combate real; não o apresentamos como comprovado em partida.

Os testes backend (17), frontend (2) e build Vite passaram novamente, e o backend/Frontend completaram a partida integrada com ACK e persistência. Não houve alteração C nesta continuação; o WASM permanece o artefato compilado e validado no commit `b6de306`. Nenhum teste SQL mutável foi repetido nesta continuação; a regressão v2 e migration já haviam passado em schema de teste isolado. Os detalhes e as avaliações por genoma estão em `docs/avaliacao-proveniencia-v2-2026-10-31.md`. Não foram feitas alterações em `doom-wasm`, em outros schemas, nem no código da aplicação.

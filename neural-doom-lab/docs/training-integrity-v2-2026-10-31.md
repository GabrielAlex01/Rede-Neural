# Integridade de treinamento v2 — 31/10/2026

## Migração e handshake

`database/migrations/13_training_integrity_v2.sql` foi instalada nos schemas isolados de jogo e de testes com a conta instaladora já configurada. Ela não usa `ALTER`, não atualiza tabelas antigas e não marca sessões retroativamente. A versão confiável é copiada para `nn_genome_evaluation_training_v2` apenas quando a sessão foi registrada ainda aberta, avaliada e encerrada.

O token de conclusão fica em `nn_training_session_completion_v2`. O backend o envia em `session_end_ack`, o frontend o devolve em `session_end_ack_receipt` e o backend grava o recebimento. A evolução v2 deve aceitar somente sessões com `ack_confirmed_at` preenchido. Sessões comuns sem registro continuam fechando pela procedure v2 existente e não entram na tabela de treinamento.

O cadastro inicial usa `INSERT IGNORE`, e o encerramento reaproveita o token já persistido; assim chamadas concorrentes ou repetidas não criam cadastros ou ACKs diferentes. Não foi necessário ampliar privilégios nem alterar configurações globais do MySQL. O Python global não tinha o conector MySQL, então a integração foi executada pelo `.venv` existente no projeto.

## Validação SQL e da ponte

- Migration repetida sem falha no schema SQL de testes.
- Testes `11_attack_provenance_v2.sql` e `12_training_integrity_v2.sql` passaram. O teste 12 usa eventos artificiais somente para validar a fórmula, a recusa de registro retroativo, o token idempotente e a confirmação do ACK; não mede combate nem aprendizado.
- Integração FastAPI/WebSocket com o MySQL local passou. Uma sessão marcada explicitamente como sintética obteve uma decisão SQL, persistiu um evento de fixture, gravou a avaliação `combat_outcome_v2_1` e confirmou o ACK. O banco confirmou uma linha de decisão, uma avaliação com fitness `3.0000` e `ack_confirmed_at` preenchido. Essa fixture não é evidência de jogo.

## Partida automatizada headless

Registro: `2026-10-31T22-29-04.055Z`, sessão `c0b73447-0d00-4137-a22e-fd82803b897c`. Foi uma partida automatizada por Playwright/Edge headless em Freedoom 2 MAP01, skill 2, com EXTERNAL_AI e MySQL. O script controla o jogador pelo contexto isolado do navegador e salvou JSON e screenshot no diretório temporário `neural-doom-results-v2`. Não houve janela na área de trabalho. Relatórios anteriores chamavam o mapa de E1M1; os logs `startmap: 1`/`startepisode: 1` motivaram a correção do rótulo.

| Medida | Resultado observado |
|---|---:|
| Controle automatizado | 23,26 s (20 s configurados) |
| Decisões respondidas pelo SQL | 205 de 205 solicitações |
| NPCs registrados / genomas distintos | 11 / 8 |
| Latência WebSocket ida e volta média / P95 | 17,41 ms / 29,79 ms |
| Ofertas ao engine / aplicadas / rejeitadas | 577 / 399 (69,2%) / 178 (30,8%) |
| Fallback ORIGINAL_AI | 11 (aguardando decisão MySQL); respostas SQL inválidas: 0 |
| ATTACK escolhido pelo SQL / ofertas ao engine / aplicadas / rejeitadas | 36 / 83 / 23 / 60 |
| Eventos persistidos | 11 `PLAYER_DAMAGE` (97), 12 `NPC_DAMAGE` (91), 3 `NPC_DEATH`; nenhum `PLAYER_KILL` |
| Avaliações / ACK do frontend confirmado | 8 / sim |

Os três `NPC_DEATH` ocorreram sem morte do jogador, o que é compatível com nenhum `PLAYER_KILL`: esse evento representa um NPC neural eliminar o jogador. O match teve combate real automatizado, mas não tem seed de jogo gravada e não é comparação controlada entre genomas ou gerações. Não há evidência de melhoria por aprendizado.

O engine aplicou 23 das 83 ofertas `ATTACK`; 60 foram rejeitadas. As respostas do SQL foram todas válidas, então essas rejeições ocorreram depois da decisão na aplicação pelo engine. Este registro não discrimina a causa geométrica/cooldown de cada recusa; não se deve contar as 36 escolhas SQL como 36 ataques executados.

O único erro de console observado no navegador foi a requisição opcional `/favicon.ico` com 404. A partida, a ponte, o encerramento e o ACK foram concluídos. Uma tentativa separada de 8 segundos não produziu solicitações a NPCs e não foi contabilizada como partida.

## Limites deste checkpoint

O match usou a arquitetura padrão `npc_teste_4_6_4`, não uma população genética v2 isolada. Os novos valores foram preservados em tabelas versionadas, mas ainda não houve comparação repetida entre arquiteturas, genomas ou gerações. Nenhum resultado aqui justifica declarar uma arquitetura vencedora ou aprendizado comprovado.

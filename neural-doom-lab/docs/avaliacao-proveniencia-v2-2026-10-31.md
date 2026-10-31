# Validação da proveniência v2 — 31/10/2026

## Alteração e isolamento dos dados

O patch `engine/neural-ai-bridge.patch` agora envia a marca `neural_attack_provenance_v2`. O backend recusa observações sem essa marca, registra a sessão em `nn_engine_session_provenance_v2` e encerra pelo procedimento `sp_nn_finish_session_v2`. Avaliações corrigidas ficam em `nn_genome_evaluation_v2` e `nn_generation_summary_v2`; nenhum registro ou fitness legado foi recalculado.

A migration `database/migrations/12_attack_provenance_v2.sql` foi aplicada ao schema SQL de testes e ao schema de jogo, ambos em MySQL 8.0.46/3306. O login-path do instalador não tinha privilégio `ALTER`, então a solução usa tabelas novas e não exige ampliar permissões. A conta da aplicação conseguiu executar as procedures na integração real. Antes e depois das partidas, o schema de jogo manteve 128 avaliações legadas; havia 28 sessões legadas antes das partidas. Nenhum outro schema foi usado.

O teste `database/tests/11_attack_provenance_v2.sql` passou duas vezes no schema SQL de testes. É uma fixture sintética de regressão SQL: comprovou cálculo/persistência e que `nn_genome_evaluation` e `nn_genome.fitness` legados ficaram iguais. Não é resultado de combate nem evidência de aprendizado. Os testes SQL antigos que reescrevem genomas ou evoluem populações não foram repetidos sobre um schema de testes já preenchido.

## Condições das partidas automatizadas

Foram feitas quatro partidas com Edge headless controlando o jogador, Freedoom 2, E1M1, EXTERNAL_AI, backend FastAPI e o MySQL local. Cada execução controlou o jogo por 45 segundos com a mesma sequência de teclado; o log do engine registrou `startskill 2`. Houve duas execuções para cada rede, cada uma com UUID de sessão novo. O processo do backend foi reiniciado ao alternar arquitetura.

| Arquitetura, geração 1 | Sessão | NPCs com genoma | Decisões SQL | Seleção do MySQL | Ofertas ao engine: aplicadas / rejeitadas | Fallback ORIGINAL_AI | RTT médio / P95 |
|---|---|---:|---:|---|---:|---:|---:|
| H64 | `a8a1ae71-a43d-4164-a22a-ede48a3e0fe7` | 14 | 732 | 732 FLEE | 1.247 / 906 | 20 | 33,3 / 65,0 ms |
| H64 | `f04b5bb6-f03e-463b-9691-ad22c04b3c7e` | 11 | 693 | 693 FLEE | 1.185 / 853 | 14 | 29,6 / 54,1 ms |
| Referência 4→6→4 | `afa71157-2447-4142-b3f9-7a10e8e91f87` | 11 | 158 | 53 ATTACK, 105 IDLE | 327 / 96 | 14 | 20,9 / 39,3 ms |
| Referência 4→6→4 | `33a7c8ab-10a4-443c-8b9c-2eb702a4839b` | 11 | 158 | 53 ATTACK, 105 IDLE | 327 / 96 | 14 | 21,9 / 45,1 ms |

Os números de ofertas e resultados vêm do resumo final no ACK, não da leitura do painel antes de encerrar. Todos os quatro ACKs chegaram com `closed=true`; cada sessão tem quatro avaliações v2 persistidas e foi encontrada no schema correto. Não houve resposta SQL inválida, fallback por backend offline ou evento de combate rejeitado pelo backend. O fallback registrado veio de `waiting_for_mysql`, quando uma resposta ainda não estava disponível para aquele tick.

## ATTACK e rejeições do engine

ATTACK foi calculada pelo MySQL em ambas as partidas da referência. Em cada uma, 53 decisões SQL ATTACK originaram 124 ofertas repetidas ao engine: 28 passaram pelos gates do Chocolate Doom e 96 foram rejeitadas. A telemetria do jogo registrou 15 eventos PLAYER_DAMAGE, 108 de dano efetivo e uma eliminação por sessão.

O NPC vivo `24`, associado ao genoma 25 da geração 1, recebeu 7 decisões SQL ATTACK e causou 74 de dano e uma eliminação em cada partida. A ação aplicada aparece nos logs do engine; os eventos com o mesmo ID chegaram à procedure SQL e aparecem na avaliação v2. Isso confirma o caminho MySQL → backend → engine → ataque → impacto, não somente a escolha da rede.

O engine mantém seus critérios: cooldown `MF_JUSTATTACKED` e alcance/linha de ataque (`P_CheckMeleeRange`/`P_CheckMissileRange`). Os logs mostram tanto rejeições quanto aplicações para ATTACK; a telemetria atual agrega rejeições e não grava qual dos gates recusou cada oferta, então não há contagem exata por motivo. Não houve erro de comunicação nesses pedidos. A H64 ofereceu apenas FLEE; sua taxa de aceitação foi aproximadamente 58%, pois a execução do movimento pode falhar quando `P_Move` não encontra passagem. As rejeições permanecem visíveis nas métricas.

Uma resposta SQL é reutilizada pelo bridge em mais de um ciclo do engine (até 1 s, com novas consultas limitadas a cada 250 ms): na referência foram 53 seleções ATTACK e 124 ofertas. Parte das ofertas repetidas encontra cooldown. Não foi alterada essa semântica nesta correção.

## H64 geração 1: comportamento e fitness observado

Nas 1.425 decisões reais da H64, todas escolheram FLEE. As ativações médias das saídas foram: FLEE 0,984908; IDLE 0,610831; ATTACK 0,498838; CHASE 0,027930. A saída FLEE ficou dominante nas entradas reais observadas; o resultado é consistente com a configuração dos pesos/biases, não com perda de resposta do backend. Não houve dano ao jogador nem eliminação atribuível à H64. Os NPCs sofreram 167 de dano e tiveram cinco mortes ao todo nas duas partidas.

| Geração 1 | Partidas | Avaliações por genoma | Fitness médio | Melhor | Pior | Dano ao jogador | Eliminações | Dano recebido por NPC | Mortes NPC |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| H64 | 2 | 8 | -35,5188 | 0,8750 | -57,2500 | 0 | 0 | 167 | 5 |
| Referência 4→6→4 | 2 | 8 | -18,6167 | 83,0833 | -98,0000 | 216 | 2 | 282 | 10 |

As duas repetições da referência reproduziram as mesmas decisões e resultados de combate. Isso documenta o comportamento observado nesses genomas e condições; não prova que uma arquitetura aprendeu mais que outra. Nenhuma nova geração foi evoluída ou testada depois desta correção. Os fitness legados não foram usados para esta conclusão.

## Escopo de validação e limitações

- A partida automatizada exercitou IDLE, ATTACK, FLEE, ORIGINAL_AI fallback, múltiplos NPCs, eventos de dano/morte e ACK após reinício do backend.
- CHASE não foi selecionada pelos dois genótipos testados nesta comparação. Seu comportamento não foi validado em partida aqui.
- Estas foram partidas automatizadas, não uma sessão humana. O teste manual de jogabilidade ainda é necessário.
- O contador atual registra aplicado/rejeitado, mas não a razão específica por rejeição. Não se forçou o engine a aceitar ataques fora de cooldown ou alcance.
- Não foi afirmada melhora de aprendizado: os genomas avaliados eram geração 1 já existente e a comparação não foi uma evolução controlada.
- Os logs de navegador registraram um erro de recurso HTTP 404 sem identificar o URL; o engine iniciou, decisões foram processadas e ACKs/avaliações persistiram. Não foi atribuído a um endpoint específico.

## Partida suplementar longa — 31/10/2026

Depois de reiniciar o backend, foi feita uma partida automatizada adicional de 120 segundos no Edge headless, Freedoom 2 E1M1, skill 2, com a mesma sequência de controles e a arquitetura de referência `auto_20261025_ref46`. A sessão `7000cbcd-aa6a-4dab-bc71-5ceebedaec92` enviou o ACK `closed=true`; o schema de jogo persistiu a marca v2 e quatro avaliações. Essa sessão aumenta a observação de combate, mas não constitui repetição controlada para comparar fitness entre arquiteturas.

O SQL selecionou 914 `ATTACK` e 981 `IDLE` em 1.895 decisões. O ACK final registrou 11.106 oportunidades, 10.968 ofertas ao engine, 5.552 aplicadas, 5.416 rejeitadas e 138 fallbacks por `waiting_for_mysql`; não houve resposta SQL inválida nem fallback por backend offline. As 5.416 rejeições foram ofertas repetidas de `ATTACK`, enquanto `IDLE` teve 5.482 ofertas aplicadas. Uma mesma decisão selecionada é reapresentada em vários ticks do engine; portanto ofertas rejeitadas não equivalem a decisões SQL distintas. O registro agregado não identifica se cada rejeição de ATTACK veio de cooldown ou dos gates de alcance/linha de ataque.

O RTT completo observado entre o WebSocket do jogo e a resposta foi 397,2 ms em média e 546,6 ms no P95 sob a carga desta partida. Esse valor é mais alto que nas partidas curtas anteriores e deve ser tratado como uma observação de carga, não como latência estável. O ACK não registrou pedidos sem resposta; houve 138 oportunidades encaminhadas ao ORIGINAL_AI enquanto aguardavam o resultado do MySQL.

O engine reportou 70 ATTACK aceitos. A telemetria persistida registrou 25 eventos `PLAYER_DAMAGE` (271 de dano efetivo) e dois `PLAYER_KILL`. O NPC 24, atribuído ao genoma 25, recebeu sete seleções SQL de ATTACK, causou 74 de dano e uma eliminação, e não teve evento de morte nessa sessão. O NPC 504, também do genoma 25, causou 94 de dano e uma eliminação. A avaliação v2 do genoma 25 totalizou 188 de dano, duas eliminações e fitness 134,5500; genoma 26 teve 83 de dano e fitness -81,6333; genomas 27 e 28 não causaram dano e tiveram fitness -76,3667 e -174,3833. São resultados de uma única partida automatizada, insuficientes para demonstrar melhora ou aprendizado.

### Projétil com impacto depois da morte do atirador

A auditoria do código confirma o snapshot de `neural_instance_id` no projétil criado durante um ataque neural aceito. A morte do ator encerra `neural_attack_active`, sem limpar o ID já salvo no projétil; `P_DamageMobj` usa esse ID estável para atribuir dano/eliminações, sem depender do ponteiro de origem. Em todo o histórico v2 consultado, inclusive nesta partida suplementar, nenhum NPC teve um evento `PLAYER_DAMAGE` posterior ao seu próprio `NPC_DEATH`. Assim, o comportamento pós-morte está coberto pela inspeção do código e pela compilação integrada existente, mas ainda não foi exercitado por uma colisão real observada em partida. Os impactos em vida e as eliminações atribuídos a ataques neurais foram observados em jogo; não se afirma que o caso específico de projétil tardio tenha sido reproduzido.

No patch atual não existe mais um campo `neural_controlled`. `P_SpawnMobj` zera os campos transitórios e cria um ID novo. A primeira resposta SQL válida marca `neural_evaluation_member`, que identifica a entidade avaliada e permanece durante fallback/ORIGINAL_AI; morte por dano recebido continua sendo um resultado de sobrevivência desse membro, mesmo que a origem não seja neural. Já `neural_attack_active` é transitório: inicia zerado, só é ligado após ATTACK passar os gates do engine e é limpo ao voltar a `A_Chase`, morrer, ressuscitar ou carregar save. Assim o fallback não recebe crédito positivo de dano/eliminação, enquanto `NPC_DAMAGE`/`NPC_DEATH` seguem medindo o resultado de sobrevivência da entidade atribuída ao genoma. Esses eventos de sobrevivência não alegam identificar quem causou cada dano ou morte.

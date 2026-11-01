# Neural Doom Lab

Freedoom 2 no navegador com NPCs que recebem decisões calculadas por uma MLP no MySQL. O FastAPI faz a ponte WebSocket; não escolhe ações nem executa treinamento. O modo `Local mock` existe somente para desenvolvimento. Os pesos iniciais são aleatórios e só há avaliação de desempenho depois de uma partida com eventos reais.

## Estrutura

- `frontend/`: interface, cliente WebSocket e Chocolate Doom/WebAssembly.
- `backend/`: serviço FastAPI e conexão com MySQL.
- `database/core/`: schema base, procedures, fixtures SQL e seed opcional das sete topologias; o instalador lê somente esses arquivos do próprio projeto.
- `engine/`: patch do bridge C e script para recompilar o engine.
- `licenses/`: licenças e avisos de terceiros.
- `LICENSE`: licença do projeto.

## Requisitos

Para executar no Windows: MySQL Server 8.0.46, Python 3.10+, Node.js/npm. A configuração testada foi Windows 11, MySQL 8.0.46, Python 3.14.2 e Node.js 24.19.0. MySQL Workbench é opcional para administração.

O clone inclui os arquivos de execução do Chocolate Doom/WASM e Freedoom 2 em `.data`; o computador que só joga não precisa de EMScripten, CMake, Ninja, compilador C nem WAD separado. Esses itens são necessários apenas para reconstruir o engine; consulte [`engine/README.md`](engine/README.md).

## Instalação reproduzível no Windows

Instale MySQL Server 8.0.46, Python e Node.js. Crie um login-path local para uma conta administrativa; `mysql_config_editor` solicita a senha de forma interativa:

```powershell
$mysqlBin = "$env:ProgramFiles\MySQL\MySQL Server 8.0\bin"
& "$mysqlBin\mysql_config_editor.exe" set `
  --login-path=neural-doom-installer-20261024 `
  --host=127.0.0.1 --port=3306 --user=root --password
```

Na raiz do clone, rode:

```powershell
cd neural-doom-lab
.\scripts\setup.ps1 -Mode Windows
```

O script instala schemas exclusivos, migrations, população demo, fixtures SQL no schema de testes e dependências, e inicia MySQL bridge/FastAPI/frontend. Gera a configuração privada em `backend/.env`, ignorada pelo Git. Se os schemas `neural_doom_local_game_20261024` ou `neural_doom_local_sql_test_20261024` já existirem sem o ledger desta instalação, o setup para sem adotá-los nem apagá-los.

```powershell
.\scripts\doctor.ps1 -Mode Windows
.\scripts\test.ps1 -Mode Windows
.\scripts\test.ps1 -Mode Windows -IncludeHeadlessMatch
.\scripts\stop.ps1 -Mode Windows
```

Para Docker Compose, quando o daemon estiver ativo, use `setup.ps1`, `doctor.ps1`, `test.ps1` e `stop.ps1` com `-Mode Docker`. Os dados ficam no volume persistente `mysql_data`; não use `down -v` para parar os serviços.

O procedimento detalhado para MySQL Workbench, instalação segura, uso pela rede local e transferência por Git bundle está em [`docs/portabilidade-windows.md`](docs/portabilidade-windows.md).

Em um clone limpo, as migrations 17 e 18 do laboratório entram no plano SQL automaticamente. Em schemas locais antigos e sem o ledger portátil, não use `setup.ps1` para adotá-los: a validação geral para por segurança. Para atualizar somente as procedures aditivas do laboratório nesses dois schemas já conferidos, use o login-path do instalador:

```powershell
cd neural-doom-lab
.\scripts\Install-Neural-Lab-API.ps1 -InstallerLoginPath neural-doom-installer-20261024
```

O script verifica previamente MySQL 8.0.46, ambos os nomes de schema, as tabelas e procedures-base. Ele altera somente procedures do laboratório (incluindo a seleção explícita de genoma) em `neural_doom_local_game_20261024` e `neural_doom_local_sql_test_20261024`; não adota o ledger, recria schema, concede privilégios nem muda dados existentes. A migration 18 não altera arquiteturas, genomas, sessões ou avaliações. A conta da aplicação continua usando apenas `EXECUTE`.

O inventário das sete topologias testadas, a diferença entre a instalação padrão e o seed histórico opcional, os resultados reais e as consultas de camadas/pesos/genomas no Workbench estão em [`docs/arquiteturas-e-experimentos.md`](docs/arquiteturas-e-experimentos.md).

## Jogar contra os NPCs

1. Confirme que o MySQL está ativo, que a população foi criada e que o backend iniciou sem erro.
2. Na página, selecione **Modo de operação: `EXTERNAL_AI`** e **Fonte de decisão: `MySQL neural (via backend)`**. `Local mock` não consulta o banco.
3. Clique em **Play** e, no menu do Freedoom, inicie a partida. O indicador de conexão deve mostrar `Connected`.
4. Controles conferidos no bundle web: ↑/↓ avançam e recuam, ←/→ giram, Ctrl atira, Espaço usa/abre e Shift corre. WASD e mouse look não são anunciados como controles validados. Fullscreen e o botão Pointer são recursos da interface separados do movimento testado.
5. Se o backend ou o MySQL estiver indisponível, a decisão externa é rejeitada e o NPC permanece na IA original. A resposta precisa chegar dentro do limite de 1,5 s; decisões ausentes/atrasadas usam fallback.
6. Ao terminar, selecione `ORIGINAL_AI` para encerrar e avaliar a sessão. O fechamento automático ao sair da página é uma tentativa adicional; trocar para `ORIGINAL_AI` com WebSocket conectado é o caminho confiável para aguardar o envio.
7. O painel **NPC atual → Resumo da sessão** distingue saídas SQL selecionadas, ações entregues ao engine, aplicadas, rejeitadas e oportunidades em que ocorreu fallback. O backend recebe snapshots cumulativos e devolve a contagem no ACK de encerramento; o resumo também é escrito no terminal do backend. `ATTACK` selecionada não significa ataque executado: somente o contador **aplicadas** confirma que o engine aceitou a ação; dano real continua sendo confirmado pelos eventos de combate SQL.

## Laboratório neural interativo

Abra **Laboratório neural interativo** abaixo da área do jogo para consultar dados do MySQL. O painel inicia recolhido e não faz consultas enquanto fechado. A configuração sugerida é `EXTERNAL_AI` + `MySQL neural (via backend)`, com `auto_20261025_h32` (4→32→4, geração 1) como candidata experimental e `auto_20261025_ref46` (4→6→4, geração 1) como alternativa menor, somente se o catálogo SQL indicar que continuam utilizáveis. A partida automatizada de referência foi Freedoom 2 MAP01, skill 2. Esses nomes são verificados pelo catálogo, e os dados disponíveis não comprovam superioridade ou aprendizado.

Selecione qualquer arquitetura utilizável no catálogo para a próxima sessão; depois que uma decisão sai, arquitetura e genoma ficam travados até o encerramento. A interface salva a escolha no navegador e a envia ao FastAPI. Arquiteturas sem uma geração/população que a procedure aceite não são listadas como selecionáveis.

O painel lista arquiteturas, camadas, número de neurônios, gerações e genomas. Por padrão, o SQL distribui o roster utilizável. Para testar um genoma específico, escolha uma geração e um genoma e clique em **Usar genoma selecionado na próxima partida**. O backend chama uma procedure SQL que valida arquitetura, geração/população e associação do NPC; o mesmo NPC não pode trocar de genoma no meio da sessão. O botão **Usar genoma da última inferência** apenas troca a inspeção para o genoma que o SQL atribuiu ao NPC.

Ao receber uma decisão com `run_id`, a interface consulta `nn_decision_activation`, que já armazena as ativações calculadas pelo MySQL. As quatro entradas e as quatro saídas aparecem pelos nomes `HEALTH_RATIO`, `PLAYER_DISTANCE_RATIO`, `PLAYER_VISIBLE`, `HEALTH_DELTA`, `IDLE`, `CHASE`, `ATTACK` e `FLEE`; camadas maiores são paginadas, sem transferir toda a rede em cada tick. A área de pesos exibe as conexões de entrada paginadas e o bias do neurônio escolhido, consultados no genoma selecionado. Ações SQL escolhidas, ACK do engine (aplicada/rejeitada/fallback) e três tempos são separados: tempo do `CALL` de inferência medido pelo backend, round trip navegador↔backend e tempo desde a consulta até o retorno de aplicação do engine. As barras são apenas uma escala visual da página; os números exibidos são os valores persistidos.

Para começar do zero: (1) escolha um nome ainda não usado; (2) informe as camadas com 4 entradas e 4 saídas fixas, por exemplo `4, 8, 4`; (3) confira pesos, biases e parâmetros e crie; (4) selecione essa topologia vazia em **Arquitetura vazia para receber a população**, informe quantidade e semente e inicialize; (5) escolha a arquitetura, geração e genoma no catálogo utilizável; (6) opcionalmente fixe o genoma para a próxima sessão e inicie o jogo com EXTERNAL_AI/MySQL. A seleção é confirmada pelas decisões SQL e pelo ACK, e a sessão encerrada grava a avaliação v2. Uma população recém-criada começa na geração 0 e não é treinamento concluído. Nomes repetidos, população duplicada e associação incompatível são recusados; não há substituição de registros históricos. A interface calcula pesos, biases e parâmetros, preserva as quatro entradas/saídas e limita larguras a 512 e parâmetros a 120.000. Operações administrativas exigem origem local autorizada e não expõem credenciais no browser.

Para verificar a tela em Edge headless, com um contexto isolado, backend/MySQL locais e screenshot fora do repositório:

```powershell
cd neural-doom-lab/frontend
npm run test:neural-lab-ui
```

O relatório e `neural-lab-panel.png` ficam em `%TEMP%\neural-doom-lab-ui-check`. O teste confirma que o painel fechado não consulta o banco, carrega o catálogo real e pesos/biases de um genoma existente, valida a contagem de parâmetros e não causa overflow em 390 px. Ele não é uma partida. Para executar também uma partida curta com rede recém-criada, use `npm run test:match -- --create-new-network`; o script cria nome único, topologia 4→8→4, dois genomas com semente registrada, fixa um genoma e grava JSON/capturas em `%TEMP%\neural-doom-results`. O resultado observado desta rodada está em [`docs/validacao-interface-modos-2026-11-01.md`](docs/validacao-interface-modos-2026-11-01.md).

Para verificar os modos sem desktop, use Edge/Playwright headless:

```powershell
npm run test:neural-lab-modes
```

O smoke separado verifica ORIGINAL_AI sem inferências/sessão neural e EXTERNAL_AI com Local mock sem WebSocket neural nem chamadas ao laboratório MySQL. Local mock é uma política JavaScript de desenvolvimento, não uma inferência SQL.

Para comparar a cadência de renderização do navegador com Freedoom 2 MAP01 ativo e o painel recolhido/aberto, sem usar EXTERNAL_AI nem gravar sessão/fitness:

```powershell
npm run test:neural-lab-fps
```

O relatório e as capturas ficam em `%TEMP%\neural-doom-lab-fps-check`. A métrica é a cadência de `requestAnimationFrame` do browser durante o jogo; não é um contador interno de FPS do Chocolate Doom. A partida usa ORIGINAL_AI e controles de Playwright, não constitui validação da rede neural.

## Conferir a partida no Workbench

Selecione `neural_doom_local_game_20261024` como schema padrão. Esta consulta mostra as sessões H64 mais recentes sem combinar tabelas de decisões e NPCs numa junção multiplicativa:

```sql
SELECT a.nome, s.session_id, s.criada_em, s.encerrada_em,
       (SELECT COUNT(*) FROM nn_decision_run r WHERE r.session_id = s.session_id) AS decisoes_sql,
       (SELECT COUNT(*) FROM nn_session_npc n WHERE n.session_id = s.session_id) AS npcs
FROM nn_engine_session s
JOIN nn_architecture a ON a.id = s.architecture_id
WHERE a.nome = 'auto_20261025_h64'
ORDER BY s.criada_em DESC
LIMIT 5;
```

Copie um `session_id` para consultar as ações escolhidas e a geração/genoma realmente atribuídos. As ações aplicadas/rejeitadas são confirmadas pelo resumo do engine no frontend e no ACK, não pela tabela de decisões SQL:

```sql
SELECT action, COUNT(*) AS decisoes
FROM nn_decision_run
WHERE session_id = 'COLE-O-UUID-DA-SESSAO'
GROUP BY action;

SELECT n.engine_npc_id, g.id AS genome_id, g.geracao, g.fitness,
       (SELECT COUNT(*) FROM nn_decision_run r
        WHERE r.session_id = n.session_id AND r.engine_npc_id = n.engine_npc_id) AS decisoes
FROM nn_session_npc n
JOIN nn_genome g ON g.id = n.genome_id
WHERE n.session_id = 'COLE-O-UUID-DA-SESSAO'
ORDER BY n.engine_npc_id;
```

O jogo não garante que todos os genomas da população apareçam em cada mapa. A sessão atribui genomas em ordem por NPC; `nn_generation_summary.completa` indica se a geração inteira tem avaliações. Uma rede aleatória pode agir mal e não deve ser apresentada como já treinada.

## Experimentos com redes maiores

A MLP original `npc_teste_4_6_4` permanece intacta. Para preparar, de forma opcional, populações isoladas e seeds fixas para as sete topologias testadas sem usar o Workbench, execute na raiz do clone:

```powershell
Get-Content -Raw neural-doom-lab/database/core/11_prepare_autonomous_architecture_experiments.sql |
  & 'C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe' `
    --login-path=neural-doom-installer-20261024 `
    --database=neural_doom_local_game_20261024 --batch --raw
```

O instalador limpo não executa esse seed. Ele cria as quatro experiências v2 padrão mais a população demo. O script opcional cria sete aliases legados (`auto_20261025_*`) com população inicial de 4, seed fixa, mutação de 5%, duas gerações planejadas e duas avaliações reais por genoma. Valida topologia e configuração de nomes existentes e aborta diante de conflito; não recria populações idênticas nem altera os aliases v2. A criação das redes 128 e 256 pode demorar devido ao número de pesos. O arquivo deve ser executado exclusivamente no schema de jogo indicado; ele não cria ou apaga bancos. Veja [`docs/arquiteturas-e-experimentos.md`](docs/arquiteturas-e-experimentos.md) para a situação real de cada arquitetura, resultados, limites e consultas Workbench.

Com `mysql.exe`, o `login-path` local e as dependências de `frontend` instaladas, o benchmark reproduzível pode ser iniciado sem Workbench:

```powershell
cd neural-doom-lab/frontend
npm run test:experiments -- --prepare-only # instala/verifica apenas a preparação; não abre partidas
npm run test:experiments                 # partidas automatizadas no Edge headless
```

O runner inicializa Vite se necessário, inicia um FastAPI temporário por arquitetura na porta 8001, e só o encerra se foi criado por ele. O backend principal na porta 8000 não é substituído. Cada partida dura 75 s no Freedoom 2 MAP01/skill 2, usa controles fixos automatizados e salva JSON/captura fora do repositório em `%TEMP%\neural-doom-automated-experiments`. O script confere arquitetura, ACK, fechamento SQL, igualdade entre decisões do ACK e linhas persistidas, ações aceitas pelo engine e eventos de combate; não evolui genomas após falha de integridade, cobertura incompleta ou P95 WebSocket acima de 800 ms. O seed do Freedoom não é controlável no bundle atual, então os resultados são comparáveis apenas de forma exploratória e não comprovam melhora. Não use `--prepare-only` como teste de jogabilidade.

Os resultados reais obtidos em 25/10/2026, incluindo limitações de amostra e a distinção entre partida automatizada e humana, estão em [`docs/experimentos-2026-10-25.md`](docs/experimentos-2026-10-25.md).

Configure `NN_ARCHITECTURE_NAME` com o nome do experimento no backend de avaliação. As sessões ficam associadas automaticamente ao experimento. A evolução `sp_nn_evolve_training_experiment` recusa avançar enquanto faltar qualquer avaliação prevista. `database/modelagem.md` documenta a preparação, as consultas e as condições de comparação.

## Evolução genética v2

O fluxo v2 usa apenas sessões reais registradas e avaliações cuja confirmação de ACK foi persistida no MySQL. A migration 15 seleciona e cruza genomas sem alterar o fitness legado; a migration 16 distribui rosters curtos entre os genomas menos avaliados. As migrations 14–16 e as fixtures SQL continuam isoladas dos experimentos reais.

Para preparar e executar as quatro topologias prioritárias no Windows sem abrir janelas de navegador:

```powershell
cd C:\Users\victo\Rede-Neural-work\neural-doom-lab\frontend
node scripts/run-genetic-experiments-v2.mjs --prepare-only
node scripts/run-genetic-experiments-v2.mjs
```

O runner usa Edge headless, MySQL local e FastAPI temporário na porta 8001; a configuração privada do FastAPI permanece em `backend/.env`. Cada geração exige duas avaliações ACK-confirmadas por genoma. `--prepare-only` não inicia partidas. Os JSONs e screenshots ficam em `%TEMP%\neural-doom-genetic-experiments-v2`.

Os resultados medidos, as ações aplicadas/rejeitadas, latência e limites de interpretação estão em [`docs/experimentos-geneticos-v2-2026-10-31.md`](docs/experimentos-geneticos-v2-2026-10-31.md). A comparação é exploratória: o seed aleatório do Freedoom não pode ser fixado pelo bundle, e nenhuma partida humana foi validada nesta etapa.

O engine envia quatro observações reais. Arquiteturas `12→…` e `16→…` não são habilitadas até que novas entradas sejam instrumentadas e validadas no DOOM. O limite atual é 512 neurônios por camada e 120000 pesos+biases. Mais parâmetros aumentam o custo MySQL e não significam comportamento melhor. Testes de topologia, sementes e evolução usam fixtures e não são evidência de treinamento real.

## Consultar inferência e combate

Execute no Workbench, depois de selecionar o schema local isolado (exemplo: `neural_doom_local_game_20261024`):

```sql
SELECT r.id AS run_id, r.criado_em, s.session_id, s.engine_npc_id,
       s.genome_id, r.health, r.max_health, r.player_distance,
       r.player_visible, r.health_ratio, r.player_distance_ratio,
       r.health_delta, r.action, r.confidence
FROM nn_decision_run r
JOIN nn_session_npc s
  ON s.session_id = r.session_id AND s.engine_npc_id = r.engine_npc_id
ORDER BY r.id DESC LIMIT 50;

SELECT r.session_id, r.engine_npc_id, r.action, COUNT(*) AS decisoes_sql,
       MIN(r.confidence) AS confianca_minima, MAX(r.confidence) AS confianca_maxima
FROM nn_decision_run r
GROUP BY r.session_id, r.engine_npc_id, r.action
ORDER BY MAX(r.id) DESC LIMIT 100;

SELECT e.session_id, e.genome_id, e.damage_to_player, e.player_kills,
       e.damage_received, e.npc_deaths, e.survival_seconds, e.fitness
FROM nn_genome_evaluation e
ORDER BY e.avaliado_em DESC, e.genome_id;

SELECT a.geracao, a.tamanho_populacao, a.individuos_avaliados,
       a.fitness_medio, a.melhor_fitness, a.pior_fitness, a.completa
FROM nn_generation_summary a
JOIN nn_architecture n ON n.id = a.architecture_id
WHERE n.nome = 'npc_teste_4_6_4'
ORDER BY a.geracao;
```

As ativações de uma decisão ficam em `nn_decision_activation` (ligadas por `run_id`). Os eventos `PLAYER_DAMAGE`, `PLAYER_KILL`, `NPC_DAMAGE` e `NPC_DEATH` são telemetria de combate real do engine para NPCs neural-controlados; eles comprovam efeitos reais, mas não são uma associação causal a uma decisão `ATTACK` específica. O painel/ACK do backend distingue seleção SQL, entrega, aplicação, rejeição e fallback. A fórmula atual é `dano ao jogador + 100 × abates - 0,25 × dano recebido - 50 × mortes do NPC + segundos de sobrevivência / 60`.

## Evoluir uma geração

Depois de partidas reais suficientes para avaliar cada genoma da geração, confira `nn_generation_summary.completa = 1`. Então, por exemplo, evolua a geração 0 preservando a elite de 4 indivíduos e usando taxa de mutação de 5%:

```sql
CALL sp_nn_evolve_generation('npc_teste_4_6_4', 0, 4, 0.05);
```

A procedure recusa gerações com indivíduos sem avaliação real e não substitui uma geração que já existe. Os pesos/biases filhos usam crossover e mutação limitados a `[-1, 1]`. O engine seleciona a geração de maior número; avalie os descendentes em jogo antes de afirmar que a nova geração melhorou. Compare fitness médio/melhor/pior e tamanho/indivíduos avaliados no resumo. Um único resultado ou uma diferença de pesos não prova evolução.

## Testes e builds

Backend:

```powershell
cd neural-doom-lab
python -m unittest discover -s backend -p "test_*.py" -v
```

Frontend:

```powershell
cd neural-doom-lab/frontend
npm run build
```

O build web gera `frontend/dist/` localmente; não o versione. Para recompilar o bridge C/WASM, consulte [`engine/README.md`](engine/README.md). Um build bem-sucedido não substitui validação de partida real.

## Arquitetura e limites conhecidos

`HEALTH_RATIO`, `PLAYER_DISTANCE_RATIO`, `PLAYER_VISIBLE` e `HEALTH_DELTA` são as quatro entradas. O índice interno do estado do DOOM é guardado para diagnóstico, não tratado como medida contínua. O MySQL executa forward propagation e escolhe a maior saída entre `IDLE`, `CHASE`, `ATTACK` e `FLEE`; o FastAPI apenas valida, chama procedures e devolve a ação. Para os detalhes do schema e das procedures, veja [`../database/modelagem.md`](../database/modelagem.md).

Os genomas começam aleatórios; não existe backpropagation nem aprendizado supervisionado. A evolução usa fitness de eventos reais no SQL. A infraestrutura de experimentos está pronta, mas ainda são necessárias partidas humanas repetidas e comparáveis antes de afirmar melhora entre arquiteturas ou gerações. Movimento, combate, modo multi-NPC e fallback também devem ser confirmados manualmente no ambiente de apresentação.

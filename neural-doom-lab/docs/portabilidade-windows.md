# Instalação portátil do Neural Doom Lab

Este guia descreve uma instalação nova no Windows, o uso opcional do Docker, administração pelo MySQL Workbench e transferência do histórico Git. Os scripts são conservadores: nunca apagam schemas ou volumes, recusam adotar schemas sem a marca desta instalação e registram cada etapa SQL com checksum.

## Requisitos verificados

O teste desta revisão foi executado em Windows 11 Pro (build 26300), MySQL Community Server 8.0.46 x64, Python 3.14.2, Node.js 24.19.0/npm 11.17.0 e Microsoft Edge 156.0.4314.50. O instalador atualmente valida a linha MySQL 8.0.46; outras versões não foram aceitas nesta validação.

Para a instalação Windows sem Docker:

- MySQL Server 8.0.46 em execução, normalmente na porta `3306`.
- Uma conta instaladora capaz de criar os dois schemas nomeados abaixo, suas tabelas, rotinas e triggers, criar uma conta de aplicação local e conceder `EXECUTE` somente no schema do jogo.
- Python 3.10 ou mais novo, Node.js/npm e conexão com os registries de dependências.
- Microsoft Edge instalado apenas para a partida headless de validação; o jogo normal roda no navegador.

Workbench é opcional e serve para inspecionar dados. EMScripten, compilador C, CMake, Ninja e Freedoom WAD são necessários apenas para reconstruir o engine; os arquivos `.js`, `.wasm` e `.data` de execução já estão no clone. O `.data` contém o bundle licenciado Freedoom 2; nenhum IWAD proprietário é necessário.

A instalação foi validada em Windows local contra uma instância MySQL 8.0.46 temporária e isolada em `127.0.0.1:13317`; os serviços MySQL já existentes e os schemas do Workbench não foram usados nem alterados. O runtime Docker não foi iniciado nesta máquina porque o daemon não estava disponível; somente a sintaxe do Compose foi conferida. Notebook e rede da faculdade ainda precisam de teste físico.

## Instalação nova no Windows, sem Docker

1. Instale MySQL Server 8.0.46 e confirme que está ativo em `127.0.0.1:3306`. O Workbench pode permanecer configurado como está.
2. Crie um login-path local da conta administrativa. Este comando solicita a senha sem colocá-la no histórico ou na linha de comando:

```powershell
$mysqlBin = "$env:ProgramFiles\MySQL\MySQL Server 8.0\bin"
& "$mysqlBin\mysql_config_editor.exe" set `
  --login-path=neural-doom-installer-20261024 `
  --host=127.0.0.1 --port=3306 --user=root --password
```

Use uma conta instaladora própria em vez de `root` se ela tiver os privilégios necessários. Não copie o login-path nem senhas para o repositório. Se o nome do login-path for diferente, passe `-InstallerLoginPath <nome>` aos scripts.
3. Clone/abra o repositório e rode:

```powershell
cd Rede-Neural-work\neural-doom-lab
.\scripts\setup.ps1 -Mode Windows
```

O setup verifica MySQL e as credenciais, cria somente `neural_doom_local_game_20261024` e `neural_doom_local_sql_test_20261024`, aplica os scripts SQL em ordem, instala a população demo e as quatro experiências v2, executa as fixtures SQL apenas no schema de testes, gera `backend/.env` com credencial aleatória de aplicação, prepara `.venv` e `frontend/node_modules` e inicia FastAPI/Vite. A conta gerada recebe `EXECUTE` no schema de jogo; o processo instalador continua separado. A configuração privada fica ignorada pelo Git.

Se preferir instalar e preparar dependências sem iniciar serviços, use `-NoStart`; depois rode `scripts/start.ps1 -Mode Windows`. O servidor MySQL permanece ativo ao parar o jogo.

```powershell
.\scripts\doctor.ps1 -Mode Windows
.\scripts\test.ps1 -Mode Windows
.\scripts\test.ps1 -Mode Windows -IncludeHeadlessMatch
.\scripts\stop.ps1 -Mode Windows
```

`doctor.ps1` confirma FastAPI com `SELECT 1` no MySQL e o frontend HTTP. `test.ps1` executa backend, testes do frontend e build; `-IncludeHeadlessMatch` usa Edge headless, sem teclado/mouse físico, e grava JSON e screenshot em `%TEMP%\neural-doom-results`.

Se a política local do PowerShell bloquear scripts, invoque o setup numa sessão processual com bypass, sem alterar a política persistente:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\setup.ps1 -Mode Windows
```

O instalador recusa qualquer um dos dois nomes de schema se já existir sem o marcador de propriedade e ledger da instalação. Ele não tenta adotar nem esvaziar schemas pré-criados manualmente. Para evitar colisão com dados já existentes, use uma instância MySQL de testes isolada; não apague ou renomeie schemas para contornar a recusa.

Para uma segunda instalação num MySQL separado/porta diferente, inicie essa instância e use, por exemplo:

```powershell
.\scripts\setup.ps1 -Mode Windows -MySqlPort 3307 -InstallerLoginPath neural-doom-installer-20261024
```

Cada passo concluído fica no ledger com SHA-256. Reexecutar pula passos idênticos; divergência de checksum ou etapa interrompida falha de modo fechado, sem DROP/reinstalação automática. Fixtures não idempotentes só rodam uma vez no schema de testes vazio.

## Docker Compose opcional

Com Docker Desktop/Engine e daemon funcional:

```powershell
cd Rede-Neural-work\neural-doom-lab
.\scripts\setup.ps1 -Mode Docker
.\scripts\doctor.ps1 -Mode Docker
.\scripts\test.ps1 -Mode Docker
.\scripts\stop.ps1 -Mode Docker
```

O Compose fixa MySQL `8.0.46`, Python `3.14.2` e Node `24.19.0`, expõe as portas do jogo somente em loopback por padrão e mantém os dados no volume `mysql_data`. `stop.ps1` para os containers sem remover o volume. Não use `docker compose down -v` se quiser preservar partidas, genomas e avaliações. Docker não exige MySQL nem Python/Node instalados no host para o runtime; Node e Edge no host são necessários para a partida automatizada via Playwright.

## MySQL Workbench

Workbench é somente uma interface de leitura/administração; FastAPI e as procedures executam no MySQL Server. No modo Windows, conecte à instância local em `127.0.0.1:3306`; no Compose, use `127.0.0.1:13306`. Selecione `neural_doom_local_game_20261024` e consulte:

```sql
SELECT VERSION() AS mysql_version, @@port AS mysql_port;
SELECT COUNT(*) AS tabelas
FROM information_schema.tables
WHERE table_schema = 'neural_doom_local_game_20261024'
  AND table_type = 'BASE TABLE';
SELECT nome, n_entradas, n_saidas
FROM nn_architecture ORDER BY id;
SELECT experiment_name, population_size, planned_generations
FROM nn_training_experiment_v2 ORDER BY experiment_name;
```

Para decisões e avaliações persistidas de uma partida:

```sql
SELECT r.action, COUNT(*) AS decisoes_sql
FROM nn_decision_run r
WHERE r.session_id = 'UUID-DA-SESSAO'
GROUP BY r.action;

SELECT e.genome_id, e.damage_to_player, e.player_kills, e.damage_received,
       e.npc_deaths, e.survival_seconds, e.fitness
FROM nn_genome_evaluation_training_v2 e
WHERE e.session_id = 'UUID-DA-SESSAO'
ORDER BY e.genome_id;

SELECT fitness_version, evaluation_count, ack_confirmed_at
FROM nn_training_session_completion_v2
WHERE session_id = 'UUID-DA-SESSAO';
```

As tabelas `nn_genome_evaluation_training_v2` e `nn_training_session_completion_v2` distinguem avaliação v2 com proveniência e confirmação de ACK. Uma decisão SQL não prova que o engine aplicou a ação: verifique o resumo de métricas do ACK para as contagens `applied`, `rejected` e `fallback`.

## Jogar localmente e pela rede local

No notebook, abra `http://127.0.0.1:5173`, selecione `EXTERNAL_AI` e `MySQL neural`, clique em Play e inicie o mapa. Ao acabar, selecione `ORIGINAL_AI` para fechar a sessão, aguarde o ACK e confira a avaliação no Workbench. O backend usa a arquitetura demo `genetic_v2_ref46_20261031` por padrão.

Para apresentar a partir do notebook a outro computador numa rede privada confiável, inicie os serviços assim:

```powershell
.\scripts\setup.ps1 -Mode Windows -BindAddress 0.0.0.0
```

No outro dispositivo, abra `http://IP-DO-NOTEBOOK:5173`; o cliente monta o WebSocket com o host da página e chega à API na porta `8000`. Permita apenas essas portas na rede privada conforme a política local. Não exponha o MySQL `3306` nem o backend/jogo em rede pública: a interface não oferece autenticação de usuário. Se a rede da faculdade bloquear comunicação entre dispositivos, essa modalidade não funcionará.

## Build separado do engine

O jogo pode ser executado sem toolchain C. Para alterar/recompilar o bridge, siga [`../engine/README.md`](../engine/README.md), que fixa Emscripten, Chocolate Doom e as instruções para obter Freedoom 2. O checkout upstream fica em `engine/vendor/`, o patch fonte está versionado e nenhum arquivo do workspace original `doom-wasm` é usado ou alterado.

## Transferir commits sem push

Para levar histórico local completo ao notebook por arquivo:

```powershell
cd Rede-Neural-work
git bundle create Rede-Neural-work.bundle --all
git bundle verify .\Rede-Neural-work.bundle
```

Copie o bundle por um meio autorizado e, no outro computador:

```powershell
git clone .\Rede-Neural-work.bundle Rede-Neural-work
cd Rede-Neural-work
git switch codex/mysql-neural-doom
```

Se a equipe autorizar publicação remota, publique a branch existente separadamente pelo fluxo Git aprovado. Este guia não faz push nem merge. O `.env`, virtualenv, `node_modules`, `dist`, `.runtime`, logs, WADs e temporários não fazem parte do bundle Git.

## Resultados das partidas automatizadas

Uma instalação limpa foi clonada do commit `be0f4f6` da branch `codex/mysql-neural-doom`, sem `.env`, venv, `node_modules`, `dist` ou caches do workspace. O setup usou MySQL 8.0.46 privado e novo em `127.0.0.1:13318`; Python foi instalado com cache desativado e npm usou um diretório de cache vazio. Foram instaladas 16 etapas SQL no schema de jogo e 29 no de testes (15 fixtures), com 38 tabelas em cada, 21 rotinas no schema de jogo, cinco arquiteturas, 40 genomas e quatro experimentos genéticos v2. Uma segunda execução do instalador marcou todas as 45 etapas como já instaladas sem reaplicar fixtures. O usuário gerado do backend recebeu somente `EXECUTE` no schema de jogo.

O resultado final de partida desse clone, em Edge headless no E1M1/skill 2 e arquitetura `genetic_v2_ref46_20261031`, durou 31,3 s e gerou 149 decisões SQL válidas em três NPCs: 101 CHASE e 48 ATTACK. O ACK final registrou 318 ações aplicadas, 105 rejeitadas e três oportunidades em fallback. Das 123 ofertas ATTACK ao engine, 18 foram aplicadas e 105 rejeitadas. Quatro eventos `PLAYER_DAMAGE` produziram 16 de dano ao jogador na avaliação de um genoma. A latência WebSocket teve média de 27,2 ms e P95 de 41,3 ms. O ACK foi fechado, a avaliação de fitness v2 foi concluída e o recibo foi confirmado; três avaliações foram persistidas com `ack_confirmed_at` preenchido.

Antes do clone final, duas partidas de fumaça no mesmo MySQL privado também exercitaram outras saídas: uma teve 148 decisões (100 CHASE, 48 ATTACK), 315 ações aplicadas, 99 rejeitadas e quatro fallbacks; outra teve 179 decisões (143 CHASE, 36 FLEE), 464 ações aplicadas, 67 rejeitadas e quatro fallbacks. Em ambas o ACK e as três avaliações foram persistidos. Esses testes não controlam a semente do Freedoom nem demonstram melhora genética; `IDLE` não apareceu em nenhuma das partidas. Na instalação limpa passaram 21 testes backend, seis frontend, o build Vite e a partida headless. O build do WASM não foi repetido porque o código do engine não mudou nesta etapa; os artefatos versionados foram carregados pelo jogo. O Compose foi validado sintaticamente, mas o daemon não estava disponível para validar containers. Nenhuma partida humana foi feita; notebook e computadores da faculdade continuam pendentes de teste físico.

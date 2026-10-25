# Bridge neural para Chocolate Doom

O jogo usa o bundle em `frontend/public/engine/`. A implementação C do bridge está versionada como patch reproduzível em `neural-ai-bridge.patch`, aplicado sobre Chocolate Doom no commit fixo `3e0cd5dc0cd0d5b6788100a2fbc1cdd4ce014b35`. Não é necessário editar nem copiar arquivos do workspace original `doom-wasm`.

O patch integra o ponto de decisão em `A_Chase`, identifica atores com ID próprio, envia vida atual/máxima, distância, visibilidade e estado diagnóstico ao JavaScript, aplica `IDLE`, `CHASE`, `ATTACK` ou `FLEE` e só reporta combate depois que uma ação externa foi aplicada. Estados inválidos ou ausentes deixam a lógica original seguir. A variação de HP é calculada no MySQL entre observações reais consecutivas do mesmo `(session_id, engine_npc_id)`.

## Recompilar no Windows

Versões usadas no build verificado: Emscripten SDK 4.0.14, Chocolate Doom no commit acima, CMake 4.4.4 e Ninja 1.13.2. Instale Git, CMake e Ninja e deixe-os disponíveis no `PATH`. O [guia oficial do emsdk](https://emscripten.org/docs/tools_reference/emsdk.html) descreve instalação/ativação do SDK. No Windows, por exemplo:

```powershell
git clone https://github.com/emscripten-core/emsdk.git C:\emsdk
cd C:\emsdk
.\emsdk.bat install 4.0.14
.\emsdk.bat activate 4.0.14
$env:EMSDK = (Resolve-Path .).Path
```

Obtenha `freedoom2.wad` apenas do [site oficial do Freedoom](https://freedoom.github.io/download.html). Não use um IWAD proprietário. O arquivo não é versionado (`*.wad` é ignorado pelo Git). Para reproduzir o mesmo `chocolate-doom.data` incluído no bundle atual, use a mesma versão do Freedoom 2, cujo SHA-256 é `A8772E088847032510D97BA2312406A6998F21CBAB44D4FF10696FAA9C0ECD4B`. Outra versão licenciada também pode ser empacotada, mas produzirá um arquivo `.data` diferente.

Na raiz de `neural-doom-lab`, execute:

```powershell
powershell -ExecutionPolicy Bypass -File .\engine\build-wasm.ps1
```

O script verifica Emscripten 4.0.14, clona o commit exato de Chocolate Doom em `engine/vendor/`, aplica o patch somente se ainda não estiver aplicado, compila `chocolate-doom` e copia `.js`, `.wasm` e `.data` para o frontend. Também aceita uma cópia local do checkout upstream para testes:

```powershell
powershell -ExecutionPolicy Bypass -File .\engine\build-wasm.ps1 `
  -ChocolateDoomSource C:\caminho\para\chocolate-doom `
  -FreedoomWad C:\caminho\para\freedoom2.wad
```

`engine/vendor/`, `engine/build/` e o WAD local são ignorados. O patch e as instruções necessários para reconstruir permanecem no repositório; os artefatos compilados não são a única cópia da integração. O frontend pode ser validado separadamente com `cd frontend; npm run build`.

## Identidade, sessão e eventos

- `npc_id` é um contador monotônico da engine durante a partida, não um endereço. Os eventos usam o mesmo ID enviado na decisão.
- O frontend cria UUID novo por partida; o MySQL relaciona genoma e NPC pelo par sessão/ID do engine.
- `max_health` permite calcular `HEALTH_RATIO`; o HP anterior persistido permite calcular `HEALTH_DELTA`. Na primeira decisão de cada NPC na sessão, delta é zero. Dano recebido entre decisões aparece agregado na próxima observação. Após morte não há novas decisões; `NPC_DEATH` é enviado uma vez. Nova partida cria sessão e IDs novos, sem herdar HP anterior.
- O estado de `actor->state` é enviado somente para diagnóstico. Não é entrada contínua da rede.
- O backend do browser só aceita uma resposta correspondente ao NPC/request pendente. O bridge marca o NPC como controlado apenas quando a ação é aplicada; respostas atrasadas/inválidas preservam a IA original.
- `p_inter.c` registra dano real ao jogador, eliminações do jogador, dano real recebido por NPC neural e morte de NPC neural. Eventos de NPC só seguem para o backend quando esse ator já recebeu uma ação externa aplicada.

O build comprova que o bridge compila e que os arquivos são gerados. Só uma partida real pode validar perseguição, ataque, evasão, mortes, comportamento multi-NPC, latência e fallback integral.

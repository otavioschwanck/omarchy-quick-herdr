import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Widget de barra: quantos agentes do Herdr estao rodando, parados numa
// pergunta e ociosos -- de quantas maquinas voce ligar -- e uma lista para ler
// a conversa de cada um, ir ate ele ou responder sem sair da barra.
//
// Todo o trafego passa por bin/herdr-bar, que devolve uma linha de JSON. O
// helper existe porque um clique aqui vira varias chamadas encadeadas -- foco
// no Herdr, descoberta da janela do compositor, dispatch do Hyprland -- e
// encadear Process em QML e como se escreve callback hell.
Panel {
  id: root

  moduleName: "otavio.quick-herdr"
  // Alvo de IPC para quem preferir uma tecla a um clique:
  //   omarchy-shell otavio.quick-herdr toggle
  ipcTarget: "otavio.quick-herdr"

  readonly property string helper: String(Qt.resolvedUrl("bin/herdr-bar")).replace(/^file:\/\//, "")

  // ------------------------------------------------------------- settings
  // Propriedades simples atualizadas de uma vez, e nao um binding por chave:
  // uma cadeia de bindings derivados que sujam todos na mesma mudanca reentra
  // em si mesma, e o Qt reporta isso como binding loop.
  property string session: "default"
  property var machines: []
  property bool useLocal: true
  property string label: ""
  property int refreshSeconds: 4
  property int prSeconds: 180
  property int maxRows: 20
  property bool hideWhenEmpty: false

  function applySettings() {
    session = String(setting("session", "default") || "default");
    label = String(setting("label", "") || "").trim();

    // "remote" era o formato antigo, de uma maquina so por widget. Continua
    // valendo como uma entrada da lista: quem ja tinha o widget configurado
    // nao pode ver a barra esvaziar por causa de uma troca de formato.
    var lista = Model.maquinasDe(setting("machines", ""));
    var antigo = String(setting("remote", "") || "").trim();
    if (antigo !== "" && !Model.temMaquina(lista, antigo)) lista = [antigo].concat(lista);
    machines = lista;
    useLocal = setting("local", lista.length === 0) !== false;

    // Por SSH cada atualizacao e uma ida e volta pela rede; o piso maior evita
    // que o padrao local vire uma enxurrada de conexoes na outra ponta.
    var minimo = lista.length > 0 ? 5 : 2;
    refreshSeconds = Math.max(minimo, Number(setting("interval", lista.length > 0 ? 8 : 4)) || minimo);
    prSeconds = Math.max(30, Number(setting("prInterval", 180)) || 180);
    maxRows = Math.max(1, Number(setting("maxRows", 20)) || 20);
    hideWhenEmpty = setting("hideWhenEmpty", false) === true;
    refresh();
  }

  onSettingsChanged: applySettings()
  Component.onCompleted: applySettings()

  // O bar dimensiona o slot pelo implicitWidth do item que carrega. Sem
  // repassar o do botao, o widget existe, roda e nao ocupa espaco nenhum.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Convencao dos paineis nativos: as cores de realce saem do tema.
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property color urgentColor: bar ? bar.urgent : Color.urgent
  readonly property color dimColor: Qt.darker(barForeground, 1.5)
  readonly property color fadeColor: Qt.darker(barForeground, 1.8)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ---------------------------------------------------------------- estado
  property var counts: ({})
  property var rows: []
  // Recuo progressivo com a lista fechada. O tick custa ~60ms de CPU, dos quais
  // 5ms sao o dado -- o resto e partida de interpretador, paga de novo a cada
  // atualizacao. Numa sessao parada isso e puro desperdicio, entao cada ciclo
  // sem novidade dobra a espera ate o teto; qualquer mudanca nas contagens, ou
  // abrir a lista, volta ao piso na hora.
  property int quietTicks: 0
  readonly property int maxQuietTicks: 3
  property string lastCounts: ""

  readonly property int effectiveInterval:
    opened ? refreshSeconds * 1000
           : Math.min(refreshSeconds * 1000 * Math.pow(2, quietTicks), 60000)

  // Linhas abertas, por (maquina, pane). Uma linha aberta mostra as ultimas
  // falas em vez de so a ultima; quem esta parado numa pergunta ja nasce
  // aberto, porque a pergunta e o motivo de voce ter aberto a lista.
  property var expandidas: ({})

  function chaveDe(linha) {
    return (linha.machine || "") + "\u0000" + linha.pane_id;
  }

  function estaExpandida(linha) {
    var chave = chaveDe(linha);
    if (chave in expandidas) return expandidas[chave] === true;
    // Quem parou numa pergunta ja nasce aberto: a pergunta e o motivo de voce
    // ter aberto a lista. Um clique no chevron ainda fecha, porque a chave
    // passa a existir com "false".
    return !!(linha.options && linha.options.length);
  }

  function alternarExpansao(linha) {
    // Reatribuir o objeto inteiro, e nao mexer numa chave: o QML so reavalia
    // os bindings quando a propriedade em si muda.
    var novo = {};
    for (var k in expandidas) novo[k] = expandidas[k];
    novo[chaveDe(linha)] = !estaExpandida(linha);
    expandidas = novo;
  }

  property string defaultPane: ""
  property string defaultMachine: ""
  // Uma entrada por maquina consultada, com o erro dela quando falhou: com
  // varias ligadas, "deu erro" sem dizer qual nao ajuda ninguem.
  property var machineStates: []
  property string ghState: ""
  property string helperError: ""

  // Pagina de configuracao, aberta com o botao direito na barra. Mora no mesmo
  // popup porque e a mesma pergunta ("qual Herdr e este?") vista de outro lado.
  property bool settingsOpen: false
  property var hosts: []

  // Alternativa escolhida que abriu um campo em vez de responder sozinha, e o
  // agente dela. Enquanto isso estiver preenchido, o campo do painel escreve
  // ali dentro, e nao um prompt novo.
  property var pendingOption: null
  property string pendingPane: ""
  property string pendingMachine: ""

  function cancelPending() {
    pendingOption = null;
    pendingPane = "";
    pendingMachine = "";
  }

  // O comando que a dica de erro sugere, pronto para a área de transferência.
  // Vale para o erro persistente e para o recado passageiro: os dois vêm do
  // mesmo helper e trazem a saída entre crases pelo mesmo motivo.
  readonly property string errorCommand: Model.comandoDe(
    helperError !== "" ? helperError : (statusIsError ? status : "")
  )
  property bool copied: false

  function copyCommand(comando) {
    if (!comando || !bar) return;
    // printf e não echo: o comando pode ter barra invertida, e echo a
    // interpretaria antes de o texto chegar na área de transferência.
    bar.run("printf %s " + bar.shellQuote(comando) + " | wl-copy");
    copied = true;
    copiedTimer.restart();
  }

  Timer {
    id: copiedTimer
    interval: 2500
    onTriggered: root.copied = false
  }

  // Mensagem passageira embaixo do campo ("enviado para bot", "bloqueado").
  property string status: ""
  property bool statusIsError: false

  function note(texto, erro) {
    status = texto;
    statusIsError = erro === true;
    statusTimer.restart();
  }

  Timer {
    id: statusTimer
    interval: 4000
    onTriggered: root.status = ""
  }

  Timer {
    id: claimList
    interval: 160
    onTriggered: if (root.opened) keyCatcher.forceActiveFocus()
  }

  // Comandos que valem para o widget inteiro: a lista agregada, o alvo do
  // campo, a configuracao. Nao levam maquina.
  function argv(args) {
    var base = [root.helper];
    if (root.session !== "default") base = base.concat(["--session", root.session]);
    return base.concat(args);
  }

  // Comandos que agem sobre um agente, e por isso precisam saber de que
  // maquina ele e. Cada linha da lista carrega a sua.
  function argvPara(maquina, args) {
    var base = argv([]);
    if (maquina) base = base.concat(["--remote", maquina]);
    return base.concat(args);
  }

  // As mensagens custam uma leitura de terminal por agente, e so aparecem na
  // lista: com o popup fechado a barra quer as contagens e mais nada.
  function refresh() {
    if (snapshotProc.running) return;

    var args = ["all"];
    if (root.opened) args.push("--messages");
    if (root.useLocal) args.push("--local");
    for (var i = 0; i < root.machines.length; i++) args.push("--remote", root.machines[i]);

    snapshotProc.command = argv(args);
    snapshotProc.running = true;
  }

  // Os PRs tem ritmo proprio: o snapshot le so o cache, e quem vai ao GitHub e
  // este comando. Rodar os dois no mesmo timer poria uma chamada de rede por
  // repositorio a cada poucos segundos, para um numero que quase nunca muda.
  function refreshPrs() {
    if (!prsProc.running) {
      prsProc.command = argv(["prs"]);
      prsProc.running = true;
    }
  }

  function apply(payload) {
    var dados;
    try {
      dados = JSON.parse(payload);
    } catch (e) {
      helperError = "resposta ilegível do helper";
      return;
    }

    helperError = dados.ok === false ? String(dados.error || "erro no helper") : "";
    counts = dados.counts || ({});
    ghState = String(dados.gh || "");
    defaultPane = String(dados.default || "");
    defaultMachine = String(dados.default_machine || "");
    machineStates = dados.machines || [];

    var lista = dados.rows || [];
    rows = lista.slice(0, maxRows);

    // A digital sao as contagens, e nao as linhas: com a lista fechada e so
    // isso que a barra desenha, e um titulo de terminal que muda sozinho nao
    // e motivo para voltar a atualizar de quatro em quatro segundos.
    var digital = JSON.stringify(counts);
    if (digital === lastCounts) quietTicks = Math.min(quietTicks + 1, maxQuietTicks);
    else { quietTicks = 0; lastCounts = digital; }
  }

  // -------------------------------------------------------------- acoes
  // Cada acao tem seu Process: um Process so roda um comando por vez, e mandar
  // texto enquanto o snapshot esta no ar e o caso normal, nao o excepcional.

  function goTo(linha) {
    if (!linha) return;
    focusProc.command = argvPara(linha.machine, ["focus", linha.pane_id]);
    focusProc.running = true;
    close();
  }

  function setDefault(linha) {
    if (!linha) return;
    // Clicar na estrela do alvo atual desmarca: e o unico gesto que sobra para
    // voltar a nao ter padrao, e o campo precisa desse estado para dizer que
    // nao tem para onde mandar.
    //
    // "." e a maquina local: um argumento vazio no argv seria indistinguivel
    // de argumento nenhum.
    var atual = linha.pane_id === root.defaultPane && linha.machine === root.defaultMachine;
    defaultProc.command = argv(
      atual ? ["pick", "-"] : ["pick", linha.machine || ".", linha.pane_id, linha.cwd || ""]
    );
    defaultProc.running = true;

    // Marcar o alvo e escrever para ele sao o mesmo gesto partido em dois, e o
    // segundo era um clique perdido. Desmarcar nao foca nada: o campo acabou de
    // ficar sem destino.
    if (!atual) field.forceActiveFocus();
  }

  function send(texto) {
    var alvo = root.defaultPane;
    if (!alvo) {
      note("escolha um padrão na lista (★)", true);
      return;
    }
    if (!texto || !texto.trim()) return;

    sendProc.payload = texto.trim();
    sendProc.command = argvPara(root.defaultMachine, ["send", alvo]);
    sendProc.running = true;
  }

  // Responder um dialogo aperta a alternativa e mantem o painel aberto: o
  // agente vai mudar de estado em seguida, e ver isso acontecer e metade da
  // razao de responder daqui em vez de ir ate a aba.
  function answer(linha, opcao) {
    if (!linha || !opcao) return;
    answerProc.command = argvPara(linha.machine, ["answer", linha.pane_id, String(opcao.index), String(opcao.label)]);
    answerProc.running = true;
  }

  // Uma alternativa como "No, and tell Claude what to do differently" ou "Chat
  // about this" nao responde nada sozinha: ela abre um campo e fica esperando.
  // Apertar a tecla e parar ali deixaria o agente travado num input vazio,
  // entao o painel pede o texto antes de encostar no dialogo.
  function pickOption(linha, opcao) {
    if (!linha || !opcao) return;
    if (opcao.prompts === true) {
      pendingOption = opcao;
      pendingPane = linha.pane_id;
      pendingMachine = linha.machine || "";
      field.text = "";
      field.forceActiveFocus();
      return;
    }
    answer(linha, opcao);
  }

  function sendPending(texto) {
    if (!pendingOption || !texto || !texto.trim()) return;
    answerTextProc.payload = texto.trim();
    answerTextProc.command = argvPara(pendingMachine, [
      "answer", pendingPane, String(pendingOption.index), String(pendingOption.label), "--with-text"
    ]);
    answerTextProc.running = true;
    cancelPending();
  }

  // ------------------------------------------------------------ configuracao
  function loadHosts() {
    if (!hostsProc.running) {
      hostsProc.command = argv(["hosts"]);
      hostsProc.running = true;
    }
  }

  function setConfig(chave, valor) {
    configProc.command = argv(["config", "set", String(chave), String(valor)]);
    configProc.running = true;
  }

  // Para o que nao e texto -- o booleano de "esta maquina".
  function setConfigJson(chave, bruto) {
    configJsonProc.command = argv(["config", "set", String(chave), String(bruto), "--json"]);
    configJsonProc.running = true;
  }

  // Ligar e desligar uma maquina na lista. Desligar fecha o tunel na hora, em
  // vez de deixar o ControlPersist segurando por mais alguns minutos:
  // "desliguei" tem de significar "desconectou", nao "vai desconectar quando
  // der".
  function toggleMachine(alvo) {
    var lista = root.machines.slice();
    var onde = lista.indexOf(alvo);

    if (onde >= 0) {
      lista.splice(onde, 1);
      disconnectProc.command = argv(["disconnect", alvo]);
      disconnectProc.running = true;
    } else {
      lista.push(alvo);
    }

    // O array vai como string separada por espaco porque a IPC do shell le um
    // argumento "[...]" como lista de argumentos -- array de verdade nao
    // atravessa ela. Nome de host nao tem espaco, entao nao ha ambiguidade.
    machines = lista;
    setConfig("machines", Model.juntarMaquinas(lista));
    // A chave antiga guardava uma maquina so; deixa-la para tras faria ela
    // reaparecer na lista a cada leitura de configuracao.
    setConfig("remote", "");
    refresh();
  }

  function toggleLocal() {
    useLocal = !useLocal;
    setConfigJson("local", useLocal ? "true" : "false");
    refresh();
  }

  function openPr(url) {
    if (!url) return;
    if (bar) bar.run("omarchy-launch-webapp " + bar.shellQuote(url));
    close();
  }

  // ------------------------------------------------------------- processos
  Process {
    id: snapshotProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.apply(text)
    }
    onExited: function (code) {
      if (code !== 0 && code !== null) root.helperError = "helper saiu com " + code;
    }
  }

  Process {
    id: prsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.refresh()
    }
  }

  Process {
    id: hostsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var dados = root.parse(text);
        if (!dados) return;
        if (dados.ok === false) root.note(String(dados.error), true);
        root.hosts = dados.hosts || [];
      }
    }
  }

  Process {
    id: disconnectProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.refresh()
    }
  }

  Process {
    id: configJsonProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var dados = root.parse(text);
        if (dados && dados.ok === false) root.note(String(dados.error), true);
      }
    }
  }

  Process {
    id: configProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var dados = root.parse(text);
        if (dados && dados.ok === false) root.note(String(dados.error), true);
      }
    }
  }

  // O texto vai pelo stdin pelo mesmo motivo do envio normal: argv aparece no
  // `ps` de qualquer processo da maquina.
  Process {
    id: answerTextProc

    property string payload: ""

    stdinEnabled: true
    onStarted: {
      write(payload + "\n");
      payload = "";
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var dados = root.parse(text);
        if (!dados) return;
        if (dados.ok === false) root.note(String(dados.error), true);
        else root.note("escrevi em “" + String(dados.answered) + "”", false);
        root.refresh();
      }
    }
  }

  Process {
    id: answerProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var dados = root.parse(text);
        if (!dados) return;
        if (dados.ok === false) root.note(String(dados.error), true);
        else root.note("respondi “" + String(dados.answered) + "”", false);
        root.refresh();
      }
    }
  }

  Process {
    id: focusProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var dados = root.parse(text);
        if (dados && dados.ok === false) root.note(String(dados.error), true);
      }
    }
  }

  Process {
    id: defaultProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var dados = root.parse(text);
        if (dados && dados.ok === false) root.note(String(dados.error), true);
        root.refresh();
      }
    }
  }

  // O prompt vai pelo stdin e nunca pelo argv: argv aparece no `ps` de qualquer
  // processo da maquina, e prompt de agente costuma carregar caminho, nome de
  // cliente e trecho de codigo.
  Process {
    id: sendProc

    property string payload: ""

    stdinEnabled: true
    onStarted: {
      write(payload + "\n");
      payload = "";
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var dados = root.parse(text);
        if (!dados) return;
        if (dados.ok === false) root.note(String(dados.error), true);
        else root.note("enviado para " + Model.nomeDe(Model.acharPane(root.rows, String(dados.pane_id || ""))), false);
        root.refresh();
      }
    }
  }

  function parse(texto) {
    try {
      return JSON.parse(texto);
    } catch (e) {
      return null;
    }
  }

  // ---------------------------------------------------------------- timers
  Timer {
    interval: root.effectiveInterval
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: root.prSeconds * 1000
    // Rede so enquanto a lista esta a vista: fechado, o numero do PR nao
    // aparece em lugar nenhum e a chamada seria puro desperdicio.
    running: root.opened
    repeat: true
    onTriggered: root.refreshPrs()
  }

  onOpenedChanged: {
    if (opened) {
      quietTicks = 0;
      refresh();
      if (settingsOpen) loadHosts();
      else refreshPrs();
      cursor = rows.length ? 0 : -1;
      field.text = "";
      cancelPending();
      // O painel prima o proprio foco quando mapeia, e um QQC TextField visivel
      // o toma nesse instante. Reivindicar a lista depois disso e o que faz o
      // popup abrir navegavel: escrever e um gesto a mais ("i"), nao o padrao.
      claimList.restart();
    } else {
      status = "";
      field.text = "";
      settingsOpen = false;
      cancelPending();
    }
  }

  // ------------------------------------------------------------------ bar
  WidgetButton {
    id: button

    bar: root.bar
    text: Model.barText(root.counts, root.label, button.vertical)
    // Bloqueado e o unico estado que pede voce agora. O botao inteiro vira
    // urgente porque a barra e vista de relance, e nao lida numero a numero.
    active: (root.counts.blocked || 0) > 0
    concealed: root.hideWhenEmpty && (root.counts.total || 0) === 0
    tooltipText: root.helperError !== ""
                 ? root.helperError
                 : Model.titulo(root.label, root.machines, root.useLocal) + " — " + Model.tooltip(root.counts)

    onPressed: function (mouseButton) {
      if (mouseButton === Qt.MiddleButton) {
        root.refresh();
        return;
      }
      // Botao direito abre a mesma gaveta na pagina de configuracao. Configurar
      // um widget e coisa que se procura nele, e nao num arquivo cujo caminho
      // voce tem de lembrar.
      if (mouseButton === Qt.RightButton) {
        root.settingsOpen = true;
        if (!root.opened) root.open();
        else root.loadHosts();
        return;
      }
      root.settingsOpen = false;
      root.toggle();
    }
  }

  // ---------------------------------------------------------------- popup
  property int cursor: -1

  function moveCursor(delta) {
    if (!rows.length) {
      cursor = -1;
      return;
    }
    var proximo = cursor + delta;
    if (proximo < 0) proximo = rows.length - 1;
    if (proximo >= rows.length) proximo = 0;
    cursor = proximo;
  }

  onRowsChanged: if (cursor >= rows.length) cursor = rows.length - 1

  // Com a lista rolando, navegar de seta podia levar o cursor para fora da
  // vista: a linha ficava selecionada num pedaco do painel que ninguem estava
  // vendo. Rola o minimo para trazer a linha inteira de volta, e nao a
  // centraliza -- centralizar mexeria na lista mesmo quando a linha ja esta
  // visivel, e uma lista que se move sozinha e dificil de acompanhar.
  function revelarCursor() {
    if (!rolagem.interactive || cursor < 0) return;

    var item = listaLinhas.itemAt(cursor);
    if (!item) return;

    var topo = item.mapToItem(column, 0, 0).y;
    var base = topo + item.height;

    if (topo < rolagem.contentY) rolagem.contentY = Math.max(0, topo);
    else if (base > rolagem.contentY + rolagem.height) rolagem.contentY = base - rolagem.height;
  }

  onCursorChanged: revelarCursor()

  readonly property var defaultRow: Model.acharLinha(rows, defaultMachine, defaultPane)
  readonly property var cursorRow: cursor >= 0 && cursor < rows.length ? rows[cursor] : null

  KeyboardPanel {
    id: panel

    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    // Bem mais largo que os paineis de status: aqui cada linha carrega uma frase
    // inteira de conversa, e a pergunta de um dialogo vai inteira. Largura
    // comprada aqui e altura economizada -- e altura e o que falta num popup
    // pendurado na barra.
    contentWidth: panel.fittedContentWidth(Style.space(780))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher

      anchors.fill: parent

      // Com o campo em foco o dispatcher tem de sair da frente por inteiro:
      // "i" e "j" sao texto para o campo e comando para a lista.
      blocked: field.activeFocus

      // Esc na configuracao volta para a lista antes de fechar: sair da gaveta
      // inteira porque voce errou a pagina custa reabrir e reachar o widget.
      onCloseRequested: {
        if (root.settingsOpen) root.settingsOpen = false;
        else root.close();
      }
      onMoveRequested: function (dx, dy) {
        if (dy !== 0) root.moveCursor(dy);
      }
      onActivateRequested: {
        if (root.cursor >= 0 && root.cursor < root.rows.length)
          root.goTo(root.rows[root.cursor]);
      }
      onTextKey: function (t) {
        if (t === "i") { field.forceActiveFocus(); return; }
        if (t === "r") { root.refresh(); root.refreshPrs(); return; }

        var linha = root.cursorRow;
        if (!linha) return;

        if (t === "*") { root.setDefault(linha); return; }

        // 1..9 responde o dialogo da linha sob o cursor. Vale a posicao na
        // lista, e nao a tecla do agente: nos dialogos sem numero nao ha tecla
        // nenhuma, e a lista e o que voce esta vendo.
        var n = "123456789".indexOf(t);
        if (n >= 0 && Model.temOpcoes(linha) && n < linha.options.length)
          root.pickOption(linha, linha.options[n]);
      }

      // Uma linha aberta cresce, e quatro falas de uma conversa longa passam
      // da altura da tela. O painel para de crescer e passa a rolar: cortar
      // seria perder justamente o fim da conversa, que e a parte nova.
      Flickable {
        id: rolagem

        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      Column {
        id: column

        width: rolagem.width
        spacing: Style.space(6)

        // ---------- cabecalho ----------
        Item {
          width: parent.width
          implicitHeight: header.implicitHeight

          PanelSectionHeader {
            id: header
            anchors.left: parent.left
            text: root.settingsOpen
                  ? "‹  " + Model.titulo(root.label, root.machines, root.useLocal) + " · configuração"
                  : Model.titulo(root.label, root.machines, root.useLocal)
            foreground: root.barForeground
            fontFamily: root.fontFamily

            // O proprio titulo e o caminho de volta: com uma pagina so para
            // sair, um botao dedicado seria mais cromo que ajuda.
            MouseArea {
              anchors.fill: parent
              enabled: root.settingsOpen
              cursorShape: Qt.PointingHandCursor
              onClicked: root.settingsOpen = false
            }
          }

          Text {
            anchors.right: parent.right
            anchors.baseline: header.baseline
            visible: !root.settingsOpen
            text: Model.tooltip(root.counts)
            color: (root.counts.blocked || 0) > 0 ? root.urgentColor : root.dimColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }

        // ---------- campo de envio ----------
        // Fica em cima da lista porque e o gesto mais barato do painel: manda
        // uma linha e nao tira voce de onde voce esta.
        TextField {
          id: field

          width: parent.width
          visible: !root.settingsOpen
          enabled: root.pendingOption !== null || root.defaultPane !== ""
          placeholderText: root.pendingOption
                           ? Model.placeholderOpcao(root.pendingOption)
                           : Model.placeholder(root.defaultRow, root.rows.length > 0)
          foreground: root.barForeground
          // A borda acesa é o que separa "escrevendo dentro de um diálogo" de
          // "mandando um prompt novo": são destinos diferentes no mesmo campo.
          accent: root.pendingOption ? root.urgentColor : root.barForeground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall

          onAccepted: {
            if (root.pendingOption) root.sendPending(text);
            else root.send(text);
            text = "";
          }

          Keys.onEscapePressed: function (event) {
            text = "";
            root.cancelPending();
            keyCatcher.forceActiveFocus();
            event.accepted = true;
          }
        }

        Text {
          width: parent.width
          visible: root.status !== ""
          text: root.status
          color: root.statusIsError ? root.urgentColor : root.dimColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
          elide: Text.ElideRight
        }

        // ---------- configuração ----------
        // Quais Herdr este widget está olhando. Cada máquina é um interruptor:
        // ligada, os agentes dela entram na mesma lista; desligada, o túnel
        // fecha na hora. O resto das chaves fica no shell.json, que é onde
        // ficariam de qualquer jeito -- esta é a que ninguém adivinha.
        Column {
          visible: root.settingsOpen
          width: parent.width
          spacing: Style.space(4)

          PanelSectionHeader {
            text: "Máquinas"
            foreground: root.barForeground
            fontFamily: root.fontFamily
          }

          component MachineRow: Rectangle {
            id: machine

            property string target: ""
            property string title: ""
            property string note: ""
            property bool dim: false

            readonly property bool ligada: machine.target === ""
                                           ? root.useLocal
                                           : Model.temMaquina(root.machines, machine.target)
            readonly property string falha: Model.erroDaMaquina(root.machineStates, machine.target)

            width: parent ? parent.width : 0
            implicitHeight: aviso.visible
                            ? Style.space(26) + aviso.implicitHeight
                            : Style.space(26)
            radius: Style.space(6)
            color: machineMouse.containsMouse ? root.hoverFill : "transparent"

            MouseArea {
              id: machineMouse

              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                if (machine.target === "") root.toggleLocal();
                else root.toggleMachine(machine.target);
              }
            }

            Row {
              id: cabeca

              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              height: Style.space(26)
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              spacing: Style.space(8)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(14)
                text: machine.ligada ? "☑" : "☐"
                color: root.barForeground
                opacity: machine.ligada ? 1 : 0.45
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - Style.space(22) - Style.space(70)
                text: machine.title
                color: root.barForeground
                opacity: machine.dim && !machine.ligada ? 0.55 : 1
                elide: Text.ElideRight
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: machine.note
                color: root.fadeColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            // O erro fica na linha da máquina que o causou. Numa lista de
            // quatro, "deu erro" no rodapé não diz qual nem por quê.
            Text {
              id: aviso

              visible: machine.ligada && machine.falha !== ""
              anchors.top: cabeca.bottom
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: Style.space(32)
              anchors.rightMargin: Style.space(10)
              text: machine.falha
              color: root.urgentColor
              wrapMode: Text.WordWrap
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          // "esta máquina" é um interruptor como os outros, e não a ausência
          // de escolha: dá para olhar só as remotas, ou só a local, ou tudo.
          MachineRow {
            target: ""
            title: "esta máquina"
          }

          Repeater {
            model: root.hosts

            MachineRow {
              required property var modelData

              target: String(modelData.target || "")
              title: Model.rotuloHost(modelData)
              note: modelData.online ? "online" : "offline"
              // Offline não impede: a máquina pode acordar, e o widget diria
              // o que houve. Escondê-la é que seria mentira.
              dim: !modelData.online
            }
          }

          // As que estão ligadas mas não vieram da Tailscale (alvo digitado à
          // mão, apelido do ~/.ssh/config). Sem esta lista elas ficariam
          // ligadas e invisíveis, sem gesto para desligar.
          Repeater {
            model: Model.maquinasSoltas(root.machines, root.hosts)

            MachineRow {
              required property var modelData

              target: String(modelData)
              title: String(modelData)
              note: "manual"
            }
          }

          TextField {
            id: alvoManual

            width: parent.width
            placeholderText: "outro alvo SSH (user@host, apelido do ~/.ssh/config)…"
            foreground: root.barForeground
            accent: root.barForeground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall

            onAccepted: {
              var alvo = text.trim();
              if (alvo !== "" && !Model.temMaquina(root.machines, alvo)) root.toggleMachine(alvo);
              text = "";
            }

            Keys.onEscapePressed: function (event) {
              text = "";
              keyCatcher.forceActiveFocus();
              event.accepted = true;
            }
          }

          Text {
            width: parent.width
            topPadding: Style.space(4)
            text: "As demais chaves (intervalo, sessão, linhas) ficam na entrada deste widget em ~/.config/omarchy/shell.json."
            color: root.fadeColor
            wrapMode: Text.WordWrap
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // ---------- lista ----------
        Text {
          visible: !root.settingsOpen && root.rows.length === 0
          width: parent.width
          text: root.helperError !== "" ? root.helperError : "Nenhum agente na sessão do Herdr."
          color: root.helperError !== "" ? root.urgentColor : root.barForeground
          opacity: root.helperError !== "" ? 1 : 0.6
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          wrapMode: Text.WordWrap
        }

        // O conserto, pronto para colar. Um comando que você tem de redigitar
        // de um popup não é uma dica, é uma pista -- e uma linha de `ssh-copy-id`
        // com nome de máquina da Tailscale é justamente o tipo de coisa que se
        // digita errado duas vezes antes de acertar.
        Rectangle {
          visible: !root.settingsOpen && root.errorCommand !== ""
          width: parent.width
          implicitHeight: Style.space(26)
          radius: Style.space(6)
          color: copyMouse.containsMouse ? root.hoverFill : "transparent"
          border.width: 1
          border.color: root.fadeColor

          MouseArea {
            id: copyMouse

            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.copyCommand(root.errorCommand)
          }

          Row {
            anchors.fill: parent
            anchors.leftMargin: Style.space(10)
            anchors.rightMargin: Style.space(10)
            spacing: Style.space(8)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: root.copied ? "✓" : "⧉"
              color: root.copied ? root.barForeground : root.dimColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - Style.space(40)
              text: root.copied ? "copiado" : root.errorCommand
              color: copyMouse.containsMouse || root.copied ? root.barForeground : root.dimColor
              elide: Text.ElideRight
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }
        }

        Repeater {
          id: listaLinhas

          model: root.settingsOpen ? [] : root.rows

          Rectangle {
            id: row

            required property var modelData
            required property int index

            readonly property bool highlighted: mouse.containsMouse || root.cursor === index
            readonly property bool isDefault: modelData.pane_id === root.defaultPane
                                              && modelData.machine === root.defaultMachine
            readonly property string pr: Model.rotuloPr(modelData)
            readonly property bool expandida: root.estaExpandida(modelData)

            width: column.width
            implicitHeight: conteudo.implicitHeight + Style.space(10)
            radius: Style.space(6)
            color: row.highlighted ? root.hoverFill : "transparent"

            // Declarada antes do conteudo de proposito: em QML quem vem depois
            // fica por cima e recebe o clique primeiro, e o numero do PR e a
            // estrela precisam ganhar desta area que cobre a linha inteira.
            MouseArea {
              id: mouse

              anchors.fill: parent
              hoverEnabled: true
              acceptedButtons: Qt.LeftButton | Qt.RightButton
              cursorShape: Qt.PointingHandCursor
              onEntered: root.cursor = row.index
              onClicked: function (evento) {
                // Direito abre a conversa, esquerdo vai ate ela. Ler o que
                // aconteceu e decidir se vale ir sao dois gestos, e gastar o
                // clique de ir para descobrir isso e caro: ele fecha o painel.
                if (evento.button === Qt.RightButton) root.alternarExpansao(row.modelData);
                else root.goTo(row.modelData);
              }
            }

            Column {
              id: conteudo

              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              spacing: Style.space(2)

              // ----- identificacao -----
              Row {
                width: parent.width
                spacing: Style.space(8)

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(12)
                  text: Model.glifo(row.modelData.status)
                  color: row.modelData.status === "blocked" ? root.urgentColor : root.barForeground
                  opacity: row.modelData.status === "idle" || row.modelData.status === "unknown" ? 0.45 : 1
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                Text {
                  id: projeto

                  anchors.verticalCenter: parent.verticalCenter
                  width: Math.min(implicitWidth, Style.space(150))
                  text: row.modelData.project
                  color: root.barForeground
                  elide: Text.ElideRight
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                // O titulo do terminal e o que distingue duas abas do mesmo
                // projeto; cede a largura para o resto e some quando repetiria
                // o projeto. A largura desconta a estrela mesmo quando ela esta
                // escondida: reservar o espaco custa uma folga a direita e evita
                // que a linha se remonte cada vez que o cursor passa por ela.
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width
                         - Style.space(20)
                         - projeto.width
                         - (row.pr !== "" ? Style.space(50) : 0)
                         - Style.space(26)
                         - Style.space(20)
                  text: row.modelData.title
                  color: root.dimColor
                  elide: Text.ElideRight
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                // Abrir e fechar a conversa. Aparece sob o cursor e fica
                // enquanto a linha estiver aberta -- senao, uma linha aberta
                // com o mouse longe nao teria gesto visivel para fechar.
                Text {
                  visible: row.highlighted || row.expandida
                  anchors.verticalCenter: parent.verticalCenter
                  text: row.expandida ? "\uf077" : "\uf078"
                  color: root.barForeground
                  opacity: chevronMouse.containsMouse ? 0.9 : 0.4
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption

                  MouseArea {
                    id: chevronMouse

                    anchors.fill: parent
                    anchors.margins: -Style.space(4)
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.alternarExpansao(row.modelData)
                  }
                }

                Text {
                  visible: row.pr !== ""
                  anchors.verticalCenter: parent.verticalCenter
                  text: row.pr
                  color: prMouse.containsMouse ? root.barForeground : root.dimColor
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.underline: prMouse.containsMouse

                  MouseArea {
                    id: prMouse

                    anchors.fill: parent
                    anchors.margins: -Style.space(4)
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.openPr(row.modelData.pr_url)
                  }
                }

                // Alvo do campo de texto. Preenchida no alvo atual, vazia sob o
                // cursor: uma estrela em toda linha viraria ruido numa lista que
                // e feita para ser lida de relance.
                Text {
                  visible: row.isDefault || row.highlighted
                  anchors.verticalCenter: parent.verticalCenter
                  text: row.isDefault ? "★" : "☆"
                  color: root.barForeground
                  opacity: row.isDefault ? 0.9 : (starMouse.containsMouse ? 0.9 : 0.4)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body

                  MouseArea {
                    id: starMouse

                    anchors.fill: parent
                    anchors.margins: -Style.space(4)
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.setDefault(row.modelData)
                  }
                }
              }

              // ----- o que foi dito -----
              // Uma fala para cada agente e tres para o do campo: e nele que
              // voce vai responder, e para responder precisa da conversa, nao
              // da manchete. Alinhadas sob o nome do projeto, nao sob o glifo,
              // para a coluna de estado continuar sendo uma coluna.
              Repeater {
                model: Model.falasVisiveis(row.modelData, row.expandida)

                Row {
                  required property var modelData

                  width: conteudo.width
                  leftPadding: Style.space(20)
                  spacing: Style.space(6)

                  Text {
                    // Sem verticalCenter: ancorar ao centro de um Row cuja
                    // altura depende deste mesmo texto e circular, e o Qt
                    // resolve segurando a altura numa linha so -- que era
                    // exatamente por que o texto quebrado nao aparecia.
                    y: Style.space(1)
                    width: Style.space(9)
                    text: Model.voz(modelData.who)
                    color: root.fadeColor
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  // Elidida em repouso, inteira sob o cursor: a lista continua
                  // varrivel de relance, e ler a fala toda custa so apontar
                  // para ela. Cresce para baixo, entao a linha apontada nao
                  // foge do ponteiro -- as de baixo e que descem.
                  Text {
                    width: parent.width - Style.space(38)
                    text: modelData.text
                    color: root.dimColor
                    // Aberta ou sob o cursor, a fala vai inteira; fechada e em
                    // repouso, cabe numa linha. Cresce para baixo, entao a
                    // linha apontada nao foge do ponteiro.
                    elide: row.expandida || row.highlighted ? Text.ElideNone : Text.ElideRight
                    wrapMode: row.expandida || row.highlighted ? Text.WordWrap : Text.NoWrap
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }

              // ----- o que ele esta perguntando -----
              // So aparece em quem esta bloqueado, e so quando o dialogo tem
              // alternativas reconheciveis. Um agente que pergunta de outro
              // jeito nao ganha botao nenhum -- o campo de texto responde
              // qualquer coisa, e um botao adivinhado apertaria a errada.
              Column {
                // Pergunta sem alternativa reconhecivel ainda e pergunta: um
                // "[y/N]" nao rende botao, mas rende a frase que voce precisa
                // ler antes de ir ate a aba responder.
                visible: Model.temOpcoes(row.modelData)
                         || row.modelData.question !== ""
                         || (row.modelData.context || []).length > 0
                width: conteudo.width
                topPadding: visible ? Style.space(4) : 0
                spacing: Style.space(4)

                // O corpo do diálogo: o comando que ele quer rodar, o "Tip:"
                // que muda o que você escolheria, a descrição. "Do you want to
                // proceed?" sozinho não é uma pergunta — é a metade dela que
                // não informa nada.
                //
                // Um Text só, e não um por linha: as quebras já vêm no texto, e
                // é a fonte monoespaçada da barra que mantém o bloco de comando
                // alinhado como ele estava na tela.
                Text {
                  visible: (row.modelData.context || []).length > 0
                  x: Style.space(20)
                  width: conteudo.width - Style.space(20)
                  // RichText porque as cores vêm do terminal: o Claude Code já
                  // realçou o diff e o bloco de comando, e repintar aqui seria
                  // adivinhar de novo o que a outra ponta já sabe.
                  textFormat: Text.RichText
                  text: Model.htmlDoContexto(row.modelData.context)
                  color: root.fadeColor
                  wrapMode: Text.Wrap
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  visible: row.modelData.question !== ""
                  x: Style.space(20)
                  width: conteudo.width - Style.space(20)
                  text: row.modelData.question
                  color: root.barForeground
                  // Inteira, e nao elidida: e sobre esta frase que voce decide,
                  // e meia pergunta e pior que nenhuma -- a metade que sobra
                  // parece a pergunta toda e voce responde a outra coisa.
                  wrapMode: Text.WordWrap
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                // Uma alternativa por linha, largura cheia, texto que quebra
                // em vez de elidir. Em fila os rotulos curtos caberiam, mas o
                // "Yes, and always allow access to /home/..." -- justamente o
                // que carrega a decisao -- chegaria cortado no "/hom…", que e
                // um sim sem objeto. Altura gasta aqui e a altura da escolha.
                Column {
                  x: Style.space(20)
                  width: conteudo.width - Style.space(20)
                  spacing: Style.space(3)

                  Repeater {
                    model: row.modelData.options || []

                    Rectangle {
                      id: opcao

                      required property var modelData
                      required property int index

                      readonly property string badge: Model.badge(modelData)

                      width: parent.width
                      implicitHeight: rotulo.implicitHeight + Style.space(10)
                      radius: Style.space(5)
                      color: opcaoMouse.containsMouse ? root.hoverFill : "transparent"
                      border.width: 1
                      // A escolhida ja tem o cursor do proprio dialogo; a borda
                      // acesa repete isso aqui para o Enter que voce daria la
                      // ter um equivalente visivel aqui.
                      border.color: opcao.modelData.selected ? root.barForeground : root.fadeColor

                      MouseArea {
                        id: opcaoMouse

                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onEntered: root.cursor = row.index
                        onClicked: root.pickOption(row.modelData, opcao.modelData)
                      }

                      Text {
                        // Numerado ganha o cracha da tecla; lista com cursor
                        // nao ganha numero nenhum, porque ali nao ha tecla para
                        // digitar -- o widget anda com as setas por voce.
                        visible: opcao.badge !== ""
                        x: Style.space(10)
                        y: Style.space(5)
                        width: Style.space(14)
                        text: opcao.badge
                        color: root.barForeground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        font.bold: true
                      }

                      Text {
                        id: rotulo

                        x: Style.space(10) + (opcao.badge !== "" ? Style.space(20) : 0)
                        y: Style.space(5)
                        width: opcao.width - x - Style.space(10)
                        text: opcao.modelData.label
                        color: opcaoMouse.containsMouse ? root.barForeground : root.dimColor
                        wrapMode: Text.WordWrap
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                      }
                    }
                  }
                }
              }
            }
          }
        }

        // ---------- rodape ----------
        Text {
          width: parent.width
          visible: !root.settingsOpen && text !== ""
          text: Model.avisoGh(root.ghState)
          color: root.fadeColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          text: root.settingsOpen
                ? Model.ajudaConfig(root.hosts)
                : Model.ajuda(root.rows, root.defaultRow, field.activeFocus, root.cursorRow)
          color: root.fadeColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
          elide: Text.ElideRight
        }
      }
      }
    }
  }
}

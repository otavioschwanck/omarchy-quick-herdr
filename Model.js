// Rotulos, glifos e ordenacao do widget do Herdr. Fora do QML porque e tudo
// string e aritmetica de contagem: aqui da para testar com node.

// idle e done sao o mesmo estado por baixo -- done e o idle de um trabalho que
// terminou sem ninguem olhando. A barra conta os dois como ocioso; a lista os
// separa, porque "terminou enquanto voce estava longe" e a linha que voce quer
// abrir primeiro.
var GLIFOS = {
  working: "▶",
  blocked: "◼",
  done:    "✓",
  idle:    "○",
  unknown: "·"
};

var PALAVRAS = {
  working: "rodando",
  blocked: "bloqueado",
  done:    "terminou",
  idle:    "ocioso",
  unknown: "indefinido"
};

// Quem falou. O "" e o glifo de pessoa da Nerd Font, que a barra do Omarchy
// ja usa; o "✳" e a marca que o proprio Claude Code desenha no terminal, entao
// a lista fala a mesma lingua da aba para onde ela leva.
var VOZES = {
  agente: "✳",
  voce:   "\uf007"
};

function glifo(status) {
  return GLIFOS[status] || GLIFOS.unknown;
}

function palavra(status) {
  return PALAVRAS[status] || PALAVRAS.unknown;
}

function voz(quem) {
  return VOZES[quem] || VOZES.agente;
}

// Os tres numeros da barra, sempre os tres. Esconder um zero encolheria o
// widget e empurraria o resto da barra a cada agente que comeca ou para --
// largura estavel vale mais que dois caracteres.
//
// O glifo e o numero levam um espaco entre si, e os grupos levam dois: colados,
// "▶2◼1○3" vira uma mancha que voce tem de parar para decifrar, e a barra e
// feita para ser lida de relance.
function barText(counts, label, vertical) {
  var c = counts || {};
  var partes = [
    GLIFOS.working + " " + (c.working || 0),
    GLIFOS.blocked + " " + (c.blocked || 0),
    GLIFOS.idle + " " + (c.ocioso || 0)
  ];

  if (vertical) return (label ? label + "\n" : "") + partes.join("\n");
  return (label ? label + "  " : "") + partes.join("  ");
}

function tooltip(counts) {
  var c = counts || {};
  return (c.working || 0) + " rodando · " +
         (c.blocked || 0) + " bloqueado · " +
         (c.ocioso || 0) + " ocioso";
}

// Titulo do painel. Uma maquina so ganha nome; varias viram contagem, porque
// listar quatro hostnames no cabecalho custaria a largura da lista inteira.
function titulo(label, maquinas, comLocal) {
  if (label) return "Quick Herdr · " + label;

  var lista = maquinas || [];
  if (lista.length === 0) return "Quick Herdr";
  if (lista.length === 1 && !comLocal) return "Quick Herdr · " + String(lista[0]).split(".")[0];
  return "Quick Herdr · " + (lista.length + (comLocal ? 1 : 0)) + " máquinas";
}

// Nome curto de uma linha, para o placeholder do campo e para as mensagens.
function nomeDe(linha) {
  if (!linha) return "";
  return linha.project || linha.title || linha.pane_id || "";
}

function acharPane(rows, paneId) {
  var lista = rows || [];
  for (var i = 0; i < lista.length; i++) {
    if (lista[i].pane_id === paneId) return lista[i];
  }
  return null;
}

// Com varias maquinas na mesma lista, o pane_id sozinho deixou de identificar:
// "w2:p1" existe em todas elas.
function acharLinha(rows, maquina, paneId) {
  var lista = rows || [];
  for (var i = 0; i < lista.length; i++) {
    if (lista[i].pane_id === paneId && (lista[i].machine || "") === (maquina || "")) return lista[i];
  }
  return null;
}

// Placeholder do campo de texto. Ele e o unico lugar que diz para onde o texto
// vai, entao precisa dizer tambem quando nao vai para lugar nenhum -- e quando
// mandar custa recusar o que o agente esta pedindo.
function placeholder(padrao, temAgentes) {
  if (padrao && padrao.status === "blocked") return "responder a " + nomeDe(padrao) + " — recusa o pedido…";
  if (padrao) return "mandar para " + nomeDe(padrao) + "…";
  if (!temAgentes) return "nenhum agente no Herdr";
  return "escolha um padrão na lista (★)";
}

// O que aparece no cracha de uma alternativa. Vazio nas listas sem numero: ali
// nao ha tecla para digitar, o widget anda com as setas por voce, e um numero
// inventado so ensinaria um atalho que nao existe.
function badge(opcao) {
  return opcao && opcao.key ? opcao.key : "";
}

// A lista de maquinas ligadas. Vem como string separada por espaco, que e como
// o widget grava: a IPC do shell interpreta um argumento "[...]" como lista de
// argumentos, entao array de verdade nao atravessa ela. Nome de host nao tem
// espaco, entao a separacao e sem ambiguidade -- e quem editar o shell.json a
// mao pode escrever um array, que tambem e aceito aqui.
function maquinasDe(valor) {
  if (Array.isArray(valor)) return valor.map(String).filter(function (m) { return m !== ""; });
  return String(valor || "").split(/[\s,]+/).filter(function (m) { return m !== ""; });
}

function juntarMaquinas(lista) {
  return (lista || []).join(" ");
}

function temMaquina(lista, alvo) {
  return (lista || []).indexOf(alvo) >= 0;
}

// Etiqueta da maquina numa linha da lista. So aparece quando ha mais de uma
// ligada: com uma so, a coluna repetiria a mesma palavra em todas as linhas.
function badgeMaquina(maquina, varias) {
  if (!varias) return "";
  return maquina ? String(maquina).split(".")[0] : "aqui";
}

// O erro de uma maquina especifica, para aparecer na linha dela.
function erroDaMaquina(estados, alvo) {
  var lista = estados || [];
  for (var i = 0; i < lista.length; i++) {
    if ((lista[i].target || "") === (alvo || "")) return lista[i].ok === false ? String(lista[i].error || "") : "";
  }
  return "";
}

// Maquinas ligadas que nao vieram da Tailscale: alvo digitado a mao, apelido do
// ~/.ssh/config. Sem lista-las, ficariam ligadas e invisiveis -- sem gesto para
// desligar.
function maquinasSoltas(maquinas, hosts) {
  var conhecidas = (hosts || []).map(function (h) { return h.target; });
  return (maquinas || []).filter(function (m) { return conhecidas.indexOf(m) < 0; });
}

// As maquinas que falharam, para o rodape dizer qual e por que.
function falhasDe(maquinas) {
  var ruins = (maquinas || []).filter(function (m) { return m && m.ok === false; });
  return ruins.map(function (m) {
    return (m.target ? String(m.target).split(".")[0] : "aqui") + ": " + m.error;
  });
}

// As falas que a linha mostra: a ultima quando fechada, todas quando aberta.
// Elas ja vieram todas no mesmo pacote, entao expandir nao custa ida e volta.
function falasVisiveis(linha, expandida) {
  var falas = (linha && linha.messages) || [];
  return expandida ? falas : falas.slice(-1);
}

// ------------------------------------------------------------------- cores

function escaparHtml(texto) {
  return String(texto)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

// O HTML colapsa espaco: dois viram um, e os do comeco da linha somem. Isso
// come justamente a indentacao, que num bloco de codigo e o que o torna
// legivel. Entao toda corrida de dois ou mais vira espaco rigido, e a do
// comeco da linha tambem quando e de um so -- espaco isolado no meio continua
// espaco comum, senao a linha comprida perderia onde quebrar.
function preservarEspacos(texto, comecoDaLinha) {
  var escapado = escaparHtml(texto).replace(/ {2,}/g, function (corrida) {
    return Array(corrida.length + 1).join("&nbsp;");
  });
  return comecoDaLinha ? escapado.replace(/^ /, "&nbsp;") : escapado;
}

// As linhas do dialogo em HTML, com as cores que o terminal ja pintou. O
// Claude Code realca diff e bloco de comando; aproveitar isso e mais fiel (e
// muito mais barato) que reimplementar um highlighter aqui.
function htmlDoContexto(linhas) {
  var saida = [];

  for (var i = 0; i < (linhas || []).length; i++) {
    var trechos = linhas[i] || [];
    var partes = [];

    for (var j = 0; j < trechos.length; j++) {
      var trecho = trechos[j];
      // Nao so no primeiro trecho: quando a linha e realcada, a indentacao
      // cai dentro do trecho colorido, e era ali que ela sumia.
      var texto = preservarEspacos(trecho.t, j === 0);
      var estilo = [];

      if (trecho.f) estilo.push("color:" + trecho.f);
      if (trecho.g) estilo.push("background-color:" + trecho.g);
      if (trecho.b) estilo.push("font-weight:bold");

      partes.push(estilo.length ? '<span style="' + estilo.join(";") + '">' + texto + "</span>" : texto);
    }

    saida.push(partes.join(""));
  }

  return saida.join("<br>");
}

function temOpcoes(linha) {
  return !!(linha && linha.options && linha.options.length);
}

// O comando dentro das crases de uma dica de erro. As dicas do helper trazem o
// conserto entre crases justamente para o painel poder oferecer o texto para
// copiar: um comando que voce tem de redigitar de um popup nao e uma dica.
function comandoDe(texto) {
  var achado = /`([^`]+)`/.exec(String(texto || ""));
  return achado ? achado[1] : "";
}

// Placeholder quando o campo esta escrevendo dentro de uma alternativa, e nao
// mandando um prompt novo. Diz o rotulo porque sao destinos diferentes e a
// unica diferenca visivel entre eles e este texto.
function placeholderOpcao(opcao) {
  return "escrever em “" + String((opcao && opcao.label) || "").replace(/\s*\(esc\)\s*$/, "") + "”…";
}

function rotuloHost(host) {
  if (!host) return "";
  var nome = host.short || host.target || "";
  return host.name && host.name !== nome ? nome + "  " + host.name : nome;
}

function ajudaConfig(hosts) {
  if (!hosts || !hosts.length) return "sem máquinas na Tailscale · use o campo abaixo";
  return "clique para ligar e desligar · esc volta para a lista";
}

// Por que a coluna de PR esta vazia. Sem isso, "nenhum PR" e indistinguivel de
// "o gh nunca foi autenticado nesta maquina", e so um dos dois tem conserto.
function avisoGh(gh) {
  if (gh === "missing") return "gh não instalado — sem números de PR";
  if (gh === "unauthenticated") return "gh não autenticado — rode `gh auth login`";
  // Os repositorios estao na outra ponta: rodar git nos caminhos que o Herdr
  // remoto devolve daria numero errado ou nenhum.
  if (gh === "remote") return "sessão remota — sem números de PR";
  return "";
}

function rotuloPr(linha) {
  if (!linha || !linha.pr_number) return "";
  return "#" + linha.pr_number;
}

// O texto de ajuda muda com o que da para fazer agora: uma lista vazia nao tem
// o que navegar, e um campo sem alvo nao tem para onde mandar.
function ajuda(rows, padrao, escrevendo, sobCursor) {
  if (escrevendo) {
    if (padrao && padrao.status === "blocked") return "↵ recusa o pedido e manda isto · esc volta para a lista";
    return "↵ enviar · esc voltar para a lista";
  }
  if (!rows || !rows.length) return "nenhum agente · r atualizar";
  if (temOpcoes(sobCursor)) return "1…9 responder · ↵ ir · i escrever outra coisa";
  if (padrao) return "↑↓ navegar · ↵ ir · ★ padrão · i escrever";
  return "↑↓ navegar · ↵ ir · ★ escolher o padrão";
}

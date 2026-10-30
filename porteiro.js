/* porteiro.js — login do Bispo na frente do app (e-mail e senha do Supabase)
 *
 * O que faz:
 *  1. Sem login, cobre o app com a tela de entrada.
 *  2. Em toda chamada a /api/ask e /api/sync, entrega ao servidor o "crachá"
 *     do login. O servidor confere o crachá; sem ele, recusa (a IA não é cobrada).
 *  3. Versão na tela, aviso de "Atualizar agora" e o botão manual de atualizar.
 *
 * Uso no index.html, dentro do <head>:
 *   <script src="porteiro.js" data-app="Nome do App" data-versao="1.0"></script>
 * Para proteger outro servidor (ex.: um Worker), acrescente
 *   data-protege="https://nome.eneaspr.workers.dev"   (vários: separados por vírgula)
 * O login ("bispo-auth") é o mesmo dos outros apps pessoais.
 */
(function () {
  "use strict";
  var SUPA_URL = "https://ghjbljypxksubmcsvaig.supabase.co";
  var SUPA_KEY = "sb_publishable_qXCYqg1WdmelY9D1mptZXg_U8NdoKby";
  var eu = document.currentScript;
  var APP = (eu && eu.dataset.app) || "App";
  var VERSAO = (eu && eu.dataset.versao) || "";
  var PROTEGE = ((eu && eu.dataset.protege) || "").split(",").map(function (s) { return s.trim(); }).filter(Boolean);
  function protegido(url) {
    var caminho = "";
    try { var u = new URL(url, location.href); caminho = u.pathname; url = u.href; } catch (e) {}
    if (/^\/api\/(ask|sync)\b/.test(caminho)) return true;
    return PROTEGE.some(function (p) { return url.indexOf(p) === 0; });
  }

  var sb = null, liberar, prontoLogin = new Promise(function (ok) { liberar = ok; });

  function esc(s) { return String(s || "").replace(/[&<>"]/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]; }); }

  /* ---------- aparência da tela de entrada ---------- */
  var css = document.createElement("style");
  css.textContent =
    "#porteiro{position:fixed;inset:0;z-index:2147483000;display:flex;align-items:center;justify-content:center;padding:20px;" +
    "background:linear-gradient(180deg,#16233F,#0B1426);font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif}" +
    "#porteiro form{background:#FFFDF6;color:#1B2438;border-radius:18px;padding:26px 22px;width:100%;max-width:360px;box-shadow:0 12px 40px rgba(0,0,0,.35)}" +
    "#porteiro h1{font-family:Cinzel,Georgia,serif;font-size:20px;text-align:center;color:#16233F;margin:0 0 4px;letter-spacing:.5px}" +
    "#porteiro p{font-size:13px;text-align:center;color:#6B6658;margin:0 0 18px}" +
    "#porteiro label{display:block;font-size:12px;color:#6B6658;margin:10px 0 5px;font-weight:600}" +
    "#porteiro input{width:100%;box-sizing:border-box;border:1px solid #E1DACB;border-radius:10px;padding:12px;font-size:16px;background:#fff;color:#1B2438}" +
    "#porteiro input:focus{outline:2px solid #C9A227;border-color:#C9A227}" +
    "#porteiro button{width:100%;margin-top:18px;padding:13px;border:none;border-radius:11px;background:#16233F;color:#fff;font-size:15px;font-weight:700;cursor:pointer}" +
    "#porteiro button:disabled{opacity:.6}" +
    "#porteiro .erro{color:#B2452F;font-size:13px;text-align:center;min-height:18px;margin-top:10px}" +
    "#porteiro .ver{font-size:11px;text-align:center;color:#9A9384;margin-top:6px}" +
    "#porteiro-aviso{position:fixed;left:12px;right:12px;bottom:calc(env(safe-area-inset-bottom,0px) + 86px);z-index:2147482000;max-width:460px;margin:0 auto;" +
    "background:#16233F;color:#fff;border:1px solid #C9A227;border-radius:14px;padding:12px 14px;display:flex;align-items:center;justify-content:space-between;gap:10px;" +
    "font:14px -apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;box-shadow:0 8px 24px rgba(0,0,0,.35)}" +
    "#porteiro-aviso button{background:#C9A227;color:#16233F;font-weight:700;border:none;border-radius:9px;padding:8px 12px;white-space:nowrap;cursor:pointer}";
  document.head.appendChild(css);

  function mostrarLogin(msg) {
    if (document.getElementById("porteiro")) {
      var e0 = document.getElementById("porteiroErro"); if (e0 && msg) e0.textContent = msg; return;
    }
    var emailSalvo = ""; try { emailSalvo = localStorage.getItem("bispo-email") || ""; } catch (e) {}
    var d = document.createElement("div");
    d.id = "porteiro";
    d.innerHTML =
      '<form autocomplete="on">' +
      "<h1>" + esc(APP) + "</h1><p>Entre com o seu e-mail e senha</p>" +
      '<label for="porteiroEmail">E-mail</label><input id="porteiroEmail" type="email" inputmode="email" autocomplete="username" value="' + esc(emailSalvo) + '">' +
      '<label for="porteiroSenha">Senha</label><input id="porteiroSenha" type="password" autocomplete="current-password">' +
      '<button type="submit" id="porteiroBtn">Entrar</button>' +
      '<div class="erro" id="porteiroErro">' + esc(msg || "") + "</div>" +
      (VERSAO ? '<div class="ver">v' + esc(VERSAO) + "</div>" : "") +
      "</form>";
    (document.body || document.documentElement).appendChild(d);
    d.querySelector("form").addEventListener("submit", function (ev) { ev.preventDefault(); entrar(); });
    setTimeout(function () { var a = document.getElementById(emailSalvo ? "porteiroSenha" : "porteiroEmail"); if (a) a.focus(); }, 60);
  }
  function esconderLogin() { var d = document.getElementById("porteiro"); if (d) d.remove(); }

  async function entrar() {
    var email = document.getElementById("porteiroEmail").value.trim();
    var senha = document.getElementById("porteiroSenha").value;
    var err = document.getElementById("porteiroErro"), btn = document.getElementById("porteiroBtn");
    if (!email || !senha) { err.textContent = "Preencha e-mail e senha."; return; }
    if (!sb) { err.textContent = "Sem conexão. Tente de novo."; return; }
    btn.disabled = true; btn.textContent = "Entrando...";
    var r = await sb.auth.signInWithPassword({ email: email, password: senha });
    btn.disabled = false; btn.textContent = "Entrar";
    if (r.error) { err.textContent = /invalid/i.test(r.error.message || "") ? "E-mail ou senha incorretos." : "Não foi possível entrar. Confira a internet."; return; }
    try { localStorage.setItem("bispo-email", email); } catch (e) {}
    esconderLogin(); liberar();
  }

  async function token() {
    if (!sb) return null;
    try { var r = await sb.auth.getSession(); return (r.data && r.data.session && r.data.session.access_token) || null; }
    catch (e) { return null; }
  }

  /* ---------- entrega o crachá em toda chamada ao servidor ---------- */
  var fetchOriginal = window.fetch.bind(window);
  window.fetch = async function (input, init) {
    var url = typeof input === "string" ? input : (input && input.url) || "";
    if (!protegido(url)) return fetchOriginal(input, init);
    await prontoLogin;
    var t = await token();
    init = Object.assign({}, init || {});
    var h = new Headers(init.headers || (typeof input !== "string" && input.headers) || {});
    if (t) h.set("Authorization", "Bearer " + t);
    init.headers = h;
    var resp = await fetchOriginal(input, init);
    if (resp.status === 401 || resp.status === 403) {
      try { var j = await resp.clone().json(); if (j && j.login) mostrarLogin(j.error || j.erro || "Entre de novo para continuar."); } catch (e) {}
    }
    return resp;
  };

  /* ---------- sair / atualizar ---------- */
  window.porteiroSair = async function () {
    try { if (sb) await sb.auth.signOut(); } catch (e) {}
    location.reload();
  };
  window.porteiroAtualizar = async function () {
    try {
      if ("serviceWorker" in navigator) { var regs = await navigator.serviceWorker.getRegistrations(); await Promise.all(regs.map(function (r) { return r.unregister(); })); }
      if (window.caches) { var ks = await caches.keys(); await Promise.all(ks.map(function (k) { return caches.delete(k); })); }
    } catch (e) {}
    location.replace(location.pathname + "?v=" + Date.now());
  };
  async function verificarVersao() {
    if (!VERSAO) return;
    try {
      var r = await fetchOriginal("index.html?nocache=" + Date.now(), { cache: "no-store" });
      if (!r.ok) return;
      var m = (await r.text()).match(/porteiro\.js[^>]*data-versao="([^"]+)"/);
      if (m && m[1] !== VERSAO && !document.getElementById("porteiro-aviso")) {
        var d = document.createElement("div"); d.id = "porteiro-aviso";
        d.innerHTML = "Nova versão disponível (v" + esc(m[1]) + '). <button type="button">Atualizar agora</button>';
        d.querySelector("button").onclick = window.porteiroAtualizar;
        document.body.appendChild(d);
      }
    } catch (e) {}
  }

  /* ---------- início ---------- */
  function iniciar() {
    if (!window.supabase) { mostrarLogin("Sem conexão. Abra de novo com internet."); return; }
    sb = window.supabase.createClient(SUPA_URL, SUPA_KEY, {
      auth: { storageKey: "bispo-auth", persistSession: true, autoRefreshToken: true }
    });
    sb.auth.getSession().then(function (r) {
      if (r.data && r.data.session) liberar(); else mostrarLogin();
    }).catch(function () { mostrarLogin(); });
  }
  var s = document.createElement("script");
  s.src = "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2";
  s.onload = function () { if (document.body) iniciar(); else document.addEventListener("DOMContentLoaded", iniciar); };
  s.onerror = function () { document.addEventListener("DOMContentLoaded", function () { mostrarLogin("Sem conexão. Abra de novo com internet."); }); if (document.body) mostrarLogin("Sem conexão. Abra de novo com internet."); };
  document.head.appendChild(s);

  document.addEventListener("DOMContentLoaded", function () {
    verificarVersao();
    document.addEventListener("visibilitychange", function () { if (!document.hidden) verificarVersao(); });
    setInterval(verificarVersao, 30 * 60 * 1000);
  });
})();

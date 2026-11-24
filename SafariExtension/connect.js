(() => {
  if (location.origin !== "http://127.0.0.1:49196" || location.pathname !== "/connect") return;
  const ticket = location.hash.slice(1);
  const status = document.getElementById("pair-status");
  const help = document.getElementById("pair-help");
  if (!status || !/^[a-f0-9]{32}$/.test(ticket)) return;
  browser.runtime.sendMessage({type: "kadraj-pair", ticket}).then(result => {
    if (result?.ok || result?.reason === "code") history.replaceState(null, "", location.pathname);
    if (result?.ok) {
      status.textContent = "Kadraj’a bağlandı.";
      if (help) help.textContent = "Bu sekmeyi kapatabilirsiniz.";
    } else if (result?.reason === "code") {
      status.textContent = "Bağlantı isteği geçersiz veya süresi doldu.";
      if (help) help.textContent = "Kadraj menüsünden Safari’ye bağlan’ı tekrar seçin.";
    }
  }).catch(() => {});
})();

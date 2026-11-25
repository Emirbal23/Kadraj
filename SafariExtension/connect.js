(async () => {
  if (location.origin !== "http://127.0.0.1:49196" || location.pathname !== "/connect") return;
  const ticket = location.hash.slice(1);
  const status = document.getElementById("pair-status");
  const help = document.getElementById("pair-help");
  if (!status) return;

  const hasTicket = /^[a-f0-9]{32}$/.test(ticket);
  const send = message => browser.runtime.sendMessage(message).catch(() => null);
  const pairing = hasTicket ? await send({type: "kadraj-pair", ticket}) : null;
  const connected = pairing?.ok || (await send({type: "kadraj-status"}))?.ok;
  if (hasTicket && (connected || pairing?.reason === "code")) {
    history.replaceState(null, "", location.pathname);
  }
  if (connected) {
    status.textContent = "Kadraj’a bağlandı.";
    if (help) help.textContent = "Videonun açık olduğu sekmeye dönebilirsiniz.";
  } else if (pairing?.reason === "code") {
    status.textContent = "Bağlantı isteği geçersiz veya süresi doldu.";
    if (help) help.textContent = "Kadraj menüsünden Safari’ye bağlan’ı tekrar seçin.";
  } else {
    status.textContent = "Kadraj bağlantısı doğrulanamadı.";
    if (help) help.textContent = "Kadraj’ı açın ve menüsünden Safari’ye bağlan’ı tekrar seçin.";
  }
})();

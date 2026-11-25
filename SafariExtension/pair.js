const output = document.querySelector("output");
const button = document.querySelector("button");
let hasLocalAccess = false;

async function connectionTab() {
  const [tab] = await browser.tabs.query({active: true, currentWindow: true}).catch(() => []);
  return tab?.url?.split("#")[0] === kadrajConnect.href ? tab : null;
}

async function checkConnection() {
  const result = await browser.runtime.sendMessage({type: "kadraj-status"}).catch(() => null);
  hasLocalAccess = await browser.permissions.contains({origins: [kadrajOrigin]}).catch(() => false);
  const tab = hasLocalAccess ? await connectionTab() : null;
  output.value = result?.ok
    ? (tab ? "Kadraj’a bağlandı. Videonun açık olduğu sekmeye dönebilirsiniz." : "Kadraj’a bağlandı.")
    : "Mac menü çubuğunda Kadraj → Safari’ye bağlan’ı seçin.";
  button.textContent = hasLocalAccess ? "Bağlantı sekmesini yenile" : "Yerel bağlantıya izin ver";
  button.hidden = hasLocalAccess && !tab;
}

button.addEventListener("click", async () => {
  const access = {origins: [kadrajOrigin]};
  const granted = hasLocalAccess || await browser.permissions.request(access).catch(() => false);
  if (!granted) return;
  const tab = await connectionTab();
  if (tab) await browser.tabs.reload(tab.id).catch(() => {});
  await checkConnection();
});

void checkConnection();

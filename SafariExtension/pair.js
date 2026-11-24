const output = document.querySelector("output");
const button = document.querySelector("button");

async function checkConnection() {
  const result = await browser.runtime.sendMessage({type: "kadraj-status"}).catch(() => null);
  output.value = result?.ok ? "Kadraj’a bağlandı." : "Mac menü çubuğunda Kadraj → Safari’ye bağlan’ı seçin.";
  button.hidden = await browser.permissions.contains({origins: [kadrajOrigin]}).catch(() => false);
}

button.addEventListener("click", async () => {
  const granted = await browser.permissions.request({origins: [kadrajOrigin]}).catch(() => false);
  if (!granted) return;
  const [tab] = await browser.tabs.query({active: true, currentWindow: true}).catch(() => []);
  if (tab?.url?.split("#")[0] === kadrajConnect.href) await browser.tabs.reload(tab.id).catch(() => {});
  await checkConnection();
});

void checkConnection();

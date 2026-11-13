const { app, BrowserWindow, shell, Menu } = require("electron");
const path = require("path");
app.commandLine.appendSwitch("autoplay-policy", "no-user-gesture-required");
function create() {
  Menu.setApplicationMenu(null);
  const w = new BrowserWindow({
    width: 520, height: 920, minWidth: 380, minHeight: 600,
    backgroundColor: "#000000", title: "KI-Start",
    icon: path.join(__dirname, "icon.png"),
    webPreferences: { webSecurity: false, contextIsolation: true }
  });
  w.loadFile(path.join(__dirname, "www", "index.html"));
  w.webContents.setWindowOpenHandler(({ url }) => { shell.openExternal(url); return { action: "deny" }; });
  w.webContents.on("will-navigate", (e, url) => { if (!url.startsWith("file:")) { e.preventDefault(); shell.openExternal(url); } });
}
app.whenReady().then(create);
app.on("window-all-closed", () => app.quit());

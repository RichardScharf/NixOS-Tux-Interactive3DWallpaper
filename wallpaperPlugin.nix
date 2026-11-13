{ config, pkgs, lib, ... }:

let
  defaultWallpaperUrl = "";

  # Offline Three.js r128 fallback in /nix/store
  threeJsLib = builtins.fetchurl {
    url = "https://cdnjs.cloudflare.com/ajax/libs/three.js/r128/three.min.js";
    sha256 = "1qhw5j590xf1q2z9j1dagvxqrakmqwqmsavkdii6hqfrr37bnx4j";
  };

  declarativeWebWallpaperPlugin = pkgs.stdenv.mkDerivation {
    pname = "plasma6-webwallpaper-declarative";
    version = "2.4.0";

    dontUnpack = true;
    dontConfigure = true;
    dontWrapQtApps = true;

    nativeBuildInputs = with pkgs; [
      cmake
      ninja
      kdePackages.qtbase
      kdePackages.qtdeclarative
    ];

    buildInputs = with pkgs; [
      kdePackages.qtbase
      kdePackages.qtdeclarative
    ];

    buildPhase = ''
      mkdir -p src build

      cat << 'EOF' > src/CMakeLists.txt
      cmake_minimum_required(VERSION 3.22)
      project(wallpaperinput LANGUAGES CXX)

      set(CMAKE_CXX_STANDARD 20)
      set(CMAKE_CXX_STANDARD_REQUIRED ON)
      set(CMAKE_AUTOMOC ON)

      find_package(Qt6 REQUIRED COMPONENTS Core Gui Qml Quick DBus)

      add_library(wallpaperinputplugin SHARED wallpaperinput.cpp)
      target_link_libraries(wallpaperinputplugin PRIVATE
          Qt6::Core
          Qt6::Gui
          Qt6::Qml
          Qt6::Quick
          Qt6::DBus
      )
      EOF

      cat << 'EOF' > src/wallpaperinput.cpp
      #include <QCoreApplication>
      #include <QWindow>
      #include <QScreen>
      #include <QEvent>
      #include <QMouseEvent>
      #include <QHoverEvent>
      #include <QWheelEvent>
      #include <QDragMoveEvent>
      #include <QTimer>
      #include <QVariantMap>
      #include <QDBusVariant>
      #include <QtMath>
      #include <QDBusConnection>
      #include <QDBusMessage>
      #include <QDBusPendingCall>
      #include <QDBusPendingReply>
      #include <QQmlExtensionPlugin>
      #include <qqml.h>

      // Singleton hub for:
      // 1. KWin Wayland global cursor positions (workspace.cursorPosChanged)
      // 2. System Power-Save profile state (org.freedesktop.UPower.PowerProfiles / net.hadess.PowerProfiles)
      class KWinCursorReceiver : public QObject {
          Q_OBJECT
          Q_CLASSINFO("D-Bus Interface", "org.nixos.WallpaperInput")

      public:
          static KWinCursorReceiver* instance() {
              static KWinCursorReceiver inst;
              return &inst;
          }

          bool powerSaverActive() const { return m_powerSaverActive; }

          void ensureKWinScriptLoadedAsync(const QString &scriptPath) {
              if (!m_powerSubscribed) {
                  m_powerSubscribed = true;
                  initPowerProfileWatcherAsync();
              }

              if (m_scriptLoaded || scriptPath.isEmpty()) return;
              m_scriptLoaded = true;
              m_scriptPath = scriptPath;

              auto bus = QDBusConnection::sessionBus();
              bus.registerService(QStringLiteral("org.nixos.WallpaperInput"));
              bus.registerObject(QStringLiteral("/CursorBridge"), this, QDBusConnection::ExportScriptableSlots);

              QTimer::singleShot(1500, this, [this]() {
                  auto sbus = QDBusConnection::sessionBus();

                  QDBusMessage unloadMsg = QDBusMessage::createMethodCall(
                      QStringLiteral("org.kde.KWin"),
                      QStringLiteral("/Scripting"),
                      QStringLiteral("org.kde.kwin.Scripting"),
                      QStringLiteral("unloadScript")
                  );
                  unloadMsg << QStringLiteral("nixos_webgl_cursor_bridge");
                  sbus.asyncCall(unloadMsg);

                  QDBusMessage loadMsg = QDBusMessage::createMethodCall(
                      QStringLiteral("org.kde.KWin"),
                      QStringLiteral("/Scripting"),
                      QStringLiteral("org.kde.kwin.Scripting"),
                      QStringLiteral("loadScript")
                  );
                  loadMsg << m_scriptPath << QStringLiteral("nixos_webgl_cursor_bridge");

                  QDBusPendingCall pending = sbus.asyncCall(loadMsg);
                  auto *watcher = new QDBusPendingCallWatcher(pending, this);
                  connect(watcher, &QDBusPendingCallWatcher::finished, this, [sbus](QDBusPendingCallWatcher *w) {
                      w->deleteLater();
                      QDBusPendingReply<int> reply = *w;

                      QDBusMessage startMsg = QDBusMessage::createMethodCall(
                          QStringLiteral("org.kde.KWin"),
                          QStringLiteral("/Scripting"),
                          QStringLiteral("org.kde.kwin.Scripting"),
                          QStringLiteral("start")
                      );
                      sbus.asyncCall(startMsg);

                      if (reply.isValid()) {
                          int id = reply.value();
                          QDBusMessage runMsg = QDBusMessage::createMethodCall(
                              QStringLiteral("org.kde.KWin"),
                              QStringLiteral("/Scripting/Script%1").arg(id),
                              QStringLiteral("org.kde.kwin.Script"),
                              QStringLiteral("run")
                          );
                          sbus.asyncCall(runMsg);
                      }
                  });
              });
          }

      public Q_SLOTS:
          Q_SCRIPTABLE void notifyCursor(int globalX, int globalY) {
              Q_EMIT kwinCursorMoved(static_cast<qreal>(globalX), static_cast<qreal>(globalY));
          }

          void onPowerPropertiesChanged(const QString &iface, const QVariantMap &changed, const QStringList &) {
              Q_UNUSED(iface);
              if (changed.contains(QStringLiteral("ActiveProfile"))) {
                  updateProfileString(changed.value(QStringLiteral("ActiveProfile")).toString());
              }
          }

      Q_SIGNALS:
          void kwinCursorMoved(qreal globalX, qreal globalY);
          void powerSaverActiveChanged(bool active);

      private:
          KWinCursorReceiver() = default;

          void initPowerProfileWatcherAsync() {
              auto sysBus = QDBusConnection::systemBus();

              // Listen for live profile switches from KDE Battery / Power Devil
              sysBus.connect(
                  QStringLiteral("org.freedesktop.UPower.PowerProfiles"),
                  QStringLiteral("/org/freedesktop/UPower/PowerProfiles"),
                  QStringLiteral("org.freedesktop.DBus.Properties"),
                  QStringLiteral("PropertiesChanged"),
                  this,
                  SLOT(onPowerPropertiesChanged(QString,QVariantMap,QStringList))
              );
              sysBus.connect(
                  QStringLiteral("net.hadess.PowerProfiles"),
                  QStringLiteral("/net/hadess/PowerProfiles"),
                  QStringLiteral("org.freedesktop.DBus.Properties"),
                  QStringLiteral("PropertiesChanged"),
                  this,
                  SLOT(onPowerPropertiesChanged(QString,QVariantMap,QStringList))
              );

              queryActiveProfileAsync(
                  QStringLiteral("org.freedesktop.UPower.PowerProfiles"),
                  QStringLiteral("/org/freedesktop/UPower/PowerProfiles"),
                  QStringLiteral("org.freedesktop.UPower.PowerProfiles")
              );
              queryActiveProfileAsync(
                  QStringLiteral("net.hadess.PowerProfiles"),
                  QStringLiteral("/net/hadess/PowerProfiles"),
                  QStringLiteral("net.hadess.PowerProfiles")
              );
          }

          void queryActiveProfileAsync(const QString &service, const QString &path, const QString &iface) {
              QDBusMessage msg = QDBusMessage::createMethodCall(
                  service,
                  path,
                  QStringLiteral("org.freedesktop.DBus.Properties"),
                  QStringLiteral("Get")
              );
              msg << iface << QStringLiteral("ActiveProfile");
              QDBusPendingCall pending = QDBusConnection::systemBus().asyncCall(msg);
              auto *watcher = new QDBusPendingCallWatcher(pending, this);
              connect(watcher, &QDBusPendingCallWatcher::finished, this, [this](QDBusPendingCallWatcher *w) {
                  w->deleteLater();
                  QDBusPendingReply<QDBusVariant> reply = *w;
                  if (reply.isValid()) {
                      updateProfileString(reply.value().variant().toString());
                  }
              });
          }

          void updateProfileString(const QString &profile) {
              if (profile.isEmpty()) return;
              const bool isSaver = (profile == QStringLiteral("power-saver"));
              if (m_powerSaverActive != isSaver) {
                  m_powerSaverActive = isSaver;
                  Q_EMIT powerSaverActiveChanged(m_powerSaverActive);
              }
          }

          bool m_scriptLoaded = false;
          bool m_powerSubscribed = false;
          bool m_powerSaverActive = false;
          QString m_scriptPath;
      };

      // Per-monitor input, screen-geometry, and power-state bridge
      class WallpaperInputBridge : public QObject {
          Q_OBJECT
          Q_PROPERTY(QWindow* targetWindow READ targetWindow WRITE setTargetWindow NOTIFY targetWindowChanged)
          Q_PROPERTY(QRect windowScreenGeometry READ windowScreenGeometry NOTIFY windowScreenGeometryChanged)
          Q_PROPERTY(bool active READ active WRITE setActive NOTIFY activeChanged)
          Q_PROPERTY(bool trackOverWindows READ trackOverWindows WRITE setTrackOverWindows NOTIFY trackOverWindowsChanged)
          Q_PROPERTY(bool independentScreenMouse READ independentScreenMouse WRITE setIndependentScreenMouse NOTIFY independentScreenMouseChanged)
          Q_PROPERTY(bool resetMouseOnLeave READ resetMouseOnLeave WRITE setResetMouseOnLeave NOTIFY resetMouseOnLeaveChanged)
          Q_PROPERTY(bool powerSaverActive READ powerSaverActive NOTIFY powerSaverActiveChanged)
          Q_PROPERTY(QString kwinScriptPath READ kwinScriptPath WRITE setKwinScriptPath NOTIFY kwinScriptPathChanged)

      public:
          explicit WallpaperInputBridge(QObject *parent = nullptr) : QObject(parent) {
              // 60Hz (16ms) coalescing timer so 1000Hz+ mice don't flood QtWebEngine IPC
              m_coalesceTimer.setInterval(16);
              connect(&m_coalesceTimer, &QTimer::timeout, this, &WallpaperInputBridge::flushPendingCursor);

              auto *hub = KWinCursorReceiver::instance();

              connect(hub, &KWinCursorReceiver::powerSaverActiveChanged, this, [this](bool) {
                  Q_EMIT powerSaverActiveChanged();
              });

              connect(hub, &KWinCursorReceiver::kwinCursorMoved, this, [this](qreal gx, qreal gy) {
                  if (!m_active) return;

                  const QRectF sRect = effectiveScreenRect();
                  const bool isInside = sRect.contains(gx, gy);

                  if (isInside) {
                      m_cursorInsideScreen = true;
                      if (m_trackOverWindows) {
                          queueCursor(gx - sRect.x(), gy - sRect.y());
                      }
                  } else {
                      // Cursor is on another monitor!
                      if (m_cursorInsideScreen) {
                          m_cursorInsideScreen = false;
                          if (m_resetMouseOnLeave) {
                              m_hasPendingMove = false;
                              m_coalesceTimer.stop();
                              m_lastX = -99999.0;
                              m_lastY = -99999.0;
                              Q_EMIT cursorResetToCenter();
                              return;
                          }
                      }
                      // Only forward out-of-monitor coordinates if independent mode is disabled
                      if (!m_independentScreenMouse && m_trackOverWindows) {
                          queueCursor(gx - sRect.x(), gy - sRect.y());
                      }
                  }
              });
          }

          ~WallpaperInputBridge() override {
              if (m_targetWindow) {
                  m_targetWindow->removeEventFilter(this);
              }
          }

          QWindow* targetWindow() const { return m_targetWindow; }
          void setTargetWindow(QWindow *w) {
              if (m_targetWindow == w) return;
              if (m_targetWindow) {
                  m_targetWindow->removeEventFilter(this);
                  disconnect(m_targetWindow, nullptr, this, nullptr);
              }
              m_targetWindow = w;
              if (m_targetWindow) {
                  m_targetWindow->installEventFilter(this);
                  connect(m_targetWindow, &QWindow::screenChanged, this, &WallpaperInputBridge::bindScreen);
                  bindScreen(m_targetWindow->screen());
              } else {
                  bindScreen(nullptr);
              }
              Q_EMIT targetWindowChanged();
          }

          QRect windowScreenGeometry() const { return m_windowScreenGeometry; }

          bool active() const { return m_active; }
          void setActive(bool a) {
              if (m_active == a) return;
              m_active = a;
              if (!m_active) {
                  m_coalesceTimer.stop();
                  m_hasPendingMove = false;
              }
              Q_EMIT activeChanged();
          }

          bool trackOverWindows() const { return m_trackOverWindows; }
          void setTrackOverWindows(bool t) {
              if (m_trackOverWindows == t) return;
              m_trackOverWindows = t;
              Q_EMIT trackOverWindowsChanged();
          }

          bool independentScreenMouse() const { return m_independentScreenMouse; }
          void setIndependentScreenMouse(bool ind) {
              if (m_independentScreenMouse == ind) return;
              m_independentScreenMouse = ind;
              Q_EMIT independentScreenMouseChanged();
          }

          bool resetMouseOnLeave() const { return m_resetMouseOnLeave; }
          void setResetMouseOnLeave(bool r) {
              if (m_resetMouseOnLeave == r) return;
              m_resetMouseOnLeave = r;
              Q_EMIT resetMouseOnLeaveChanged();
          }

          bool powerSaverActive() const {
              return KWinCursorReceiver::instance()->powerSaverActive();
          }

          QString kwinScriptPath() const { return m_kwinScriptPath; }
          void setKwinScriptPath(const QString &p) {
              if (m_kwinScriptPath == p) return;
              m_kwinScriptPath = p;
              KWinCursorReceiver::instance()->ensureKWinScriptLoadedAsync(p);
              Q_EMIT kwinScriptPathChanged();
          }

      Q_SIGNALS:
          void targetWindowChanged();
          void windowScreenGeometryChanged();
          void activeChanged();
          void trackOverWindowsChanged();
          void independentScreenMouseChanged();
          void resetMouseOnLeaveChanged();
          void powerSaverActiveChanged();
          void kwinScriptPathChanged();

          void cursorMoved(qreal x, qreal y);
          void cursorResetToCenter();
          void mousePressed(qreal x, qreal y);
          void mouseReleased(qreal x, qreal y);
          void wheelScrolled(qreal x, qreal y, qreal deltaX, qreal deltaY);

      protected:
          bool eventFilter(QObject *watched, QEvent *event) override {
              if (!m_active || watched != m_targetWindow) {
                  return false;
              }

              switch (event->type()) {
                  case QEvent::MouseMove: {
                      auto *me = static_cast<QMouseEvent *>(event);
                      const QPointF p = me->position();
                      m_cursorInsideScreen = true;
                      queueCursor(p.x(), p.y());
                      break;
                  }
                  case QEvent::HoverMove: {
                      auto *he = static_cast<QHoverEvent *>(event);
                      const QPointF p = he->position();
                      m_cursorInsideScreen = true;
                      queueCursor(p.x(), p.y());
                      break;
                  }
                  case QEvent::DragEnter:
                  case QEvent::DragMove: {
                      auto *de = static_cast<QDragMoveEvent *>(event);
                      const QPointF p = de->position();
                      m_cursorInsideScreen = true;
                      queueCursor(p.x(), p.y());
                      break;
                  }
                  case QEvent::Leave:
                  case QEvent::HoverLeave: {
                      // If window-tracking is disabled and cursor leaves the desktop surface,
                      // reset to center if requested
                      if (!m_trackOverWindows && m_resetMouseOnLeave) {
                          m_cursorInsideScreen = false;
                          m_hasPendingMove = false;
                          m_coalesceTimer.stop();
                          Q_EMIT cursorResetToCenter();
                      }
                      break;
                  }
                  case QEvent::MouseButtonPress: {
                      auto *me = static_cast<QMouseEvent *>(event);
                      const QPointF p = me->position();
                      m_cursorInsideScreen = true;
                      if (me->button() == Qt::LeftButton) {
                          Q_EMIT mousePressed(qRound(p.x()), qRound(p.y()));
                      }
                      break;
                  }
                  case QEvent::MouseButtonRelease: {
                      auto *me = static_cast<QMouseEvent *>(event);
                      const QPointF p = me->position();
                      if (me->button() == Qt::LeftButton) {
                          Q_EMIT mouseReleased(qRound(p.x()), qRound(p.y()));
                      }
                      break;
                  }
                  case QEvent::Wheel: {
                      auto *we = static_cast<QWheelEvent *>(event);
                      const QPointF p = we->position();
                      const QPoint delta = we->angleDelta();
                      if (!delta.isNull()) {
                          Q_EMIT wheelScrolled(qRound(p.x()), qRound(p.y()), delta.x(), delta.y());
                      }
                      break;
                  }
                  default:
                      break;
              }

              return false;
          }

      private:
          void bindScreen(QScreen *scr) {
              if (m_boundScreen) {
                  disconnect(m_boundScreen, nullptr, this, nullptr);
              }
              m_boundScreen = scr;
              if (m_boundScreen) {
                  connect(m_boundScreen, &QScreen::geometryChanged, this, &WallpaperInputBridge::updateScreenGeometry);
              }
              updateScreenGeometry();
          }

          void updateScreenGeometry() {
              const QRect nextRect = m_boundScreen ? m_boundScreen->geometry() : QRect();
              if (m_windowScreenGeometry != nextRect) {
                  m_windowScreenGeometry = nextRect;
                  Q_EMIT windowScreenGeometryChanged();
              }
          }

          void queueCursor(qreal lx, qreal ly) {
              const qreal rx = qRound(lx);
              const qreal ry = qRound(ly);
              if (qAbs(rx - m_lastX) < 1.0 && qAbs(ry - m_lastY) < 1.0) {
                  return;
              }
              m_pendingX = rx;
              m_pendingY = ry;
              m_hasPendingMove = true;
              if (!m_coalesceTimer.isActive()) {
                  flushPendingCursor();
                  m_coalesceTimer.start();
              }
          }

          void flushPendingCursor() {
              if (!m_hasPendingMove) {
                  m_coalesceTimer.stop();
                  return;
              }
              m_hasPendingMove = false;
              m_lastX = m_pendingX;
              m_lastY = m_pendingY;
              Q_EMIT cursorMoved(m_lastX, m_lastY);
          }

          QRectF effectiveScreenRect() const {
              if (m_windowScreenGeometry.width() > 0 && m_windowScreenGeometry.height() > 0) {
                  return QRectF(m_windowScreenGeometry);
              }
              if (m_targetWindow && m_targetWindow->screen()) {
                  return QRectF(m_targetWindow->screen()->geometry());
              }
              return QRectF(0, 0, 1920, 1080);
          }

          QWindow *m_targetWindow = nullptr;
          QScreen *m_boundScreen = nullptr;
          QRect m_windowScreenGeometry;
          QTimer m_coalesceTimer;
          bool m_active = true;
          bool m_trackOverWindows = true;
          bool m_independentScreenMouse = true;
          bool m_resetMouseOnLeave = true;
          bool m_cursorInsideScreen = true;
          bool m_hasPendingMove = false;
          QString m_kwinScriptPath;
          qreal m_pendingX = 0.0;
          qreal m_pendingY = 0.0;
          qreal m_lastX = -99999.0;
          qreal m_lastY = -99999.0;
      };

      class WallpaperInputPlugin : public QQmlExtensionPlugin {
          Q_OBJECT
          Q_PLUGIN_METADATA(IID QQmlExtensionInterface_iid)
      public:
          void registerTypes(const char *uri) override {
              qmlRegisterType<WallpaperInputBridge>(uri, 1, 0, "WallpaperInputBridge");
              qmlRegisterType<WallpaperInputBridge>("WallpaperInput", 1, 0, "WallpaperInputBridge");
          }
      };

      #include "wallpaperinput.moc"
      EOF

      cmake -S src -B build -GNinja -DCMAKE_BUILD_TYPE=Release
      ninja -C build
    '';

    installPhase = ''
      pkgDir="$out/share/plasma/wallpapers/org.nixos.webglwallpaper"
      mkdir -p \
        "$pkgDir/contents/ui/WallpaperInput" \
        "$pkgDir/contents/config" \
        "$pkgDir/contents/code"

      # 1. Install compiled QML C++ plugin
      cp build/libwallpaperinputplugin.so "$pkgDir/contents/ui/WallpaperInput/"

      cat << 'EOF' > "$pkgDir/contents/ui/WallpaperInput/qmldir"
      module WallpaperInput
      plugin wallpaperinputplugin
      classname WallpaperInputPlugin
      EOF

      # 2. KWin Wayland Cursor Script (60Hz cap at source)
      cat << 'EOF' > "$pkgDir/contents/code/kwin-cursor-bridge.js"
      var lastX = -99999;
      var lastY = -99999;
      var lastTime = 0;

      function forwardCursor() {
          var now = Date.now();
          if (now - lastTime < 16) return;
          var p = workspace.cursorPos;
          if (!p) return;
          var ix = Math.round(p.x);
          var iy = Math.round(p.y);
          if (ix === lastX && iy === lastY) return;
          lastX = ix;
          lastY = iy;
          lastTime = now;
          callDBus(
              "org.nixos.WallpaperInput",
              "/CursorBridge",
              "org.nixos.WallpaperInput",
              "notifyCursor",
              ix,
              iy
          );
      }

      if (workspace && workspace.cursorPosChanged) {
          workspace.cursorPosChanged.connect(forwardCursor);
          forwardCursor();
      }
      EOF

      # 3. Plasma 6 Wallpaper metadata.json
      cat << 'EOF' > "$pkgDir/metadata.json"
      {
        "KPackageStructure": "Plasma/Wallpaper",
        "KPlugin": {
          "Authors": [
            {
              "Name": "Declarative WebWallpaper"
            }
          ],
          "Category": "Wallpaper",
          "Description": "Hardware-accelerated HTML5/WebGL Wallpaper with Per-Monitor Smart Pause, Power-Save & Mouse Interactivity",
          "Icon": "preferences-desktop-wallpaper",
          "Id": "org.nixos.webglwallpaper",
          "License": "GPL-3.0-or-later",
          "Name": "NixOS WebGL Wallpaper",
          "ServiceTypes": [
            "Plasma/Wallpaper"
          ],
          "Version": "2.4.0"
        },
        "X-KDE-ParentApp": "org.kde.plasmashell",
        "X-Plasma-API-Minimum-Version": "6.0",
        "X-Plasma-MainScript": "ui/main.qml"
      }
      EOF

      # 4. Configuration Schema (contents/config/main.xml)
      cat << 'EOF' > "$pkgDir/contents/config/main.xml"
      <?xml version="1.0" encoding="UTF-8"?>
      <kcfg xmlns="http://www.kde.org/standards/kcfg/1.0"
            xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
            xsi:schemaLocation="http://www.kde.org/standards/kcfg/1.0
            http://www.kde.org/standards/kcfg/1.0/kcfg.xsd" >
        <kcfgfile name=""/>
        <group name="General">
          <entry name="Url" type="String">
            <label>HTML/WebGL Wallpaper URL or File Path</label>
            <default>${defaultWallpaperUrl}</default>
          </entry>
          <entry name="SmartPause" type="Bool">
            <label>Smart Pause on Fullscreen or Maximized Window</label>
            <default>true</default>
          </entry>
          <entry name="PauseOnMaximized" type="Bool">
            <label>Also pause when a window is maximized</label>
            <default>true</default>
          </entry>
          <entry name="PauseOnPowerSave" type="Bool">
            <label>Auto-pause when system Power Save mode is enabled</label>
            <default>true</default>
          </entry>
          <entry name="InteractiveMouse" type="Bool">
            <label>Enable Mouse Position, Click, and Scrollwheel Interactivity</label>
            <default>true</default>
          </entry>
          <entry name="TrackOverWindows" type="Bool">
            <label>Continue tracking mouse while dragging or hovering over windows</label>
            <default>true</default>
          </entry>
          <entry name="IndependentScreenMouse" type="Bool">
            <label>Keep mouse tracking independent per monitor</label>
            <default>true</default>
          </entry>
          <entry name="ResetMouseOnLeave" type="Bool">
            <label>Reset wallpaper mouse to center when cursor moves to another monitor</label>
            <default>true</default>
          </entry>
        </group>
      </kcfg>
      EOF

      # 5. Desktop Settings UI with All Checkboxes (contents/ui/config.qml)
      cat << 'EOF' > "$pkgDir/contents/ui/config.qml"
      import QtQuick
      import QtQuick.Controls as QQC2
      import QtQuick.Dialogs
      import QtQuick.Layouts
      import org.kde.kirigami as Kirigami

      Kirigami.FormLayout {
          id: configRoot

          property string cfg_Url
          property bool cfg_SmartPause
          property bool cfg_PauseOnMaximized
          property bool cfg_PauseOnPowerSave
          property bool cfg_InteractiveMouse
          property bool cfg_TrackOverWindows
          property bool cfg_IndependentScreenMouse
          property bool cfg_ResetMouseOnLeave

          RowLayout {
              Kirigami.FormData.label: "Wallpaper URL / HTML:"
              Layout.fillWidth: true

              QQC2.TextField {
                  id: urlField
                  Layout.fillWidth: true
                  text: configRoot.cfg_Url
                  onTextEdited: configRoot.cfg_Url = text
              }

              QQC2.Button {
                  icon.name: "document-open"
                  text: "Browse..."
                  onClicked: fileDialog.open()
              }
          }

          QQC2.CheckBox {
              Kirigami.FormData.label: "Smart Pause & Power:"
              text: "Freeze WebGL rendering when a fullscreen window covers this monitor"
              checked: configRoot.cfg_SmartPause
              onToggled: configRoot.cfg_SmartPause = checked
          }

          QQC2.CheckBox {
              text: "Also freeze when any window is maximized on this monitor"
              enabled: configRoot.cfg_SmartPause
              checked: configRoot.cfg_PauseOnMaximized
              onToggled: configRoot.cfg_PauseOnMaximized = checked
          }

          QQC2.CheckBox {
              text: "Auto-pause when system Power Save mode is enabled"
              checked: configRoot.cfg_PauseOnPowerSave
              onToggled: configRoot.cfg_PauseOnPowerSave = checked
          }

          QQC2.CheckBox {
              Kirigami.FormData.label: "Mouse Interactivity:"
              text: "Enable mouse hover, left-click, file-drag, and scrollwheel interactivity"
              checked: configRoot.cfg_InteractiveMouse
              onToggled: configRoot.cfg_InteractiveMouse = checked
          }

          QQC2.CheckBox {
              text: "Continue tracking mouse position while dragging or hovering over windows"
              enabled: configRoot.cfg_InteractiveMouse
              checked: configRoot.cfg_TrackOverWindows
              onToggled: configRoot.cfg_TrackOverWindows = checked
          }

          QQC2.CheckBox {
              Kirigami.FormData.label: "Multi-Monitor Behavior:"
              text: "Keep mouse independent per screen (ignore cursor when on other monitors)"
              enabled: configRoot.cfg_InteractiveMouse
              checked: configRoot.cfg_IndependentScreenMouse
              onToggled: configRoot.cfg_IndependentScreenMouse = checked
          }

          QQC2.CheckBox {
              text: "Reset wallpaper mouse to screen center when cursor moves to another monitor"
              enabled: configRoot.cfg_InteractiveMouse
              checked: configRoot.cfg_ResetMouseOnLeave
              onToggled: configRoot.cfg_ResetMouseOnLeave = checked
          }

          FileDialog {
              id: fileDialog
              title: "Select HTML/WebGL Wallpaper File"
              nameFilters: ["HTML files (*.html *.htm)", "All files (*)"]
              onAccepted: {
                  configRoot.cfg_Url = selectedFile.toString()
                  urlField.text = configRoot.cfg_Url
              }
          }
      }
      EOF

      # 6. Main Wallpaper QML (contents/ui/main.qml)
      cat << 'EOF' > "$pkgDir/contents/ui/main.qml"
      import QtQuick
      import QtQuick.Window
      import QtWebEngine
      import org.kde.plasma.plasmoid
      import org.kde.taskmanager as TaskManager
      import "./WallpaperInput"

      WallpaperItem {
          id: root

          readonly property string configuredUrl: root.configuration.Url || "${defaultWallpaperUrl}"
          readonly property bool smartPauseEnabled: root.configuration.SmartPause !== undefined ? root.configuration.SmartPause : true
          readonly property bool pauseOnMaximized: root.configuration.PauseOnMaximized !== undefined ? root.configuration.PauseOnMaximized : true
          readonly property bool pauseOnPowerSave: root.configuration.PauseOnPowerSave !== undefined ? root.configuration.PauseOnPowerSave : true
          readonly property bool interactiveMouse: root.configuration.InteractiveMouse !== undefined ? root.configuration.InteractiveMouse : true
          readonly property bool trackOverWindows: root.configuration.TrackOverWindows !== undefined ? root.configuration.TrackOverWindows : true
          readonly property bool independentScreenMouse: root.configuration.IndependentScreenMouse !== undefined ? root.configuration.IndependentScreenMouse : true
          readonly property bool resetMouseOnLeave: root.configuration.ResetMouseOnLeave !== undefined ? root.configuration.ResetMouseOnLeave : true

          property bool isPaused: false
          property bool pageReady: false

          onPauseOnPowerSaveChanged: pauseEvalTimer.restart()
          onSmartPauseEnabledChanged: pauseEvalTimer.restart()
          onPauseOnMaximizedChanged: pauseEvalTimer.restart()

          // Strictly per-monitor TasksModel using the true QScreen geometry of this DesktopView window
          TaskManager.TasksModel {
              id: tasksModel
              filterByScreen: true
              screenGeometry: inputBridge.windowScreenGeometry
              filterByActivity: true
              filterByVirtualDesktop: true

              onDataChanged: pauseEvalTimer.restart()
              onRowsInserted: pauseEvalTimer.restart()
              onRowsRemoved: pauseEvalTimer.restart()
              onActiveTaskChanged: pauseEvalTimer.restart()
          }

          TaskManager.VirtualDesktopInfo {
              id: virtualDesktopInfo
              onCurrentDesktopChanged: pauseEvalTimer.restart()
          }

          TaskManager.ActivityInfo {
              id: activityInfo
              onCurrentActivityChanged: pauseEvalTimer.restart()
          }

          Timer {
              id: pauseEvalTimer
              interval: 120
              repeat: false
              onTriggered: root.evaluateSmartPause()
          }

          function evaluateSmartPause() {
              // 1. Check Power Save mode first
              if (root.pauseOnPowerSave && inputBridge.powerSaverActive) {
                  root.setWallpaperPaused(true);
                  return;
              }

              // 2. Check Per-Monitor Fullscreen / Maximized windows
              if (!root.smartPauseEnabled) {
                  root.setWallpaperPaused(false);
                  return;
              }

              let shouldPause = false;
              const count = tasksModel.count;

              for (let i = 0; i < count; i++) {
                  const idx = tasksModel.index(i, 0);
                  const isMinimized = tasksModel.data(idx, TaskManager.AbstractTasksModel.IsMinimized);
                  const isHidden = tasksModel.data(idx, TaskManager.AbstractTasksModel.IsHidden);
                  if (isMinimized || isHidden) {
                      continue;
                  }

                  const isFullScreen = tasksModel.data(idx, TaskManager.AbstractTasksModel.IsFullScreen);
                  const isMaximized = tasksModel.data(idx, TaskManager.AbstractTasksModel.IsMaximized);

                  if (isFullScreen || (root.pauseOnMaximized && isMaximized)) {
                      shouldPause = true;
                      break;
                  }
              }

              root.setWallpaperPaused(shouldPause);
          }

          function setWallpaperPaused(pauseState) {
              if (root.isPaused === pauseState) {
                  return;
              }
              root.isPaused = pauseState;

              if (pauseState) {
                  webview.runJavaScript("if (window.__wallpaperSetPaused) window.__wallpaperSetPaused(true);");
                  freezeDelayTimer.restart();
              } else {
                  freezeDelayTimer.stop();
                  webview.lifecycleState = WebEngineView.LifecycleState.Active;
                  webview.runJavaScript("if (window.__wallpaperSetPaused) window.__wallpaperSetPaused(false);");
              }
          }

          Timer {
              id: freezeDelayTimer
              interval: 60
              repeat: false
              onTriggered: {
                  if (root.isPaused) {
                      webview.lifecycleState = WebEngineView.LifecycleState.Frozen;
                  }
              }
          }

          WebEngineView {
              id: webview
              anchors.fill: parent
              url: root.configuredUrl
              backgroundColor: "transparent"

              settings.accelerated2dCanvasEnabled: true
              settings.webGLEnabled: true
              settings.localContentCanAccessRemoteUrls: true
              settings.localContentCanAccessFileUrls: true
              settings.showScrollBars: false

              onContextMenuRequested: function(request) {
                  request.accepted = true;
              }

              onLoadingChanged: function(loadRequest) {
                  if (loadRequest.status === WebEngineView.LoadSucceededStatus) {
                      webview.runJavaScript(`
                          (function() {
                              if (window.__nixosWallpaperBridgeInstalled) return;
                              window.__nixosWallpaperBridgeInstalled = true;

                              if (typeof window.THREE === 'undefined') {
                                  const s = document.createElement('script');
                                  s.src = "file://${threeJsLib}";
                                  s.onload = function() {
                                      const scripts = document.body.querySelectorAll('script:not([src])');
                                      scripts.forEach(sc => { try { eval(sc.textContent); } catch (e) {} });
                                  };
                                  document.head.appendChild(s);
                              }

                              window.__rawRAF = window.requestAnimationFrame.bind(window);
                              window.__pausedCallbacks = [];
                              window.__universalPaused = false;

                              window.requestAnimationFrame = function(cb) {
                                  if (window.__universalPaused) {
                                      window.__pausedCallbacks.push(cb);
                                      return -1;
                                  }
                                  return window.__rawRAF(cb);
                              };

                              window.__wallpaperSetPaused = function(paused) {
                                  window.__universalPaused = paused;
                                  if (!paused && window.__pausedCallbacks.length > 0) {
                                      const queue = window.__pausedCallbacks.splice(0);
                                      queue.forEach(fn => window.__rawRAF(fn));
                                  }
                              };

                              window.__activeRangeSlider = null;

                              function updateSliderAt(slider, clientX) {
                                  const rect = slider.getBoundingClientRect();
                                  if (rect.width <= 0) return;
                                  const ratio = Math.max(0, Math.min(1, (clientX - rect.left) / rect.width));
                                  const min = parseFloat(slider.min || "0");
                                  const max = parseFloat(slider.max || "1");
                                  const step = parseFloat(slider.step || "0.01");
                                  let val = min + ratio * (max - min);
                                  if (step > 0) {
                                      val = Math.round(val / step) * step;
                                  }
                                  slider.value = val;
                                  slider.dispatchEvent(new Event('input', { bubbles: true }));
                                  slider.dispatchEvent(new Event('change', { bubbles: true }));
                              }

                              window.__wallpaperInput = function(type, x, y, dx, dy) {
                                  if (window.__universalPaused) return;

                                  if (type === 'move') {
                                      if (window.__activeRangeSlider) {
                                          updateSliderAt(window.__activeRangeSlider, x);
                                      }
                                      window.dispatchEvent(new MouseEvent('mousemove', {
                                          clientX: x,
                                          clientY: y,
                                          bubbles: true
                                      }));
                                  } else if (type === 'center') {
                                      window.__activeRangeSlider = null;
                                      window.dispatchEvent(new MouseEvent('mousemove', {
                                          clientX: window.innerWidth * 0.5,
                                          clientY: window.innerHeight * 0.5,
                                          bubbles: true
                                      }));
                                  } else if (type === 'down') {
                                      const el = document.elementFromPoint(x, y) || document.body;
                                      if (el && el.tagName === 'INPUT' && el.type === 'range') {
                                          window.__activeRangeSlider = el;
                                          updateSliderAt(el, x);
                                      }
                                      el.dispatchEvent(new MouseEvent('mousedown', {
                                          clientX: x,
                                          clientY: y,
                                          button: 0,
                                          buttons: 1,
                                          bubbles: true
                                      }));
                                  } else if (type === 'up') {
                                      window.__activeRangeSlider = null;
                                      const el = document.elementFromPoint(x, y) || document.body;
                                      el.dispatchEvent(new MouseEvent('mouseup', {
                                          clientX: x,
                                          clientY: y,
                                          button: 0,
                                          buttons: 0,
                                          bubbles: true
                                      }));
                                      el.dispatchEvent(new MouseEvent('click', {
                                          clientX: x,
                                          clientY: y,
                                          button: 0,
                                          bubbles: true
                                      }));
                                  } else if (type === 'wheel') {
                                      window.dispatchEvent(new WheelEvent('wheel', {
                                          clientX: x,
                                          clientY: y,
                                          deltaX: -dx,
                                          deltaY: -dy,
                                          bubbles: true,
                                          cancelable: true
                                      }));
                                  }
                              };
                          })();
                      `);
                      root.pageReady = true;
                      root.evaluateSmartPause();
                  }
              }
          }

          WallpaperInputBridge {
              id: inputBridge
              targetWindow: root.Window.window
              active: root.interactiveMouse && !root.isPaused && root.pageReady
              trackOverWindows: root.trackOverWindows
              independentScreenMouse: root.independentScreenMouse
              resetMouseOnLeave: root.resetMouseOnLeave
              kwinScriptPath: "/run/current-system/sw/share/plasma/wallpapers/org.nixos.webglwallpaper/contents/code/kwin-cursor-bridge.js"

              onWindowScreenGeometryChanged: pauseEvalTimer.restart()
              onPowerSaverActiveChanged: pauseEvalTimer.restart()

              onCursorMoved: function(x, y) {
                  webview.runJavaScript("if (window.__wallpaperInput) window.__wallpaperInput('move'," + x + "," + y + ",0,0);");
              }

              onCursorResetToCenter: function() {
                  webview.runJavaScript("if (window.__wallpaperInput) window.__wallpaperInput('center',0,0,0,0);");
              }

              onMousePressed: function(x, y) {
                  webview.runJavaScript("if (window.__wallpaperInput) window.__wallpaperInput('down'," + x + "," + y + ",0,0);");
              }

              onMouseReleased: function(x, y) {
                  webview.runJavaScript("if (window.__wallpaperInput) window.__wallpaperInput('up'," + x + "," + y + ",0,0);");
              }

              onWheelScrolled: function(x, y, dx, dy) {
                  webview.runJavaScript("if (window.__wallpaperInput) window.__wallpaperInput('wheel'," + x + "," + y + "," + dx + "," + dy + ");");
              }
          }
      }
      EOF
    '';
  };
in
{
  environment.systemPackages = with pkgs; [
    kdePackages.qtwebengine
    declarativeWebWallpaperPlugin
  ];

  environment.sessionVariables = {
    QTWEBENGINE_CHROMIUM_FLAGS = "--ignore-gpu-blocklist --enable-gpu-rasterization --enable-webgl --enable-zero-copy --canvas-oop-rasterization --allow-file-access-from-files";
  };
}

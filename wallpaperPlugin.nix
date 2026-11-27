{ config, pkgs, lib, ... }:

let
  defaultWallpaperUrl = "file:///PATH/TO/YOUR/WALLPAPERfile.html";

  # Offline Three.js r128 fallback in /nix/store
  threeJsLib = builtins.fetchurl {
    url = "https://cdnjs.cloudflare.com/ajax/libs/three.js/r128/three.min.js";
    sha256 = "1qhw5j590xf1q2z9j1dagvxqrakmqwqmsavkdii6hqfrr37bnx4j";
  };

  declarativeWebWallpaperPlugin = pkgs.stdenv.mkDerivation {
    pname = "plasma6-webwallpaper-declarative";
    version = "2.8.2";

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
      #include <QQuickItem>
      #include <QEvent>
      #include <QMouseEvent>
      #include <QHoverEvent>
      #include <QWheelEvent>
      #include <QDragMoveEvent>
      #include <QTimer>
      #include <QFileSystemWatcher>
      #include <QUrl>
      #include <QFileInfo>
      #include <QDir>
      #include <QFile>
      #include <QDateTime>
      #include <QStandardPaths>
      #include <QCryptographicHash>
      #include <QImage>
      #include <QVariant>
      #include <QVariantMap>
      #include <QDBusVariant>
      #include <QtMath>
      #include <QDBusConnection>
      #include <QDBusMessage>
      #include <QDBusPendingCall>
      #include <QDBusPendingReply>
      #include <QQmlExtensionPlugin>
      #include <qqml.h>
      #include <thread>

      class KWinCursorReceiver : public QObject {
          Q_OBJECT
          Q_CLASSINFO("D-Bus Interface", "org.nixos.WallpaperInput")

      public:
          static KWinCursorReceiver* instance() {
              static KWinCursorReceiver inst;
              return &inst;
          }

          bool powerSaverActive() const { return m_powerSaverActive; }
          bool screenLocked() const { return m_screenLocked; }
          bool systemSleeping() const { return m_systemSleeping; }

          void setScriptPath(const QString &scriptPath) {
              if (!scriptPath.isEmpty()) {
                  m_scriptPath = scriptPath;
              }
              initWatchersOnce();
          }

          void updateKWinConsumerCount(int delta) {
              m_activeConsumers = qMax(0, m_activeConsumers + delta);
              m_kwinToggleDebounce.start(300);
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

          void onScreenSaverActiveChanged(bool locked) {
              if (m_screenLocked != locked) {
                  m_screenLocked = locked;
                  Q_EMIT screenLockedChanged(m_screenLocked);
              }
          }

          void onPrepareForSleep(bool sleeping) {
              if (m_systemSleeping != sleeping) {
                  m_systemSleeping = sleeping;
                  Q_EMIT systemSleepingChanged(m_systemSleeping);
              }
              if (!sleeping) {
                  refreshPowerProfileNow();
                  Q_EMIT systemResumed();
              }
          }

      Q_SIGNALS:
          void kwinCursorMoved(qreal globalX, qreal globalY);
          void powerSaverActiveChanged(bool active);
          void screenLockedChanged(bool locked);
          void systemSleepingChanged(bool sleeping);
          void systemResumed();

      private:
          KWinCursorReceiver() {
              m_kwinToggleDebounce.setSingleShot(true);
              connect(&m_kwinToggleDebounce, &QTimer::timeout, this, &KWinCursorReceiver::syncKWinScriptStateAsync);
          }

          void initWatchersOnce() {
              if (m_watchersInitialized) return;
              m_watchersInitialized = true;

              auto sbus = QDBusConnection::sessionBus();
              sbus.registerService(QStringLiteral("org.nixos.WallpaperInput"));
              sbus.registerObject(QStringLiteral("/CursorBridge"), this, QDBusConnection::ExportScriptableSlots);

              sbus.connect(
                  QStringLiteral("org.freedesktop.ScreenSaver"),
                  QStringLiteral("/ScreenSaver"),
                  QStringLiteral("org.freedesktop.ScreenSaver"),
                  QStringLiteral("ActiveChanged"),
                  this,
                  SLOT(onScreenSaverActiveChanged(bool))
              );

              auto sysBus = QDBusConnection::systemBus();
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

              sysBus.connect(
                  QStringLiteral("org.freedesktop.login1"),
                  QStringLiteral("/org/freedesktop/login1"),
                  QStringLiteral("org.freedesktop.login1.Manager"),
                  QStringLiteral("PrepareForSleep"),
                  this,
                  SLOT(onPrepareForSleep(bool))
              );

              refreshPowerProfileNow();
          }

          void refreshPowerProfileNow() {
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

          void syncKWinScriptStateAsync() {
              if (m_scriptPath.isEmpty()) return;
              const bool shouldBeLoaded = (m_activeConsumers > 0);
              if (m_scriptLoaded == shouldBeLoaded) return;
              m_scriptLoaded = shouldBeLoaded;

              auto sbus = QDBusConnection::sessionBus();

              QDBusMessage unloadMsg = QDBusMessage::createMethodCall(
                  QStringLiteral("org.kde.KWin"),
                  QStringLiteral("/Scripting"),
                  QStringLiteral("org.kde.kwin.Scripting"),
                  QStringLiteral("unloadScript")
              );
              unloadMsg << QStringLiteral("nixos_webgl_cursor_bridge");
              sbus.asyncCall(unloadMsg);

              if (!shouldBeLoaded) return;

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

          QTimer m_kwinToggleDebounce;
          int m_activeConsumers = 0;
          bool m_watchersInitialized = false;
          bool m_scriptLoaded = false;
          bool m_powerSaverActive = false;
          bool m_screenLocked = false;
          bool m_systemSleeping = false;
          QString m_scriptPath;
      };

      class WallpaperInputBridge : public QObject {
          Q_OBJECT
          Q_PROPERTY(QWindow* targetWindow READ targetWindow WRITE setTargetWindow NOTIFY targetWindowChanged)
          Q_PROPERTY(QQuickItem* webView READ webView WRITE setWebView NOTIFY webViewChanged)
          Q_PROPERTY(QRect windowScreenGeometry READ windowScreenGeometry NOTIFY windowScreenGeometryChanged)
          Q_PROPERTY(bool active READ active WRITE setActive NOTIFY activeChanged)
          Q_PROPERTY(bool trackOverWindows READ trackOverWindows WRITE setTrackOverWindows NOTIFY trackOverWindowsChanged)
          Q_PROPERTY(bool independentScreenMouse READ independentScreenMouse WRITE setIndependentScreenMouse NOTIFY independentScreenMouseChanged)
          Q_PROPERTY(bool resetMouseOnLeave READ resetMouseOnLeave WRITE setResetMouseOnLeave NOTIFY resetMouseOnLeaveChanged)
          Q_PROPERTY(bool cursorInsideScreen READ cursorInsideScreen NOTIFY cursorInsideScreenChanged)
          Q_PROPERTY(bool powerSaverActive READ powerSaverActive NOTIFY powerSaverActiveChanged)
          Q_PROPERTY(bool screenLocked READ screenLocked NOTIFY screenLockedChanged)
          Q_PROPERTY(bool systemSleeping READ systemSleeping NOTIFY systemSleepingChanged)
          Q_PROPERTY(QString watchedFileUrl READ watchedFileUrl WRITE setWatchedFileUrl NOTIFY watchedFileUrlChanged)
          Q_PROPERTY(bool watchFileChanges READ watchFileChanges WRITE setWatchFileChanges NOTIFY watchFileChangesChanged)
          Q_PROPERTY(QString snapshotUrl READ snapshotUrl NOTIFY snapshotUrlChanged)
          Q_PROPERTY(QString kwinScriptPath READ kwinScriptPath WRITE setKwinScriptPath NOTIFY kwinScriptPathChanged)

      public:
          explicit WallpaperInputBridge(QObject *parent = nullptr) : QObject(parent) {
              m_coalesceTimer.setInterval(16);
              connect(&m_coalesceTimer, &QTimer::timeout, this, &WallpaperInputBridge::flushPendingCursor);

              m_reloadDebounceTimer.setSingleShot(true);
              m_reloadDebounceTimer.setInterval(250);
              connect(&m_reloadDebounceTimer, &QTimer::timeout, this, [this]() {
                  rewatchLocalFile();
                  if (m_watchFileChanges) {
                      Q_EMIT watchedFileModified();
                  }
              });

              connect(&m_fileWatcher, &QFileSystemWatcher::fileChanged, this, [this](const QString &) {
                  m_reloadDebounceTimer.start();
              });

              auto *hub = KWinCursorReceiver::instance();

              connect(hub, &KWinCursorReceiver::powerSaverActiveChanged, this, [this](bool) {
                  Q_EMIT powerSaverActiveChanged();
              });

              connect(hub, &KWinCursorReceiver::screenLockedChanged, this, [this](bool) {
                  Q_EMIT screenLockedChanged();
              });

              connect(hub, &KWinCursorReceiver::systemSleepingChanged, this, [this](bool) {
                  Q_EMIT systemSleepingChanged();
              });

              connect(hub, &KWinCursorReceiver::systemResumed, this, [this]() {
                  Q_EMIT systemResumed();
              });

              connect(hub, &KWinCursorReceiver::kwinCursorMoved, this, [this](qreal gx, qreal gy) {
                  const QRectF sRect = effectiveScreenRect();
                  const bool isInside = sRect.contains(gx, gy);

                  setCursorInsideScreen(isInside);

                  if (!m_active) return;

                  if (isInside) {
                      if (m_desktopHasDirectHover) return;
                      if (m_trackOverWindows) {
                          queueCursor(gx - sRect.x(), gy - sRect.y(), false);
                      }
                  } else {
                      m_desktopHasDirectHover = false;
                      if (m_wasInsideForReset) {
                          m_wasInsideForReset = false;
                          if (m_resetMouseOnLeave) {
                              m_hasPendingMove = false;
                              m_coalesceTimer.stop();
                              m_lastX = -99999.0;
                              m_lastY = -99999.0;
                              const QRectF r = effectiveScreenRect();
                              deliverNativeHover(r.width() * 0.5, r.height() * 0.5);
                              Q_EMIT cursorResetToCenter();
                              return;
                          }
                      }
                      if (!m_independentScreenMouse && m_trackOverWindows) {
                          queueCursor(gx - sRect.x(), gy - sRect.y(), false);
                      }
                  }
              });
          }

          ~WallpaperInputBridge() override {
              updateKWinSubscription(false);
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

          QQuickItem* webView() const { return m_webView; }
          void setWebView(QQuickItem *item) {
              if (m_webView == item) return;
              m_webView = item;
              m_nativeHoverVerified = false;
              m_sentHoverEnter = false;
              Q_EMIT webViewChanged();
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
              syncKWinNeed();
              Q_EMIT activeChanged();
          }

          bool trackOverWindows() const { return m_trackOverWindows; }
          void setTrackOverWindows(bool t) {
              if (m_trackOverWindows == t) return;
              m_trackOverWindows = t;
              syncKWinNeed();
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
              syncKWinNeed();
              Q_EMIT resetMouseOnLeaveChanged();
          }

          bool cursorInsideScreen() const { return m_cursorInsideScreen; }

          bool powerSaverActive() const {
              return KWinCursorReceiver::instance()->powerSaverActive();
          }

          bool screenLocked() const {
              return KWinCursorReceiver::instance()->screenLocked();
          }

          bool systemSleeping() const {
              return KWinCursorReceiver::instance()->systemSleeping();
          }

          QString watchedFileUrl() const { return m_watchedFileUrl; }
          void setWatchedFileUrl(const QString &urlStr) {
              if (m_watchedFileUrl == urlStr) return;
              m_watchedFileUrl = urlStr;
              m_nativeHoverVerified = false;
              m_sentHoverEnter = false;
              rewatchLocalFile();
              updateSnapshotCachePath();
              Q_EMIT watchedFileUrlChanged();
          }

          bool watchFileChanges() const { return m_watchFileChanges; }
          void setWatchFileChanges(bool w) {
              if (m_watchFileChanges == w) return;
              m_watchFileChanges = w;
              rewatchLocalFile();
              Q_EMIT watchFileChangesChanged();
          }

          QString snapshotUrl() const {
              if (!m_snapshotFilePath.isEmpty() && QFileInfo::exists(m_snapshotFilePath) && QFileInfo(m_snapshotFilePath).size() > 0) {
                  return QStringLiteral("file://%1?v=%2").arg(m_snapshotFilePath).arg(m_snapshotVersion);
              }
              return QString();
          }

          QString kwinScriptPath() const { return m_kwinScriptPath; }
          void setKwinScriptPath(const QString &p) {
              if (m_kwinScriptPath == p) return;
              m_kwinScriptPath = p;
              KWinCursorReceiver::instance()->setScriptPath(p);
              syncKWinNeed();
              Q_EMIT kwinScriptPathChanged();
          }

          Q_INVOKABLE void confirmNativeHoverWorking() {
              m_nativeHoverVerified = true;
          }

          Q_INVOKABLE void resetNativeHoverState() {
              m_nativeHoverVerified = false;
              m_sentHoverEnter = false;
          }

          Q_INVOKABLE void saveSnapshotAsync(const QVariant &imageVariant) {
              if (m_snapshotFilePath.isEmpty()) {
                  Q_EMIT snapshotSaved();
                  return;
              }
              QImage img = imageVariant.value<QImage>();
              if (img.isNull() || img.width() < 64 || img.height() < 64) {
                  Q_EMIT snapshotSaved();
                  return;
              }

              if (m_savingSnapshot) {
                  m_queuedSnapshot = img;
                  m_hasQueuedSnapshot = true;
                  return;
              }

              startSnapshotWorker(img);
          }

      Q_SIGNALS:
          void targetWindowChanged();
          void webViewChanged();
          void windowScreenGeometryChanged();
          void activeChanged();
          void trackOverWindowsChanged();
          void independentScreenMouseChanged();
          void resetMouseOnLeaveChanged();
          void cursorInsideScreenChanged();
          void powerSaverActiveChanged();
          void screenLockedChanged();
          void systemSleepingChanged();
          void systemResumed();
          void watchedFileUrlChanged();
          void watchFileChangesChanged();
          void watchedFileModified();
          void snapshotUrlChanged();
          void snapshotSaved();
          void kwinScriptPathChanged();

          void cursorMoved(qreal x, qreal y);
          void probeNativeHover();
          void cursorResetToCenter();
          void mousePressed(qreal x, qreal y);
          void mouseReleased(qreal x, qreal y);
          void wheelScrolled(qreal x, qreal y, qreal deltaX, qreal deltaY);

      protected:
          bool eventFilter(QObject *watched, QEvent *event) override {
              if (watched != m_targetWindow) return false;

              switch (event->type()) {
                  case QEvent::HoverEnter: {
                      m_desktopHasDirectHover = true;
                      setCursorInsideScreen(true);
                      break;
                  }
                  case QEvent::MouseMove: {
                      auto *me = static_cast<QMouseEvent *>(event);
                      const QPointF p = me->position();
                      m_desktopHasDirectHover = true;
                      setCursorInsideScreen(true);
                      if (m_active) queueCursor(p.x(), p.y(), true);
                      break;
                  }
                  case QEvent::HoverMove: {
                      auto *he = static_cast<QHoverEvent *>(event);
                      const QPointF p = he->position();
                      m_desktopHasDirectHover = true;
                      setCursorInsideScreen(true);
                      if (m_active) queueCursor(p.x(), p.y(), true);
                      break;
                  }
                  case QEvent::DragEnter:
                  case QEvent::DragMove: {
                      auto *de = static_cast<QDragMoveEvent *>(event);
                      const QPointF p = de->position();
                      m_desktopHasDirectHover = true;
                      setCursorInsideScreen(true);
                      if (m_active) queueCursor(p.x(), p.y(), true);
                      break;
                  }
                  case QEvent::Leave:
                  case QEvent::HoverLeave: {
                      m_desktopHasDirectHover = false;
                      if (!m_trackOverWindows) {
                          setCursorInsideScreen(false);
                          if (m_resetMouseOnLeave && m_active) {
                              m_hasPendingMove = false;
                              m_coalesceTimer.stop();
                              const QRectF r = effectiveScreenRect();
                              deliverNativeHover(r.width() * 0.5, r.height() * 0.5);
                              Q_EMIT cursorResetToCenter();
                          }
                      }
                      break;
                  }
                  case QEvent::MouseButtonPress: {
                      auto *me = static_cast<QMouseEvent *>(event);
                      const QPointF p = me->position();
                      m_desktopHasDirectHover = true;
                      setCursorInsideScreen(true);
                      if (m_active && me->button() == Qt::LeftButton) {
                          m_isLeftButtonDown = true;
                          Q_EMIT mousePressed(qRound(p.x()), qRound(p.y()));
                      }
                      break;
                  }
                  case QEvent::MouseButtonRelease: {
                      auto *me = static_cast<QMouseEvent *>(event);
                      const QPointF p = me->position();
                      if (me->button() == Qt::LeftButton) {
                          m_isLeftButtonDown = false;
                          if (m_active) {
                              Q_EMIT mouseReleased(qRound(p.x()), qRound(p.y()));
                          }
                      }
                      break;
                  }
                  case QEvent::Wheel: {
                      auto *we = static_cast<QWheelEvent *>(event);
                      const QPointF p = we->position();
                      const QPoint delta = we->angleDelta();
                      if (m_active && !delta.isNull()) {
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
          void startSnapshotWorker(const QImage &img) {
              bool hasVisibleContent = false;
              const int w = img.width();
              const int h = img.height();
              for (int gy = 1; gy <= 16 && !hasVisibleContent; ++gy) {
                  const int py = (h * gy) / 17;
                  for (int gx = 1; gx <= 16; ++gx) {
                      const int px = (w * gx) / 17;
                      const QRgb rgb = img.pixel(px, py);
                      if (qRed(rgb) > 6 || qGreen(rgb) > 6 || qBlue(rgb) > 6) {
                          hasVisibleContent = true;
                          break;
                      }
                  }
              }
              if (!hasVisibleContent) {
                  Q_EMIT snapshotSaved();
                  return;
              }

              m_savingSnapshot = true;
              const QString targetPath = m_snapshotFilePath;

              std::thread([this, img, targetPath]() {
                  QFileInfo fi(targetPath);
                  QDir dir = fi.dir();
                  dir.mkpath(dir.absolutePath());

                  const QString tmpPath = targetPath + QStringLiteral(".tmp.jpg");
                  if (img.save(tmpPath, "JPG", 92)) {
                      QFile::remove(targetPath);
                      QFile::rename(tmpPath, targetPath);
                  }

                  pruneStaleCacheFiles(dir);

                  QMetaObject::invokeMethod(this, [this]() {
                      m_savingSnapshot = false;
                      m_snapshotVersion++;
                      Q_EMIT snapshotUrlChanged();
                      Q_EMIT snapshotSaved();

                      if (m_hasQueuedSnapshot) {
                          QImage next = m_queuedSnapshot;
                          m_queuedSnapshot = QImage();
                          m_hasQueuedSnapshot = false;
                          startSnapshotWorker(next);
                      }
                  }, Qt::QueuedConnection);
              }).detach();
          }

          static void pruneStaleCacheFiles(const QDir &dir) {
              const QFileInfoList tmpFiles = dir.entryInfoList(QStringList() << QStringLiteral("*.tmp.jpg"), QDir::Files);
              for (const QFileInfo &t : tmpFiles) {
                  QFile::remove(t.absoluteFilePath());
              }

              const QFileInfoList snaps = dir.entryInfoList(
                  QStringList() << QStringLiteral("snap_*.jpg"),
                  QDir::Files,
                  QDir::Time
              );
              const QDateTime cutoff = QDateTime::currentDateTimeUtc().addDays(-7);
              for (int i = 0; i < snaps.size(); ++i) {
                  if (i >= 8 || snaps.at(i).lastModified().toUTC() < cutoff) {
                      QFile::remove(snaps.at(i).absoluteFilePath());
                  }
              }
          }

          QQuickItem* findRenderDelegate() const {
              if (!m_webView) return nullptr;
              const auto children = m_webView->childItems();
              for (QQuickItem *child : children) {
                  if (child && child->isVisible() && child->width() > 0 && child->height() > 0) {
                      return child;
                  }
              }
              return nullptr;
          }

          bool deliverNativeHover(qreal lx, qreal ly) {
              QQuickItem *delegate = findRenderDelegate();
              if (!delegate) return false;

              const QPointF pos(lx, ly);
              const QPointF globalPos = effectiveScreenRect().topLeft() + pos;

              if (!m_sentHoverEnter) {
                  m_sentHoverEnter = true;
                  QHoverEvent enterEv(QEvent::HoverEnter, pos, globalPos, QPointF(-1, -1));
                  QCoreApplication::sendEvent(delegate, &enterEv);
              }

              QHoverEvent moveEv(QEvent::HoverMove, pos, globalPos, m_lastNativePos);
              m_lastNativePos = pos;
              return QCoreApplication::sendEvent(delegate, &moveEv);
          }

          void updateSnapshotCachePath() {
              const QString cacheDir = QStandardPaths::writableLocation(QStandardPaths::GenericCacheLocation)
                                       + QStringLiteral("/nixos-webgl-wallpaper");
              const QString screenTag = m_boundScreen
                  ? m_boundScreen->name()
                  : QStringLiteral("%1x%2").arg(m_windowScreenGeometry.width()).arg(m_windowScreenGeometry.height());
              const QByteArray key = (m_watchedFileUrl + QStringLiteral("|") + screenTag).toUtf8();
              const QString hash = QString::fromLatin1(
                  QCryptographicHash::hash(key, QCryptographicHash::Sha256).toHex().left(16)
              );
              const QString nextPath = cacheDir + QStringLiteral("/snap_") + hash + QStringLiteral(".jpg");
              if (m_snapshotFilePath != nextPath) {
                  m_snapshotFilePath = nextPath;
                  m_snapshotVersion++;
                  Q_EMIT snapshotUrlChanged();
              }
          }

          void setCursorInsideScreen(bool inside) {
              if (inside) m_wasInsideForReset = true;
              if (m_cursorInsideScreen != inside) {
                  m_cursorInsideScreen = inside;
                  Q_EMIT cursorInsideScreenChanged();
              }
          }

          void syncKWinNeed() {
              const bool needKWin = !m_kwinScriptPath.isEmpty() && m_active && (m_trackOverWindows || m_resetMouseOnLeave);
              updateKWinSubscription(needKWin);
          }

          void updateKWinSubscription(bool subscribe) {
              if (m_subscribedToKWin == subscribe) return;
              m_subscribedToKWin = subscribe;
              KWinCursorReceiver::instance()->updateKWinConsumerCount(subscribe ? 1 : -1);
          }

          void rewatchLocalFile() {
              const QStringList current = m_fileWatcher.files();
              if (!current.isEmpty()) {
                  m_fileWatcher.removePaths(current);
              }
              if (!m_watchFileChanges || m_watchedFileUrl.isEmpty()) return;

              QUrl url(m_watchedFileUrl);
              const QString localPath = url.isLocalFile() ? url.toLocalFile() : m_watchedFileUrl;
              if (QFileInfo::exists(localPath)) {
                  m_fileWatcher.addPath(localPath);
              }
          }

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
                  updateSnapshotCachePath();
                  Q_EMIT windowScreenGeometryChanged();
              }
          }

          void queueCursor(qreal lx, qreal ly, bool fromDirectDesktop) {
              const qreal rx = qRound(lx);
              const qreal ry = qRound(ly);
              if (qAbs(rx - m_lastX) < 1.0 && qAbs(ry - m_lastY) < 1.0) return;
              m_pendingX = rx;
              m_pendingY = ry;
              m_pendingFromDesktop = fromDirectDesktop;
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

              const bool sentNative = deliverNativeHover(m_lastX, m_lastY);

              if (sentNative && m_nativeHoverVerified && m_pendingFromDesktop && !m_isLeftButtonDown) {
                  return;
              }

              Q_EMIT cursorMoved(m_lastX, m_lastY);

              if (sentNative && !m_nativeHoverVerified && m_pendingFromDesktop && (++m_probeCounter % 8 == 1)) {
                  Q_EMIT probeNativeHover();
              }
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
          QQuickItem *m_webView = nullptr;
          QScreen *m_boundScreen = nullptr;
          QRect m_windowScreenGeometry;
          QTimer m_coalesceTimer;
          QTimer m_reloadDebounceTimer;
          QFileSystemWatcher m_fileWatcher;
          QPointF m_lastNativePos{0.0, 0.0};
          QImage m_queuedSnapshot;
          quint64 m_snapshotVersion = 1;
          int m_probeCounter = 0;
          bool m_active = true;
          bool m_trackOverWindows = true;
          bool m_independentScreenMouse = true;
          bool m_resetMouseOnLeave = true;
          bool m_cursorInsideScreen = true;
          bool m_wasInsideForReset = true;
          bool m_desktopHasDirectHover = false;
          bool m_isLeftButtonDown = false;
          bool m_nativeHoverVerified = false;
          bool m_sentHoverEnter = false;
          bool m_watchFileChanges = true;
          bool m_subscribedToKWin = false;
          bool m_hasPendingMove = false;
          bool m_pendingFromDesktop = false;
          bool m_savingSnapshot = false;
          bool m_hasQueuedSnapshot = false;
          QString m_watchedFileUrl;
          QString m_snapshotFilePath;
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

      cp build/libwallpaperinputplugin.so "$pkgDir/contents/ui/WallpaperInput/"

      cat << 'EOF' > "$pkgDir/contents/ui/WallpaperInput/qmldir"
      module WallpaperInput
      plugin wallpaperinputplugin
      classname WallpaperInputPlugin
      EOF

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
          "Description": "Hardware-accelerated HTML5/WebGL Wallpaper with Seamless Freeze-Frame Continuity, Virtual Clock & Smart Pause",
          "Icon": "preferences-desktop-wallpaper",
          "Id": "org.nixos.webglwallpaper",
          "License": "GPL-3.0-or-later",
          "Name": "NixOS WebGL Wallpaper",
          "ServiceTypes": [
            "Plasma/Wallpaper"
          ],
          "Version": "2.8.2"
        },
        "X-KDE-ParentApp": "org.kde.plasmashell",
        "X-Plasma-API-Minimum-Version": "6.0",
        "X-Plasma-MainScript": "ui/main.qml"
      }
      EOF

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
          <entry name="PauseOnTiledCoverage" type="Bool">
            <label>Also pause when tiled/floating windows cover >=90% of this monitor</label>
            <default>true</default>
          </entry>
          <entry name="PauseOnPowerSave" type="Bool">
            <label>Auto-pause when system Power Save mode or Screen Lock is active</label>
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
          <entry name="FreezeInactiveMonitor" type="Bool">
            <label>Freeze rendering 2s after cursor leaves monitor (wakes instantly on return)</label>
            <default>false</default>
          </entry>
          <entry name="UseSnapshotCache" type="Bool">
            <label>Show cached static screenshot during boot, pause, lock screen, hibernate, and reload</label>
            <default>true</default>
          </entry>
          <entry name="VirtualTimeContinuity" type="Bool">
            <label>Freeze virtual animation clock while paused (seamless physics/shader resume)</label>
            <default>true</default>
          </entry>
          <entry name="AutoReloadOnModify" type="Bool">
            <label>Automatically hot-reload wallpaper when the local HTML file is saved</label>
            <default>true</default>
          </entry>
        </group>
      </kcfg>
      EOF

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
          property bool cfg_PauseOnTiledCoverage
          property bool cfg_PauseOnPowerSave
          property bool cfg_InteractiveMouse
          property bool cfg_TrackOverWindows
          property bool cfg_IndependentScreenMouse
          property bool cfg_ResetMouseOnLeave
          property bool cfg_FreezeInactiveMonitor
          property bool cfg_UseSnapshotCache
          property bool cfg_VirtualTimeContinuity
          property bool cfg_AutoReloadOnModify

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
              text: "Also freeze when tiled/floating windows cover ≥90% of this monitor"
              enabled: configRoot.cfg_SmartPause
              checked: configRoot.cfg_PauseOnTiledCoverage
              onToggled: configRoot.cfg_PauseOnTiledCoverage = checked
          }

          QQC2.CheckBox {
              text: "Auto-pause on system Power Save mode or Screen Lock (Meta+L)"
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

          QQC2.CheckBox {
              text: "Deep-freeze monitor 2s after cursor leaves (wakes instantly on cursor return)"
              enabled: configRoot.cfg_InteractiveMouse && configRoot.cfg_IndependentScreenMouse
              checked: configRoot.cfg_FreezeInactiveMonitor
              onToggled: configRoot.cfg_FreezeInactiveMonitor = checked
          }

          QQC2.CheckBox {
              Kirigami.FormData.label: "Continuity Cache & Live Dev:"
              text: "Use static screenshot shield during boot, pause, lock screen, hibernate & reload (zero black screen)"
              checked: configRoot.cfg_UseSnapshotCache
              onToggled: configRoot.cfg_UseSnapshotCache = checked
          }

          QQC2.CheckBox {
              text: "Freeze virtual animation clock while paused (seamless physics/shader resume; disable for real-time clocks)"
              checked: configRoot.cfg_VirtualTimeContinuity
              onToggled: configRoot.cfg_VirtualTimeContinuity = checked
          }

          QQC2.CheckBox {
              text: "Live hot-reload wallpaper automatically when the local .html file is saved"
              checked: configRoot.cfg_AutoReloadOnModify
              onToggled: configRoot.cfg_AutoReloadOnModify = checked
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
          readonly property bool pauseOnTiledCoverage: root.configuration.PauseOnTiledCoverage !== undefined ? root.configuration.PauseOnTiledCoverage : true
          readonly property bool pauseOnPowerSave: root.configuration.PauseOnPowerSave !== undefined ? root.configuration.PauseOnPowerSave : true
          readonly property bool interactiveMouse: root.configuration.InteractiveMouse !== undefined ? root.configuration.InteractiveMouse : true
          readonly property bool trackOverWindows: root.configuration.TrackOverWindows !== undefined ? root.configuration.TrackOverWindows : true
          readonly property bool independentScreenMouse: root.configuration.IndependentScreenMouse !== undefined ? root.configuration.IndependentScreenMouse : true
          readonly property bool resetMouseOnLeave: root.configuration.ResetMouseOnLeave !== undefined ? root.configuration.ResetMouseOnLeave : true
          readonly property bool freezeInactiveMonitor: root.configuration.FreezeInactiveMonitor !== undefined ? root.configuration.FreezeInactiveMonitor : false
          readonly property bool useSnapshotCache: root.configuration.UseSnapshotCache !== undefined ? root.configuration.UseSnapshotCache : true
          readonly property bool virtualTimeContinuity: root.configuration.VirtualTimeContinuity !== undefined ? root.configuration.VirtualTimeContinuity : true
          readonly property bool autoReloadOnModify: root.configuration.AutoReloadOnModify !== undefined ? root.configuration.AutoReloadOnModify : true

          property bool isPaused: false
          property bool surfacePurgeShieldActive: false
          property bool inactiveMonitorSettled: false
          property bool pageReady: false
          property bool webviewPainted: false

          onConfiguredUrlChanged: {
              root.webviewPainted = false;
              root.pageReady = false;
              inputBridge.resetNativeHoverState();
          }

          onVirtualTimeContinuityChanged: root.syncVirtualTimeMode()
          onPauseOnPowerSaveChanged: pauseEvalTimer.restart()
          onSmartPauseEnabledChanged: pauseEvalTimer.restart()
          onPauseOnMaximizedChanged: pauseEvalTimer.restart()
          onPauseOnTiledCoverageChanged: pauseEvalTimer.restart()
          onFreezeInactiveMonitorChanged: {
              if (!root.freezeInactiveMonitor) {
                  inactiveMonitorSettleTimer.stop();
                  root.inactiveMonitorSettled = false;
              } else if (!inputBridge.cursorInsideScreen) {
                  inactiveMonitorSettleTimer.restart();
              }
              pauseEvalTimer.restart();
          }

          function syncVirtualTimeMode() {
              if (!root.pageReady) return;
              webview.runJavaScript(
                  "if (window.__setVirtualTimeContinuity) window.__setVirtualTimeContinuity(" +
                  (root.virtualTimeContinuity ? "true" : "false") + ");"
              );
          }

          function captureDiskSnapshot() {
              if (!root.useSnapshotCache || !root.pageReady || !root.webviewPainted) return;
              webview.grabToImage(function(result) {
                  if (result && result.image) {
                      inputBridge.saveSnapshotAsync(result.image);
                  }
              });
          }

          function verifyLiveRenderAndReveal() {
              if (!root.pageReady || root.isPaused || inputBridge.systemSleeping || inputBridge.screenLocked) {
                  return;
              }
              webview.lifecycleState = WebEngineView.LifecycleState.Active;
              webview.runJavaScript(
                  "window.__wallpaperResumeAndVerify ? window.__wallpaperResumeAndVerify() : \"ready\"",
                  function(status) {
                      if (status === "reload") {
                          root.webviewPainted = false;
                          root.surfacePurgeShieldActive = true;
                          webview.reload();
                      } else {
                          resumeFramePollTimer.attempts = 0;
                          resumeFramePollTimer.restart();
                      }
                  }
              );
          }

          Timer {
              id: resumeFramePollTimer
              property int attempts: 0
              interval: 50
              repeat: true
              onTriggered: {
                  if (root.isPaused || inputBridge.systemSleeping || inputBridge.screenLocked || !root.pageReady) {
                      resumeFramePollTimer.stop();
                      return;
                  }
                  resumeFramePollTimer.attempts += 1;
                  webview.runJavaScript("Boolean(window.__resumeFramesPainted)", function(painted) {
                      if (painted || resumeFramePollTimer.attempts >= 8) {
                          resumeFramePollTimer.stop();
                          if (!root.isPaused && !inputBridge.systemSleeping && !inputBridge.screenLocked) {
                              root.webviewPainted = true;
                              root.surfacePurgeShieldActive = false;
                              snapshotCaptureTimer.restart();
                          }
                      }
                  });
              }
          }

          Timer {
              id: snapshotCaptureTimer
              interval: 900
              repeat: false
              onTriggered: {
                  if (!root.isPaused) {
                      root.captureDiskSnapshot();
                  }
              }
          }

          Timer {
              id: inactiveMonitorSettleTimer
              interval: 1800
              repeat: false
              onTriggered: {
                  if (root.freezeInactiveMonitor && !inputBridge.cursorInsideScreen) {
                      root.inactiveMonitorSettled = true;
                      root.evaluateSmartPause();
                  }
              }
          }

          function effectiveTasksScreenGeometry() {
              const g = inputBridge.windowScreenGeometry;
              if (g && g.width > 0 && g.height > 0) {
                  return g;
              }
              if (root.width > 0 && root.height > 0) {
                  return Qt.rect(0, 0, root.width, root.height);
              }
              return Qt.rect(0, 0, 1920, 1080);
          }

          TaskManager.TasksModel {
              id: tasksModel
              filterByScreen: true
              screenGeometry: root.effectiveTasksScreenGeometry()
              filterByActivity: true
              filterByVirtualDesktop: true

              onDataChanged: function(topLeft, bottomRight, roles) {
                  if (!roles || roles.length === 0 ||
                      roles.indexOf(TaskManager.AbstractTasksModel.IsFullScreen) !== -1 ||
                      roles.indexOf(TaskManager.AbstractTasksModel.IsMaximized) !== -1 ||
                      roles.indexOf(TaskManager.AbstractTasksModel.IsMinimized) !== -1 ||
                      roles.indexOf(TaskManager.AbstractTasksModel.IsHidden) !== -1 ||
                      roles.indexOf(TaskManager.AbstractTasksModel.IsGroupParent) !== -1 ||
                      roles.indexOf(TaskManager.AbstractTasksModel.Geometry) !== -1) {
                      pauseEvalTimer.restart();
                  }
              }
              onRowsInserted: pauseEvalTimer.restart()
              onRowsRemoved: pauseEvalTimer.restart()
              onModelReset: pauseEvalTimer.restart()
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
              interval: 80
              repeat: false
              onTriggered: root.evaluateSmartPause()
          }

          function isScreenCoveredByTiledWindows(rects, sRect) {
              if (!sRect || sRect.width <= 0 || sRect.height <= 0 || rects.length === 0) {
                  return false;
              }
              const cols = 12;
              const rows = 8;
              const totalCells = cols * rows;
              const cellW = sRect.width / cols;
              const cellH = sRect.height / rows;
              let coveredCells = 0;

              for (let r = 0; r < rows; r++) {
                  const cy = sRect.y + (r + 0.5) * cellH;
                  for (let c = 0; c < cols; c++) {
                      const cx = sRect.x + (c + 0.5) * cellW;
                      for (let i = 0; i < rects.length; i++) {
                          const w = rects[i];
                          if (cx >= w.x && cx <= (w.x + w.width) && cy >= w.y && cy <= (w.y + w.height)) {
                              coveredCells++;
                              break;
                          }
                      }
                  }
              }
              return (coveredCells / totalCells) >= 0.90;
          }

          // Inspects a single QModelIndex and any grouped child windows (e.g. multiple terminal windows)
          function inspectTaskIndex(modelIndex, visibleRects, stateOut) {
              if (!modelIndex || !modelIndex.valid) return;

              const isMinimized = Boolean(tasksModel.data(modelIndex, TaskManager.AbstractTasksModel.IsMinimized));
              const isHidden = Boolean(tasksModel.data(modelIndex, TaskManager.AbstractTasksModel.IsHidden));

              if (!isMinimized && !isHidden) {
                  const isFullScreen = Boolean(tasksModel.data(modelIndex, TaskManager.AbstractTasksModel.IsFullScreen));
                  const isMaximized = Boolean(tasksModel.data(modelIndex, TaskManager.AbstractTasksModel.IsMaximized));

                  if (isFullScreen || (root.pauseOnMaximized && isMaximized)) {
                      stateOut.paused = true;
                  }

                  if (root.pauseOnTiledCoverage) {
                      const geom = tasksModel.data(modelIndex, TaskManager.AbstractTasksModel.Geometry);
                      if (geom && geom.width > 0 && geom.height > 0) {
                          visibleRects.push(geom);
                      }
                  }
              }

              const childCount = tasksModel.rowCount(modelIndex);
              for (let c = 0; c < childCount; c++) {
                  const childIdx = tasksModel.index(c, 0, modelIndex);
                  root.inspectTaskIndex(childIdx, visibleRects, stateOut);
                  if (stateOut.paused) {
                      break;
                  }
              }
          }

          function evaluateSmartPause() {
              if (inputBridge.systemSleeping || inputBridge.screenLocked || (root.pauseOnPowerSave && inputBridge.powerSaverActive)) {
                  root.setWallpaperPaused(true);
                  return;
              }

              if (root.freezeInactiveMonitor && root.inactiveMonitorSettled && !inputBridge.cursorInsideScreen) {
                  root.setWallpaperPaused(true);
                  return;
              }

              if (!root.smartPauseEnabled) {
                  root.setWallpaperPaused(false);
                  return;
              }

              const count = tasksModel.count;
              const visibleRects = [];
              const stateOut = { paused: false };

              for (let i = 0; i < count; i++) {
                  const idx = tasksModel.index(i, 0);
                  root.inspectTaskIndex(idx, visibleRects, stateOut);
                  if (stateOut.paused) {
                      break;
                  }
              }

              let shouldPause = stateOut.paused;
              if (!shouldPause && root.pauseOnTiledCoverage && visibleRects.length >= 2) {
                  shouldPause = root.isScreenCoveredByTiledWindows(visibleRects, root.effectiveTasksScreenGeometry());
              }

              root.setWallpaperPaused(shouldPause);
          }

          function setWallpaperPaused(pauseState) {
              if (root.isPaused === pauseState) return;
              root.isPaused = pauseState;

              if (pauseState) {
                  resumeFramePollTimer.stop();
                  webview.runJavaScript("if (window.__wallpaperSetPaused) window.__wallpaperSetPaused(true);");

                  if (root.useSnapshotCache && root.pageReady && root.webviewPainted) {
                      webview.grabToImage(function(result) {
                          if (result && result.image) {
                              inputBridge.saveSnapshotAsync(result.image);
                          } else if (root.isPaused) {
                              root.surfacePurgeShieldActive = true;
                              freezeDelayTimer.restart();
                          }
                      });
                      pauseFallbackTimer.restart();
                  } else {
                      root.surfacePurgeShieldActive = true;
                      freezeDelayTimer.restart();
                  }
              } else {
                  pauseFallbackTimer.stop();
                  freezeDelayTimer.stop();
                  webview.lifecycleState = WebEngineView.LifecycleState.Active;
                  root.verifyLiveRenderAndReveal();
              }
          }

          Timer {
              id: pauseFallbackTimer
              interval: 120
              repeat: false
              onTriggered: {
                  if (root.isPaused) {
                      root.surfacePurgeShieldActive = true;
                      freezeDelayTimer.restart();
                  }
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
              settings.localStorageEnabled: true
              settings.showScrollBars: false

              onContextMenuRequested: function(request) {
                  request.accepted = true;
              }

              onRenderProcessTerminated: function(terminationStatus, exitCode) {
                  root.webviewPainted = false;
                  root.surfacePurgeShieldActive = true;
                  if (!root.isPaused && !inputBridge.systemSleeping) {
                      webview.reload();
                  }
              }

              onLoadingChanged: function(loadRequest) {
                  if (loadRequest.status === WebEngineView.LoadStartedStatus) {
                      root.webviewPainted = false;
                      inputBridge.resetNativeHoverState();
                      webview.runJavaScript(`
                          (function() {
                              if (typeof window.THREE === "undefined" && !window.__threeInjecting) {
                                  window.__threeInjecting = true;
                                  const s = document.createElement("script");
                                  s.src = "file://${threeJsLib}";
                                  document.head.appendChild(s);
                              }
                          })();
                      `);
                  } else if (loadRequest.status === WebEngineView.LoadSucceededStatus) {
                      webview.runJavaScript(`
                          (function() {
                              if (window.__nixosWallpaperBridgeInstalled) return;
                              window.__nixosWallpaperBridgeInstalled = true;

                              // Offline Three.js r128 fallback & script re-runner if booted without internet
                              if (typeof window.THREE === "undefined" && !window.__threeFallbackStarted) {
                                  window.__threeFallbackStarted = true;
                                  const s = document.createElement("script");
                                  s.src = "file://${threeJsLib}";
                                  s.onload = function() {
                                      const scripts = Array.from(document.querySelectorAll("script:not([src])"));
                                      for (const sc of scripts) {
                                          if (sc.textContent && sc.textContent.indexOf("THREE") !== -1 && sc.textContent.indexOf("__nixosWallpaperBridgeInstalled") === -1) {
                                              try {
                                                  (0, eval)(sc.textContent);
                                                  break;
                                              } catch (e) {}
                                          }
                                      }
                                  };
                                  document.head.appendChild(s);
                              }

                              // Offline fallback SVG for Tux if an external Tux/Linux image URL fails offline
                              const offlineTuxDataUri = "data:image/svg+xml;utf8," + encodeURIComponent(
                                  "<svg xmlns=\\"http://www.w3.org/2000/svg\\" viewBox=\\"0 0 256 256\\">" +
                                  "<ellipse cx=\\"128\\" cy=\\"144\\" rx=\\"68\\" ry=\\"82\\" fill=\\"#111318\\"/>" +
                                  "<ellipse cx=\\"128\\" cy=\\"154\\" rx=\\"46\\" ry=\\"62\\" fill=\\"#f4f5f7\\"/>" +
                                  "<circle cx=\\"128\\" cy=\\"66\\" r=\\"42\\" fill=\\"#111318\\"/>" +
                                  "<ellipse cx=\\"113\\" cy=\\"60\\" rx=\\"8\\" ry=\\"11\\" fill=\\"#ffffff\\"/>" +
                                  "<ellipse cx=\\"143\\" cy=\\"60\\" rx=\\"9\\" ry=\\"12\\" fill=\\"#ffffff\\"/>" +
                                  "<circle cx=\\"115\\" cy=\\"62\\" r=\\"4\\" fill=\\"#090a0d\\"/>" +
                                  "<circle cx=\\"141\\" cy=\\"62\\" r=\\"4.5\\" fill=\\"#090a0d\\"/>" +
                                  "<polygon points=\\"112,76 144,76 128,94\\" fill=\\"#f59e0b\\"/>" +
                                  "<ellipse cx=\\"92\\" cy=\\"224\\" rx=\\"24\\" ry=\\"10\\" fill=\\"#f59e0b\\"/>" +
                                  "<ellipse cx=\\"164\\" cy=\\"224\\" rx=\\"24\\" ry=\\"10\\" fill=\\"#f59e0b\\"/>" +
                                  "</svg>"
                              );

                              window.addEventListener("error", function(ev) {
                                  const target = ev.target;
                                  if (target && target.tagName === "IMG" && !target.dataset.offlineFallbackApplied) {
                                      const srcLower = (target.getAttribute("src") || "").toLowerCase();
                                      const altLower = (target.getAttribute("alt") || "").toLowerCase();
                                      if (srcLower.indexOf("tux") !== -1 || srcLower.indexOf("linux") !== -1 || altLower.indexOf("tux") !== -1 || altLower.indexOf("linux") !== -1) {
                                          target.dataset.offlineFallbackApplied = "1";
                                          target.src = offlineTuxDataUri;
                                      }
                                  }
                              }, true);

                              window.__webglContextLost = false;
                              window.addEventListener("webglcontextlost", function() {
                                  window.__webglContextLost = true;
                              }, true);
                              window.addEventListener("webglcontextrestored", function() {
                                  window.__webglContextLost = false;
                              }, true);

                              window.__lastTrustedMove = 0;
                              window.addEventListener("mousemove", function(e) {
                                  if (e.isTrusted) {
                                      window.__lastTrustedMove = window.__rawPerfNow ? window.__rawPerfNow() : performance.now();
                                  }
                              }, { capture: true, passive: true });

                              window.__rawPerfNow = performance.now.bind(performance);
                              window.__totalPausedDurationMs = 0;
                              window.__pauseStartRawMs = null;
                              window.__virtualTimeContinuity = true;

                              performance.now = function() {
                                  const raw = window.__rawPerfNow();
                                  if (!window.__virtualTimeContinuity) {
                                      return raw;
                                  }
                                  const activePause = (window.__pauseStartRawMs !== null)
                                      ? (raw - window.__pauseStartRawMs)
                                      : 0;
                                  return raw - window.__totalPausedDurationMs - activePause;
                              };

                              window.__setVirtualTimeContinuity = function(enabled) {
                                  const nextState = Boolean(enabled);
                                  if (window.__virtualTimeContinuity === nextState) return;
                                  if (!nextState) {
                                      window.__pauseStartRawMs = null;
                                  } else if (window.__universalPaused) {
                                      window.__pauseStartRawMs = window.__rawPerfNow();
                                  }
                                  window.__virtualTimeContinuity = nextState;
                              };

                              window.__rawRAF = window.requestAnimationFrame.bind(window);
                              window.__pausedCallbacks = [];
                              window.__universalPaused = false;
                              window.__resumeFramesPainted = false;

                              window.requestAnimationFrame = function(cb) {
                                  const wrappedCb = function(rawTimestamp) {
                                      const effectiveTime = window.__virtualTimeContinuity
                                          ? performance.now()
                                          : rawTimestamp;
                                      cb(effectiveTime);
                                  };
                                  if (window.__universalPaused) {
                                      window.__pausedCallbacks.push(wrappedCb);
                                      return -1;
                                  }
                                  return window.__rawRAF(wrappedCb);
                              };

                              window.__wallpaperSetPaused = function(paused) {
                                  if (window.__universalPaused === paused) return;
                                  window.__universalPaused = paused;
                                  if (paused) {
                                      window.__resumeFramesPainted = false;
                                      if (window.__pauseStartRawMs === null) {
                                          window.__pauseStartRawMs = window.__rawPerfNow();
                                      }
                                  } else {
                                      if (window.__pauseStartRawMs !== null) {
                                          if (window.__virtualTimeContinuity) {
                                              window.__totalPausedDurationMs += (window.__rawPerfNow() - window.__pauseStartRawMs);
                                          }
                                          window.__pauseStartRawMs = null;
                                      }
                                      if (window.__pausedCallbacks.length > 0) {
                                          const queue = window.__pausedCallbacks.splice(0);
                                          queue.forEach(fn => window.__rawRAF(fn));
                                      }
                                  }
                              };

                              window.__wallpaperResumeAndVerify = function() {
                                  if (window.__webglContextLost) {
                                      return "reload";
                                  }
                                  const canvases = document.querySelectorAll("canvas");
                                  for (let i = 0; i < canvases.length; i++) {
                                      const c = canvases[i];
                                      if (c.width === 0 || c.height === 0) return "reload";
                                      try {
                                          const gl = c.getContext("webgl2") || c.getContext("webgl");
                                          if (gl && gl.isContextLost()) return "reload";
                                      } catch (e) {}
                                  }
                                  window.__resumeFramesPainted = false;
                                  window.__wallpaperSetPaused(false);
                                  window.dispatchEvent(new Event("resize"));
                                  window.__rawRAF(function() {
                                      window.__rawRAF(function() {
                                          window.__resumeFramesPainted = true;
                                      });
                                  });
                                  return "ok";
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
                                  slider.dispatchEvent(new Event("input", { bubbles: true }));
                                  slider.dispatchEvent(new Event("change", { bubbles: true }));
                              }

                              window.__wM = function(x, y) {
                                  if (window.__universalPaused) return;
                                  if (window.__activeRangeSlider) {
                                      updateSliderAt(window.__activeRangeSlider, x);
                                  }
                                  const nowRaw = window.__rawPerfNow ? window.__rawPerfNow() : performance.now();
                                  if (nowRaw - window.__lastTrustedMove < 24) return;
                                  window.dispatchEvent(new MouseEvent("mousemove", {
                                      clientX: x,
                                      clientY: y,
                                      bubbles: true
                                  }));
                              };

                              window.__wallpaperInput = function(type, x, y, dx, dy) {
                                  if (window.__universalPaused) return;

                                  if (type === "move") {
                                      window.__wM(x, y);
                                  } else if (type === "center") {
                                      window.__activeRangeSlider = null;
                                      window.dispatchEvent(new MouseEvent("mousemove", {
                                          clientX: window.innerWidth * 0.5,
                                          clientY: window.innerHeight * 0.5,
                                          bubbles: true
                                      }));
                                  } else if (type === "down") {
                                      const el = document.elementFromPoint(x, y) || document.body;
                                      if (el && el.tagName === "INPUT" && el.type === "range") {
                                          window.__activeRangeSlider = el;
                                          updateSliderAt(el, x);
                                      }
                                      el.dispatchEvent(new MouseEvent("mousedown", {
                                          clientX: x,
                                          clientY: y,
                                          button: 0,
                                          buttons: 1,
                                          bubbles: true
                                      }));
                                  } else if (type === "up") {
                                      window.__activeRangeSlider = null;
                                      const el = document.elementFromPoint(x, y) || document.body;
                                      el.dispatchEvent(new MouseEvent("mouseup", {
                                          clientX: x,
                                          clientY: y,
                                          button: 0,
                                          buttons: 0,
                                          bubbles: true
                                      }));
                                      el.dispatchEvent(new MouseEvent("click", {
                                          clientX: x,
                                          clientY: y,
                                          button: 0,
                                          bubbles: true
                                      }));
                                  } else if (type === "wheel") {
                                      window.dispatchEvent(new WheelEvent("wheel", {
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
                      root.syncVirtualTimeMode();
                      root.evaluateSmartPause();
                      if (!root.isPaused && !inputBridge.systemSleeping && !inputBridge.screenLocked) {
                          root.verifyLiveRenderAndReveal();
                      } else {
                          root.surfacePurgeShieldActive = true;
                      }
                  }
              }
          }

          Image {
              id: snapshotPlaceholder
              anchors.fill: parent
              z: 10
              source: root.useSnapshotCache ? inputBridge.snapshotUrl : ""
              cache: false
              asynchronous: false
              fillMode: Image.PreserveAspectCrop
              opacity: (root.useSnapshotCache && status === Image.Ready && (!root.webviewPainted || root.surfacePurgeShieldActive || inputBridge.systemSleeping || inputBridge.screenLocked)) ? 1.0 : 0.0
              visible: opacity > 0.005

              Behavior on opacity {
                  NumberAnimation {
                      duration: 160
                      easing.type: Easing.OutCubic
                  }
              }
          }

          WallpaperInputBridge {
              id: inputBridge
              targetWindow: root.Window.window
              webView: webview
              active: root.interactiveMouse && !root.isPaused && root.pageReady
              trackOverWindows: root.trackOverWindows
              independentScreenMouse: root.independentScreenMouse
              resetMouseOnLeave: root.resetMouseOnLeave
              watchedFileUrl: root.configuredUrl
              watchFileChanges: root.autoReloadOnModify
              kwinScriptPath: "/run/current-system/sw/share/plasma/wallpapers/org.nixos.webglwallpaper/contents/code/kwin-cursor-bridge.js"

              onWindowScreenGeometryChanged: pauseEvalTimer.restart()
              onPowerSaverActiveChanged: pauseEvalTimer.restart()

              onScreenLockedChanged: {
                  if (inputBridge.screenLocked) {
                      root.surfacePurgeShieldActive = true;
                      root.evaluateSmartPause();
                  } else {
                      root.evaluateSmartPause();
                      if (!root.isPaused && !inputBridge.systemSleeping) {
                          root.verifyLiveRenderAndReveal();
                      }
                  }
              }

              onSystemSleepingChanged: {
                  if (inputBridge.systemSleeping) {
                      root.webviewPainted = false;
                      root.surfacePurgeShieldActive = true;
                  }
                  pauseEvalTimer.restart();
              }

              onSystemResumed: {
                  root.webviewPainted = false;
                  root.surfacePurgeShieldActive = true;
                  root.evaluateSmartPause();
                  if (!root.isPaused && !inputBridge.screenLocked) {
                      root.verifyLiveRenderAndReveal();
                  }
              }

              onSnapshotSaved: {
                  if (root.isPaused) {
                      pauseFallbackTimer.stop();
                      root.surfacePurgeShieldActive = true;
                      freezeDelayTimer.restart();
                  }
              }

              onWatchedFileModified: {
                  if (root.useSnapshotCache && root.pageReady && root.webviewPainted && !root.isPaused) {
                      webview.grabToImage(function(result) {
                          if (result && result.image) {
                              inputBridge.saveSnapshotAsync(result.image);
                          }
                          root.webviewPainted = false;
                          root.surfacePurgeShieldActive = true;
                          webview.reload();
                      });
                  } else {
                      root.webviewPainted = false;
                      root.surfacePurgeShieldActive = true;
                      webview.reload();
                  }
              }

              onCursorInsideScreenChanged: {
                  if (inputBridge.cursorInsideScreen) {
                      inactiveMonitorSettleTimer.stop();
                      if (root.inactiveMonitorSettled) {
                          root.inactiveMonitorSettled = false;
                          root.evaluateSmartPause();
                      }
                  } else if (root.freezeInactiveMonitor) {
                      inactiveMonitorSettleTimer.restart();
                  }
              }

              onProbeNativeHover: {
                  webview.runJavaScript("Boolean(window.__lastTrustedMove && window.__lastTrustedMove > 0)", function(verified) {
                      if (verified) {
                          inputBridge.confirmNativeHoverWorking();
                      }
                  });
              }

              onCursorMoved: function(x, y) {
                  webview.runJavaScript("window.__wM&&__wM(" + x + "," + y + ");");
              }

              onCursorResetToCenter: function() {
                  webview.runJavaScript("window.__wallpaperInput&&__wallpaperInput(\"center\",0,0,0,0);");
              }

              onMousePressed: function(x, y) {
                  webview.runJavaScript("window.__wallpaperInput&&__wallpaperInput(\"down\"," + x + "," + y + ",0,0);");
              }

              onMouseReleased: function(x, y) {
                  webview.runJavaScript("window.__wallpaperInput&&__wallpaperInput(\"up\"," + x + "," + y + ",0,0);");
              }

              onWheelScrolled: function(x, y, dx, dy) {
                  webview.runJavaScript("window.__wallpaperInput&&__wallpaperInput(\"wheel\"," + x + "," + y + "," + dx + "," + dy + ");");
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

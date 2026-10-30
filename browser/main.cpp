/*
 * quarry-browser — the real site, inside quarry rather than beside it.
 *
 * WHY THIS IS A SEPARATE PROGRAM
 *
 * The app runs under quickshell, which constructs Qt with an EMPTY argument
 * list. Qt WebEngine aborts the whole process when `QCoreApplication` has no
 * arguments — not a QML error a Loader can catch, an abort — so a web view can
 * never live inside quarry's own process. Measured: `Qt.application.arguments`
 * is `[]` there, and instantiating a WebEngineView takes the shell down with
 * it.
 *
 * So the page opens in a window of quarry's own, the way the board already
 * does: same palette, same chrome, launched with a url and nothing else. The
 * WebEngine setup here — initialize before the application exists, the
 * Chromium flags for embedded sign-in and hardware video decode — is lifted
 * from tela, which is the same author's browser and already had these right.
 */
#include <csignal>
#include <unistd.h>

#include <QDir>
#include <QFile>
#include <QGuiApplication>
#include <QSocketNotifier>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QStandardPaths>
#include <QtWebEngineQuick/QtWebEngineQuick>
#include <QUrl>

/*
 * WHERE A DUMP'S ANSWER GOES.
 *
 * `console.log` from QML travels through Qt's logging, which a rule in the
 * environment can filter out entirely — and an answer a caller is parsing
 * must not be something a log setting can silence. So the answer goes to
 * stdout directly, and the reason for a failure to stderr, from here.
 */
class DumpSink : public QObject
{
    Q_OBJECT
public:
    using QObject::QObject;

    Q_INVOKABLE void answer(const QString &text)
    {
        fprintf(stdout, "%s\n", qPrintable(text));
        fflush(stdout);
        QGuiApplication::exit(0);
    }

    Q_INVOKABLE void fail(const QString &why)
    {
        fprintf(stderr, "quarry-browser: %s\n", qPrintable(why));
        fflush(stderr);
        QGuiApplication::exit(1);
    }
};

int main(int argc, char *argv[])
{
    // Before anything else: WebEngine has to be initialised while the process
    // is still single-threaded and before a QGuiApplication exists.
    qputenv("QT_SCALE_FACTOR_ROUNDING_POLICY", "PassThrough");
    if (qEnvironmentVariableIsEmpty("QTWEBENGINE_CHROMIUM_FLAGS")) {
        // Third-party cookies for embedded "sign in with…" flows, and the
        // GPU's own video decoder rather than the CPU's. Both from tela.
        qputenv("QTWEBENGINE_CHROMIUM_FLAGS",
                "--disable-features=ThirdPartyStoragePartitioning,TrackingProtection3pcd "
                "--enable-features=VaapiVideoDecoder,VaapiVideoDecodeLinuxGL,AcceleratedVideoDecodeLinuxGL "
                "--ignore-gpu-blocklist");
    }
    QtWebEngineQuick::initialize();

    /*
     * A SECOND MODE: READ A PAGE, PRINT WHAT IT SAYS, EXIT.
     *
     * Some things a site knows are only true after its JavaScript has run —
     * the video count under a category is drawn by a script, so the API does
     * not publish it and a plain HTTP fetch never sees it. There is now an
     * engine in quarry that can run that script, so a lens can ask a page a
     * question instead of guessing.
     *
     *   quarry-browser --dump <url> --js <file> [--settle <ms>] [--timeout <ms>]
     *
     * Always offscreen: a window belongs to a person opening one, and this is
     * a lens fetching data. Forced here rather than left to the caller, so it
     * cannot land on somebody's screen by being called wrongly.
     */
    QStringList plain;
    QStringList extraTabs;
    int servePort = 0;
    QString jsPath;
    int settleMs = 1200;
    int timeoutMs = 25000;
    bool dump = false;
    for (int i = 1; i < argc; ++i) {
        const QString arg = QString::fromUtf8(argv[i]);
        const auto next = [&]() { return i + 1 < argc ? QString::fromUtf8(argv[++i]) : QString(); };
        if (arg == QStringLiteral("--dump"))
            dump = true;
        else if (arg == QStringLiteral("--js"))
            jsPath = next();
        else if (arg == QStringLiteral("--settle"))
            settleMs = next().toInt();
        else if (arg == QStringLiteral("--timeout"))
            timeoutMs = next().toInt();
        /*
         * A SECOND TAB FROM THE COMMAND LINE.
         *
         * `--tab <url>`, repeatable. A lens opening two related pages at once
         * is the obvious use; the other one is that a tab strip nobody can
         * open two tabs into is a tab strip nobody can test without a
         * keyboard, and this window is tested headless.
         */
        else if (arg == QStringLiteral("--tab"))
            extraTabs << next();
        /*
         * SERVE MODE — A BROWSER QUARRY CAN DRAW ITSELF.
         *
         * quickshell constructs Qt with an empty argument list and Chromium
         * refuses to start without one: measured, not assumed —
         * "FATAL: Argument list is empty, the program name is not passed to
         * QCoreApplication", exit 255. So a web view can never live inside
         * quarry's process, and an in-app browser has to be a page rendered
         * SOMEWHERE ELSE and drawn by quarry.
         *
         * `--serve <port>` is that somewhere else: the page renders into an
         * offscreen surface (no window on anybody's screen) with Chromium's
         * own DevTools protocol listening, which streams the rendered frames
         * as JPEGs and accepts mouse and key events back. quarry connects to
         * it over a WebSocket and draws what comes.
         */
        else if (arg == QStringLiteral("--serve"))
            servePort = next().toInt();
        else
            plain << arg;
    }
    /*
     * A dump opens NO window (see Browser.qml), so it needs no display of its
     * own — but Qt still needs a platform. Where the session has one, it is
     * used with the window simply never shown, because the offscreen platform
     * gives Chromium no surface at all and pages then never finish loading.
     * With no session at all — a cron run, a login shell — offscreen is the
     * only option and is correct.
     */
    if (dump && qEnvironmentVariableIsEmpty("WAYLAND_DISPLAY") && qEnvironmentVariableIsEmpty("DISPLAY"))
        qputenv("QT_QPA_PLATFORM", "offscreen");
    /*
     * A served page renders but is never shown: offscreen always, whatever
     * the session is. It also has to actually RENDER — a hidden window
     * composites nothing and the screencast then delivers no frames, which
     * is the one thing this mode exists to do.
     */
    if (servePort > 0) {
        qputenv("QT_QPA_PLATFORM", "offscreen");
        qputenv("QTWEBENGINE_REMOTE_DEBUGGING", QByteArray::number(servePort));
    }

    QGuiApplication app(argc, argv);
    app.setApplicationName(QStringLiteral("quarry-browser"));
    app.setOrganizationName(QStringLiteral("quarry"));
    app.setDesktopFileName(QStringLiteral("quarry"));

    // The page to open, and optionally what to call the window.
    QString target = !plain.isEmpty() ? plain.at(0) : QStringLiteral("about:blank");
    if (!target.contains(QStringLiteral("://")) && !target.startsWith(QStringLiteral("about:")))
        target.prepend(QStringLiteral("https://"));
    const QString title = plain.size() > 1 ? plain.at(1) : QString();

    // The script to run once the page has settled. Read here so a missing
    // file fails before a browser engine has been started for nothing.
    QString script;
    if (dump) {
        if (jsPath.isEmpty()) {
            script = QStringLiteral("JSON.stringify({title: document.title, url: location.href})");
        } else {
            QFile file(jsPath);
            if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) {
                fprintf(stderr, "quarry-browser: cannot read %s\n", qPrintable(jsPath));
                return 2;
            }
            script = QString::fromUtf8(file.readAll());
        }
    }

    /*
     * WHERE A SESSION LIVES.
     *
     * Without this the window runs off-the-record: every cookie thrown away
     * on close, so signing in to anything is pointless and the third-party
     * cookie flags above have nothing to sign into. One directory, next to
     * the rest of quarry's own data, and the profile in Browser.qml points
     * both its storage and its cache at it.
     */
    const QString dataHome = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation);
    const QString storage = dataHome + QStringLiteral("/quarry/browser");
    QDir().mkpath(storage);
    QDir().mkpath(storage + QStringLiteral("/cache"));

    /*
     * A CLEAN DEATH, SO THE SESSION SURVIVES IT.
     *
     * Chromium writes cookies to its store in batches and flushes the rest on
     * shutdown. Killed outright — a session manager closing the desktop, a
     * terminal being closed — that flush never happens and the sign-in you
     * just did is gone. So SIGTERM and SIGINT ask Qt to quit properly, via a
     * self-pipe because a signal handler may not touch Qt directly.
     */
    static int sigFd[2];
    if (::pipe(sigFd) == 0) {
        auto *notifier = new QSocketNotifier(sigFd[0], QSocketNotifier::Read, &app);
        QObject::connect(notifier, &QSocketNotifier::activated, &app, [] {
            char byte = 0;
            const ssize_t got = ::read(sigFd[0], &byte, 1);
            Q_UNUSED(got);
            QGuiApplication::quit();
        });
        const auto handler = [](int) {
            const char byte = 1;
            const ssize_t put = ::write(sigFd[1], &byte, 1);
            Q_UNUSED(put);
        };
        std::signal(SIGTERM, handler);
        std::signal(SIGINT, handler);
    }

    QQmlApplicationEngine engine;
    DumpSink sink;
    engine.rootContext()->setContextProperty(QStringLiteral("dumpSink"), &sink);
    engine.rootContext()->setContextProperty(QStringLiteral("dumpMode"), dump);
    engine.rootContext()->setContextProperty(QStringLiteral("dumpScript"), script);
    engine.rootContext()->setContextProperty(QStringLiteral("dumpSettle"), settleMs);
    engine.rootContext()->setContextProperty(QStringLiteral("dumpTimeout"), timeoutMs);
    engine.rootContext()->setContextProperty(QStringLiteral("startUrl"), target);
    engine.rootContext()->setContextProperty(QStringLiteral("extraTabs"), extraTabs);
    engine.rootContext()->setContextProperty(QStringLiteral("serveMode"), servePort > 0);
    engine.rootContext()->setContextProperty(QStringLiteral("startTitle"), title);
    engine.rootContext()->setContextProperty(QStringLiteral("storageDir"), storage);
    engine.rootContext()->setContextProperty(
        QStringLiteral("downloadDir"),
        QStandardPaths::writableLocation(QStandardPaths::DownloadLocation));
    /*
     * WHICH Browser.qml, IN WHICH ORDER.
     *
     * The installed copy used to come first, which meant a freshly built
     * binary in a checkout silently ran the QML from the LAST package
     * install — edits appeared to do nothing, and a fix looked like it had
     * failed. So: an explicit override first, then whatever sits beside this
     * binary, and the installed copy last, which is the only one an actual
     * installation has.
     */
    QStringList candidates;
    const QByteArray override = qgetenv("QUARRY_BROWSER_QML");
    if (!override.isEmpty())
        candidates << QString::fromUtf8(override);
    candidates << QCoreApplication::applicationDirPath() + QStringLiteral("/Browser.qml")
               << QStringLiteral(QUARRY_BROWSER_QML)
               << QStringLiteral("/usr/share/quarry/browser/Browser.qml");
    for (const QString &path : candidates) {
        engine.load(QUrl::fromLocalFile(path));
        if (!engine.rootObjects().isEmpty())
            return app.exec();
    }
    qWarning("quarry-browser: could not find Browser.qml (looked in %s)",
             qPrintable(candidates.join(QStringLiteral(", "))));
    return 2;
}

#include "main.moc"

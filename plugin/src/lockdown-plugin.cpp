// Appliance UI/hotkey lockdown plugin.
//
// Disables and hides the Record/Replay Buffer/Virtual Camera/Settings
// widgets from the OBS main window, clears every registered hotkey's key
// bindings (including Start/Stop Streaming - this appliance only needs
// streaming controllable via the UI button and obs-websocket, not a
// physical key combo), and reacts to recording/replay-buffer start as a
// fallback kill-switch. This does NOT replace the other lockdown layers
// (obs-websocket auth, unwritable recording output path) - obs-websocket
// and any other in-process caller still reach
// obs_frontend_recording_start()/etc directly, bypassing the UI and hotkeys
// entirely.
//
// We deliberately use hide()/setEnabled(false), NOT deleteLater(): OBSBasic
// (OBS's main window class) keeps raw pointers to these exact widgets as
// member variables and dereferences them later from its own code - e.g.
// refreshing button state after a profile switch. deleteLater() destroys
// the QObject once the event loop turns over, so the next time OBS's own
// code touches that now-dangling pointer it segfaults with no graceful
// error logged. Observed in testing: switching profiles reliably crashed
// the whole obs process (and therefore the container) until this was
// changed from delete to hide+disable.
//
// Menus are found by visible text via FindTopMenu() rather than objectName,
// since OBS's internal naming conventions vary between releases. Widget
// objectNames are still used for the main-window buttons/actions in
// kActionNames/kButtonNames - if those miss, DumpUI() logs the real names.

#include <obs.h>
#include <obs-module.h>
#include <obs-frontend-api.h>

#include <QMainWindow>
#include <QAction>
#include <QAbstractButton>
#include <QPushButton>
#include <QDockWidget>
#include <QMenu>
#include <QMenuBar>
#include <QString>

OBS_DECLARE_MODULE()
OBS_MODULE_USE_DEFAULT_LOCALE("appliance-lockdown", "en-US")

namespace {

const char *const kActionNames[] = {
	"actionStartRecording",   "actionStopRecording",
	"actionStartReplayBuffer", "actionStopReplayBuffer",
	"actionStartVirtualCam",  "actionStopVirtualCam",
	"action_Settings",        "actionSettings",
	nullptr,
};

const char *const kButtonNames[] = {
	"recordButton", "replayBufferButton", "vcamButton", "settingsButton",
	nullptr,
};

// Help menu: keep only the "Log Files" submenu entry; everything else is hidden.
const char *const kHelpKeepText[] = {
	"log files",
	nullptr,
};

// Within the Log Files submenu: keep only "View Current Log".
const char *const kLogFilesKeepText[] = {
	"view current log",
	nullptr,
};

// Tools menu: keep only the Source Profiler entry (added by a plugin, may not exist).
const char *const kToolsKeepText[] = {
	"source profiler",
	nullptr,
};

// View menu: hide these specific entries; everything else (Scene List Mode,
// Stats, and the checked toolbar/status-bar toggles) stays. Hide-list rather
// than keep-list so we don't accidentally remove the toolbar toggles.
const char *const kViewHideText[] = {
	"reset ui",
	"fullscreen",
	"multiview",
	"always on top",
	nullptr,
};

// Aitum dock: keep only the stream button; everything else (record, replay,
// virtual cam, settings, heart, refresh) is hidden. Matched against each
// button's text() and toolTip() case-insensitively.
const char *const kAitumKeepButtons[] = {
	"stream",
	nullptr,
};

// Diagnostic only: logs the real objectName()/text() of every top-level
// menu, every action inside each menu, and every QPushButton in the main
// window, to the OBS log. Every objectName guessed elsewhere in this file
// has been wrong at least once this session - this replaces guessing with
// ground truth from an actual running instance's log.
void DumpUI(QMainWindow *win)
{
	blog(LOG_INFO, "[appliance-lockdown] ---- UI dump start ----");
	if (QMenuBar *bar = win->menuBar()) {
		for (QAction *topAction : bar->actions()) {
			QMenu *menu = topAction->menu();
			blog(LOG_INFO,
			     "[appliance-lockdown] top-menu objectName=\"%s\" text=\"%s\"",
			     qPrintable(menu ? menu->objectName() : topAction->objectName()),
			     qPrintable(topAction->text()));
			if (!menu)
				continue;
			for (QAction *action : menu->actions()) {
				if (action->isSeparator())
					continue;
				blog(LOG_INFO,
				     "[appliance-lockdown]   item objectName=\"%s\" text=\"%s\"",
				     qPrintable(action->objectName()), qPrintable(action->text()));
			}
		}
	}
	for (QPushButton *btn : win->findChildren<QPushButton *>()) {
		blog(LOG_INFO, "[appliance-lockdown] button objectName=\"%s\" text=\"%s\"",
		     qPrintable(btn->objectName()), qPrintable(btn->text()));
	}
	for (QDockWidget *dock : win->findChildren<QDockWidget *>()) {
		blog(LOG_INFO, "[appliance-lockdown] dock objectName=\"%s\" title=\"%s\"",
		     qPrintable(dock->objectName()), qPrintable(dock->windowTitle()));
		for (QAbstractButton *btn : dock->findChildren<QAbstractButton *>()) {
			blog(LOG_INFO,
			     "[appliance-lockdown]   dock-btn objectName=\"%s\" text=\"%s\" tooltip=\"%s\"",
			     qPrintable(btn->objectName()), qPrintable(btn->text()),
			     qPrintable(btn->toolTip()));
		}
	}
	blog(LOG_INFO, "[appliance-lockdown] ---- UI dump end ----");
}

void RemoveByObjectName(QMainWindow *win, const char *const *names)
{
	for (int i = 0; names[i]; ++i) {
		if (QAction *action = win->findChild<QAction *>(names[i])) {
			action->setEnabled(false);
			action->setVisible(false);
		}
		if (QPushButton *btn = win->findChild<QPushButton *>(names[i])) {
			btn->setEnabled(false);
			btn->setVisible(false);
		}
	}
}

// Finds a top-level menu bar menu by visible text (& accelerators stripped,
// case-insensitive substring match). More robust than findChild<QMenu*>(name)
// because OBS's internal objectName conventions vary between releases
// (e.g. menuFile vs menu_File vs menu_file).
static QMenu *FindTopMenu(QMainWindow *win, const char *titleSubstr)
{
	QMenuBar *bar = win->menuBar();
	if (!bar)
		return nullptr;
	QString needle = QString::fromLatin1(titleSubstr);
	for (QAction *act : bar->actions()) {
		QString title = act->text();
		title.remove('&');
		if (title.contains(needle, Qt::CaseInsensitive))
			return act->menu();
	}
	return nullptr;
}

static void HideAction(QAction *action)
{
	action->setEnabled(false);
	action->setVisible(false);
}

// True if the action's visible text contains any of substrings
// (case-insensitive). The '&' mnemonic markers are stripped first so a marker
// sitting inside a matched span (e.g. "Always on &Top" vs "always on top")
// doesn't break the match.
static bool ActionTextMatches(QAction *action, const char *const *substrings)
{
	QString text = action->text();
	text.remove('&');
	for (int i = 0; substrings[i]; ++i) {
		if (text.contains(QString::fromLatin1(substrings[i]), Qt::CaseInsensitive))
			return true;
	}
	return false;
}

static void HideAllEntries(QMenu *menu)
{
	if (!menu)
		return;
	for (QAction *action : menu->actions())
		HideAction(action);
}

// Inverse of TrimEntries: hides only the actions whose text matches one of
// hideSubstrings, leaving everything else visible.
static void HideEntries(QMenu *menu, const char *const *hideSubstrings)
{
	if (!menu)
		return;
	for (QAction *action : menu->actions()) {
		if (ActionTextMatches(action, hideSubstrings))
			HideAction(action);
	}
}

static void TrimEntries(QMenu *menu, const char *const *keepSubstrings)
{
	if (!menu)
		return;
	for (QAction *action : menu->actions()) {
		if (!ActionTextMatches(action, keepSubstrings))
			HideAction(action);
	}
}

// In every dock whose windowTitle() contains dockTitleSubstr, hides all
// buttons (QPushButton, QToolButton, etc.) except those whose text() or
// toolTip() contains one of keepSubstrings (case-insensitive). Used to
// strip Aitum's record/settings/extra buttons while keeping only stream.
void TrimDockButtons(QMainWindow *win, const char *dockTitleSubstr,
		     const char *const *keepSubstrings)
{
	QString needle = QString::fromLatin1(dockTitleSubstr);
	for (QDockWidget *dock : win->findChildren<QDockWidget *>()) {
		if (!dock->windowTitle().contains(needle, Qt::CaseInsensitive))
			continue;
		for (QAbstractButton *btn : dock->findChildren<QAbstractButton *>()) {
			bool keep = false;
			for (int i = 0; keepSubstrings[i]; ++i) {
				QString sub = QString::fromLatin1(keepSubstrings[i]);
				if (btn->text().contains(sub, Qt::CaseInsensitive) ||
				    btn->toolTip().contains(sub, Qt::CaseInsensitive)) {
					keep = true;
					break;
				}
			}
			if (!keep) {
				btn->setEnabled(false);
				btn->setVisible(false);
			}
		}
	}
}

// obs_enum_hotkeys() walks every hotkey registered in the process, not just
// ones this plugin registered itself, and obs_hotkey_load(id, <empty array>)
// clears a hotkey's key bindings without unregistering the action. We wipe
// every hotkey's bindings unconditionally - including Start/Stop Streaming -
// rather than name-matching for Record/Replay/VirtualCam specifically: this
// appliance only needs streaming controllable via the visible UI button and
// obs-websocket, not a physical keyboard shortcut, and not having to guess
// at OBS's internal hotkey name strings removes a whole class of "did we
// actually match the real name" risk.
bool HotkeyEnumCallback(void *, obs_hotkey_id id, obs_hotkey_t *)
{
	obs_data_array_t *empty = obs_data_array_create();
	obs_hotkey_load(id, empty);
	obs_data_array_release(empty);
	return true; // keep enumerating
}

void DisableAllHotkeys()
{
	obs_enum_hotkeys(HotkeyEnumCallback, nullptr);
}

void OnFrontendEvent(enum obs_frontend_event event, void *)
{
	switch (event) {
	case OBS_FRONTEND_EVENT_FINISHED_LOADING: {
		auto *win = (QMainWindow *)obs_frontend_get_main_window();
		if (!win)
			break;
		DumpUI(win);
		RemoveByObjectName(win, kActionNames);
		RemoveByObjectName(win, kButtonNames);
		// Empty menus entirely (looked up by visible menu bar text)
		HideAllEntries(FindTopMenu(win, "File"));
		HideAllEntries(FindTopMenu(win, "Profile"));
		HideAllEntries(FindTopMenu(win, "Scene Collection"));
		// Tools: keep only Source Profiler (plugin-provided, may not exist)
		TrimEntries(FindTopMenu(win, "Tools"), kToolsKeepText);
		// View: hide Reset UI, Fullscreen, Multiview, Always on Top; keep the rest
		HideEntries(FindTopMenu(win, "View"), kViewHideText);
		// Help: keep only "Log Files" submenu entry, then within it only "View Current Log"
		if (QMenu *help = FindTopMenu(win, "Help")) {
			TrimEntries(help, kHelpKeepText);
			for (QAction *act : help->actions()) {
				if (QMenu *sub = act->menu())
					TrimEntries(sub, kLogFilesKeepText);
			}
		}
		// Aitum dock: keep only the stream button
		TrimDockButtons(win, "aitum", kAitumKeepButtons);
		DisableAllHotkeys();
		break;
	}
	case OBS_FRONTEND_EVENT_RECORDING_STARTING:
		// libobs exposes no veto hook for *_STARTING - this only reacts
		// after the fact. Real prevention is the UI/hotkey removal above
		// plus the unwritable RecFilePath/FilePath baked into basic.ini
		// (seeded from the S3 template by obs-instance-manager), not this
		// callback.
		obs_frontend_recording_stop();
		break;
	case OBS_FRONTEND_EVENT_REPLAY_BUFFER_STARTING:
		obs_frontend_replay_buffer_stop();
		break;
	default:
		break;
	}
}

} // namespace

bool obs_module_load(void)
{
	obs_frontend_add_event_callback(OnFrontendEvent, nullptr);
	return true;
}

void obs_module_unload(void) {}

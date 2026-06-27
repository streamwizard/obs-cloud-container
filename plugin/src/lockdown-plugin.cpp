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
// IMPORTANT: the objectName()s below are best-effort guesses based on
// common OBS Qt widget naming conventions, NOT verified against the actual
// OBS 32.1.2 window-basic-main.ui/.cpp source. Before relying on this in
// production, inspect a running instance's widget tree (e.g. dump
// QObject::findChildren<QWidget*>() names at FINISHED_LOADING into the log)
// and correct this list.

#include <obs.h>
#include <obs-module.h>
#include <obs-frontend-api.h>

#include <QMainWindow>
#include <QAction>
#include <QPushButton>
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
	// "action_Settings", "actionSettings", -- temporarily re-enabled
	nullptr,
};

const char *const kButtonNames[] = {
	"recordButton", "replayBufferButton", "vcamButton",
	// "settingsButton", -- temporarily re-enabled
	nullptr,
};

// Top-level menu-bar menus to hide entirely, including their entry in the
// menu bar itself (not just the items inside). objectName()s are
// best-effort guesses following the same "menuXxx" convention as
// "menuTools" (already confirmed working in testing), not verified
// against the OBS 32.1.2 source.
const char *const kMenusToHide[] = {
	"menuFile",
	"menuProfile",
	nullptr,
};

// Help menu entries whose text contains any of these (case-insensitive)
// are kept; everything else in Help is hidden. We only want to leave a
// way to get at log files for support/debugging - "Help Portal", "Visit
// Website", "Discord", "Check for Updates", "About", etc. all go.
const char *const kHelpKeepText[] = {
	"log",
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

// Hides every entry inside a menu (the menu itself stays in the menu bar,
// just empty/inert). Used for Tools, where we don't want any of OBS's
// bundled tools reachable. setVisible/setEnabled rather than deleteLater
// for the same dangling-pointer reason as above.
void HideAllMenuEntries(QMainWindow *win, const char *menuObjectName)
{
	QMenu *menu = win->findChild<QMenu *>(menuObjectName);
	if (!menu)
		return;
	for (QAction *action : menu->actions()) {
		action->setEnabled(false);
		action->setVisible(false);
	}
}

// Hides a menu's own entry in the menu bar (menuAction()), so the whole
// menu disappears rather than just emptying its contents. Used for
// File/Profile, which this appliance has no legitimate use for at all.
void HideMenuEntirely(QMainWindow *win, const char *menuObjectName)
{
	QMenu *menu = win->findChild<QMenu *>(menuObjectName);
	if (!menu)
		return;
	if (QAction *menuAction = menu->menuAction()) {
		menuAction->setEnabled(false);
		menuAction->setVisible(false);
	}
}

// Hides every entry in a menu except ones whose text contains one of
// keepSubstrings (case-insensitive). Used for Help, to leave only the
// log-files entry reachable.
void TrimMenuKeepingText(QMainWindow *win, const char *menuObjectName,
			  const char *const *keepSubstrings)
{
	QMenu *menu = win->findChild<QMenu *>(menuObjectName);
	if (!menu)
		return;
	for (QAction *action : menu->actions()) {
		bool keep = false;
		for (int i = 0; keepSubstrings[i]; ++i) {
			if (action->text().contains(QString::fromLatin1(keepSubstrings[i]),
						     Qt::CaseInsensitive)) {
				keep = true;
				break;
			}
		}
		if (!keep) {
			action->setEnabled(false);
			action->setVisible(false);
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
		HideAllMenuEntries(win, "menuTools");
		for (int i = 0; kMenusToHide[i]; ++i)
			HideMenuEntirely(win, kMenusToHide[i]);
		TrimMenuKeepingText(win, "menuHelp", kHelpKeepText);
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
